#!/usr/bin/env bash
# verify-artifact.sh — post-build unpack assertions for an AegisFusion zip.
# Audits r3/r4 (and the N1-N8 response) require these checks against the CI
# artifact BEFORE any release: the source tree can be clean while a stale or
# unhardened payload silently ships.
#
# Usage: bash scripts/verify/verify-artifact.sh <path-to-AegisFusion-*.zip>
# Exit 0 = every assertion passed (artifact is release-candidate);
# exit 1 = at least one assertion failed (do NOT distribute).
set -u

ZIP="${1:?usage: verify-artifact.sh <AegisFusion-*.zip>}"
[ -f "$ZIP" ] || { echo "!! no such file: $ZIP" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/af-verify.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
unzip -qq "$ZIP" -d "$WORK" || { echo "!! unzip failed" >&2; exit 1; }

PASS=0 FAIL=0
ok()  { if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok  - $1"; else FAIL=$((FAIL+1)); echo "  FAIL- $1"; fi; }

echo "== verifying $(basename "$ZIP")"

# --- C1: bundled PIF scripts must be hardened -------------------------------
# exactly 1 literal --no-check-certificate: the probe's fallback assignment
# (SSL_FLAG="--no-check-certificate") — all 8 download sites must use $SSL_FLAG.
_n=$(grep -c -- '--no-check-certificate' "$WORK/autopif4.sh" 2>/dev/null || echo 0)
[ "$_n" = "1" ] && ok "autopif4.sh: exactly 1 literal --no-check-certificate (probe fallback only)" 1 \
                || ok "autopif4.sh: --no-check-certificate count = $_n (want 1)" 0
_n=$(grep -o '\$SSL_FLAG' "$WORK/autopif4.sh" 2>/dev/null | wc -l)
[ "$_n" = "8" ] && ok "autopif4.sh: 8 SSL_FLAG download sites (hardened)" 1 \
                || ok "autopif4.sh: SSL_FLAG count = $_n (want 8)" 0
grep -q 'TLS verification: probe FAILED' "$WORK/autopif4.sh" \
    && ok "autopif4.sh: N4 probe block present (full GET, loud downgrade)" 1 \
    || ok "autopif4.sh: N4 probe block missing" 0
grep -q 'eval $FIELD=' "$WORK/migrate.sh" \
    && ok "migrate.sh: no 'eval FIELD=' (C1 RCE chain cut)" 0 \
    || ok "migrate.sh: no 'eval FIELD=' (C1 RCE chain cut)" 1
grep -q 'eval set --' "$WORK/migrate.sh" \
    && ok "migrate.sh: no 'eval set --'" 0 \
    || ok "migrate.sh: no 'eval set --'" 1

# --- H1: diagnostics export must mask device identifiers --------------------
grep -q 'maskDeviceIds' "$WORK/webroot/js/logs.js" \
    && ok "logs.js: maskDeviceIds present" 1 \
    || ok "logs.js: maskDeviceIds MISSING (H1 open)" 0
grep -qF '(secondImei|imei2|imei|meid|serialno|serial)"\s*:\s*"' "$WORK/webroot/js/logs.js" \
    && ok "logs.js: JSON-form mask rule present (audit N1)" 1 \
    || ok "logs.js: JSON-form mask rule missing (audit N1)" 0
grep -q 'chmod 0600' "$WORK/webroot/js/logs.js" \
    && ok "logs.js: diagnostic file written 0600 (L8)" 1 \
    || ok "logs.js: diagnostic file not 0600" 0

# --- r5: every mask copy must ship WIDENED (form-independent) ---------------
# There are four copies of the mask: the JS export (logs.js), the two scripts
# whose output is pasted into reports (engine-check.sh, engine-verdict.sh) and
# the install-time in-place rewriter (customize.sh). Until audit r5 the
# unquoted rule accepted only [A-Za-z0-9]{4,} right after '=', which let a
# hyphenated value, a short-prefix value, a space-separated value and the
# serialno property the engine reads through untouched — into a file that lands
# on world-readable /sdcard/Download. A source tree that is fixed while the
# staged overlay is stale ships the leak anyway; that is exactly what this
# post-unpack check is for.
for _c in webroot/js/logs.js engine-check.sh engine-verdict.sh customize.sh; do
    grep -qF 'serialno|serial' "$WORK/$_c" 2>/dev/null \
        && ok "$_c: r5 widened key list (serialno) present" 1 \
        || ok "$_c: r5 widened key list MISSING (stale mask copy)" 0
done
for _c in engine-check.sh engine-verdict.sh customize.sh; do
    grep -qF ';)}]+' "$WORK/$_c" 2>/dev/null \
        && ok "$_c: r5 widened value class present" 1 \
        || ok "$_c: r5 widened value class MISSING" 0
done
grep -qF ';)\]}]+' "$WORK/webroot/js/logs.js" 2>/dev/null \
    && ok "webroot/js/logs.js: r5 widened value class present" 1 \
    || ok "webroot/js/logs.js: r5 widened value class MISSING" 0
if grep -qF '=([A-Za-z0-9]{4,})' "$WORK/webroot/js/logs.js" 2>/dev/null; then
    ok "logs.js: old alnum-only unquoted rule is gone" 0
else
    ok "logs.js: old alnum-only unquoted rule is gone" 1
fi

# --- N2: the upstream console must NOT ship ---------------------------------
if ls -d "$WORK/webroot/teesim" >/dev/null 2>&1; then
    ok "webroot/teesim absent (upstream console dropped, audit N2)" 0
else
    ok "webroot/teesim absent (upstream console dropped, audit N2)" 1
fi
grep -q 'head -c 1200' "$WORK/engine-check.sh" \
    && ok "engine-check.sh: raw /status print absent (audit N1)" 0 \
    || ok "engine-check.sh: raw /status print absent (audit N1)" 1

# --- patch 0006: the ENGINE binary must log masked harvest lines ------------
# only CI-compiled truth: the dex must NOT carry the plaintext format string.
if [ -f "$WORK/teesim-service.dex" ]; then
    DEX="$WORK/teesim-service.dex"
elif [ -f "$WORK/service.apk" ]; then
    DEX="$WORK/service.apk"
else
    DEX=""
    ok "teesim-service.dex/service.apk present" 0
fi
if [ -n "$DEX" ]; then
    grep -aq "imei='" "$DEX" \
        && ok "engine dex: NO plaintext imei=' format string (patch 0006 in)" 0 \
        || ok "engine dex: NO plaintext imei=' format string (patch 0006 in)" 1
    grep -aq "len=" "$DEX" \
        && ok "engine dex: masked 'len=' harvest form present" 1 \
        || ok "engine dex: 'len=' harvest form MISSING (pre-0006 payload?)" 0
fi

# --- sanity: core files exist -----------------------------------------------
# R7-1 (2026-09-19, review finding): the install-time fetch must never shadow a
# surviving identity. It may only run when NEITHER the module dir NOR the
# durable master ($TEE_DIR/pif-master) holds a fingerprint - otherwise a module
# update would replace the restored identity (including a user-curated one)
# because pif-fetch's restore pass is skipped once the module dir has a file.
grep -qF 'pif-master/custom.pif.prop' "$WORK/customize.sh" 2>/dev/null \
    && ok "customize.sh: install-time fetch respects the durable master (R7-1)" 1 \
    || ok "customize.sh: durable-master guard MISSING (R7-1 regression)" 0
grep -qF 'for f in custom.pif.prop custom.pif.json; do' "$WORK/customize.sh" 2>/dev/null \
    && ok "customize.sh: fetch accepts only canonical outputs (R7-1)" 1 \
    || ok "customize.sh: canonical-output guard MISSING (R7-1)" 0

# U3 + R7-2 functional regression (2026-09-19): the SHIPPED migrate.sh must treat
# a value containing command substitutions as pure data. The harden layer
# rebuilds this file from the upstream zip on every build, so a drifted patch
# pattern could silently restore the old `eval` - counting greps would not catch
# that, running it does. Measured before the fix: both `$(...)` and backticks
# executed (files appeared); after: inert.
_inj="$(mktemp -d 2>/dev/null)" || _inj=""
if [ -n "$_inj" ] && [ -f "$WORK/migrate.sh" ]; then
    printf 'MODEL=$(touch %s/PWNED_A)\nFINGERPRINT=`touch %s/PWNED_B`\nMANUFACTURER=Google\n' "$_inj" "$_inj" > "$_inj/in.prop"
    ( cd "$_inj" && sh "$WORK/migrate.sh" -p in.prop out.prop >/dev/null 2>&1 ) || true
    if [ -e "$_inj/PWNED_A" ] || [ -e "$_inj/PWNED_B" ]; then
        ok "migrate.sh: hostile value EXECUTED code (U3/R7-2 regression)" 0
    else
        ok "migrate.sh: hostile value stays inert (U3/R7-2 holds)" 1
    fi
    rm -rf "$_inj" 2>/dev/null
fi

# 'undefined variable' class guard (2026-09-19): a script that reads $TEE_DIR
# without defining it silently writes to "/" instead (mkdir -p "" is a no-op and
# the writes are 2>/dev/null'd) - that is exactly how the R7-1 install-time fetch
# shipped with a dead durable-master guard. Any shipped script referencing it
# must define it (env-overridable, like the other scripts).
# --- verdict socket fallback + inherited schedule (2026-09-20) -------------
# On ROMs with logging disabled the durable engine trace never fills, so the
# verdict must be able to read the daemon's in-memory push/ack state over the
# admin socket (patch 0007), and the keybox schedule must be anchored on the
# last successful fetch instead of an in-memory counter that resets every boot.
if grep -q 'socket_verdict' "$WORK/engine-verdict.sh" 2>/dev/null \
   && grep -q 'socket-live' "$WORK/keybox-fetch.sh" 2>/dev/null; then
    ok "engine verdict: admin-socket fallback present (logcat-dead devices)" 1
else
    ok "engine verdict: admin-socket fallback present (logcat-dead devices)" 0
fi
if grep -qF '.kb-last-fetch' "$WORK/service.sh" 2>/dev/null \
   && grep -qF 'now - lfts))" -ge "$((iv * 3600))' "$WORK/service.sh" 2>/dev/null; then
    ok "keybox schedule: anchored on the last successful fetch (inherits)" 1
else
    ok "keybox schedule: anchored on the last successful fetch (inherits)" 0
fi

# --- installer copy must follow the user's real setting (F-4, 2026-09-19) ---
# The installer summary hardcoded "every 24h" while the device had 12h, and the
# WebUI's own scale (0/12/24/72/168, 0 = off) makes two ways to lie: the wrong
# number, and a cadence claim while the user has auto-fetch switched OFF.
if grep -q 'keybox-refresh' "$WORK/customize.sh" 2>/dev/null \
   && ! grep -qE 'every 24h \(STRONG' "$WORK/customize.sh" 2>/dev/null; then
    ok "installer: reports the configured keybox interval, not a constant" 1
else
    ok "installer: reports the configured keybox interval, not a constant" 0
fi
if grep -q 'auto-fetch is OFF' "$WORK/customize.sh" 2>/dev/null; then
    ok "installer: says OFF when the user disabled auto-fetch (0)" 1
else
    ok "installer: says OFF when the user disabled auto-fetch (0)" 0
fi

# --- keybox verdict anchor + boot ordering (2026-09-19) -------------------
# The verdict is anchored on the keybox CONTENT (kbhash) because identical bytes
# get re-written by several paths (TrickyStore symlink materialisation, backup
# restores, identical re-deploys); an mtime-only anchor called those verdicts
# stale forever and the WebUI sat on "待引擎确认（keybox 刚变更）" (author's field
# report after a v3.2.3 -> v1.0.1 update). Two readers implement the rule
# separately - engine-verdict.sh's show branch and the launcher.js probe - and
# this project has repeatedly shipped a fix to one copy only, so assert both.
if grep -q 'kbhash' "$WORK/engine-verdict.sh" 2>/dev/null \
   && grep -q 'kbhash' "$WORK/webroot/js/launcher.js" 2>/dev/null; then
    ok "keybox verdict: both readers anchor on the content hash" 1
else
    ok "keybox verdict: both readers anchor on the content hash (one copy is missing it)" 0
fi
# The recorded anchor must describe the keybox the daemon is about to read: the
# boot-time symlink materialisation rewrites keybox.xml, so it has to run first.
_ks=$(grep -n 'TEE keybox: validate it BEFORE' "$WORK/service.sh" 2>/dev/null | head -1 | cut -d: -f1)
_kv=$(grep -n 'boot-time engine verdict' "$WORK/service.sh" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$_ks" ] && [ -n "$_kv" ] && [ "$_ks" -lt "$_kv" ]; then
    ok "service.sh: keybox materialisation precedes the boot verdict" 1
else
    ok "service.sh: keybox materialisation precedes the boot verdict" 0
fi
# The hourly tick must be able to converge a stale/absent verdict without a reboot.
if grep -q 'engine-verdict.sh" show' "$WORK/service.sh" 2>/dev/null; then
    ok "service.sh: hourly tick re-takes a stale verdict" 1
else
    ok "service.sh: hourly tick re-takes a stale verdict" 0
fi
# Same class as the TEE_DIR bug: an undefined variable that silently writes to
# "/" - here it would be a freeze instead. apps.js must not enumerate the app
# list before it has painted the placeholder.
if grep -q "正在读取应用列表" "$WORK/webroot/js/apps.js" 2>/dev/null; then
    ok "apps page: paints a loading placeholder before enumerating" 1
else
    ok "apps page: paints a loading placeholder before enumerating" 0
fi

for _f in "$WORK"/*.sh; do
    [ -f "$_f" ] || continue
    if grep -q '\$TEE_DIR' "$_f" 2>/dev/null; then
        grep -q '^TEE_DIR=' "$_f" 2>/dev/null \
            && ok "$(basename "$_f"): defines TEE_DIR before use" 1 \
            || ok "$(basename "$_f"): uses \$TEE_DIR but never defines it" 0
    fi
done

for f in module.prop customize.sh service.sh keybox-fetch.sh pif-fetch.sh \
         engine-check.sh engine-verdict.sh keybox-swap.sh webroot/index.html; do
    [ -f "$WORK/$f" ] && ok "core file: $f" 1 || ok "core file: $f MISSING" 0
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
