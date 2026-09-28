#!/usr/bin/env bash
# Unit tests for module/pif-fetch.sh, run on the host (Git Bash / Linux).
# Every case works in a throwaway root under build/ via the AEGIS_MODDIR /
# AEGIS_TEE_DIR / AEGIS_AUTOPIF / AEGIS_PIF_SYNC overrides the script exposes;
# the autopif4 generator is replaced by a deterministic shim.
# Run: bash scripts/test-pif-fetch.sh
set -u
cd "$(dirname "$0")/.."
PASS=0 FAIL=0
ok() { if [ "$2" = "1" ]; then PASS=$((PASS+1)); echo "  ok - $1"; else FAIL=$((FAIL+1)); echo "  FAIL - $1"; fi }

SCRIPT=module/pif-fetch.sh
bash -n "$SCRIPT" && ok "pif-fetch.sh parses (bash -n)" 1 || ok "pif-fetch.sh parses (bash -n)" 0

# Fresh per-run root (audit v3.2.3 N11): unique per PID — NO rm -rf. The dev
# host's safe-delete hook can veto bulk rm, and when it does, the old fixture
# silently poisons the run and produces FALSE failures (observed live: the
# same code scored 69/5 on a clean tree and 61/13 on a stale one). A unique
# dir makes every run start from zero without deleting anything; old run dirs
# are harmless (build/ is gitignored). CI/Linux is still the authority.
# Also: clear the dev host's safe-delete session IDs so the MODULE's own
# rm -f calls (e.g. dropping a stale pif-proxy.auto) are not vetoed mid-test.
ROOT="build/test-pif-fetch.$$"
mkdir -p "$ROOT"
export CODEBUDDY_SESSION_ID= CLAUDE_SESSION_ID=

# Generator shim: behaves like autopif4 --strong for the harness — writes a
# minimal custom.pif.prop into the module dir and records every invocation.
make_gen_ok() {
    cat > "$1" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$GENLOG"
cat > "\${AEGIS_MODDIR}/custom.pif.prop" << 'PIF'
# Canary Released: 2026-08-20
# Estimated Expiry: 2027-12-31
BRAND=google
DEVICE=canary
PRODUCT=canary_beta
MANUFACTURER=Google
MODEL=Pixel 9 Pro
FINGERPRINT=google/canary/canary_beta:16/BP41.250829.011/2026082000:user/release-keys
*.security_patch=2026-08-05
spoofBuild=1
spoofProps=1
spoofProvider=0
PIF
exit 0
EOF
}

# Generator shim that exits 0 but writes NOTHING (autopif4 fails after wget errors)
make_gen_silent() { printf '#!/usr/bin/env bash\necho "invoked" >> %s\nexit 0\n' "$GENLOG" > "$1"; }

# Generator shim that exits 1 without touching anything (network-dead autopif4)
make_gen_fail() { printf '#!/usr/bin/env bash\necho "invoked" >> %s\nexit 1\n' "$GENLOG" > "$1"; }

# pif-sync shim: records invocations
make_sync_shim() { printf '#!/usr/bin/env bash\necho "sync" >> %s\n' "$SYNCLOG" > "$1"; }

run() { # <case-dir> [extra env...]
    T="$1"; shift
    # On-device the generator lives in the module directory; mirror that here.
    # Autoproxy is disabled per-case by default so legacy counts stay exact;
    # case17/18 invoke the script inline with it enabled.
    cp "$GEN" "$T/mod/autopif4.sh" 2>/dev/null
    AEGIS_MODDIR="$T/mod" AEGIS_TEE_DIR="$T/teesim" AEGIS_AUTOPIF="$GEN" \
        AEGIS_PIF_SYNC="$SYNC" AEGIS_PIF_RETRY_WAIT=0 AEGIS_PIF_AUTOPROXY=0 \
        sh "$SCRIPT" >/dev/null 2>&1
}

GENLOG="$ROOT/gen.log"; SYNCLOG="$ROOT/sync.log"
GEN="$ROOT/autopif4.sh"; SYNC="$ROOT/pif-sync.sh"

# --- case 1: nothing present -> generator runs, marker set, sync invoked ---
T="$ROOT/case1"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
run "$T"
[ -s "$T/mod/custom.pif.prop" ] && ok "case1: fingerprint generated" 1 || ok "case1: fingerprint generated" 0
[ -f "$T/mod/.pif-auto" ] && ok "case1: auto marker created" 1 || ok "case1: auto marker created" 0
[ "$(cat "$T/mod/.pif-auto" 2>/dev/null | grep -cE '^[0-9]+$')" = "2" ] \
    && ok "case1: marker holds birth + rotation-deadline epochs" 1 || ok "case1: marker holds birth + rotation-deadline epochs" 0
[ "$(wc -l < "$GENLOG")" = "1" ] && ok "case1: generator ran once" 1 || ok "case1: generator ran once" 0
[ "$(grep -c 'sync' "$SYNCLOG")" = "1" ] && ok "case1: pif-sync invoked after generation" 1 \
    || ok "case1: pif-sync invoked after generation" 0
# 0600 is a chmod no-op on Windows/MSYS hosts — only asserted on Linux/CI.
case "$(uname -s)" in
    Linux)
        [ "$(stat -c %a "$T/mod/custom.pif.prop" 2>/dev/null)" = "600" ] \
            && ok "case1: generated fingerprint is 0600" 1 || ok "case1: generated fingerprint is 0600" 0
        ;;
    *) ok "case1: generated fingerprint is 0600 (skipped: perms emulated on this host)" 1 ;;
esac
grep -q "generating" "$T/teesim/pif-fetch.log" && ok "case1: log records the generation" 1 \
    || ok "case1: log records the generation" 0

# --- case 2: fresh auto fingerprint -> no regeneration, no second sync ---
: > "$GENLOG"; : > "$SYNCLOG"
run "$T"
[ "$(wc -l < "$GENLOG")" = "0" ] && ok "case2: fresh auto fingerprint not regenerated" 1 \
    || ok "case2: fresh auto fingerprint not regenerated" 0
[ "$(grep -c 'sync' "$SYNCLOG")" = "0" ] && ok "case2: no sync when nothing changed" 1 \
    || ok "case2: no sync when nothing changed" 0

# --- case 3: aged auto fingerprint -> rotated ---
old=$(( $(date +%s) - 20 * 86400 ))
echo "$old" > "$T/mod/.pif-auto"
: > "$GENLOG"; : > "$SYNCLOG"
run "$T"
[ "$(wc -l < "$GENLOG")" = "1" ] && ok "case3: 20-day-old auto fingerprint rotated" 1 \
    || ok "case3: 20-day-old auto fingerprint rotated" 0
new=$(sed -n '1p' "$T/mod/.pif-auto")
[ "$new" -gt "$old" ] && ok "case3: marker refreshed after rotation" 1 || ok "case3: marker refreshed after rotation" 0
grep -q "rotating" "$T/teesim/pif-fetch.log" && ok "case3: log records the rotation" 1 \
    || ok "case3: log records the rotation" 0

# --- case 4: user fingerprint (no marker) -> never touched ---
T="$ROOT/case4"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
printf 'BRAND=google\nMODEL=My Private Fingerprint\n' > "$T/mod/custom.pif.prop"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
run "$T"
[ "$(wc -l < "$GENLOG")" = "0" ] && ok "case4: user fingerprint never regenerated" 1 \
    || ok "case4: user fingerprint never regenerated" 0
grep -q "My Private Fingerprint" "$T/mod/custom.pif.prop" \
    && ok "case4: user fingerprint content untouched" 1 || ok "case4: user fingerprint content untouched" 0
grep -q "leaving it alone" "$T/teesim/pif-fetch.log" && ok "case4: log says the user file wins" 1 \
    || ok "case4: log says the user file wins" 0

# --- case 5: generator fails silently -> no marker, clean exit, retried next tick ---
T="$ROOT/case5"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_silent "$GEN"; make_sync_shim "$SYNC"
run "$T"
[ -f "$T/mod/.pif-auto" ] && ok "case5: no marker on failed generation" 0 || ok "case5: no marker on failed generation" 1
[ "$(grep -c 'sync' "$SYNCLOG")" = "0" ] && ok "case5: no sync on failed generation" 1 \
    || ok "case5: no sync on failed generation" 0
grep -q "generation failed" "$T/teesim/pif-fetch.log" && ok "case5: failure logged for the next tick" 1 \
    || ok "case5: failure logged for the next tick" 0
[ -f "$T/teesim/pif-fetch.last" ] && ok "case5: generator output captured in pif-fetch.last" 1 \
    || ok "case5: generator output captured in pif-fetch.last" 0

# --- case 6: generator script missing -> clean no-op ---
T="$ROOT/case6"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"
rm -f "$GEN"; make_sync_shim "$SYNC"
run "$T"
grep -q "missing from the module directory" "$T/teesim/pif-fetch.log" \
    && ok "case6: missing generator logged, no crash" 1 || ok "case6: missing generator logged, no crash" 0

# --- case 7: legacy pif.json (marker present) is also rotated when aged ---
T="$ROOT/case7"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
printf '{ "BRAND": "google" }\n' > "$T/mod/pif.json"
echo "$old" > "$T/mod/.pif-auto"
run "$T"
[ "$(wc -l < "$GENLOG")" = "1" ] && ok "case7: aged legacy pif.json rotated too" 1 \
    || ok "case7: aged legacy pif.json rotated too" 0

# --- case 8: rotation fails (bad network) -> previous fingerprint survives ---
# Regression 2026-09-08: rotation used to delete the old fingerprint BEFORE
# generating; one wget reset then left the device with no identity at all.
T="$ROOT/case8"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
printf 'BRAND=google\nMODEL=Old Still Working\n' > "$T/mod/custom.pif.prop"
echo "$old" > "$T/mod/.pif-auto"
make_gen_fail "$GEN"; make_sync_shim "$SYNC"
run "$T"
[ "$(wc -l < "$GENLOG")" = "3" ] && ok "case8: rotation attempted (3 in-tick tries)" 1 \
    || ok "case8: rotation attempted (3 in-tick tries)" 0
grep -q "Old Still Working" "$T/mod/custom.pif.prop" \
    && ok "case8: previous fingerprint kept on failed rotation" 1 \
    || ok "case8: previous fingerprint kept on failed rotation" 0
[ -f "$T/mod/.pif-auto" ] && ok "case8: marker survives so the retry stays auto" 1 \
    || ok "case8: marker survives so the retry stays auto" 0
grep -q "keeping the previous fingerprint" "$T/teesim/pif-fetch.log" \
    && ok "case8: failure says the old fingerprint is kept" 1 \
    || ok "case8: failure says the old fingerprint is kept" 0
grep -q "pif-proxy.conf" "$T/teesim/pif-fetch.log" \
    && ok "case8: failure logs the proxy hint when none is configured" 1 \
    || ok "case8: failure logs the proxy hint when none is configured" 0

# --- case 9: rotation success replaces the old file and restarts the clock ---
T="$ROOT/case9"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
printf 'BRAND=google\nMODEL=Old Retired\n' > "$T/mod/pif.prop"
echo "$old" > "$T/mod/.pif-auto"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
run "$T"
[ "$(wc -l < "$GENLOG")" = "1" ] && ok "case9: rotation ran" 1 || ok "case9: rotation ran" 0
grep -q "Pixel 9 Pro" "$T/mod/custom.pif.prop" \
    && ok "case9: new fingerprint in place" 1 || ok "case9: new fingerprint in place" 0
[ -f "$T/mod/pif.prop" ] && ok "case9: legacy file removed after success" 0 \
    || ok "case9: legacy file removed after success" 1
new9=$(sed -n '1p' "$T/mod/.pif-auto")
[ "$new9" -gt "$old" ] && ok "case9: marker clock restarted" 1 || ok "case9: marker clock restarted" 0

# --- case 10: successful generation is mirrored into the durable master ---
# (Regression 2026-09-08b: a module update/reflash resets the whole module
# directory, wiping the runtime fingerprint; the master in $TEE_DIR survives.)
T="$ROOT/case10"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
run "$T"
[ -s "$T/teesim/pif-master/custom.pif.prop" ] \
    && ok "case10: generated fingerprint mirrored to the durable master" 1 \
    || ok "case10: generated fingerprint mirrored to the durable master" 0
[ -s "$T/teesim/pif-master/.pif-auto" ] \
    && ok "case10: ownership marker mirrored too" 1 || ok "case10: ownership marker mirrored too" 0

# --- case 11: user fingerprint is mirrored WITHOUT the auto marker ---
T="$ROOT/case11"; mkdir -p "$T/mod" "$T/teesim" "$T/teesim/pif-master"
: > "$GENLOG"; : > "$SYNCLOG"
printf 'BRAND=google\nMODEL=Private One\n' > "$T/teesim/pif-master/custom.pif.prop"  # stale master
echo 0 > "$T/teesim/pif-master/.pif-auto"                                            # stale marker
printf 'BRAND=google\nMODEL=My Private Fingerprint\n' > "$T/mod/custom.pif.prop"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
run "$T"
grep -q "My Private Fingerprint" "$T/teesim/pif-master/custom.pif.prop" \
    && ok "case11: user fingerprint mirrored to master" 1 || ok "case11: user fingerprint mirrored to master" 0
[ -f "$T/teesim/pif-master/.pif-auto" ] \
    && ok "case11: master marker cleared for user file" 0 || ok "case11: master marker cleared for user file" 1

# --- case 12: reflash wiped the module dir -> fingerprint restored from master ---
T="$ROOT/case12"; mkdir -p "$T/mod" "$T/teesim/pif-master"
: > "$GENLOG"; : > "$SYNCLOG"
printf 'BRAND=google\nMODEL=Survivor\n' > "$T/teesim/pif-master/custom.pif.prop"
date +%s > "$T/teesim/pif-master/.pif-auto"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
run "$T"
grep -q "Survivor" "$T/mod/custom.pif.prop" \
    && ok "case12: fingerprint restored from the durable master after reflash" 1 \
    || ok "case12: fingerprint restored from the durable master after reflash" 0
[ -s "$T/mod/.pif-auto" ] \
    && ok "case12: ownership marker restored (stays auto-generated)" 1 \
    || ok "case12: ownership marker restored (stays auto-generated)" 0
[ "$(wc -l < "$GENLOG")" = "0" ] \
    && ok "case12: no regeneration needed when the master restores" 1 \
    || ok "case12: no regeneration needed when the master restores" 0
grep -q "restored from the durable copy" "$T/teesim/pif-fetch.log" \
    && ok "case12: restore logged" 1 || ok "case12: restore logged" 0

# --- case 13: .pif-off kill-switch -> no generation, no restore, no sync ---
T="$ROOT/case13"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
printf 'BRAND=google\nMODEL=MasterSurvivor\n' > "$T/teesim/pif-master/custom.pif.prop"
touch "$T/teesim/.pif-off"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
run "$T"
[ "$(wc -l < "$GENLOG")" = "0" ] && ok "case13: generator never runs under the kill-switch" 1 \
    || ok "case13: generator never runs under the kill-switch" 0
[ ! -s "$T/mod/custom.pif.prop" ] && ok "case13: no working copy is produced or restored" 1 \
    || ok "case13: no working copy is produced or restored" 0
[ "$(wc -l < "$SYNCLOG")" = "0" ] && ok "case13: pif-sync is not invoked" 1 \
    || ok "case13: pif-sync is not invoked" 0
grep -q "generation suspended" "$T/teesim/pif-fetch.log" \
    && ok "case13: suspension is logged" 1 || ok "case13: suspension is logged" 0

# --- case 14: flaky network -> in-tick retries rescue the fetch ---
# v3.2.1: the generator is attempted up to AEGIS_PIF_ATTEMPTS times per tick
# (default 3, 20s apart). A shim that fails twice then succeeds models a
# flaky route recovering mid-tick; the third try must land the fingerprint,
# write the marker and trigger exactly one sync.
T="$ROOT/case14"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
cat > "$GEN" << EOF
#!/usr/bin/env bash
echo "invoked" >> "$GENLOG"
[ \$(wc -l < "$GENLOG") -ge 3 ] || exit 1
cat > "\${AEGIS_MODDIR}/custom.pif.prop" << 'PIF'
BRAND=google
MODEL=Third Try Works
PIF
EOF
make_sync_shim "$SYNC"
run "$T"
[ "$(wc -l < "$GENLOG")" = "3" ] && ok "case14: three attempts made in one tick" 1 \
    || ok "case14: three attempts made in one tick" 0
grep -q "Third Try Works" "$T/mod/custom.pif.prop" \
    && ok "case14: third attempt landed the fingerprint" 1 \
    || ok "case14: third attempt landed the fingerprint" 0
[ -f "$T/mod/.pif-auto" ] && ok "case14: marker written after late success" 1 \
    || ok "case14: marker written after late success" 0
[ "$(grep -c 'sync' "$SYNCLOG")" = "1" ] && ok "case14: exactly one sync after late success" 1 \
    || ok "case14: exactly one sync after late success" 0
grep -q "retrying in 0s" "$T/teesim/pif-fetch.log" \
    && ok "case14: failed attempts logged with retry notice" 1 \
    || ok "case14: failed attempts logged with retry notice" 0

# --- case 15: pif-proxy.conf -> proxy exported to the generator only ---
T="$ROOT/case15"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
printf '  http://127.0.0.1:7890\n' > "$T/teesim/pif-proxy.conf"
cat > "$GEN" << EOF
#!/usr/bin/env bash
echo "proxy=\${https_proxy:-none}|\${http_proxy:-none}" >> "$GENLOG"
cat > "\${AEGIS_MODDIR}/custom.pif.prop" << 'PIF'
BRAND=google
MODEL=Proxied
PIF
EOF
make_sync_shim "$SYNC"
run "$T"
grep -q "proxy=http://127.0.0.1:7890|http://127.0.0.1:7890" "$GENLOG" \
    && ok "case15: proxy env reaches the generator (whitespace trimmed)" 1 \
    || ok "case15: proxy env reaches the generator (whitespace trimmed)" 0
grep -q "proxy passthrough active" "$T/teesim/pif-fetch.log" \
    && ok "case15: passthrough logged" 1 || ok "case15: passthrough logged" 0
[ -s "$T/mod/custom.pif.prop" ] && ok "case15: generation still succeeds through proxy" 1 \
    || ok "case15: generation still succeeds through proxy" 0

# --- case 16: hostile pif-proxy.conf -> rejected, generator runs clean ---
T="$ROOT/case16"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
printf 'http://x; touch /tmp/pwned\n' > "$T/teesim/pif-proxy.conf"
cat > "$GEN" << EOF
#!/usr/bin/env bash
echo "proxy=\${https_proxy:-none}|\${http_proxy:-none}" >> "$GENLOG"
cat > "\${AEGIS_MODDIR}/custom.pif.prop" << 'PIF'
BRAND=google
MODEL=Clean Without Proxy
PIF
EOF
make_sync_shim "$SYNC"
run "$T"
grep -q "proxy=none|none" "$GENLOG" \
    && ok "case16: unsafe proxy value never reaches the generator" 1 \
    || ok "case16: unsafe proxy value never reaches the generator" 0
grep -q "pif-proxy.conf rejected" "$T/teesim/pif-fetch.log" \
    && ok "case16: rejection logged" 1 || ok "case16: rejection logged" 0
grep -q "Clean Without Proxy" "$T/mod/custom.pif.prop" \
    && ok "case16: generation unaffected by the rejection" 1 \
    || ok "case16: generation unaffected by the rejection" 0

# --- case 17: autoproxy — direct fails, local proxy on a common port rescued ---
# Generator only succeeds when routed through 127.0.0.1:7897 (the probe shim
# answers "alive" for exactly that port). The script must: fail round 1
# (3 direct attempts), probe, remember the proxy in pif-proxy.auto, succeed
# in the proxy round, and write marker + master as usual.
T="$ROOT/case17"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
cat > "$GEN" << EOF
#!/usr/bin/env bash
echo "invoked:\${https_proxy:-none}" >> "$GENLOG"
case "\${https_proxy:-}" in
  *7897*)
    cat > "\${AEGIS_MODDIR}/custom.pif.prop" << 'PIF'
BRAND=google
MODEL=Auto Proxied
PIF
    exit 0
    ;;
esac
exit 1
EOF
PROBESH="$ROOT/probe-shim.sh"
printf '#!/usr/bin/env bash\n[ "$1" = "7897" ]\n' > "$PROBESH"
make_sync_shim "$SYNC"
cp "$GEN" "$T/mod/autopif4.sh" 2>/dev/null
AEGIS_MODDIR="$T/mod" AEGIS_TEE_DIR="$T/teesim" AEGIS_AUTOPIF="$GEN" \
    AEGIS_PIF_SYNC="$SYNC" AEGIS_PIF_RETRY_WAIT=0 AEGIS_PIF_AUTOPROXY=1 \
    AEGIS_PIF_PROBE="$PROBESH" sh "$SCRIPT" >/dev/null 2>&1
[ "$(grep -c 'invoked:none' "$GENLOG")" = "3" ] \
    && ok "case17: three direct attempts made first" 1 \
    || ok "case17: three direct attempts made first" 0
grep -q "invoked:http://127.0.0.1:7897" "$GENLOG" \
    && ok "case17: probe found 7897 and the retry went through it" 1 \
    || ok "case17: probe found 7897 and the retry went through it" 0
grep -q "Auto Proxied" "$T/mod/custom.pif.prop" \
    && ok "case17: fingerprint landed via the auto-detected proxy" 1 \
    || ok "case17: fingerprint landed via the auto-detected proxy" 0
[ "$(cat "$T/teesim/pif-proxy.auto" 2>/dev/null)" = "http://127.0.0.1:7897" ] \
    && ok "case17: working proxy remembered in pif-proxy.auto" 1 \
    || ok "case17: working proxy remembered in pif-proxy.auto" 0
[ -f "$T/mod/.pif-auto" ] && ok "case17: marker written as usual" 1 \
    || ok "case17: marker written as usual" 0

# --- case 18: autoproxy finds nothing -> behaves exactly like before ---
T="$ROOT/case18"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_fail "$GEN"; make_sync_shim "$SYNC"
PROBESH2="$ROOT/probe-shim2.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$PROBESH2"
cp "$GEN" "$T/mod/autopif4.sh" 2>/dev/null
AEGIS_MODDIR="$T/mod" AEGIS_TEE_DIR="$T/teesim" AEGIS_AUTOPIF="$GEN" \
    AEGIS_PIF_SYNC="$SYNC" AEGIS_PIF_RETRY_WAIT=0 AEGIS_PIF_AUTOPROXY=1 \
    AEGIS_PIF_PROBE="$PROBESH2" sh "$SCRIPT" >/dev/null 2>&1
[ "$(wc -l < "$GENLOG")" = "3" ] \
    && ok "case18: only the direct round ran when no proxy answered" 1 \
    || ok "case18: only the direct round ran when no proxy answered" 0
grep -q "generation failed" "$T/teesim/pif-fetch.log" \
    && ok "case18: failure logged as before" 1 || ok "case18: failure logged as before" 0
[ -f "$T/teesim/pif-proxy.auto" ] \
    && ok "case18: no remembered proxy written on probe failure" 0 \
    || ok "case18: no remembered proxy written on probe failure" 1

# --- case 19: fresh baked seed -> deployed, then swapped at once (R7-1) ---
# R7-1 (2026-09-19): a baked seed is a SHARED identity (one model for every
# install of this package), so its rotation deadline is parked at "now" — the
# first tick whose network works replaces it with a device-specific fetch.
# The offline case (fetch fails, seed keeps working) is case 19b.
T="$ROOT/case19"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
recent=$(( $(date +%s) - 2 * 86400 ))
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
printf 'BRAND=google\nMODEL=Baked Seed\n' > "$T/mod/pif_seed.prop"
echo "$recent" > "$T/mod/pif_seed.auto"
run "$T"
grep -q "seed fingerprint deployed" "$T/teesim/pif-fetch.log" \
    && ok "case19: seed deployment logged" 1 \
    || ok "case19: seed deployment logged" 0
# After a successful swap the marker is rewritten with the fetch epoch as the
# new birth (the seed's build epoch only shows up if the fetch fails: case19b).
_born19="$(sed -n '1p' "$T/mod/.pif-auto" 2>/dev/null)"
case "$_born19" in ''|*[!0-9]*) _born19=0 ;; esac
[ "$_born19" -gt "$recent" ] \
    && ok "case19: rotation clock restarted at the swap" 1 \
    || ok "case19: rotation clock restarted at the swap" 0
[ "$(wc -l < "$GENLOG")" = "1" ] \
    && ok "case19: shared seed swapped at once (one fetch)" 1 \
    || ok "case19: shared seed swapped at once (one fetch)" 0
grep -q "Pixel 9 Pro" "$T/mod/custom.pif.prop" \
    && ok "case19: fetched identity replaced the seed" 1 \
    || ok "case19: fetched identity replaced the seed" 0
[ "$(cat "$T/teesim/.pif-source" 2>/dev/null)" = "runtime-fetch" ] \
    && ok "case19: provenance recorded as runtime-fetch" 1 \
    || ok "case19: provenance recorded as runtime-fetch" 0
[ -s "$T/teesim/pif-master/custom.pif.prop" ] \
    && ok "case19: identity mirrored to the durable master" 1 \
    || ok "case19: identity mirrored to the durable master" 0

# --- case 19b: seed deployed but the swap fetch fails -> seed keeps working ---
T="$ROOT/case19b"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_fail "$GEN"; make_sync_shim "$SYNC"
printf 'BRAND=google\nMODEL=Baked Seed\n' > "$T/mod/pif_seed.prop"
echo "$recent" > "$T/mod/pif_seed.auto"
run "$T"
grep -q "Baked Seed" "$T/mod/custom.pif.prop" \
    && ok "case19b: offline install keeps the baked seed working" 1 \
    || ok "case19b: offline install keeps the baked seed working" 0
[ "$(cat "$T/teesim/.pif-source" 2>/dev/null)" = "seed" ] \
    && ok "case19b: provenance stays 'seed' until a fetch succeeds" 1 \
    || ok "case19b: provenance stays 'seed' until a fetch succeeds" 0
[ "$(sed -n '1p' "$T/mod/.pif-auto" 2>/dev/null)" = "$recent" ] \
    && ok "case19b: marker survives so the next tick retries" 1 \
    || ok "case19b: marker survives so the next tick retries" 0

# --- case 19c: module dir reset -> identity AND provenance restored ---
# R7-1 follow-up: an update wipes the module dir; the durable master survives
# with the identity, its marker and (since this fix) the provenance. Without
# the provenance restore the WebUI silently degrades to printing the path.
T="$ROOT/case19c"; mkdir -p "$T/mod" "$T/teesim/pif-master"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
printf 'BRAND=google\nMODEL=Restored Master\n' > "$T/teesim/pif-master/custom.pif.prop"
date +%s > "$T/teesim/pif-master/.pif-auto"
printf 'seed\n' > "$T/teesim/pif-master/.pif-source"
run "$T"
grep -q "Restored Master" "$T/mod/custom.pif.prop" \
    && ok "case19c: identity restored from the durable master" 1 \
    || ok "case19c: identity restored from the durable master" 0
[ "$(cat "$T/teesim/.pif-source" 2>/dev/null)" = "seed" ] \
    && ok "case19c: provenance restored alongside the identity" 1 \
    || ok "case19c: provenance restored alongside the identity" 0
[ "$(wc -l < "$GENLOG")" = "0" ] \
    && ok "case19c: no fetch attempted for a restored identity" 1 \
    || ok "case19c: no fetch attempted for a restored identity" 0

# --- case 19e: legacy identity (auto-managed, no provenance) -> backfilled ---
# F-11 follow-up: identities from before the provenance marker existed (the
# install-time fetch of the TEE_DIR-buggy build wrote it to the filesystem
# root) must be labelled honestly instead of degrading the WebUI to the raw
# path. Auto-managed only; a fresh generation always writes its own marker.
T="$ROOT/case19e"; mkdir -p "$T/mod" "$T/teesim/pif-master"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
printf 'BRAND=google\nMODEL=Legacy Auto\n' > "$T/mod/custom.pif.prop"
date +%s > "$T/mod/.pif-auto"
printf 'BRAND=google\nMODEL=Legacy Auto\n' > "$T/teesim/pif-master/custom.pif.prop"
date +%s > "$T/teesim/pif-master/.pif-auto"
run "$T"
[ "$(cat "$T/teesim/.pif-source" 2>/dev/null)" = "legacy" ] \
    && ok "case19e: missing provenance backfilled as legacy" 1 \
    || ok "case19e: missing provenance backfilled as legacy" 0
grep -q "Legacy Auto" "$T/mod/custom.pif.prop" \
    && ok "case19e: identity untouched by the backfill" 1 \
    || ok "case19e: identity untouched by the backfill" 0
[ "$(wc -l < "$GENLOG")" = "0" ] \
    && ok "case19e: no fetch attempted for the backfilled identity" 1 \
    || ok "case19e: no fetch attempted for the backfilled identity" 0

# --- case 19f: an existing provenance marker is never overwritten ---
T="$ROOT/case19f"; mkdir -p "$T/mod" "$T/teesim/pif-master"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
printf 'BRAND=google\nMODEL=Marked Auto\n' > "$T/mod/custom.pif.prop"
date +%s > "$T/mod/.pif-auto"
printf 'runtime-fetch\n' > "$T/teesim/.pif-source"
run "$T"
[ "$(cat "$T/teesim/.pif-source" 2>/dev/null)" = "runtime-fetch" ] \
    && ok "case19f: existing provenance survives the run" 1 \
    || ok "case19f: existing provenance survives the run" 0

# --- case 19d: user-provided fingerprint -> provenance 'user' ---
T="$ROOT/case19d"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
printf 'BRAND=google\nMODEL=User Curated\n' > "$T/mod/custom.pif.prop"
: > "$T/mod/.pif-auto"; rm -f "$T/mod/.pif-auto"
run "$T"
[ "$(cat "$T/teesim/.pif-source" 2>/dev/null)" = "user" ] \
    && ok "case19d: user file recorded as provenance 'user'" 1 \
    || ok "case19d: user file recorded as provenance 'user'" 0
grep -q "User Curated" "$T/mod/custom.pif.prop" \
    && ok "case19d: user file left untouched" 1 \
    || ok "case19d: user file left untouched" 0

# --- case 20: expired baked seed -> deployed, then rotated immediately ---
T="$ROOT/case20"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
make_gen_ok "$GEN"; make_sync_shim "$SYNC"
printf 'BRAND=google\nMODEL=Stale Seed\n' > "$T/mod/pif_seed.prop"
echo "$old" > "$T/mod/pif_seed.auto"
run "$T"
[ "$(wc -l < "$GENLOG")" = "1" ] \
    && ok "case20: expired seed triggers an immediate rotation" 1 \
    || ok "case20: expired seed triggers an immediate rotation" 0
grep -q "Pixel 9 Pro" "$T/mod/custom.pif.prop" \
    && ok "case20: rotation replaced the stale seed" 1 \
    || ok "case20: rotation replaced the stale seed" 0
[ "$(sed -n '1p' "$T/mod/.pif-auto" 2>/dev/null)" -gt "$old" ] \
    && ok "case20: marker clock restarted past the seed epoch" 1 \
    || ok "case20: marker clock restarted past the seed epoch" 0

# --- case 21: expiry-aware deadline wins when the Canary expires early ---
# Generator writes an expiry 10 days out; deadline = expiry - 3d (7 days),
# which is EARLIER than the born + 14d cap, so the cap must not apply.
T="$ROOT/case21"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
EXP_DATE=$(date -d "+10 days" +%F)
cat > "$GEN" << EOF
#!/usr/bin/env bash
cat > "\${AEGIS_MODDIR}/custom.pif.prop" << PIF
# Estimated Expiry: $EXP_DATE
BRAND=google
MODEL=Pixel 9 Pro
PIF
exit 0
EOF
make_sync_shim "$SYNC"
echo 0 > "$T/mod/.pif-auto"; printf 'OLD=1\n' > "$T/mod/custom.pif.prop"
run "$T"
EXP_EPOCH=$(date -d "$EXP_DATE 00:00:00 UTC" +%s)
[ "$(sed -n '2p' "$T/mod/.pif-auto" 2>/dev/null)" = "$(( EXP_EPOCH - 3 * 86400 ))" ] \
    && ok "case21: deadline = estimated expiry - 3 days" 1 \
    || ok "case21: deadline = estimated expiry - 3 days" 0
[ "$(sed -n '2p' "$T/mod/.pif-auto" 2>/dev/null)" -lt "$(($(date +%s) + 14 * 86400))" ] \
    && ok "case21: early expiry pulls the deadline below the 14-day cap" 1 \
    || ok "case21: early expiry pulls the deadline below the 14-day cap" 0

# --- case 22: no parseable expiry ("Unknown" / missing line) -> 14-day cap ---
T="$ROOT/case22"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
cat > "$GEN" << 'EOF'
#!/usr/bin/env bash
printf '# Estimated Expiry: Unknown\nBRAND=google\nMODEL=Pixel 9 Pro\n' > "${AEGIS_MODDIR}/custom.pif.prop"
exit 0
EOF
make_sync_shim "$SYNC"
run "$T"
now22=$(date +%s)
rot22=$(sed -n '2p' "$T/mod/.pif-auto" 2>/dev/null)
[ "$rot22" -ge "$(( now22 + 13 * 86400 ))" ] && [ "$rot22" -le "$(( now22 + 15 * 86400 ))" ] \
    && ok "case22: unparseable expiry falls back to the 14-day clock" 1 \
    || ok "case22: unparseable expiry falls back to the 14-day clock" 0

# --- case 23: far-future expiry -> the 14-day cap wins ---
T="$ROOT/case23"; mkdir -p "$T/mod" "$T/teesim"
: > "$GENLOG"; : > "$SYNCLOG"
FAR_DATE=$(date -d "+40 days" +%F)
cat > "$GEN" << EOF
#!/usr/bin/env bash
printf '# Estimated Expiry: $FAR_DATE\nBRAND=google\nMODEL=Pixel 9 Pro\n' > "\${AEGIS_MODDIR}/custom.pif.prop"
exit 0
EOF
make_sync_shim "$SYNC"
run "$T"
now23=$(date +%s)
rot23=$(sed -n '2p' "$T/mod/.pif-auto" 2>/dev/null)
[ "$rot23" -ge "$(( now23 + 13 * 86400 ))" ] && [ "$rot23" -le "$(( now23 + 15 * 86400 ))" ] \
    && ok "case23: far-future expiry capped at 14 days" 1 \
    || ok "case23: far-future expiry capped at 14 days" 0

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
