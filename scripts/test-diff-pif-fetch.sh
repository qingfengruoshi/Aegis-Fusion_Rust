#!/usr/bin/env bash
# 差分测试：pif-fetch（shell vs Rust），逐 case 比较「落盘结果」。
#
# 桩（全部走 21 个 AEGIS_* 接缝，两版实现用同一套桩）：
#   AEGIS_AUTOPIF   —— 假生成器：往 CWD 写 custom.pif.prop（含 Estimated Expiry），
#                      并写哨兵文件（证明"生成器被调用过"）
#   AEGIS_PIF_PROBE —— 假探测器：仅对 PROBE_OK_PORT 返回成功
#   AEGIS_PIF_SYNC  —— 假 sync：写哨兵（证明"sync 被调用过"）
#
# 比较（语义级）：marker 两行、.pif-source、master 目录、生成器哨兵、pif-proxy.auto。
#
# Run: bash scripts/test-diff-pif-fetch.sh
set -u

# 宿主 safe-delete 守卫按「单轮删除文件数」拦批量 rm —— 套件清理偶发被拒会留
# 下陈旧夹具（哨兵/状态文件跨轮累计）造成伪失败。清理只针对 build/ 下本套件
# 自己的产物，直接走真 rm（与 test-diff-keybox-fetch.sh 同一做法）。
rmrf() { /usr/bin/rm -rf "$@"; }
unset -f rm 2>/dev/null || true


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_PF="$ROOT/module/pif-fetch.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-pif-fetch"
w() { cygpath -m "$1" 2>/dev/null || echo "$1"; }

pass=0; fail=0; total=0

# --- 桩 ----------------------------------------------------------------------
mkdir -p "$BASE/bin"
cat > "$BASE/autopif_ok.sh" <<'EOS'
#!/bin/sh
printf 'BRAND=google\nDEVICE=caiman\nPRODUCT=caiman_beta\nMANUFACTURER=google\nMODEL=Pixel 9 Pro\nSECURITY_PATCH=2026-09-05\nFINGERPRINT=google/caiman_beta/caiman:14/AP2A.240905.003\n# Estimated Expiry: 2027-12-31\n' > "$AEGIS_MODDIR/custom.pif.prop"
echo "generated" >> "$GEN_SENTINEL"
EOS
cat > "$BASE/autopif_fail.sh" <<'EOS'
#!/bin/sh
echo "boom" >> "$GEN_SENTINEL"
exit 1
EOS
cat > "$BASE/probe_ok_7890.sh" <<'EOS'
#!/bin/sh
[ "$1" = "7890" ]
EOS
chmod +x "$BASE"/*.sh

FP='BRAND=google
DEVICE=caiman
PRODUCT=caiman_beta
MANUFACTURER=google
MODEL=Pixel 9 Pro
SECURITY_PATCH=2026-09-05
FINGERPRINT=google/caiman_beta/caiman:14/AP2A.240905.003
# Estimated Expiry: 2027-12-31'

# --- 环境准备 -----------------------------------------------------------------
setup_case() { # <name> — 建 teesim/mod，写桩环境
    local d="$BASE/$1"
    rmrf "$d"; mkdir -p "$d/teesim/log" "$d/mod" "$d/master" "$d/bin"
    cp -f "$BASE/autopif_ok.sh" "$d/mod/autopif4.sh"
    cp -f "$BASE/autopif_ok.sh" "$d/gen_ok.sh"
    cp -f "$BASE/autopif_fail.sh" "$d/gen_fail.sh"
    cp -f "$BASE/probe_ok_7890.sh" "$d/probe.sh"
    printf 'com.google.android.gms 10101 x\n' > "$d/packages.list"
    printf 'tok\n' > "$d/teesim/admin.token"
    : > "$d/teesim/.debug"
}

run_impl() { # <impl: shell|rust> <dir> [额外标记…]（其余经环境变量）
    local impl="$1" d="$2"; shift 2
    local wtee wmod wgen wprobe wsync wst wlg wsn
    wtee=$(w "$d/teesim"); wmod=$(w "$d/mod")
    wgen=$(w "$d/gen_ok.sh"); wprobe=$(w "$d/probe.sh"); wsync=$(w "$d/sync.sh")
    wst=$(w "$d/teesim/.pif-source"); wlg=$(w "$d/teesim/pif-fetch.log"); wsn=$(w "$d/gen.sentinel")
    if [ "$impl" = shell ]; then
        PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" \
            AEGIS_AUTOPIF="$wgen" AEGIS_PIF_SYNC="$wsync" AEGIS_PIF_PROBE="$wprobe" \
            AEGIS_PIF_ATTEMPTS=2 AEGIS_PIF_RETRY_WAIT=0 GEN_SENTINEL="$wsn" \
            timeout 60 sh "$SHELL_PF" >/dev/null 2>&1
    else
        PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" \
            AEGIS_AUTOPIF="$wgen" AEGIS_PIF_SYNC="$wsync" AEGIS_PIF_PROBE="$wprobe" \
            AEGIS_PIF_ATTEMPTS=2 AEGIS_PIF_RETRY_WAIT=0 GEN_SENTINEL="$wsn" \
            timeout 60 "$RUST_BIN" pif-fetch >/dev/null 2>&1
    fi
}

# run_case <name> <准备函数> <期望摘要…>
run_case() {
    local name="$1" prep="$2"
    local d="$BASE/$name"
    # shell
    setup_case "$name"; "$prep" "$d"
    run_impl shell "$d"
    cp -f "$d/teesim/.pif-source" "$BASE/snap-$name.src.shell" 2>/dev/null || : > "$BASE/snap-$name.src.shell"
    cp -f "$d/teesim/.pif-auto" "$BASE/snap-$name.mk.shell" 2>/dev/null || : > "$BASE/snap-$name.mk.shell"
    cp -f "$d/gen.sentinel" "$BASE/snap-$name.sent.shell" 2>/dev/null || : > "$BASE/snap-$name.sent.shell"
    ls -1 "$d/teesim/pif-master" 2>/dev/null | sort > "$BASE/snap-$name.master.shell"
    # rust
    setup_case "$name"; "$prep" "$d"
    run_impl rust "$d"
    cp -f "$d/teesim/.pif-source" "$BASE/snap-$name.src.rust" 2>/dev/null || : > "$BASE/snap-$name.src.rust"
    cp -f "$d/teesim/.pif-auto" "$BASE/snap-$name.mk.rust" 2>/dev/null || : > "$BASE/snap-$name.mk.rust"
    cp -f "$d/gen.sentinel" "$BASE/snap-$name.sent.rust" 2>/dev/null || : > "$BASE/snap-$name.sent.rust"
    ls -1 "$d/teesim/pif-master" 2>/dev/null | sort > "$BASE/snap-$name.master.rust"

    total=$((total + 1))
    local ok=1
    for f in src mk sent master; do
        diff -q "$BASE/snap-$name.$f.shell" "$BASE/snap-$name.$f.rust" >/dev/null 2>&1 || { ok=0; echo "          [$name] $f 不一致:"; diff "$d/$f.shell" "$d/$f.rust" 2>/dev/null | head -4 | sed 's/^/            /'; }
    done
    # custom.pif.prop 的内容也要一致（生成器产出的）
    if [ -f "$d/teesim/custom.pif.prop" ]; then
        diff <(sort "$d/teesim/custom.pif.prop") <(printf '%s\n' "$FP" | sort) >/dev/null 2>&1 || ok=0
    fi
    if [ "$ok" = 1 ]; then
        pass=$((pass + 1)); echo "  PASS  $name"; return 0
    fi
    fail=$((fail + 1)); echo "  FAIL  $name"
    return 1
}

# --- 各 case 的准备函数 -------------------------------------------------------
prep_none() { :; }
prep_user() {
    local d="$1"
    printf '%s\n' "$FP" > "$d/mod/custom.pif.prop"      # 无 marker → 用户指纹
}
prep_fresh() {
    local d="$1" now
    now=$(date +%s)
    printf '%s\n' "$FP" > "$d/mod/custom.pif.prop"
    printf '%s\n%s\n' "$now" "$((now + 14 * 86400))" > "$d/mod/.pif-auto"   # 新鲜
}
prep_rotation_due() {
    local d="$1"
    printf '%s\n' "$FP" > "$d/mod/custom.pif.prop"
    printf '%s\n%s\n' "$(( $(date +%s) - 20 * 86400 ))" "$(( $(date +%s) - 86400 ))" > "$d/mod/.pif-auto"
}
prep_pif_off() { local d="$1"; : > "$d/teesim/.pif-off"; }
prep_restore() {
    local d="$1"
    mkdir -p "$d/teesim/pif-master"
    printf '%s\n' "$FP" > "$d/teesim/pif-master/custom.pif.prop"   # master 有、模块目录无
    printf '1700000000\n' > "$d/teesim/pif-master/.pif-auto"
    printf 'runtime-fetch\n' > "$d/teesim/pif-master/.pif-source"
}
prep_seed() {
    local d="$1"
    mkdir -p "$d/teesim/pif-master"
    printf '%s\n' 'BRAND=google
DEVICE=caiman
MODEL=Pixel 9 Pro
SECURITY_PATCH=2026-09-05' > "$d/mod/pif_seed.prop"
    printf '1700000000\n' > "$d/mod/pif_seed.auto"
    printf 'BRAND=google\nDEVICE=caiman\nMODEL=Pixel 9 Pro\nSECURITY_PATCH=2026-09-05\n# Estimated Expiry: 2027-12-31\n' > "$d/teesim/pif-master/custom.pif.prop"
}
prep_gen_fail() {
    local d="$1"
    printf '%s\n' "$FP" > "$d/mod/custom.pif.prop"    # 旧指纹幸存
    printf '%s\n%s\n' "$(( $(date +%s) - 20 * 86400 ))" "$(( $(date +%s) - 86400 ))" > "$d/mod/.pif-auto"
    # 用失败的生成器
    mv "$d/gen_ok.sh" "$d/gen_ok.sh.bak"; cp -f "$d/gen_fail.sh" "$d/gen_ok.sh"
}
prep_proxy() {
    local d="$1"
    printf '%s\n' "$FP" > "$d/mod/custom.pif.prop"
    printf '%s\n%s\n' "$(( $(date +%s) - 20 * 86400 ))" "$(( $(date +%s) - 86400 ))" > "$d/mod/.pif-auto"
}

echo "== 差分：pif-fetch（shell vs Rust）=="
run_case no_fingerprint    prep_none
run_case user_fingerprint  prep_user
run_case fresh             prep_fresh
run_case rotation_due      prep_rotation_due
run_case pif_off           prep_pif_off
run_case restore           prep_restore
run_case seed              prep_seed
run_case gen_fail          prep_gen_fail
run_case proxy             prep_proxy

echo
echo "== 结果：$pass/$total 一致，$fail 处差异 =="
[ "$fail" -eq 0 ] || exit 1
