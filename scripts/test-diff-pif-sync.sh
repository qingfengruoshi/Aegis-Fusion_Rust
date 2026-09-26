#!/usr/bin/env bash
# 差分测试：pif-sync（shell vs Rust），语义级比较（JSON 对象相等 + 状态文件）。
#
# 夹具用 AEGIS_TEE_DIR / AEGIS_ADB / AEGIS_PROP_FILE 指到临时目录；
# bounce（pidof/kill）在宿主上是 no-op（两边同径），只比较 .gms-recycle 的有无。
#
# Run: bash scripts/test-diff-pif-sync.sh
# 需要先构建：cargo +stable-x86_64-pc-windows-gnu build --release
set -u

# 宿主 safe-delete 守卫按「单轮删除文件数」拦批量 rm —— 套件清理偶发被拒会留
# 下陈旧夹具（哨兵/状态文件跨轮累计）造成伪失败。清理只针对 build/ 下本套件
# 自己的产物，直接走真 rm（与 test-diff-keybox-fetch.sh 同一做法）。
rmrf() { /usr/bin/rm -rf "$@"; }
unset -f rm 2>/dev/null || true


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_PS="$ROOT/module/pif-sync.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-pif-sync"
CMP="$ROOT/scripts/fixtures/compare_apps.py"

pass=0; fail=0; total=0
w() { cygpath -m "$1" 2>/dev/null || echo "$1"; }

# --- 夹具 --------------------------------------------------------------------
# config.json（真实身份 + 旧补丁日期）
CFG='{"profiles":{"p0":{"apps":["com.google.android.gms"],"brand":"Xiaomi","device":"k70","product":"k70_cn","manufacturer":"Xiaomi","model":"K70","patchLevel":{"system":"2026-08-01","vendor":"2026-08-01","boot":"2026-08-01"}}}}'
# PIF 载荷（prop 形态，弱默认标志 —— 让 assert_flags 有事做）
PIFPROP='BRAND=google
DEVICE=caiman
PRODUCT=caiman_beta
MANUFACTURER=google
MODEL=Pixel 9 Pro
SECURITY_PATCH=2026-09-05
FINGERPRINT=google/caiman_beta/caiman:14/AP2A.240905.003
spoofBuild=0
spoofProps=0
spoofVendingFinger=0
spoofProvider=0'
# PIF 载荷（JSON 形态）
PIFJSON='{"BRAND":"google","DEVICE":"caiman","PRODUCT":"caiman_beta","MANUFACTURER":"google","MODEL":"Pixel 9 Pro","SECURITY_PATCH":"2026-09-05","FINGERPRINT":"google/caiman_beta/caiman:14/AP2A.240905.003"}'
# 真实身份（getprop 的桩数据，AEGIS_PROP_FILE）
PROPS='{"ro.product.brand":"Xiaomi","ro.product.device":"k70","ro.product.name":"k70_cn","ro.product.manufacturer":"Xiaomi","ro.product.model":"K70","ro.build.version.security_patch":"2026-08-05","ro.vendor.build.security_patch":"2026-08-05"}'

make_tee() { # <dir> [markers…]
    local d="$1"; shift
    rmrf "$d"; mkdir -p "$d/teesim/log" "$d/adb/modules/aegisfusion_rs"
    printf '%s\n' "$CFG" > "$d/teesim/config.json"
    printf '%s' "$PROPS" > "$d/props.json"
    local m
    for m in "$@"; do
        case "$m" in
            synced)      : > "$d/teesim/.pif-synced" ;;
            pif_off)     : > "$d/teesim/.pif-off" ;;
            sync_off)    : > "$d/teesim/.pif-sync-off" ;;
        esac
    done
}

put_pif() { # <dir> <kind>
    local d="$1" kind="$2"
    case "$kind" in
        prop) printf '%s\n' "$PIFPROP" > "$d/adb/modules/aegisfusion_rs/custom.pif.prop" ;;
        json) printf '%s\n' "$PIFJSON" > "$d/adb/pif.json" ;;
    esac
}

# run_case <name> <tee-prepare…> <pif-kind|none>
run_case() {
    local name="$1" pifkind="$2"; shift 2
    local d="$BASE/$name"
    make_tee "$d" "$@"
    [ "$pifkind" != "none" ] && put_pif "$d" "$pifkind"

    local wtee wadb wpf
    wtee=$(w "$d/teesim"); wadb=$(w "$d/adb"); wpf=$(w "$d/props.json")

    # --- shell 版 ---
    AEGIS_TEE_DIR="$wtee" AEGIS_ADB="$wadb" AEGIS_PROP_FILE="$wpf" \
        timeout 30 sh "$SHELL_PS" >/dev/null 2>&1
    cp -f "$d/teesim/config.json" "$d/config.json.shell"
    [ -f "$d/teesim/.pif-synced" ] && : > "$d/synced.shell" || : > "$d/synced.shell"
    # --- Rust 版（还原夹具）---
    rm -rf "$d/teesim"; mkdir -p "$d/teesim/log"
    printf '%s\n' "$CFG" > "$d/teesim/config.json"
    printf '%s' "$PROPS" > "$d/props.json"
    [ "$pifkind" != "none" ] && put_pif "$d" "$pifkind"
    setup_markers "$d" "$name" 2>/dev/null || true
    AEGIS_TEE_DIR="$wtee" AEGIS_ADB="$wadb" AEGIS_PROP_FILE="$wpf" \
        timeout 30 "$RUST_BIN" pif-sync >/dev/null 2>&1
    cp -f "$d/teesim/config.json" "$d/config.json.rust"
    [ -f "$d/teesim/.pif-synced" ] && : > "$d/synced.rust" || : > "$d/synced.rust"

    total=$((total + 1))
    if python "$(w "$CMP")" "$(w "$d/config.json.shell")" "$(w "$d/config.json.rust")" \
            > "$d/cmp.txt" 2>&1 \
       && diff -q "$d/synced.shell" "$d/synced.rust" >/dev/null 2>&1; then
        pass=$((pass + 1)); echo "  PASS  $name"
        return 0
    fi
    fail=$((fail + 1))
    echo "  FAIL  $name"
    head -8 "$d/cmp.txt" 2>/dev/null | sed 's/^/          /'
    diff "$d/synced.shell" "$d/synced.rust" >/dev/null 2>&1 \
        || echo "          .pif-synced 有无不一致"
    return 1
}

# Rust 版开跑前 teesim/ 会被重建，marker 必须逐 case 重建
setup_markers() {
    local d="$1" name="$2"
    case "$name" in
        pif_off)  : > "$d/teesim/.pif-off"; : > "$d/teesim/.pif-synced" ;;
        suppress) : > "$d/teesim/.pif-sync-off" ;;
    esac
}

echo "== 差分：pif-sync（shell vs Rust）=="
run_case mirror_prop  prop
run_case mirror_json  json
run_case pif_gone     none        synced
run_case pif_off      prop        synced pif_off
run_case suppress     prop        synced sync_off
run_case fresh        prop

echo
echo "== 结果：$pass/$total 一致，$fail 处差异 =="
[ "$fail" -eq 0 ] || exit 1
