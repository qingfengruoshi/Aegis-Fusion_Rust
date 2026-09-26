#!/usr/bin/env bash
# 差分测试：keybox-swap 的 watch 流（--watch / --auto / 单候选验收）。
#
# 既有 test-diff-keybox-swap.sh 只比文件系统终态（verdict 输出当时未移植）；
# 本套件补上 **stdout + 退出码** 的逐字比较，verdict 用桩：
#   $d/mod/engine-verdict.sh —— 记录调用；watch 的返回码按 VERDMODE 夹具：
#     accept / reject / silent / reject_once（第一次 reject 之后翻转为 accept，
#     覆盖 --auto 的「第二个候选才被接受」路径）。
#
# 备份/快照文件名里的时间戳归一为 TS。
# Run: bash scripts/test-diff-keybox-swap-watch.sh
set -u
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
unset -f rm 2>/dev/null || true
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_KS="$ROOT/module/keybox-swap.sh"
SHELL_KBC="$ROOT/module/keybox-check.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-ks-watch"

pass=0; fail=0; total=0

rmrf() { /usr/bin/rm -rf "$@"; }

VALID='<?xml version="1.0"?><Keybox><Key algorithm="rsa"><Certificate>QUJDREVG</Certificate><Certificate>QUJDREVG</Certificate></Key></Keybox>'
OTHER='<?xml version="1.0"?><Keybox><Key algorithm="rsa"><Certificate>MTIzNDU2</Certificate><Certificate>MTIzNDU2</Certificate></Key></Keybox>'
OLDKB='<?xml version="1.0"?><Keybox><Key algorithm="ecdsa"><Certificate>WFlaQUJD</Certificate><Certificate>WFlaQUJD</Certificate></Key></Keybox>'

# verdict 桩：watch 的 rc/输出按 VERDMODE；reject_once 首次 reject 后翻转
make_verdict_stub() { # <moddir>
    cat > "$1/engine-verdict.sh" <<'EOS'
#!/bin/sh
echo "verdict $*" >> "$VERDLOG"
mode=$(cat "$VERDMODE" 2>/dev/null)
case "$mode" in
  reject_once)
    n=$(cat "$VERDCOUNT" 2>/dev/null); n=$((n + 1)); printf '%s' "$n" > "$VERDCOUNT"
    if [ "$n" = 1 ]; then echo "VERDICT: REJECTED (stub first)"; exit 1
    else echo "VERDICT: ACCEPTED (stub later)"; exit 0; fi ;;
  reject) echo "VERDICT: REJECTED (stub)"; exit 1 ;;
  silent) echo "VERDICT: SILENT (stub)"; exit 2 ;;
  *)      echo "VERDICT: ACCEPTED (stub)"; exit 0 ;;
esac
EOS
    chmod +x "$1/engine-verdict.sh"
}

setup() { # <d> <mode>
    local d="$1" mode="$2"
    rmrf "$d"; mkdir -p "$d/teesim/log" "$d/teesim/keybox-backups" "$d/mod"
    printf '%s' "$OLDKB" > "$d/teesim/keybox.xml"
    printf '{"profiles":{"p0":{"apps":[]}}}\n' > "$d/teesim/config.json"
    printf '%s\n' "$VALID" > "$d/cand_valid.xml"
    printf '%s\n' "$OTHER" > "$d/cand_other.xml"
    printf '%s' "$OLDKB" > "$d/teesim/log/teesim.log"
    cp -f "$SHELL_KBC" "$d/mod/keybox-check.sh"
    make_verdict_stub "$d/mod"
    printf '%s' "$mode" > "$d/verdmode"
    export VERDMODE="$d/verdmode" VERDLOG="$d/verd.log" VERDCOUNT="$d/verd.count"
    : > "$d/verd.count"
}

snapshot() { # <d> <tag> — kb + 备份清单（TS 归一）+ prerun 状态
    local d="$1" tag="$2"
    cp -f "$d/teesim/keybox.xml" "$BASE/snap-$tag.kb" 2>/dev/null || : > "$BASE/snap-$tag.kb"
    ls -1 "$d/teesim/keybox-backups" 2>/dev/null \
        | sed -E 's/[0-9]{8}-[0-9]{6}/TS/g' > "$BASE/snap-$tag.bk"
    if [ -f "$d/teesim/.keybox.prerun.xml" ]; then echo yes > "$BASE/snap-$tag.pre"; else echo no > "$BASE/snap-$tag.pre"; fi
}

norm() { # stdout 归一：时间戳 + case 目录路径
    sed -E "s|$1|<TEE>|g; s/[0-9]{8}-[0-9]{6}/TS/g" "$2"
}

run_case() { # <name> <mode> <args...>
    local name="$1" mode="$2"; shift 2
    local d="$BASE/$name"
    local wtee wmod
    wtee=$(cygpath -m "$d/teesim"); wmod=$(cygpath -m "$d/mod")

    # --- shell ---
    setup "$d" "$mode"
    local rc1
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" LC_ALL=C
      : > "$d/verd.log"
      cd "$d" && timeout 120 sh "$SHELL_KS" "$@" ) > "$BASE/$name.out.shell" 2>/dev/null
    rc1=$?
    snapshot "$d" "$name.shell"

    # --- rust（重置夹具）---
    setup "$d" "$mode"
    local rc2
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" LC_ALL=C
      : > "$d/verd.log"
      cd "$d" && timeout 60 "$RUST_BIN" keybox-swap "$@" ) > "$BASE/$name.out.rust" 2>/dev/null
    rc2=$?
    snapshot "$d" "$name.rust"

    total=$((total + 1))
    local ok=1 msg=""
    [ "$rc1" = "$rc2" ] || { ok=0; msg="$msg rc($rc1≠$rc2)"; }
    norm "$wtee" "$BASE/$name.out.shell" > "$BASE/$name.norm.shell"
    norm "$wtee" "$BASE/$name.out.rust" > "$BASE/$name.norm.rust"
    diff -q "$BASE/$name.norm.shell" "$BASE/$name.norm.rust" >/dev/null 2>&1 || { ok=0; msg="$msg stdout"; }
    for f in kb bk pre; do
        diff -q "$BASE/snap-$name.shell.$f" "$BASE/snap-$name.rust.$f" >/dev/null 2>&1 || { ok=0; msg="$msg $f"; }
    done
    if [ "$ok" = 1 ]; then
        pass=$((pass + 1)); echo "  ✅ $name"
    else
        fail=$((fail + 1)); echo "  ❌ $name（$msg）"
        [ -n "$msg" ] && diff "$BASE/$name.norm.shell" "$BASE/$name.norm.rust" 2>/dev/null | head -8 | sed 's/^/      /'
    fi
}

# 多行合法 XML：keybox-check 是行式解析，单行夹具两边都会拒绝（那是拒绝路径
# 的差分）；真正的「validate 通过 → deploy → ACCEPTED」路径用多行夹具覆盖。
python - <<'PY'
import pathlib
def emit(out, algo, body):
    with open(out, "w") as f:
        f.write('<Keybox DeviceID="suite">\n')
        f.write(f'  <Key algorithm="{algo}">\n')
        for _ in range(2):
            f.write(f'    <Certificate>\n{body}\n    </Certificate>\n')
        f.write('  </Key>\n</Keybox>\n')
emit("cand_ml_valid.xml", "rsa", "QUJDREVG")
emit("cand_ml_other.xml", "rsa", "MTIzNDU2")
PY

echo "== keybox-swap watch 流差分 =="
run_case single_accept    accept  cand_valid.xml
run_case single_reject    reject  cand_valid.xml
run_case ml_single_accept accept  cand_ml_valid.xml
run_case ml_single_reject reject  cand_ml_valid.xml
run_case watch_only       accept  --watch 5
run_case watch_silent     silent  --watch 5
run_case auto_first       accept  --auto cand_valid.xml cand_other.xml
run_case auto_second      reject_once --auto cand_valid.xml cand_other.xml
run_case ml_auto_second   reject_once --auto cand_ml_valid.xml cand_ml_other.xml
run_case auto_all_reject  reject  --auto cand_valid.xml cand_other.xml
run_case auto_usage       accept  --auto

echo
echo "结果: $pass/$total 通过, $fail 失败"
[ "$fail" -eq 0 ]
