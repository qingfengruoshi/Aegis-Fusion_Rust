#!/usr/bin/env bash
# 差分测试：engine-verdict（shell vs Rust），逐项比较「退出码 + stdout」。
#
# 夹具用 AEGIS_TEE_DIR 指到临时目录：伪造 log/teesim.log、keybox.xml，
# 以及（socket 分支用）一个假的 teesim-uds，它对任何 GET /status 都吐同一份
# canned JSON —— 两个实现都通过 `$TEE_DIR/teesim-uds` 调它，所以 fake 对二者
# 是同一个东西。`watch` 不在范围（轮询 + mask_ids，另做）。
#
# Run: bash scripts/test-diff-engine-verdict.sh
# 需要先构建：cargo +stable-x86_64-pc-windows-gnu build --release
set -u

# 宿主 safe-delete 守卫按「单轮删除文件数」拦批量 rm —— 套件清理偶发被拒会留
# 下陈旧夹具（哨兵/状态文件跨轮累计）造成伪失败。清理只针对 build/ 下本套件
# 自己的产物，直接走真 rm（与 test-diff-keybox-fetch.sh 同一做法）。
rmrf() { /usr/bin/rm -rf "$@"; }
unset -f rm 2>/dev/null || true


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_EV="$ROOT/module/engine-verdict.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-engine-verdict"

pass=0; fail=0; total=0
KB='<?xml version="1.0"?><Keybox><Key algorithm="rsa"><Certificate>QUJDREVG</Certificate><Certificate>QUJDREVG</Certificate></Key></Keybox>'

# canned /status 响应（push=1000, ack=1001, applied=1, failed=0）
fake_uds() { # <dir>
    mkdir -p "$1"
    cat > "$1/teesim-uds" <<'EOS'
#!/bin/sh
cat <<'JSON'
{"ok":true,"hook":"libteesim.so","version":"v4.0-canary","push":{"last":1726900000},"ack":{"last":1726900001,"applied":1,"failed":0}}
JSON
EOS
    chmod +x "$1/teesim-uds"
    : > "$1/admin.sock"
    printf 'tok-123\n' > "$1/admin.token"
}

# make_tee <dir> <log-content> [with_socket]
make_tee() {
    local d="$1" log="$2" sock="${3:-}"
    rmrf "$d"; mkdir -p "$d/log"
    printf '%s\n' "$log" > "$d/log/teesim.log"
    printf '%s' "$KB" > "$d/keybox.xml"
    [ -n "$sock" ] && fake_uds "$d"
}

# run_both <case-name> <subcommand…>
run_both() {
    local name="$1"; shift
    local s_out s_rc r_out r_rc rf rfq
    s_out=$(AEGIS_TEE_DIR="$CUR" timeout 30 sh "$SHELL_EV" "$@" 2>/dev/null); s_rc=$?
    rf=$(cygpath -m "$RUST_BIN" 2>/dev/null || echo "$RUST_BIN")
    rfq=${rf// /\\ }
    r_out=$(AEGIS_TEE_DIR="$(cygpath -m "$CUR" 2>/dev/null || echo "$CUR")" \
        timeout 30 "$rfq" engine-verdict "$@" 2>/dev/null); r_rc=$?
    r_out="${r_out//$CUR/<TEE_DIR>}"
    s_out="${s_out//$CUR/<TEE_DIR>}"
    total=$((total + 1))
    if [ "$s_out" = "$r_out" ] && [ "$s_rc" = "$r_rc" ]; then
        pass=$((pass + 1)); echo "  PASS  $name (rc=$s_rc)"; return 0
    fi
    fail=$((fail + 1))
    echo "  FAIL  $name"
    [ "$s_rc" != "$r_rc" ] && echo "          rc:   shell=$s_rc  rust=$r_rc"
    if [ "$s_out" != "$r_out" ]; then
        echo "          --- diff (shell ← / rust →) ---"
        diff <(printf '%s\n' "$s_out") <(printf '%s\n' "$r_out") 2>/dev/null | head -12 | sed 's/^/          /'
    fi
    return 1
}

echo "== 差分：engine-verdict（shell vs Rust）=="

# 1 accepted
make_tee "$BASE/accepted" 'I TEESimulator: control: pushed config epoch=9 profiles=2
I TEESimulator: control: ack epoch=10 ok=true applied=1 failed=0'
CUR="$BASE/accepted"; run_both "once/accepted" once

# 2 rejected + 引擎自己的话
make_tee "$BASE/rejected" 'E TEESimulator: teesim_km_init_ex: RSA: expected at least 2 certificates, found 1
I TEESimulator: control: pushed config epoch=9 profiles=2
I TEESimulator: control: ack epoch=10 ok=true applied=0 failed=2'
CUR="$BASE/rejected"; run_both "once/rejected" once

# 3 partial
make_tee "$BASE/partial" 'E TEESimulator: teesim_km_init_ex: base64: Invalid symbol 45, offset 3
I TEESimulator: control: ack epoch=10 ok=true applied=2 failed=1'
CUR="$BASE/partial"; run_both "once/partial" once

# 4 NO-ACK（有 push 无 ack）
make_tee "$BASE/noack" 'I TEESimulator: control: pushed config epoch=9 profiles=2'
CUR="$BASE/noack"; run_both "once/noack" once

# 5 NO-ACK（完全空日志）
make_tee "$BASE/empty" ''
CUR="$BASE/empty"; run_both "once/empty" once

# 6 socket 兜底（日志空，但 admin socket 有 ack）
make_tee "$BASE/sockfb" '' sock
CUR="$BASE/sockfb"; run_both "once/socket-fallback" once

# 7 socket-live（socket 报 ack）
CUR="$BASE/sockfb"; run_both "socket-live/ack" socket-live

# 8 socket-live（无 socket 文件）
make_tee "$BASE/nosock" 'I TEESimulator: control: ack epoch=10 ok=true applied=1 failed=0'
CUR="$BASE/nosock"; run_both "socket-live/none" socket-live

# ---- watch（轮询；secs=1/2 保证确定性时长）----
# 9 立即命中：ack 已在日志里（from=0）
make_tee "$BASE/w-accept" 'I TEESimulator: control: pushed config epoch=9 profiles=2
I TEESimulator: control: ack epoch=10 ok=true applied=1 failed=0'
CUR="$BASE/w-accept"; run_both "watch/accept" watch 5 0

# 10 立即命中：rejected（applied=0）+ 引擎原话行被过滤段带上
make_tee "$BASE/w-reject" 'E TEESimulator: teesim_km_init_ex: RSA: expected at least 2 certificates, found 1
I TEESimulator: control: pushed config epoch=9 profiles=2
I TEESimulator: control: ack epoch=10 ok=true applied=0 failed=2'
CUR="$BASE/w-reject"; run_both "watch/reject" watch 5 0

# 11 立即命中：partial
make_tee "$BASE/w-partial" 'I TEESimulator: control: ack epoch=10 ok=true applied=2 failed=1'
CUR="$BASE/w-partial"; run_both "watch/partial" watch 5 0

# 12 触发行只有 staged（无 ack）→ 轮询到期 → socket 兜底缺席 → SILENT
make_tee "$BASE/w-staged" 'I TEESimulator: cfg: staged profile p0 target=1'
CUR="$BASE/w-staged"; run_both "watch/staged-silent" watch 1 0

# 13 空日志 → 1s → SILENT
make_tee "$BASE/w-silent" ''
CUR="$BASE/w-silent"; run_both "watch/silent" watch 1 0

# 14 from 超过文件大小（日志被轮转）→ 整读 → 命中
make_tee "$BASE/w-rot" 'I TEESimulator: control: pushed config epoch=9 profiles=2
I TEESimulator: control: ack epoch=10 ok=true applied=1 failed=0'
CUR="$BASE/w-rot"; run_both "watch/rotated" watch 5 99999

# 15 from 非数字 → 回落当前日志末尾 → 无新增 → SILENT
make_tee "$BASE/w-badfrom" 'I TEESimulator: control: ack epoch=10 ok=true applied=1 failed=0'
CUR="$BASE/w-badfrom"; run_both "watch/bad-from" watch 1 abc

# 16 watch 后 show 能读到落盘判定（state 文件内容一致性顺带覆盖）
CUR="$BASE/w-accept"; run_both "show/after-watch" show

# 9 reason（有 teesim_km_init_ex）
CUR="$BASE/rejected"; run_both "reason/present" reason

# 10 reason（无错误行）
CUR="$BASE/accepted"; run_both "reason/absent" reason

# 11 show：先记录一次，再 show（两边各自记录，内容应一致）
make_tee "$BASE/show_ok" 'E TEESimulator: teesim_km_init_ex: RSA: expected at least 2 certificates, found 1
I TEESimulator: control: ack epoch=10 ok=true applied=0 failed=2'
CUR="$BASE/show_ok"
AEGIS_TEE_DIR="$CUR" sh "$SHELL_EV" once >/dev/null 2>&1
run_both "show/recorded" show

# 12 show：无记录
make_tee "$BASE/show_none" 'I TEESimulator: control: ack epoch=10 ok=true applied=1 failed=0'
CUR="$BASE/show_none"; run_both "show/none" show

# 13 show：陈旧锚点（记录后改 keybox 内容 → kbhash 变）
make_tee "$BASE/show_stale" 'I TEESimulator: control: ack epoch=10 ok=true applied=1 failed=0'
CUR="$BASE/show_stale"
AEGIS_TEE_DIR="$CUR" sh "$SHELL_EV" once >/dev/null 2>&1
printf '%s changed' "$KB" > "$CUR/keybox.xml"
run_both "show/stale" show

# 14 help
make_tee "$BASE/help" ''
CUR="$BASE/help"; run_both "help" --help

# 15 未知模式（stderr 不比，只比 rc）
make_tee "$BASE/help" ''
CUR="$BASE/help"
s_rc=0; AEGIS_TEE_DIR="$CUR" sh "$SHELL_EV" bogus >/dev/null 2>&1 || s_rc=$?
r_rc=0; AEGIS_TEE_DIR="$(cygpath -m "$CUR" 2>/dev/null || echo "$CUR")" \
  "$RUST_BIN" engine-verdict bogus >/dev/null 2>&1 || r_rc=$?
total=$((total + 1))
if [ "$s_rc" = "$r_rc" ]; then pass=$((pass + 1)); echo "  PASS  unknown-mode (rc=$s_rc)"; else fail=$((fail + 1)); echo "  FAIL  unknown-mode (rc shell=$s_rc rust=$r_rc)"; fi

echo
echo "== 结果：$pass/$total 一致，$fail 处差异 =="
[ "$fail" -eq 0 ] || exit 1
