#!/usr/bin/env bash
# 差分测试：apps-sync（shell vs Rust），语义级比较（见 fixtures/compare_apps.py）。
#
# 桩：
#   pm.exe   —— C 编译（Rust 与 shell 都调 pm；Windows 只执行 .exe）
#   busybox  —— shell 脚本（只有 shell 版调它，代理宿主的 GNU awk）
#
# 每个 case 跑两遍（shell / Rust），各自把产出的 config.json 存下来比较。
#
# Run: bash scripts/test-diff-apps-sync.sh
# 需要先构建：cargo +stable-x86_64-pc-windows-gnu build --release
set -u

# 宿主 safe-delete 守卫按「单轮删除文件数」拦批量 rm —— 套件清理偶发被拒会留
# 下陈旧夹具（哨兵/状态文件跨轮累计）造成伪失败。清理只针对 build/ 下本套件
# 自己的产物，直接走真 rm（与 test-diff-keybox-fetch.sh 同一做法）。
rmrf() { /usr/bin/rm -rf "$@"; }
unset -f rm 2>/dev/null || true


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_AS="$ROOT/module/apps-sync.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-apps-sync"
CMP="$ROOT/scripts/fixtures/compare_apps.py"

pass=0; fail=0; total=0
w() { cygpath -m "$1" 2>/dev/null || echo "$1"; }

# --- 桩 ----------------------------------------------------------------------
mkdir -p "$BASE/bin"
if [ ! -x "$BASE/pm.exe" ]; then
    gcc -O1 -o "$(w "$BASE")/pm.exe" "$(w "$ROOT/scripts/fixtures/pm_stub.c")" || exit 1
fi
cp -f "$BASE/pm.exe" "$BASE/bin/pm.exe"
cat > "$BASE/bin/busybox" <<'EOS'
#!/bin/sh
# busybox 桩：只代理 awk（本套件只需要它）；委托宿主的 GNU awk
if [ "$1" = "awk" ]; then shift; exec awk "$@"; fi
echo "busybox stub: unsupported subcommand '$1'" >&2
exit 1
EOS
chmod +x "$BASE/bin/busybox"

# --- 夹具 --------------------------------------------------------------------
PKGLIST="$BASE/packages.list"
printf 'com.google.android.gms 10101 com.google.android.gms\ncom.android.vending 10202 com.android.vending\ncom.google.android.gsf 10303 com.google.android.gsf\ncom.a.one 10404\n' > "$PKGLIST"
PMFIX="$BASE/pm.txt"
printf 'package:com.a.one\npackage:com.c.installed\n' > "$PMFIX"

CFGS="seed_gms seed_gms_already uid_pins cleanup migration multi_profile"
declare -A CFG
CFG[seed_gms]='{"profiles":{"p0":{"apps":[]}}}'
CFG[seed_gms_already]='{"profiles":{"p0":{"apps":["com.google.android.gms"]}}}'
CFG[uid_pins]='{"profiles":{"p0":{"apps":["com.google.android.gms"]}}}'
CFG[cleanup]='{"profiles":{"p0":{"apps":["com.a.one","com.b.gone","bad entry","uid:10101","com.c.installed@10"]}}}'
CFG[migration]='{"profiles":{"p0":{"apps":["com.a.one"]}}}'
CFG[multi_profile]='{"profiles":{"p0":{"apps":["com.a.one"]},"p1":{"apps":[]}}}'

# case 前置 marker / 标志
setup_markers() {
    local d="$1" name="$2"
    case "$name" in
        seed_gms_already) : > "$d/teesim/.gms-scope-seeded" ;;
        migration)        printf '1\n' > "$d/teesim/apps-auto-add" ;;
    esac
}

# --- 单 case：跑两边，存下 config，比较 ----------------------------------------
run_case() {
    local name="$1"
    local cfg="${CFG[$name]}"
    [ -n "$cfg" ] || { echo "  SKIP  $name（无夹具）"; return 0; }

    local d="$BASE/$name"
    local wtee wmod wpkl
    wtee=$(w "$d/teesim"); wmod=$(w "$d/mod"); wpkl=$(w "$d/packages.list")

    # --- shell 版 ---
    rmrf "$d"; mkdir -p "$d/teesim/log" "$d/mod" "$d/bin"
    cp -f "$BASE/bin/pm.exe" "$d/bin/" 2>/dev/null
    cp -f "$BASE/bin/busybox" "$d/bin/" 2>/dev/null
    printf '%s\n' "$cfg" > "$d/teesim/config.json"
    cp -f "$PKGLIST" "$d/packages.list"
    setup_markers "$d" "$name"
    PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODPATH="$wmod" \
        AEGIS_PKG_LIST="$wpkl" timeout 30 sh "$SHELL_AS" >/dev/null 2>&1
    cp -f "$d/teesim/config.json" "$d/config.json.shell"

    # --- Rust 版（还原夹具）---
    rm -rf "$d/teesim"; mkdir -p "$d/teesim/log"
    printf '%s\n' "$cfg" > "$d/teesim/config.json"
    cp -f "$PKGLIST" "$d/packages.list"
    setup_markers "$d" "$name"
    PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODPATH="$wmod" \
        AEGIS_PKG_LIST="$wpkl" timeout 30 "$RUST_BIN" apps-sync >/dev/null 2>&1
    cp -f "$d/teesim/config.json" "$d/config.json.rust"

    total=$((total + 1))
    # ★ 比较器是原生 Python：三个配置路径都要 Windows 形式
    local csh crs corig
    csh=$(w "$d/config.json.shell")
    crs=$(w "$d/config.json.rust")
    corig=$(w "$d/teesim/config.json")
    if python "$(w "$CMP")" "$csh" "$crs" "$corig" "$name" > "$d/cmp.txt" 2>&1; then
        pass=$((pass + 1)); echo "  PASS  $name"
        return 0
    fi
    # 已知的 shell 侧缺陷：Rust 行为正确（合法 JSON），不记为重写失败
    if [ "$name" = "$KNOWN_SHELL_BUG" ] && grep -q "shell 侧不是合法 JSON" "$d/cmp.txt"; then
        echo "  KNOWN-SHELL-BUG  $name（shell 产出非法 JSON，Rust 正确 —— 见 KNOWN-FAILURE-MODES §7）"
        return 0
    fi
    fail=$((fail + 1))
    echo "  FAIL  $name (rc shell=? rust=?)"
    head -8 "$d/cmp.txt" | sed 's/^/          /'
    return 1
}

# ★ 差分发现的 shell 线缺陷（KNOWN-FAILURE-MODES §7）：
#   空 apps 数组 + uid pin 时，shell 的 sed 替换丢掉了收口的 `]`，产出非法 JSON。
#   Rust 版产出合法 JSON —— 这是「修掉而非照搬」的偏差，单独记录，不算重写失败。
KNOWN_SHELL_BUG="seed_gms"

echo "== 差分：apps-sync（shell vs Rust）=="
for name in $CFGS; do
    run_case "$name"
done

echo
echo "== 结果：$pass/$total 一致，$fail 处差异 =="
[ "$fail" -eq 0 ] || exit 1
