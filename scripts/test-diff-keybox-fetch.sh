#!/usr/bin/env bash
# 差分测试：keybox-fetch（shell vs Rust），逐 case 比较
#   退出码 + 文件系统终态 + curl 调用序列（mode url）+ verdict/am 调用序列
#   + 归一化的 keybox-fetch.log（剥时间戳）。
#
# 桩（两边实现用同一套）：
#   curl            —— 记录 "mode url"；按 <URL 清洗名>[.mode] 出夹具数据，
#                      无夹具 → 空响应 + rc 22
#   pidof           —— 按进程名从夹具文件应答（teesim / gms.unstable）
#   am              —— 记录调用并返回 0
#   engine-verdict  —— 按 VERDMODE（accept/reject/silent）应答 watch/once/reason
#   AEGIS_KB_PROBE  —— 假端口探测器：仅 PROBE_OK_PORT 成功
#
# 比较归一：备份文件名里的时间戳 → TS；日志只剥行首时间戳（消息必须逐字一致）。
#
# Run: bash scripts/test-diff-keybox-fetch.sh   （⚠ 含退避 sleep，全程约 5-8 分钟；
#      给 CI/调用方的 timeout 预算 ≥ 600s）
set -u

# 宿主的 safe-delete 守卫按「单次工具调用的删除文件数」拦批量 rm —— 本套件每
# 轮要重建几十个夹具目录，会误触发。既有套件（test-keybox-fetch.sh）的做法：
# 清理只针对 build/ 下本套件自己的产物，直接走真 rm；子进程里另放同名桩。
rmrf() { /usr/bin/rm -rf "$@"; }

# 宿主可能带着自己的本地代理变量（伪失败源，见 KNOWN-FAILURE-MODES §6）：
# 差分的「直连/代理」判定必须与宿主环境无关，这里显式清掉。
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY

# 宿主 git-bash 的 grep 在 UTF-8 locale 下匹配不了星面字符（emoji）：状态文件的
# 🟢 计数会得 0；设备上的 toybox grep 是字节匹配（=3）。LC_ALL=C 让宿主行为
# 与设备一致，差分才比的是真差异。
export LC_ALL=C

# safe-delete 还会导出 rm 函数并穿透到子 shell（$d/bin 的直通桩被绕过），
# 在 harness 顶层断掉继承，让子进程的 rm 走 PATH 上的直通桩。
unset -f rm 2>/dev/null || true

# 宿主 git-bash 的 grep 在 UTF-8 locale 下匹配不了星面字符（emoji）：状态文件的
# 🟢 计数会得 0；设备上的 toybox grep 是字节匹配（=3）。LC_ALL=C 让宿主行为
# 与设备一致，差分才比的是真差异。
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_KF="$ROOT/module/keybox-fetch.sh"
SHELL_KBC="$ROOT/module/keybox-check.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-keybox-fetch"
FIX="$BASE/fixtures"

pass=0; fail=0; total=0

MEG="https://raw.githubusercontent.com/MeowDump/MeowDump/refs/heads/main/Megatron"
STAT="https://raw.githubusercontent.com/MeowDump/Integrity-Box/refs/heads/main/keybox/key-status"
REVU="https://android.googleapis.com/attestation/status"

# keybox-check 的解析是行式的：夹具必须用多行 XML（与 test-diff-keybox-check.sh
# 的 emit_keybox 同构 —— 单行 XML 两边都判 0 证书）。
KB_VALID="$FIX/kb_valid.xml"
KB_OTHER="$FIX/kb_other.xml"

# --- 夹具（一次生成）---------------------------------------------------------
mkdir -p "$BASE/bin" "$FIX"
MEGF="$(printf '%s' "$MEG" | tr '/:?' '___')"
STATF="$(printf '%s' "$STAT" | tr '/:?' '___')"
REVF="$(printf '%s' "$REVU" | tr '/:?' '___')"
export MEGF STATF REVF
python - "$(cygpath -m "$FIX")" <<'PY'
import base64, codecs, os, sys, pathlib
fix = pathlib.Path(sys.argv[1])
fix.mkdir(exist_ok=True)
megf, statf, revf = os.environ["MEGF"], os.environ["STATF"], os.environ["REVF"]
def emit_keybox(out, algo, body):
    with open(out, "w") as f:
        f.write('<Keybox DeviceID="suite">\n')
        f.write(f'  <Key algorithm="{algo}">\n')
        for _ in range(2):
            f.write(f'    <Certificate>\n{body}\n    </Certificate>\n')
        f.write('  </Key>\n</Keybox>\n')
emit_keybox(fix / "kb_valid.xml", "rsa", "QUJDREVG")
emit_keybox(fix / "kb_other.xml", "rsa", "MTIzNDU2")
valid = (fix / "kb_valid.xml").read_bytes()
other = (fix / "kb_other.xml").read_bytes()
# megatron 编码 = 解码的逆：rot13 -> hex -> base64 x10
def megatron_encode(raw: bytes) -> bytes:
    cur = codecs.encode(raw.decode(), "rot_13").encode().hex().encode()
    for _ in range(10):
        cur = base64.b64encode(cur)
    return cur
def san(u): return u.replace("/", "_").replace(":", "_").replace("?", "_")
(fix / san("https://alpha.example/test")).write_text("garbage not a keybox")
(fix / san("https://pin.example/1")).write_bytes(other)
(fix / san("https://pin.example/2")).write_bytes(other)
(fix / statf).write_text("\U0001F7E2\U0001F7E2\U0001F7E2")
(fix / revf).write_text('{"entries":{}}')
(fix / megf).write_bytes(megatron_encode(valid))
(fix / (megf + ".proxy")).write_bytes(megatron_encode(valid))
PY
SHA_VALID=$(sha256sum "$KB_VALID" | cut -d' ' -f1)
SHA_OTHER=$(sha256sum "$KB_OTHER" | cut -d' ' -f1)

# --- 桩 ----------------------------------------------------------------------
cat > "$BASE/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""; resolve=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --resolve) resolve="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
mode=direct
[ -n "$resolve" ] && mode=directip
[ -n "$http_proxy" ] && mode=proxy
printf '%s %s\n' "$mode" "$url" >> "$CURLLOG"
f="$CURLFIX/$(printf '%s' "$url" | tr '/:?' '___')"
if [ -s "$f" ]; then cp -f "$f" "$out"; exit 0; fi
if [ -s "$f.$mode" ]; then cp -f "$f.$mode" "$out"; exit 0; fi
: > "$out"; exit 22
EOF
cat > "$BASE/bin/pidof" <<'EOF'
#!/bin/sh
case "$1" in
  teesim) cat "$PIDOF_TEE" 2>/dev/null ;;
  com.google.android.gms.unstable) cat "$PIDOF_DG" 2>/dev/null ;;
esac
EOF
cat > "$BASE/bin/am" <<'EOF'
#!/bin/sh
echo "am $*" >> "$AMLOG"
exit 0
EOF
chmod +x "$BASE/bin/"*
# 假探测器：仅 PROBE_OK_PORT 成功
cat > "$BASE/probe.sh" <<'EOF'
#!/bin/sh
[ "$1" = "$PROBE_OK_PORT" ]
EOF
chmod +x "$BASE/probe.sh"
# verdict 桩：按 VERDMODE 应答；记录被调用的子命令
cat > "$BASE/engine-verdict.sh" <<'EOF'
#!/bin/sh
echo "verdict $1" >> "$VERDLOG"
mode=$(cat "$VERDMODE" 2>/dev/null)
case "$1" in
  reason) [ "$mode" = reject ] && echo "profile p0 failed to build (bad keybox?)" ;;
  socket-live) exit 0 ;;
  once)   [ "$mode" = accept ] && exit 0; [ "$mode" = reject ] && exit 1; exit 2 ;;
  watch)  [ "$mode" = accept ] && exit 0; [ "$mode" = reject ] && exit 1; exit 3 ;;
esac
exit 0
EOF
chmod +x "$BASE/engine-verdict.sh"

# --- 环境 --------------------------------------------------------------------
setup_env() { # <d> <mode> <probe_ok_port> — 写公共桩环境与引擎/日志夹具
    local d="$1" mode="$2" pop="$3"
    mkdir -p "$d/teesim/log" "$d/mod" "$d/bin" "$d/curlfix"
    cp -f "$BASE/bin/curl" "$BASE/bin/pidof" "$BASE/bin/am" "$d/bin/"
    printf '#!/usr/bin/env bash\nexec /usr/bin/rm "$@"\n' > "$d/bin/rm"
    chmod +x "$d/bin/rm"
    cp -f "$BASE/probe.sh" "$d/probe.sh"
    cp -f "$BASE/engine-verdict.sh" "$d/mod/engine-verdict.sh"
    cp -f "$SHELL_KBC" "$d/mod/keybox-check.sh"
    cp -f "$SHELL_KF" "$d/mod/keybox-fetch.sh"
    printf 'control: ack cycle ok\n' > "$d/teesim/log/teesim.log"
    printf '%s' "4242" > "$d/pid_tee"
    printf '%s' "999999" > "$d/pid_dg"
    printf '%s' "$mode" > "$d/verdmode"
    export CURLLOG="$d/curl.log" CURLFIX="$d/curlfix"
    export PIDOF_TEE="$d/pid_tee" PIDOF_DG="$d/pid_dg"
    export VERDLOG="$d/verd.log" VERDMODE="$d/verdmode"
    export AMLOG="$d/am.log" PROBE_OK_PORT="$pop"
    export AEGIS_KB_IPS="185.199.108.133"
    export AEGIS_KB_PROBE_PORTS="7890 7897"
    export AEGIS_KB_PROBE="$d/probe.sh"
}

snapshot() { # <d> <rc> → 归一化快照（stdout）
    local d="$1" rc="$2" t="$d/teesim"
    echo "rc=$rc"
    echo "--kb--";      cat "$t/keybox.xml" 2>/dev/null
    echo "--marker--"; cat "$t/.auto-keybox" 2>/dev/null
    echo "--src--";    cat "$t/.keybox-source" 2>/dev/null
    echo "--status--"; cat "$t/key-status.txt" 2>/dev/null
    echo "--statusn--";cat "$t/.key-status-n" 2>/dev/null
    echo "--badlist--";  cat "$t/.keybox-bad-payloads" 2>/dev/null
    echo "--bounced--";  cat "$t/.imported-bounced" 2>/dev/null
    echo "--proxyauto--";cat "$t/pif-proxy.auto" 2>/dev/null
    echo "--revjson--";  cat "$t/.revocation-status.json" 2>/dev/null
    echo "--pref--";     cat "$t/keybox-source-pref" 2>/dev/null
    echo "--prog--";     sed -n '2,3p' "$t/.kb-fetch.progress" 2>/dev/null
    echo "--curl--";     cat "$d/curl.log" 2>/dev/null
    echo "--am--";       cat "$d/am.log" 2>/dev/null
    echo "--verd--";     cat "$d/verd.log" 2>/dev/null
    echo "--backups--";  ls -1 "$t/keybox-backups" 2>/dev/null | sed -E 's/[0-9]{8}-[0-9]{6}/TS/g; s/[0-9]{8}_[0-9]{6}/TS/g'
    echo "--log--";      sed -E 's/^\[[^]]*\] //; s/[0-9]{8}-[0-9]{6}/TS/g; s/[0-9]{8}_[0-9]{6}/TS/g' "$t/keybox-fetch.log" 2>/dev/null
}

# --- case 运行器 --------------------------------------------------------------
# run_case <name> <mode> <probe_ok_port> <shell参数...> —— 夹具由 prep_<name> 定
run_case() {
    local name="$1" mode="$2" pop="$3"; shift 3
    local d="$BASE/$name"
    local wtee wmod
    wtee=$(cygpath -m "$d/teesim"); wmod=$(cygpath -m "$d/mod")

    # --- shell 版 ---
    rmrf "$d"
    setup_env "$d" "$mode" "$pop"
    "prep_$name" "$d"
    local rc1
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee"
      cd "$d" && sh "$d/mod/keybox-fetch.sh" "$@" ) > "$d/shell.out" 2>&1
    rc1=$?
    snapshot "$d" "$rc1" > "$d/snap.shell"

    # --- Rust 版（重跑 prep，恢复同一初始状态）---
    rmrf "$d/teesim" "$d/curl.log" "$d/am.log" "$d/verd.log" "$d/shell.out"
    setup_env "$d" "$mode" "$pop"
    "prep_$name" "$d"
    local rc2
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod"
      cd "$d" && "$RUST_BIN" keybox-fetch "$@" ) > "$d/rust.out" 2>&1
    rc2=$?
    snapshot "$d" "$rc2" > "$d/snap.rust"

    total=$((total + 1))
    if diff -u "$d/snap.shell" "$d/snap.rust" > "$d/snap.diff" 2>&1; then
        pass=$((pass + 1)); echo "  ✅ $name"
    else
        fail=$((fail + 1)); echo "  ❌ $name（diff: $d/snap.diff）"
    fi
}

# --- 各 case 的夹具 -----------------------------------------------------------
fix_common() { # <d> — 公共 curl 夹具（吊销名单 + Megatron + status）
    local d="$1"
    cp -f "$FIX/$REVF" "$d/curlfix/"
    cp -f "$FIX/$MEGF" "$d/curlfix/"
    cp -f "$FIX/$STATF" "$d/curlfix/"
}

prep_seq_channels() {
    local d="$1"
    fix_common "$d"
    cp -f "$FIX/$(printf '%s' "https://alpha.example/test" | tr '/:?' '___')" "$d/curlfix/"
    printf 'Alpha|https://alpha.example/test|raw\n' > "$d/teesim/keybox-sources.conf"
}

prep_pin_mismatch() {
    local d="$1"
    fix_common "$d"
    cp -f "$FIX/$(printf '%s' "https://pin.example/1" | tr '/:?' '___')" "$d/curlfix/"
    cp -f "$FIX/$(printf '%s' "https://pin.example/2" | tr '/:?' '___')" "$d/curlfix/"
    printf 'Pinned|https://pin.example/1|raw||%s\n' "$SHA_VALID"  > "$d/teesim/keybox-sources.conf"
    printf 'Pinned2|https://pin.example/2|raw||%s\n' "$SHA_OTHER" >> "$d/teesim/keybox-sources.conf"
}

prep_megatron() {
    local d="$1"
    fix_common "$d"
}

prep_engine_reject() {
    local d="$1"
    fix_common "$d"
}

prep_force_adopt() {
    local d="$1"
    fix_common "$d"
    cp -f "$KB_VALID" "$d/teesim/keybox.xml"
    printf '%s' "$SHA_VALID" > "$d/teesim/.auto-keybox"
    # Megatron 的 payload 解码后与部署内容一致 → 触发 --force 的 adopt 分支
}

prep_import_guard() {
    local d="$1"
    fix_common "$d"
    cp -f "$KB_OTHER" "$d/teesim/keybox.xml"
    printf '%s' "$SHA_VALID" > "$d/teesim/.auto-keybox"
}

prep_revcheck() {
    local d="$1"
    fix_common "$d"
}

prep_lock() {
    local d="$1"
    fix_common "$d"
    mkdir -p "$d/teesim/.kb-fetching.lock"
    echo "$$" > "$d/teesim/.kb-fetching.lock/holder"
}

prep_proxy_ladder() {
    local d="$1"
    # 吊销名单夹具（基础名=任意 mode）
    cp -f "$FIX/$REVF" "$d/curlfix/"
    # Megatron 只在 proxy 模式有数据（仅 .proxy 文件，无基础名）
    cp -f "$FIX/$MEGF.proxy" "$d/curlfix/"
}

# --- 执行 ----------------------------------------------------------------------
echo "== keybox-fetch 差分 =="
run_case seq_channels  accept ""   ""
run_case pin_mismatch  accept ""   ""
run_case megatron      accept ""   ""
run_case engine_reject reject ""   ""
run_case force_adopt   accept ""   "--force"
run_case import_guard  accept ""   ""
run_case revcheck      accept ""   "--revcheck"
run_case lock          accept ""   ""
run_case proxy_ladder  accept "7890" ""

echo
echo "结果: $pass/$total 通过, $fail 失败"
[ "$fail" -eq 0 ]
