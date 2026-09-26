#!/usr/bin/env bash
# Unit tests for module/pif-sync.sh, run on the host (Git Bash / Linux).
# Every case works in a throwaway root under build/ via the AEGIS_ADB /
# AEGIS_TEE_DIR / AEGIS_PROP_FILE overrides the script exposes.
# Run: bash scripts/test-pif-sync.sh
set -u
cd "$(dirname "$0")/.."
PASS=0 FAIL=0
ok() { if [ "$2" = "1" ]; then PASS=$((PASS+1)); echo "  ok - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi }

SCRIPT=module/pif-sync.sh
bash -n "$SCRIPT" && ok "pif-sync.sh parses (bash -n)" 1 || ok "pif-sync.sh parses (bash -n)" 0

# Fresh per-case roots (project-local so the sandboxed host's file hooks stay happy)
ROOT=build/test-pif-sync
rm -rf "$ROOT"
mkdir -p "$ROOT"

# Canonical template mirroring what the installer's fill_id leaves behind:
# real Xiaomi backfilled values + TEES patchLevel defaults.
make_cfg() {
    cat > "$1" << 'EOF'
{
  "version": 1,
  "profiles": {
    "default": {
      "keybox": "keybox.xml",
      "mode": "patch",
      "patchLevel": { "system": "today", "vendor": "2026-09-05", "boot": "2026-09-05" },
      "osVersion": "",
      "brand": "Xiaomi",
      "device": "mithor",
      "product": "mithor",
      "manufacturer": "Xiaomi",
      "model": "2312DRAABC",
      "serial": "",
      "imei": "865573070230008",
      "meid": "",
      "imei2": "865573070230016",
      "autoIncludeNewApps": false,
      "apps": ["com.google.android.gms"]
    }
  }
}
EOF
}

# --- case 1: no pif.json anywhere, no marker -> config must be untouched ---
T="$ROOT/case1"; mkdir -p "$T/teesim"
make_cfg "$T/teesim/config.json"
cp "$T/teesim/config.json" "$T/before.json"
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
ok "case1: exits cleanly without any pif.json" 1
cmp -s "$T/before.json" "$T/teesim/config.json" && ok "case1: config untouched" 1 || ok "case1: config untouched" 0
[ -f "$T/teesim/.pif-synced" ] && ok "case1: no marker created" 0 || ok "case1: no marker created" 1

# --- case 2: PIF present -> the profile FOLLOWS the PIF (Round 12 direction) ---
# Inverted from v3.0.13–v3.0.17: the AS-TEESIM runtime config (three greens on
# the K70, 2026-09-10) carries the PIF-spoofed Pixel identity in the profile,
# patchLevel.system = the pif's SECURITY_PATCH, in OBJECT form. The v3.0.12-era
# GMS -66 is attributed to the missing uid pins + switches-off residue of that
# era (apps-sync owns the uid pins now), not to the synced identity itself.
T="$ROOT/case2"; mkdir -p "$T/teesim"
make_cfg "$T/teesim/config.json"
cat > "$T/pif.json" << 'EOF'
{
  "MANUFACTURER": "Google",
  "MODEL": "Pixel 8 Pro",
  "FINGERPRINT": "google/husky/husky:14/AP2A.240905.003/2024090500:user/release-keys",
  "BRAND": "google",
  "PRODUCT": "husky",
  "DEVICE": "husky",
  "SECURITY_PATCH": "2024-09-05",
  "FIRST_API_LEVEL": "34"
}
EOF
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
cfg=$(cat "$T/teesim/config.json")
echo "$cfg" | grep -q '"brand": "google"' && ok "case2: PIF brand mirrored into the profile" 1 \
    || ok "case2: PIF brand mirrored into the profile" 0
echo "$cfg" | grep -q '"model": "Pixel 8 Pro"' && ok "case2: PIF model mirrored" 1 \
    || ok "case2: PIF model mirrored" 0
echo "$cfg" | grep -q '"device": "husky"' && ok "case2: PIF device mirrored" 1 || ok "case2: PIF device mirrored" 0
echo "$cfg" | grep -q '"product": "husky"' && ok "case2: PIF product mirrored" 1 || ok "case2: PIF product mirrored" 0
echo "$cfg" | grep -q '"manufacturer": "Google"' && ok "case2: PIF manufacturer mirrored" 1 \
    || ok "case2: PIF manufacturer mirrored" 0
echo "$cfg" | grep -q '"system": "2024-09-05"' && ok "case2: patchLevel.system follows the pif SECURITY_PATCH" 1 \
    || ok "case2: patchLevel.system follows the pif SECURITY_PATCH" 0
echo "$cfg" | grep -q '"patchLevel": {' && ok "case2: patchLevel stays in object form" 1 \
    || ok "case2: patchLevel stays in object form" 0
echo "$cfg" | grep -q '"vendor": "2026-09-05"' && ok "case2: patchLevel.vendor untouched" 1 \
    || ok "case2: patchLevel.vendor untouched" 0
echo "$cfg" | grep -q '"boot": "2026-09-05"' && ok "case2: patchLevel.boot untouched" 1 \
    || ok "case2: patchLevel.boot untouched" 0
echo "$cfg" | grep -q '"imei": "865573070230008"' && ok "case2: non-PIF fields (imei) preserved" 1 || ok "case2: non-PIF fields (imei) preserved" 0
echo "$cfg" | grep -q '"apps": \["com.google.android.gms"\]' && ok "case2: apps array untouched" 1 || ok "case2: apps array untouched" 0
[ -f "$T/teesim/.pif-synced" ] && ok "case2: marker created" 1 || ok "case2: marker created" 0
grep -q "PIF active (" "$T/teesim/pif-sync.log" && ok "case2: log records the active PIF" 1 || ok "case2: log records the active PIF" 0

# --- case 3: idempotent second run -> no config change ---
cp "$T/teesim/config.json" "$T/after1.json"
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
cmp -s "$T/after1.json" "$T/teesim/config.json" && ok "case3: second run changes nothing (idempotent)" 1 \
    || ok "case3: second run changes nothing (idempotent)" 0

# --- case 4: module-local pif.json found via the candidates list -> mirrored ---
T="$ROOT/case4"; mkdir -p "$T/teesim" "$T/modules/playintegrityfork"
make_cfg "$T/teesim/config.json"
echo '{"BRAND":"google","MODEL":"Pixel 9","SECURITY_PATCH":"2025-03-05","PRODUCT":"tokay","DEVICE":"tokay","MANUFACTURER":"Google"}' > "$T/modules/playintegrityfork/pif.json"
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
grep -q '"model": "Pixel 9"' "$T/teesim/config.json" && ok "case4: module-local pif.json identity mirrored" 1 \
    || ok "case4: module-local pif.json identity mirrored" 0
grep -q '"system": "2025-03-05"' "$T/teesim/config.json" && ok "case4: patchLevel.system follows the module-local pif" 1 \
    || ok "case4: patchLevel.system follows the module-local pif" 0

# --- case 5: PIF removed -> real identity restored, marker cleared ---
T="$ROOT/case5"; mkdir -p "$T/teesim"
cat > "$T/teesim/config.json" << 'EOF'
{
  "profiles": { "default": {
    "patchLevel": { "system": "2024-09-05", "vendor": "2026-09-05", "boot": "2026-09-05" },
    "brand": "google", "device": "husky", "product": "husky",
    "manufacturer": "Google", "model": "Pixel 8 Pro", "imei": ""
  } }
}
EOF
touch "$T/teesim/.pif-synced"
cat > "$T/props.json" << 'EOF'
{ "ro.product.brand": "Xiaomi", "ro.product.device": "mithor", "ro.product.product": "mithor",
  "ro.product.manufacturer": "Xiaomi", "ro.product.model": "2312DRAABC" }
EOF
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" AEGIS_PROP_FILE="$T/props.json" sh "$SCRIPT" >/dev/null 2>&1
cfg2=$(cat "$T/teesim/config.json")
echo "$cfg2" | grep -q '"brand": "Xiaomi"' && ok "case5: brand restored to the real device" 1 || ok "case5: brand restored to the real device" 0
echo "$cfg2" | grep -q '"model": "2312DRAABC"' && ok "case5: model restored" 1 || ok "case5: model restored" 0
echo "$cfg2" | grep -q '"system": "2024-09-05"' && ok "case5: patchLevel.system left alone (not a profile ID)" 1 \
    || ok "case5: patchLevel.system left alone (not a profile ID)" 0
[ -f "$T/teesim/.pif-synced" ] && ok "case5: marker cleared" 0 || ok "case5: marker cleared" 1

# --- case 6: .pif-off kill-switch with a prior sync -> FULL revert incl. patch level ---
T="$ROOT/case6"; mkdir -p "$T/teesim"
cat > "$T/teesim/config.json" << 'EOF'
{
  "profiles": { "default": {
    "patchLevel": { "system": "2026-08-05", "vendor": "2026-09-05", "boot": "2026-09-05" },
    "brand": "google", "device": "shiba", "product": "shiba",
    "manufacturer": "Google", "model": "Pixel 8", "imei": ""
  } }
}
EOF
touch "$T/teesim/.pif-synced" "$T/teesim/.pif-off"
cat > "$T/props.json" << 'EOF'
{ "ro.product.brand": "Xiaomi", "ro.product.device": "mithor", "ro.product.product": "mithor",
  "ro.product.manufacturer": "Xiaomi", "ro.product.model": "2312DRAABC",
  "ro.build.version.security_patch": "2025-11-01" }
EOF
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" AEGIS_PROP_FILE="$T/props.json" sh "$SCRIPT" >/dev/null 2>&1
cfg3=$(cat "$T/teesim/config.json")
echo "$cfg3" | grep -q '"brand": "Xiaomi"' && ok "case6: identity reverted to the real device" 1 \
    || ok "case6: identity reverted to the real device" 0
echo "$cfg3" | grep -q '"system": "2025-11-01"' \
    && ok "case6: patchLevel.system reverted too (full standalone equivalence)" 1 \
    || ok "case6: patchLevel.system reverted too (full standalone equivalence)" 0
echo "$cfg3" | grep -q '"vendor": "2026-09-05"' && ok "case6: vendor patch untouched (never synced)" 1 \
    || ok "case6: vendor patch untouched (never synced)" 0
[ -f "$T/teesim/.pif-synced" ] && ok "case6: sync marker cleared" 0 || ok "case6: sync marker cleared" 1

# --- case 7: .pif-off without a prior sync -> config untouched, no revert churn ---
T="$ROOT/case7"; mkdir -p "$T/teesim"
make_cfg "$T/teesim/config.json"
cp "$T/teesim/config.json" "$T/before7.json"
touch "$T/teesim/.pif-off"
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
cmp -s "$T/before7.json" "$T/teesim/config.json" \
    && ok "case7: kill-switch without a prior sync leaves config untouched" 1 \
    || ok "case7: kill-switch without a prior sync leaves config untouched" 0

# --- case 8: .pif-sync-off -> MIRRORING suppressed, profile untouched, but the
# payload flag health check must STILL run (v3.1.1: a stale flag used to abort
# the whole script and silently disarm every later fix) ---
T="$ROOT/case8"; mkdir -p "$T/teesim" "$T/modules/aegisfusion_rs"
make_cfg "$T/teesim/config.json"
cp "$T/teesim/config.json" "$T/before8.json"
cat > "$T/pif.json" << 'EOF'
{ "BRAND": "google", "MODEL": "Pixel 8", "SECURITY_PATCH": "2026-08-05",
  "PRODUCT": "shiba", "DEVICE": "shiba", "MANUFACTURER": "Google" }
EOF
cat > "$T/modules/aegisfusion_rs/custom.pif.prop" << 'EOF'
MANUFACTURER=Google
MODEL=Pixel 8
spoofBuild=0
spoofProps=0
spoofVendingFinger=0
spoofProvider=1
EOF
touch "$T/teesim/.pif-sync-off"
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
cmp -s "$T/before8.json" "$T/teesim/config.json" \
    && ok "case8: sync-off leaves the profile untouched despite an active PIF" 1 \
    || ok "case8: sync-off leaves the profile untouched despite an active PIF" 0
[ -f "$T/teesim/.pif-synced" ] && ok "case8: no sync marker created" 0 || ok "case8: no sync marker created" 1
grep -q "mirroring suppressed" "$T/teesim/pif-sync.log" \
    && ok "case8: suppression is logged" 1 || ok "case8: suppression is logged" 0
prop8="$T/modules/aegisfusion_rs/custom.pif.prop"
grep -q '^spoofBuild=1$' "$prop8" && ok "case8: flag health check still forces spoofBuild=1" 1 \
    || ok "case8: flag health check still forces spoofBuild=1" 0
grep -q '^spoofProps=1$' "$prop8" && ok "case8: flag health check still forces spoofProps=1" 1 \
    || ok "case8: flag health check still forces spoofProps=1" 0
grep -q '^spoofVendingFinger=1$' "$prop8" && ok "case8: flag health check adds spoofVendingFinger=1" 1 \
    || ok "case8: flag health check adds spoofVendingFinger=1" 0
grep -q '^spoofProvider=0$' "$prop8" && ok "case8: flag health check forces spoofProvider=0" 1 \
    || ok "case8: flag health check forces spoofProvider=0" 0

# --- case 9: direction inversion — a stale REAL profile follows the active PIF
# on the next ordinary sync (the Round 12 mirror_pif path, idempotent) ---
T="$ROOT/case9"; mkdir -p "$T/teesim"
cat > "$T/teesim/config.json" << 'EOF'
{
  "profiles": { "default": {
    "patchLevel": { "system": "2026-08-05", "vendor": "2026-08-05", "boot": "2026-08-05" },
    "brand": "Xiaomi", "device": "mithor", "product": "mithor",
    "manufacturer": "Xiaomi", "model": "2312DRAABC", "imei": ""
  } }
}
EOF
touch "$T/teesim/.pif-synced"
cat > "$T/pif.json" << 'EOF'
{ "BRAND": "google", "MODEL": "Pixel 10 Pro Fold", "SECURITY_PATCH": "2026-08-05",
  "PRODUCT": "rango_beta", "DEVICE": "rango", "MANUFACTURER": "Google" }
EOF
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
cfg9=$(cat "$T/teesim/config.json")
echo "$cfg9" | grep -q '"brand": "google"' && ok "case9: stale real brand migrated to the active PIF" 1 \
    || ok "case9: stale real brand migrated to the active PIF" 0
echo "$cfg9" | grep -q '"model": "Pixel 10 Pro Fold"' && ok "case9: stale real model migrated to the PIF" 1 \
    || ok "case9: stale real model migrated to the PIF" 0
echo "$cfg9" | grep -q '"product": "rango_beta"' && ok "case9: stale real product migrated to the PIF" 1 \
    || ok "case9: stale real product migrated to the PIF" 0
echo "$cfg9" | grep -q '"system": "2026-08-05"' && ok "case9: patchLevel.system kept on the PIF date" 1 \
    || ok "case9: patchLevel.system kept on the PIF date" 0
[ -f "$T/teesim/.pif-synced" ] && ok "case9: sync marker kept (PIF still active)" 1 \
    || ok "case9: sync marker kept (PIF still active)" 0

# --- case 10: product fallback — devices where ro.product.name is somehow
# unreadable fall back to ro.build.product instead of leaving a stale synced
# product in the gate (the v3.0.14 ro.product.product bug class). Rollback
# path: the PIF is GONE, the previously synced profile reverts to real. ---
T="$ROOT/case10"; mkdir -p "$T/teesim"
cat > "$T/teesim/config.json" << 'EOF'
{
  "profiles": { "default": {
    "patchLevel": { "system": "2026-01-01", "vendor": "2026-01-01", "boot": "2026-01-01" },
    "brand": "google", "device": "rango", "product": "rango_beta",
    "manufacturer": "Google", "model": "Pixel 10 Pro Fold", "imei": ""
  } }
}
EOF
touch "$T/teesim/.pif-synced"
cat > "$T/props.json" << 'EOF'
{ "ro.product.brand": "Xiaomi", "ro.product.device": "mithor",
  "ro.product.manufacturer": "Xiaomi", "ro.product.model": "2312DRAABC",
  "ro.build.product": "mithor" }
EOF
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" AEGIS_PROP_FILE="$T/props.json" sh "$SCRIPT" >/dev/null 2>&1
grep -q '"product": "mithor"' "$T/teesim/config.json" && ok "case10: product falls back to ro.build.product" 1 \
    || ok "case10: product falls back to ro.build.product" 0

# --- case 11: legacy STRING patchLevel is rewritten to the OBJECT form ---
# TEES' ConfigStore reads patchLevel with optJSONObject(); a plain-string
# value silently resolves to an EMPTY object (patch dates lost).
T="$ROOT/case11"; mkdir -p "$T/teesim"
cat > "$T/teesim/config.json" << 'EOF'
{
  "profiles": { "default": {
    "patchLevel": "2026-01-01",
    "brand": "Xiaomi", "device": "mithor", "product": "mithor",
    "manufacturer": "Xiaomi", "model": "2312DRAABC", "imei": ""
  } }
}
EOF
cat > "$T/pif.json" << 'EOF'
{ "BRAND": "google", "MODEL": "Pixel 9", "SECURITY_PATCH": "2025-03-05",
  "PRODUCT": "tokay", "DEVICE": "tokay", "MANUFACTURER": "Google" }
EOF
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
cfg11=$(cat "$T/teesim/config.json")
echo "$cfg11" | grep -q '"patchLevel": { "system": "2025-03-05", "vendor": "YYYY-MM-05", "boot": "YYYY-MM-05" }' \
    && ok "case11: string patchLevel rewritten to the object form (system = pif date)" 1 \
    || ok "case11: string patchLevel rewritten to the object form (system = pif date)" 0

# --- case 12: STRONG spoof flags asserted in our OWN bundled custom.pif.prop ---
# The Round 7 diagnostic found ALL switches at 0 (DroidGuard's runtime check
# cannot pass in that state). Only our own module payload is touched; a
# per-key spoof.conf override wins over the default.
T="$ROOT/case12"; mkdir -p "$T/teesim" "$T/modules/aegisfusion_rs"
make_cfg "$T/teesim/config.json"
cat > "$T/modules/aegisfusion_rs/custom.pif.prop" << 'EOF'
FINGERPRINT=google/caiman_beta/caiman:CANARY/ZP11.260717.006/16004061:user/release-keys
MANUFACTURER=Google
MODEL=Pixel 9 Pro
BRAND=google
PRODUCT=caiman_beta
DEVICE=caiman
SECURITY_PATCH=2026-07-05
spoofBuild=0
spoofProps=0
spoofProvider=1
EOF
echo "spoofVendingFinger=0" > "$T/teesim/spoof.conf"
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
pif12=$(cat "$T/modules/aegisfusion_rs/custom.pif.prop")
echo "$pif12" | grep -q '^spoofBuild=1$' && ok "case12: spoofBuild asserted to 1" 1 || ok "case12: spoofBuild asserted to 1" 0
echo "$pif12" | grep -q '^spoofProps=1$' && ok "case12: spoofProps asserted to 1" 1 || ok "case12: spoofProps asserted to 1" 0
echo "$pif12" | grep -q '^spoofProvider=0$' && ok "case12: spoofProvider asserted to 0" 1 || ok "case12: spoofProvider asserted to 0" 0
echo "$pif12" | grep -q '^spoofVendingFinger=0$' && ok "case12: spoof.conf override respected (VendingFinger stays 0)" 1 \
    || ok "case12: spoof.conf override respected (VendingFinger stays 0)" 0
echo "$pif12" | grep -q '"brand"' && ok "case12: config untouched by the flag pass (identity mirrored from prop)" 0 \
    || ok "case12: config untouched by the flag pass (identity mirrored from prop)" 1
grep -q '"model": "Pixel 9 Pro"' "$T/teesim/config.json" && ok "case12: prop payload identity mirrored into the profile" 1 \
    || ok "case12: prop payload identity mirrored into the profile" 0
grep -q '"system": "2026-07-05"' "$T/teesim/config.json" && ok "case12: patchLevel.system follows the prop payload date" 1 \
    || ok "case12: patchLevel.system follows the prop payload date" 0

# --- case 13: flag assertion is idempotent (second run edits nothing) ---
cp "$T/modules/aegisfusion_rs/custom.pif.prop" "$T/pif-after1.prop"
cp "$T/teesim/config.json" "$T/cfg-after1.json"
AEGIS_ADB="$T" AEGIS_TEE_DIR="$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
cmp -s "$T/pif-after1.prop" "$T/modules/aegisfusion_rs/custom.pif.prop" \
    && ok "case13: second run leaves the prop untouched (idempotent)" 1 \
    || ok "case13: second run leaves the prop untouched (idempotent)" 0
cmp -s "$T/cfg-after1.json" "$T/teesim/config.json" \
    && ok "case13: second run leaves the config untouched (idempotent)" 1 \
    || ok "case13: second run leaves the config untouched (idempotent)" 0

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
