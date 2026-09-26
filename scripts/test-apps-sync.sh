#!/usr/bin/env bash
# test-apps-sync.sh — host-side tests for apps-sync.sh, focused on the v3.0.1
# one-time GMS scope seed, the Round 12 uid pins and the v3.1.7 retirement of
# the detector-app auto-exclusion (the scope holds exactly what the user ticks).
# Runs the script with
# AEGIS_TEE_DIR pointing into build/ and stub `pm`/`busybox` on PATH, mirroring
# the shims used by test-pif-sync.sh / test-pif-fetch.sh.
#
# Run: bash scripts/test-apps-sync.sh
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
SCRIPT="$ROOT/module/apps-sync.sh"
# Audit v3.2.3 N11: unique per-PID sandbox, NO rm -rf reset — the dev host's
# safe-delete hook can veto bulk rm and leave stale fixtures behind, which
# turns the suite into false failures (observed live: 40/2 on a clean tree vs
# 35/7 on a stale one with identical code). A unique dir starts every run
# from zero; old run dirs are harmless (build/ is gitignored). CI/Linux is
# still the authority. The exported empty session IDs keep the host's
# safe-delete shim from vetoing the MODULE's own rm calls during the run.
SBX="$ROOT/build/test-apps-sync.$$"
mkdir -p "$SBX/bin"
export CODEBUDDY_SESSION_ID= CLAUDE_SESSION_ID=

PASS=0; FAIL=0
ok() { if [ "$2" = 1 ]; then PASS=$((PASS+1)); echo "  ok  - $1"; else FAIL=$((FAIL+1)); echo "  FAIL- $1"; fi; }
# chk <desc> <test args...> — evaluate `test "$@"` and feed ok(). Use `chk d ! -f x` for negation.
chk() { d="$1"; shift; if test "$@"; then ok "$d" 1; else ok "$d" 0; fi; }
# logc <file> <pattern> — match count that tolerates a missing log file.
logc() { if [ -f "$1" ]; then grep -c "$2" "$1" || true; else echo 0; fi; }

# Stub `pm`: the state file decides everything (gms installed = listed there).
cat > "$SBX/bin/pm" << 'EOF'
#!/bin/sh
STATE="$(dirname "$0")/../pm-state"
[ -f "$STATE" ] || exit 1
if [ "$1" = path ]; then grep -qx "package:$2" "$STATE" && exit 0 || exit 1; fi
if [ "$1" = list ] && [ "$2" = packages ]; then cat "$STATE"; exit 0; fi
exit 1
EOF
chmod +x "$SBX/bin/pm"

# busybox: multiplex stub — the script invokes "$BB" awk ..., so drop the
# subcommand name and hand the rest to host awk.
printf '#!/bin/sh\nshift\nexec awk "$@"\n' > "$SBX/bin/busybox" && chmod +x "$SBX/bin/busybox"

# Baseline app list (gms always installed except where a case says otherwise).
# gsf + the detector apps are installed too — the Round 12 uid-pin pass targets
# gsf, and the cleanup pass must treat installed detectors as prunable only via
# the exclusion pass, not as "uninstalled".
cat > "$SBX/pm-state" << 'EOF'
package:com.google.android.gms
package:com.android.vending
package:com.google.android.gsf
package:com.example.kept
package:io.github.vvb2060.keyattestation
package:gr.nikolasspyr.integritycheck
EOF

run() { # <case-dir>
    T="$1"
    TDIR="$SBX/$T"; mkdir -p "$TDIR/teesim"
    PATH="$SBX/bin:$PATH" AEGIS_TEE_DIR="$TDIR/teesim" sh "$SCRIPT" >/dev/null 2>&1
}

# A minimal single-profile config in the shape the WebUI/daemon produce.
mkcfg() { # <dir> <apps-json-array>
    mkdir -p "$1/teesim"
    printf '{"profiles":{"default":{"autoIncludeNewApps":false,"apps":%s}}}' "$2" > "$1/teesim/config.json"
}
flat() { tr -d '\n\r' < "$1/teesim/config.json"; }

echo "== seed: gms missing from a populated scope =="
T=case1; mkcfg "$SBX/$T" '["com.example.kept"]'
run "$T"
chk "gms inserted first with a trailing comma" \
    "$(flat "$SBX/$T")" = '{"profiles":{"default":{"autoIncludeNewApps":false,"apps":["com.google.android.gms", "com.example.kept"]}}}'
chk "seed marker written" -f "$SBX/$T/teesim/.gms-scope-seeded"
chk "seed logged" "$(logc "$SBX/$T/teesim/apps-sync.log" 'seeded com.google.android.gms')" -eq 1

echo "== seed: empty apps array =="
T=case2; mkcfg "$SBX/$T" '[]'
run "$T"
chk "gms inserted without a trailing comma" \
    "$(flat "$SBX/$T")" = '{"profiles":{"default":{"autoIncludeNewApps":false,"apps":["com.google.android.gms"]}}}'
chk "marker written for empty array too" -f "$SBX/$T/teesim/.gms-scope-seeded"

echo "== seed: gms already present -> no-op, marker still written =="
T=case3; mkcfg "$SBX/$T" '["com.google.android.gms","com.example.kept"]'
run "$T"
chk "config byte-identical" \
    "$(flat "$SBX/$T")" = '{"profiles":{"default":{"autoIncludeNewApps":false,"apps":["com.google.android.gms","com.example.kept"]}}}'
chk "no seed log line" "$(logc "$SBX/$T/teesim/apps-sync.log" 'seeded')" -eq 0
chk "marker written" -f "$SBX/$T/teesim/.gms-scope-seeded"

echo "== seed: one-shot only (deliberate removal is respected) =="
T=case4; mkcfg "$SBX/$T" '["com.example.kept"]'
run "$T"                      # first run seeds
printf '{"profiles":{"default":{"autoIncludeNewApps":false,"apps":["com.example.kept"]}}}' > "$SBX/$T/teesim/config.json"
run "$T"                      # second run must NOT re-seed
chk "second run leaves config alone" \
    "$(flat "$SBX/$T")" = '{"profiles":{"default":{"autoIncludeNewApps":false,"apps":["com.example.kept"]}}}'

echo "== seed: gms not installed -> no seed, marker written =="
T=case5; mkcfg "$SBX/$T" '["com.example.kept"]'
mv "$SBX/pm-state" "$SBX/pm-state.bak"
printf 'package:com.android.vending\npackage:com.example.kept\n' > "$SBX/pm-state"
run "$T"
chk "config untouched" "$(flat "$SBX/$T")" = '{"profiles":{"default":{"autoIncludeNewApps":false,"apps":["com.example.kept"]}}}'
chk "marker written (one attempt)" -f "$SBX/$T/teesim/.gms-scope-seeded"
mv "$SBX/pm-state.bak" "$SBX/pm-state"

echo "== guard: multi-profile config is skipped (compact one-line JSON too) =="
T=case6; mkdir -p "$SBX/$T/teesim"
printf '{"profiles":{"a":{"apps":[]},"b":{"apps":[]}}}' > "$SBX/$T/teesim/config.json"
run "$T"
chk "no profile touched" "$(flat "$SBX/$T")" = '{"profiles":{"a":{"apps":[]},"b":{"apps":[]}}}'
chk "no marker (skipped entirely)" ! -f "$SBX/$T/teesim/.gms-scope-seeded"

echo "== guard: no config.json -> silent exit =="
T=case7; run "$T"
chk "no marker created when config absent" ! -f "$SBX/$T/teesim/.gms-scope-seeded"

echo "== cleanup pass still works alongside the seed =="
T=case8; mkcfg "$SBX/$T" '["com.example.gone","com.example.kept"]'
run "$T"
F="$(flat "$SBX/$T")"
chk "gms seeded" "$(printf '%s' "$F" | grep -c 'com.google.android.gms')" -ge 1
chk "uninstalled app pruned" "$(printf '%s' "$F" | grep -c 'com.example.gone')" -eq 0
chk "installed app kept" "$(printf '%s' "$F" | grep -c 'com.example.kept')" -eq 1
chk "prune logged" "$(logc "$SBX/$T/teesim/apps-sync.log" 'cleaned, removed')" -eq 1

echo "== debug channel: flag present -> unified debug.log written =="
T=case9; mkcfg "$SBX/$T" '["com.example.kept"]'
touch "$SBX/$T/teesim/.debug"
run "$T"
chk "debug.log exists with the [appssync] tag" "$(logc "$SBX/$T/teesim/debug.log" '\[appssync\]')" -ge 1
chk "debug.log narrates the guard decision" "$(logc "$SBX/$T/teesim/debug.log" 'run start: apps-arrays=1')" -eq 1

echo "== debug channel: flag absent -> no debug.log =="
T=case10; mkcfg "$SBX/$T" '["com.example.kept"]'
run "$T"
chk "no debug.log created" ! -f "$SBX/$T/teesim/debug.log"

echo "== Round 12: uid pins for the PI core trio =="
T=case11; mkcfg "$SBX/$T" '["com.example.kept"]'
cat > "$SBX/$T/packages.list" << 'EOF'
com.google.android.gms 10250 /data/app/~~gms/base.apk=None 0
com.android.vending 10138 /data/app/~~vending/base.apk=None 0
com.google.android.gsf 10217 /data/app/~~gsf/base.apk=None 0
EOF
PATH="$SBX/bin:$PATH" AEGIS_TEE_DIR="$SBX/$T/teesim" AEGIS_PKG_LIST="$SBX/$T/packages.list" sh "$SCRIPT" >/dev/null 2>&1
F=$(flat "$SBX/$T")
chk "uid:10250 (gms) pinned" "$(printf '%s' "$F" | grep -c '"uid:10250"')" -eq 1
chk "uid:10138 (vending) pinned" "$(printf '%s' "$F" | grep -c '"uid:10138"')" -eq 1
chk "uid:10217 (gsf) pinned" "$(printf '%s' "$F" | grep -c '"uid:10217"')" -eq 1
chk "gsf package entry added" "$(printf '%s' "$F" | grep -c '"com.google.android.gsf"')" -eq 1
chk "existing entry preserved" "$(printf '%s' "$F" | grep -c '"com.example.kept"')" -eq 1
chk "pin pass logged" "$(logc "$SBX/$T/teesim/apps-sync.log" 'pinned PI core')" -eq 1

echo "== Round 12: uid pins are idempotent + survive the cleanup pass =="
PATH="$SBX/bin:$PATH" AEGIS_TEE_DIR="$SBX/$T/teesim" AEGIS_PKG_LIST="$SBX/$T/packages.list" sh "$SCRIPT" >/dev/null 2>&1
F=$(flat "$SBX/$T")
chk "second run adds nothing new (uid count still 1)" "$(printf '%s' "$F" | grep -c '"uid:10250"')" -eq 1
chk "uid entries survive cleanup" "$(printf '%s' "$F" | grep -o '"uid:' | wc -l)" -eq 3

echo "== Round 12: .uid-pins-off disables the pass =="
T=case12; mkcfg "$SBX/$T" '["com.example.kept"]'
cp "$SBX/$T/packages.list" "$SBX/$T/packages.list" 2>/dev/null || cat > "$SBX/$T/packages.list" << 'EOF'
com.google.android.gms 10250 /data/app/~~gms/base.apk=None 0
EOF
touch "$SBX/$T/teesim/.uid-pins-off"
PATH="$SBX/bin:$PATH" AEGIS_TEE_DIR="$SBX/$T/teesim" AEGIS_PKG_LIST="$SBX/$T/packages.list" sh "$SCRIPT" >/dev/null 2>&1
chk "no uid entries when disabled" "$(flat "$SBX/$T" | grep -c '"uid:')" -eq 0

echo "== v3.1.7: detector apps are NEVER auto-removed (the exclusion is retired) =="
T=case13; mkcfg "$SBX/$T" '["com.example.kept","io.github.vvb2060.keyattestation","gr.nikolasspyr.integritycheck"]'
PATH="$SBX/bin:$PATH" AEGIS_TEE_DIR="$SBX/$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
F=$(flat "$SBX/$T")
chk "keyattestation stays in scope" "$(printf '%s' "$F" | grep -c 'io.github.vvb2060.keyattestation')" -eq 1
chk "integritycheck stays in scope" "$(printf '%s' "$F" | grep -c 'gr.nikolasspyr.integritycheck')" -eq 1
chk "normal app kept" "$(printf '%s' "$F" | grep -c '"com.example.kept"')" -eq 1
chk "no exclusion log line" "$(logc "$SBX/$T/teesim/apps-sync.log" 'auto-excluded detector apps')" -eq 0
chk "no 'cleaned' line either (nothing pruned)" "$(logc "$SBX/$T/teesim/apps-sync.log" 'cleaned, removed')" -eq 0

echo "== v3.1.7: leftover v3.1.6 exclusion markers are removed once, loudly =="
T=case14; mkcfg "$SBX/$T" '["com.example.kept","io.github.vvb2060.keyattestation"]'
printf 'io.github.vvb2060.keyattestation\t1757500000\n' > "$SBX/$T/teesim/.detector-excluded"
touch "$SBX/$T/teesim/.keep-detectors"
PATH="$SBX/bin:$PATH" AEGIS_TEE_DIR="$SBX/$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
chk "stale .detector-excluded removed" ! -f "$SBX/$T/teesim/.detector-excluded"
chk "retired .keep-detectors removed" ! -f "$SBX/$T/teesim/.keep-detectors"
chk "detector kept during the same pass" "$(flat "$SBX/$T" | grep -c 'io.github.vvb2060.keyattestation')" -eq 1
chk "cleanup logged" "$(logc "$SBX/$T/teesim/apps-sync.log" 'leftover detector-exclusion markers')" -eq 1

echo "== v3.1.7: the uninstall prune still works and says why =="
T=case15; mkcfg "$SBX/$T" '["com.example.kept","com.example.gone"]'
PATH="$SBX/bin:$PATH" AEGIS_TEE_DIR="$SBX/$T/teesim" sh "$SCRIPT" >/dev/null 2>&1
chk "uninstalled app pruned normally" "$(flat "$SBX/$T" | grep -c 'com.example.gone')" -eq 0
chk "prune logged with its reason" \
    "$(logc "$SBX/$T/teesim/apps-sync.log" 'absent from pm list packages')" -eq 1
chk "no marker files created for a plain prune" ! -f "$SBX/$T/teesim/.detector-excluded"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
