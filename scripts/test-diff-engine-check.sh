#!/usr/bin/env bash
# 差分测试：engine-check（shell vs Rust），逐 case 比较**完整 stdout**。
#
# 桩（两边同一套）：
#   pidof            —— teesim / keystore2 从夹具文件应答（多 pid 覆盖 head -1 语义）
#   ps               —— 固定 etime 输出
#   logcat           —— 输出夹具文件（含全部 mask 形式 → 覆盖 mask_ids）
#   engine-verdict   —— once 打一行确定性结果
#   teesim-uds       —— 桩存在但 admin.sock 不是 socket ⇒ 只走 skipped 分支
#
# 全部输出确定性（pid 固定、无时间戳），无需归一化。
# Run: bash scripts/test-diff-engine-check.sh   （⚠ 每次 run 十余次子进程 spawn，
#      全套约 2-4 分钟；给 CI/调用方的 timeout 预算 ≥ 300s）
set -u

# 宿主代理/locale 污染同前两套：显式清掉（emoji/UTF-8 无关本套件，但保持一致）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export LC_ALL=C

# safe-delete 还会导出 rm 函数并穿透到子 shell（$d/bin 的直通桩被绕过），
# 在 harness 顶层断掉继承，让子进程的 rm 走 PATH 上的直通桩。
unset -f rm 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_EC="$ROOT/module/engine-check.sh"
SHELL_KBC="$ROOT/module/keybox-check.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-engine-check"
FIX="$BASE/fixtures"

pass=0; fail=0; total=0

# 多行合法 keybox（keybox-check 的解析是行式的，夹具必须 emit_keybox 同构）
mkdir -p "$FIX"
emit_keybox() {
    printf '<Keybox DeviceID="suite">\n  <Key algorithm="rsa">\n' > "$1"
    printf '    <Certificate>\nQUJDREVG\n    </Certificate>\n    <Certificate>\nQUJDREVG\n    </Certificate>\n' >> "$1"
    printf '  </Key>\n</Keybox>\n' >> "$1"
}
emit_keybox "$FIX/kb_valid.xml"

# --- 桩 ----------------------------------------------------------------------
mkdir -p "$BASE/bin"
cat > "$BASE/bin/pidof" <<'EOF'
#!/bin/sh
case "$1" in
  teesim) cat "$PIDOF_TEE" 2>/dev/null ;;
  keystore2) cat "$PIDOF_KS" 2>/dev/null ;;
esac
EOF
cat > "$BASE/bin/ps" <<'EOF'
#!/bin/sh
echo "  05:37"
EOF
cat > "$BASE/bin/logcat" <<'EOF'
#!/bin/sh
cat "$LOGCAT_FIX" 2>/dev/null
EOF
chmod +x "$BASE/bin/"*

cat > "$BASE/engine-verdict.sh" <<'EOF'
#!/bin/sh
case "$1" in
  once) echo "verdict(stub): applied=3 failed=0 target=1" ;;
esac
EOF
chmod +x "$BASE/engine-verdict.sh"
cat > "$BASE/uds" <<'EOF'
#!/bin/sh
echo "uds $*" >> "$UDS_LOG"
exit 0
EOF
chmod +x "$BASE/uds"

# --- 夹具 --------------------------------------------------------------------
setup_env() { # <d> <pid_tee内容> <pid_ks内容>
    local d="$1"
    mkdir -p "$d/teesim/log" "$d/mod" "$d/bin"
    cp -f "$BASE/bin/pidof" "$BASE/bin/ps" "$BASE/bin/logcat" "$d/bin/"
    printf '#!/usr/bin/env bash\nexec /usr/bin/rm "$@"\n' > "$d/bin/rm"
    chmod +x "$d/bin/rm"
    cp -f "$SHELL_EC" "$d/mod/engine-check.sh"
    cp -f "$SHELL_KBC" "$d/mod/keybox-check.sh"
    cp -f "$BASE/engine-verdict.sh" "$d/mod/engine-verdict.sh"
    cp -f "$BASE/uds" "$d/teesim/teesim-uds"
    printf '3.2.3\nversion=3.2.3\nversionCode=32\n' > "$d/mod/module.prop"
    printf '%s' "$2" > "$d/pid_tee"
    printf '%s' "$3" > "$d/pid_ks"
    export PIDOF_TEE="$d/pid_tee" PIDOF_KS="$d/pid_ks"
    export LOGCAT_FIX="$d/logcat.fix" UDS_LOG="$d/uds.log"
    # admin.token 有、admin.sock 不是 socket ⇒ 第 6 节走 skipped 分支
    printf 'tok-123\n' > "$d/teesim/admin.token"
}

# 掩码覆盖夹具：四种形式 + 边角（<4 短值不脱敏、值类在标点处截断、ro.serialno）
MASK_LINES='07-01 00:00:00.000  1234  5678 I TEESimulator: harvest imei='"'"'860711051234567'"'"' secondImei='"'"'860711051234575'"'"' meid='"'"'A0000045678901'"'"' serial='"'"'0123456789ABCDEF'"'"'
07-01 00:00:00.001  1234  5678 I TEESimulator: status {"version":"1.2.3","hook":1,"imei":"860711051234567","serial":"x8abc"}
07-01 00:00:00.002  1234  5678 I TEESimulator: props ro.serialno=abcdef123456 imei2=999000111222
07-01 00:00:00.003  1234  5678 I TEESimulator: bare imei 860711051234567 kept
07-01 00:00:00.004  1234  5678 I TEESimulator: short imei ab stays
07-01 00:00:00.005  1234  5678 I TEESimulator: punct serial a,b;c'
printf '%s\n' "$MASK_LINES" > "$BASE/mask.fix"

HEALTHY_LOG='2026-09-25 10:00:00 I teesim: control: pushed config v=7
2026-09-25 10:00:00 I teesim: control: ack applied=3 failed=0 target=1
2026-09-25 10:00:01 I teesim: cfg: staged profile p0 target=1
2026-09-25 10:00:02 I teesim: keystore2 request target=1 served by engine
2026-09-25 10:00:03 W teesim: harvest imei='"'"'860711051234567'"'"' serial='"'"'AAA'"'"'
2026-09-25 10:00:04 I teesim: Scope[resolve] picked profile p0
2026-09-25 10:00:05 I teesim: teesim_km_init_ex: ok, rsa chain valid (2 certs)'

BUILDFAIL_LOG='2026-09-25 10:00:00 I teesim: control: pushed config v=7
2026-09-25 10:00:01 I teesim: keystore2 request target=0 forwarded to HAL
2026-09-25 10:00:02 I teesim: keymint: profile p0 failed to build (bad keybox?)
2026-09-25 10:00:03 I teesim: teesim_km_init_ex: rsa: expected at least 2 certificates'

CONFIG='{"profiles":{"p0":{"mode":"ib","keybox":"keybox.xml","apps":["com.a","com.b"]},"p1":{"mode":"ib","keybox":"kb2.xml","apps":[]}}}'

prep_healthy() {
    local d="$1"
    printf '%s\n' "$HEALTHY_LOG" > "$d/teesim/log/teesim.log"
    printf '%s\n' "$MASK_LINES" > "$d/logcat.fix"
    printf '%s\n' "$MASK_LINES" > "$d/teesim/daemon.log"
    printf '%s' "$CONFIG" > "$d/teesim/config.json"
    cp -f "$FIX/kb_valid.xml" "$d/teesim/keybox.xml"
    printf 'bd860482755565f61c72d4cd204c4533a217678a7b288113b8e73b8f01d9f945' > "$d/teesim/.auto-keybox"
}
prep_dead() {
    local d="$1"
    : > "$d/logcat.fix"
}
prep_build_failed() {
    local d="$1"
    printf '%s\n' "$BUILDFAIL_LOG" > "$d/teesim/log/teesim.log"
    : > "$d/logcat.fix"
    printf '%s' "$CONFIG" > "$d/teesim/config.json"
    cp -f "$FIX/kb_valid.xml" "$d/teesim/keybox.xml"
}

run_case() { # <name> <pid_tee> <pid_ks> <prep>
    local name="$1" ptee="$2" pks="$3" prep="$4"
    local d="$BASE/$name"
    local wtee wmod
    wtee=$(cygpath -m "$d/teesim"); wmod=$(cygpath -m "$d/mod")

    # --- shell 版 ---
    rmrf_case "$d"
    setup_env "$d" "$ptee" "$pks"
    "$prep" "$d"
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" LC_ALL=C
      cd "$d" && sh "$d/mod/engine-check.sh" ) > "$d.out.shell" 2>/dev/null

    # --- Rust 版（重跑 prep 恢复同一初始状态）---
    rmrf_case "$d"
    setup_env "$d" "$ptee" "$pks"
    "$prep" "$d"
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" LC_ALL=C
      cd "$d" && "$RUST_BIN" engine-check ) > "$d.out.rust" 2>/dev/null

    total=$((total + 1))
    if diff -u "$d.out.shell" "$d.out.rust" > "$d.out.diff" 2>&1; then
        pass=$((pass + 1)); echo "  ✅ $name"
    else
        fail=$((fail + 1)); echo "  ❌ $name（diff: $d.out.diff）"
    fi
}

rmrf_case() { /usr/bin/rm -rf "$@"; }

echo "== engine-check 差分 =="
run_case healthy      "399999" "888 999" prep_healthy
run_case dead         ""       ""        prep_dead
run_case build_failed "399999" "888 999" prep_build_failed

echo
echo "结果: $pass/$total 通过, $fail 失败"
[ "$fail" -eq 0 ]
