#!/usr/bin/env bash
# assemble.sh — merge the built TEESimulator zip, the pinned fingerprint release zip
# (Play Integrity Fork) and the fusion overlay into one flashable Aegis Fusion
# module zip. v3.x is a four-in-one: TEESimulator (software keybox attestation),
# the fingerprint DroidGuard sees (PIFork Zygisk payload), keybox auto-management
# and the shell-level environment/BL-hiding layer — one flash, both PI halves.
#
# Usage: scripts/assemble.sh <teesim-release.zip> <pifork-release.zip> <overlay-dir> <out.zip>
# Env:   FUSION_VERSION / FUSION_VERSION_CODE may be pre-set (CI does this with the release tag
#        and build date); versions.env values are used as fallbacks.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <teesim-release.zip> <pifork-release.zip> <overlay-dir> <out.zip>" >&2
    exit 1
fi

TEESIM_ZIP="$1"   # out/TEESimulator-*-Release.zip produced by ./gradlew zipRelease
PIFORK_ZIP="$2"   # upstream/PlayIntegrityFork-*.zip, checksum-verified by fetch-upstreams.sh
OVERLAY="$3"      # IntegrityFusion/module
OUT_ZIP="$4"

# Resolve OUT_ZIP to an absolute path: zip_dir() cds into the staging dir before
# zipping, so a relative output path would be created inside the (temp) staging
# dir — or fail outright when its parent does not exist there (CI passes
# "out/IntegrityFusion-*.zip", which broke the first CI run).
OUT_DIR="$(dirname -- "$OUT_ZIP")"
mkdir -p -- "$OUT_DIR"
OUT_ZIP="$(cd -- "$OUT_DIR" && pwd)/$(basename -- "$OUT_ZIP")"
# Git Bash on Windows: pwd yields MSYS paths (/c/...) that native zip/python can't open;
# convert to a Windows mixed path. No-op on Linux CI.
case "$(uname -s)" in
    MINGW*|MSYS*) command -v cygpath >/dev/null 2>&1 && OUT_ZIP="$(cygpath -m "$OUT_ZIP")" ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pre-set env (e.g. from CI) wins over versions.env.
ENV_FUSION_VERSION="${FUSION_VERSION:-}"
ENV_FUSION_VERSION_CODE="${FUSION_VERSION_CODE:-}"
# shellcheck source=../versions.env
. "$ROOT/versions.env"
FUSION_VERSION="${ENV_FUSION_VERSION:-$FUSION_VERSION}"
FUSION_VERSION_CODE="${ENV_FUSION_VERSION_CODE:-$FUSION_VERSION_CODE}"

STAGE="$(mktemp -d)"
TEE_UNPACK="$(mktemp -d)"
PIF_UNPACK="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$TEE_UNPACK" "$PIF_UNPACK" 2>/dev/null || true' EXIT

# zip with a python fallback (Windows hosts usually have no zip(1)).
zip_dir() {
    local dir="$1" out="$2"
    # Native Windows python (the fallback interpreter) can't read MSYS virtual
    # paths like /tmp/tmp.xxx (mktemp -d) — it would silently os.walk an empty
    # tree and emit an empty zip. Convert both paths before handing them over.
    # No-op on Linux CI.
    if command -v cygpath >/dev/null 2>&1; then
        dir="$(cygpath -m "$dir")"
        out="$(cygpath -m "$out")"
    fi
    if command -v zip >/dev/null 2>&1; then
        rm -f "$out"
        (cd "$dir" && zip -qr9 "$out" .)
    else
        python3 - "$dir" "$out" <<'PYEOF'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
if os.path.exists(out):
    os.remove(out)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PYEOF
    fi
}

# The PlayIntegrityFork Zygisk payload hardcodes its config paths under
# /data/adb/modules/playintegrityfix/ (the module id it was built for). In a
# fusion build the payload lives in our own module (whatever id= says), so every
# hardcoded path misses and the WHOLE fingerprint half silently no-ops — the
# custom.pif.prop our pif-fetch writes is never read, DroidGuard keeps seeing
# the real device, and PI stays at BASIC only regardless of TEE state.
# (AlwaysStrong ships the same fix as a "PIF path binary patch".)
# Same-length replacement keeps the binary layout intact: the 35-byte
# ".../playintegrityfix/" is an 18-byte "/data/adb/modules/" prefix + a 16-char
# id + "/". We repoint it to OUR id, padded with trailing slashes to exactly the
# same length; repeated slashes resolve identically on Linux, so the path works.
#
# The id is deliberately NOT hardcoded here — both the id and the padding are
# derived from module/module.prop further down (PIF_PATH_OLD / PIF_PATH_NEW), so
# this script is id-agnostic and the two release lines can share it verbatim.
# The python assert below still fails the build loudly if the math ever goes wrong.
patch_pif_paths() {
    local conv=() f
    if command -v cygpath >/dev/null 2>&1; then
        for f in "$@"; do conv+=("$(cygpath -m "$f")"); done
        set -- "${conv[@]}"
    fi
    for f in "$@"; do
        [ -f "$f" ] || continue
        python3 - "$f" "$PIF_PATH_OLD" "$PIF_PATH_NEW" <<'PYEOF'
import sys
p, old_s, new_s = sys.argv[1], sys.argv[2], sys.argv[3]
old, new = old_s.encode(), new_s.encode()
assert len(old) == len(new), "prefix length mismatch: %d vs %d" % (len(old), len(new))
d = open(p, "rb").read()
n = d.count(old)
if n == 0:
    print("      %s: no hardcoded path found (already patched?)" % p)
else:
    open(p, "wb").write(d.replace(old, new))
    print("      %s: %d hardcoded path(s) repointed to the fusion module" % (p, n))
PYEOF
    done
}

for f in "$TEESIM_ZIP" "$PIFORK_ZIP" "$OVERLAY/customize.sh" "$OVERLAY/service.sh" "$OVERLAY/module.prop" "$OVERLAY/webroot/index.html"; do
    [ -e "$f" ] || { echo "!! Missing required input: $f" >&2; exit 1; }
done

# --- Derived from module.prop: the module id, and the PIF path repointing -----
# Single source of truth for the id: `module/module.prop`'s `id=`. Nothing in
# this script hardcodes it, so both release lines can use this file verbatim.
MODID="$(sed -n 's/^id=//p' "$OVERLAY/module.prop" 2>/dev/null | head -1 | tr -d ' \r\n')"
[ -n "$MODID" ] || { echo "!! cannot read the module id from $OVERLAY/module.prop" >&2; exit 1; }

# The PlayIntegrityFork Zygisk payload hardcodes /data/adb/modules/playintegrityfix/
# (the id it was built for). Repoint it to this module, padding with trailing
# slashes so the replacement is byte-length identical.
PIF_PATH_OLD="/data/adb/modules/playintegrityfix/"
_pad=$(( ${#PIF_PATH_OLD} - 18 - ${#MODID} ))
[ "$_pad" -ge 1 ] || {
    echo "!! module id '$MODID' does not fit the PIF path slot" >&2
    echo "   (max $(( ${#PIF_PATH_OLD} - 19 )) chars; the slot must stay ${#PIF_PATH_OLD} bytes)" >&2
    exit 1
}
PIF_PATH_NEW="/data/adb/modules/$MODID"
_i=0
while [ "$_i" -lt "$_pad" ]; do
    PIF_PATH_NEW="$PIF_PATH_NEW/"
    _i=$((_i + 1))
done
echo "== module id: $MODID"
echo "   PIF path repointing: $PIF_PATH_OLD -> $PIF_PATH_NEW (${#PIF_PATH_NEW} bytes, ${_pad} padding slash(es))"

unzip -q "$TEESIM_ZIP" -d "$TEE_UNPACK"
unzip -q "$PIFORK_ZIP" -d "$PIF_UNPACK"

echo "== TEESimulator payload"
# The daemon dex is renamed to teesim-service.dex: the patched module/daemon (shipped in the
# TEESim zip) looks for that name. Historical note: the rename originally avoided a classes.dex
# collision with PIF; it is kept so a stray upstream classes.dex can never shadow the daemon.
if [ -f "$TEE_UNPACK/classes.dex" ]; then
    cp "$TEE_UNPACK/classes.dex" "$STAGE/teesim-service.dex"
    echo "   classes.dex -> teesim-service.dex"
elif [ -f "$TEE_UNPACK/service.apk" ]; then
    cp "$TEE_UNPACK/service.apk" "$STAGE/service.apk"
    echo "   service.apk (debug build)"
else
    echo "!! TEESim zip has neither classes.dex nor service.apk" >&2
    exit 1
fi
for abi in arm64-v8a x86_64; do
    [ -d "$TEE_UNPACK/$abi" ] && cp -a "$TEE_UNPACK/$abi" "$STAGE/$abi" && echo "   $abi/"
done
cp "$TEE_UNPACK/sepolicy.rule" "$STAGE/"
cp "$TEE_UNPACK/config.default.json" "$STAGE/"
cp "$TEE_UNPACK/daemon" "$STAGE/"
# v3.2.3 (audit N2): the upstream console webroot is DROPPED from the bundle.
# Its log download concatenates every teesim.N.log shard — including shards
# written by pre-0006 builds with PLAINTEXT harvest lines — straight into
# /sdcard/Download with no masking (KeyAdmin.kt:713-714, default save dir is
# /sdcard/Download). Our own WebUI already covers the diagnostics surface with
# masked exports, so removing this entry closes the last unmasked export path;
# the footer link was removed from index.html accordingly.
# Dropped on purpose: upstream module.prop / customize.sh / service.sh / update.json /
# changelog.md are replaced by the fusion overlay or meaningless in a fusion build.

echo "== Fusion overlay"
# Whole overlay: customize.sh, service.sh, common_func.sh, keybox-fetch.sh, uninstall.sh,
# META-INF/ (standard Magisk installer; TEESim's zip ships none of its own) and webroot/.
cp -a "$OVERLAY/." "$STAGE/"
sed -e "s|@FUSION_VERSION@|${FUSION_VERSION} (TEESim ${TEESIM_VERSION})|" \
    -e "s|@FUSION_VERSION_CODE@|${FUSION_VERSION_CODE}|" \
    "$OVERLAY/module.prop" > "$STAGE/module.prop"
echo "   module.prop, scripts, META-INF, launcher"

echo "== Fingerprint payload (Play Integrity Fork $PIF_RELEASE)"
# The Zygisk entry point lives at the module root: zygisk/<abi>.so is what the
# root manager loads into the GMS process; classes.dex is loaded by that lib
# (no collision — the TEES daemon dex is renamed teesim-service.dex above).
# Their scripts reference $MODPATH/<name> unmodified, so script names are kept;
# OUR overlay common_func.sh was renamed fusion_func.sh to yield the root name.
for f in zygisk classes.dex example.pif.prop app_replace_list.txt \
         autopif4.sh killpi.sh migrate.sh common_func.sh common_setup.sh action.sh; do
    [ -e "$PIF_UNPACK/$f" ] || { echo "!! PlayIntegrityFork zip is missing $f" >&2; exit 1; }
    cp -a "$PIF_UNPACK/$f" "$STAGE/"
done
echo "   zygisk/ + spoofing scripts merged"
# v3.2.3 (audit R7-5): the upstream zygisk dir ships armeabi-v7a.so (~170 KB),
# but this module builds its TEESim interpreters for arm64-v8a/x86_64 only —
# a v7a device can never run the TEE half, so the v7a payload is dead weight
# that would never be loaded. Drop it; the arm64-v8a payload below is asserted.
# NOTE: it is a .so FILE (not a directory) — path must carry the extension
# (64dd168 build shipped with the extensionless path and the assertion
# passed vacuously; caught by artifact inspection).
rm -f "$STAGE/zygisk/armeabi-v7a.so"
[ ! -e "$STAGE/zygisk/armeabi-v7a.so" ] \
    || { echo "!! assemble: v7a zygisk payload still present (audit R7-5)" >&2; exit 1; }
# ⚠️ SECURITY (v3.2.3, audit finding C1): the bundled PIF scripts ship with
# --no-check-certificate on every wget and an eval of file-derived config in
# migrate.sh — a MITM on any of the Google endpoints could turn fingerprint
# generation into root code execution. harden_pif_scripts() rewrites the
# STAGING COPIES only (the versions.env SHA256 pin still verifies the upstream
# zip itself) and asserts every pattern: upstream drift fails the build
# instead of silently shipping unhardened scripts. See scripts/harden-pif.sh
# and docs/RELEASE-NOTES-v3.2.3.md.
. "$ROOT/scripts/harden-pif.sh"
echo "   hardening bundled PIF scripts (TLS verified-by-default, de-evaled config)"
harden_pif_scripts "$STAGE" || { echo "!! PIF script hardening failed" >&2; exit 1; }
# v3.2.3 (audit R8-4, destructive): upstream's stock `skippersistprop` branch
# runs `sh $MODPATH/uninstall.sh` on EVERY boot when that marker file exists.
# In a fusion build that means `rm -rf /data/adb/teesim` — imported keybox,
# rolling backups, config and logs gone — while the marker's upstream
# semantics are merely "don't write persist props", nothing to do with
# uninstalling. A user carrying the marker over from standalone PIF would
# lose their (irreplaceable) keybox at every boot. Strip the branch; the
# `if ! $SKIPPERSISTPROP` gate above it (the marker's REAL semantic) stays
# intact, and customize.sh prints a notice when the marker is present.
sed -i -e '/elif \[ "\$MODPATH\/uninstall.sh" \]; then/d' \
       -e '/sh \$MODPATH\/uninstall.sh/d' "$STAGE/common_setup.sh"
grep -q 'MODPATH/uninstall.sh' "$STAGE/common_setup.sh" \
    && { echo "!! assemble: common_setup.sh still invokes uninstall.sh at boot (audit R8-4)" >&2; exit 1; }
# Independent post-assertions (belt and braces — do not trust only the patcher):
[ "$(grep -c -- '--no-check-certificate' "$STAGE/autopif4.sh")" = "1" ] \
    || { echo "!! assemble: autopif4.sh still has un-gated --no-check-certificate" >&2; exit 1; }
grep -q 'eval \$FIELD=' "$STAGE/migrate.sh" \
    && { echo "!! assemble: migrate.sh still evals file-derived config" >&2; exit 1; }
# Repoint the payload's hardcoded config dir at OUR module (see patch_pif_paths).
# Without this the fingerprint half never loads a config and PI can only ever
# reach BASIC no matter what the TEE half does.
patch_pif_paths "$STAGE/zygisk/"*.so
# Their service.sh carries the late-boot sensitive-prop resets; it becomes a
# library sourced by our service.sh (Magisk only executes root-level scripts).
[ -e "$PIF_UNPACK/service.sh" ] || { echo "!! PlayIntegrityFork zip is missing service.sh" >&2; exit 1; }
cp "$PIF_UNPACK/service.sh" "$STAGE/pif-service.sh"
echo "   service.sh -> pif-service.sh (sourced by the fusion service.sh)"
# Their post-fs-data.sh (early prop resets + denylist management) has no
# counterpart in the overlay — adopt it directly.
[ -e "$PIF_UNPACK/post-fs-data.sh" ] || { echo "!! PlayIntegrityFork zip is missing post-fs-data.sh" >&2; exit 1; }
cp "$PIF_UNPACK/post-fs-data.sh" "$STAGE/post-fs-data.sh"
echo "   post-fs-data.sh adopted"
# Round 12: fold the fusion's early patch-level alignment into the adopted
# script. The overlay ships it as post-fs-data.fusion.sh precisely because
# the PIF zip copy above would overwrite a same-named overlay file; the
# shebang is stripped and the body appended (MODPATH/fusion_func.sh provide
# align_patch_level + resetprop_if_diff).
if [ -e "$OVERLAY/post-fs-data.fusion.sh" ]; then
    printf '\n# --- Aegis Fusion: early patch-level alignment (Round 12) ---\n' >> "$STAGE/post-fs-data.sh"
    tail -n +2 "$OVERLAY/post-fs-data.fusion.sh" >> "$STAGE/post-fs-data.sh"
    echo "   fusion early patch-level alignment appended"
fi
# Round 13: fusion integration for the action button. Upstream action.sh runs
# autopif4.sh -m and leaves the generated custom.pif.prop unmarked — but in a
# fusion build an unmarked fingerprint means "user-provided, never touched"
# (pif-fetch ownership rules), so one tap of the button would freeze that
# fingerprint forever and silently disable the whole auto-rotate cycle. Append
# a marker write (the print becomes auto-managed, 14-day clock applies) and an
# immediate pif-sync so the TEE half aligns without waiting for the next tick.
printf '\n# --- Aegis Fusion: action-button fingerprint is auto-managed (Round 13) ---\n' >> "$STAGE/action.sh"
cat >> "$STAGE/action.sh" <<'FUSION_EOF'

[ -s "$MODPATH/custom.pif.prop" ] && date +%s > "$MODPATH/.pif-auto"
[ -f "$MODPATH/pif-sync.sh" ] && sh "$MODPATH/pif-sync.sh" >/dev/null 2>&1 || true
FUSION_EOF
echo "   action.sh fusion integration appended (marker + sync)"
# v3.2.3 (audit L14 closure): upstream's action button ran `autopif4.sh -m`,
# which queries Google's flashstation with THIS DEVICE's product name — the
# only device-derived value to leave the phone. Switch to --strong: the
# button now fetches a random Pixel beta identity, the same semantics as the
# rotation cycle (and Round 13's marker + sync above still apply). With this,
# NO device-derived data reaches the network on any path.
sed -i 's/autopif4\.sh -m/autopif4.sh --strong/' "$STAGE/action.sh"
grep -q 'autopif4\.sh -m' "$STAGE/action.sh" \
    && { echo "!! assemble: action.sh still uses -m (device product leaks to Google, audit L14)" >&2; exit 1; }
# Dropped on purpose: their module.prop / customize.sh / META-INF / update.json /
# changelog are replaced by the fusion overlay or meaningless in a fusion build.

echo "== Baked seed fingerprint (v3.2.1)"
# Build-time fetch: the build host (CI on GitHub Actions, always able to reach
# Google) runs the very same autopif4.sh the device would run, and the fresh
# fingerprint is baked into the zip as pif_seed.prop (+ pif_seed.auto epoch).
# Fresh installs then boot with a working identity on day one — no empty
# window before the first successful runtime fetch. pif-fetch.sh deploys the
# seed only when the device has no fingerprint and no durable master; the
# 14-day rotation clock starts from the build epoch. Best-effort: a build-time
# fetch failure must never fail the package — the runtime fetch layer covers it.
SEED_STAGE="$STAGE/.seedgen"
mkdir -p "$SEED_STAGE"
SEED_OK=0
seed_fetch() {
    local T=""; command -v timeout >/dev/null 2>&1 && T="timeout 180"
    # bash, not sh: CI's /bin/sh is dash, whose stricter parsing can reject
    # ash/bash-isms the device shells (busybox ash / mksh) accept — seen live
    # 2026-09-12: seed_fetch died in ~16 ms on the runner with the error
    # swallowed by the redirect. bash is a superset and always present there.
    local SHELL_BIN="sh"; command -v bash >/dev/null 2>&1 && SHELL_BIN="bash"
    # Neutralize the on-device root check in a THROWAWAY COPY (the shipped
    # autopif4.sh keeps it): seen live 2026-09-12 — "autopif4: need root
    # permissions" died instantly on the runner, which is a non-root user.
    # The build host needs no root; the script only writes into its own cwd.
    cp "$STAGE/autopif4.sh" "$SEED_STAGE/autopif4.sh"
    sed -i '/if \[ "$USER" != "root"/,+2d' "$SEED_STAGE/autopif4.sh" 2>/dev/null || true
    # migrate.sh must sit next to the autopif4 copy: autopif4 converts its
    # generated pif.prop into custom.pif.prop via `sh migrate.sh -i` and the
    # whole conversion block is silently skipped when migrate.sh is missing —
    # seen live 2026-09-13 (run 94067334342): full Pixel 8a values dumped,
    # then "no seed in this build" because custom.pif.prop never appeared.
    # autopif4 assumes an Android host: GNU date lacks busybox's -D option, so
    # its sanity check falls back to find_busybox(), which only looks at
    # Magisk/KSU/APatch paths — BUT it honours a preset $BUSYBOX. Provision a
    # real busybox and point it there. Seen live 2026-09-12: "Error: date
    # broken, install busybox!" on the runner even after the root-check fix.
    if ! command -v busybox >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
            sudo apt-get install -y busybox >/dev/null 2>&1 || true
        fi
    fi
    if command -v busybox >/dev/null 2>&1; then
        export BUSYBOX="$(command -v busybox)"
        echo "   seed busybox: $BUSYBOX"
    fi
    # shellcheck disable=SC2015
    [ -f "$STAGE/migrate.sh" ] && cp "$STAGE/migrate.sh" "$SEED_STAGE/migrate.sh" || true
    ( cd "$SEED_STAGE" && $T "$SHELL_BIN" autopif4.sh --strong ) > "$STAGE/seed-fetch.log" 2>&1
    unset BUSYBOX 2>/dev/null || true
}
if seed_fetch && [ -s "$SEED_STAGE/custom.pif.prop" ]; then
    mv -f "$SEED_STAGE/custom.pif.prop" "$STAGE/pif_seed.prop"
    date +%s > "$STAGE/pif_seed.auto"
    SEED_OK=1
    echo "   seed baked: $(grep -m1 '^MODEL=' "$STAGE/pif_seed.prop" | cut -d= -f2-) (epoch $(cat "$STAGE/pif_seed.auto"))"
else
    echo "   !! build-time fetch failed; shipping WITHOUT a seed (runtime fetch layer covers it)" >&2
    echo "   ---- autopif4 output (last 25 lines) ----" >&2
    tail -n 25 "$STAGE/seed-fetch.log" >&2 2>/dev/null || true
    echo "   -----------------------------------------" >&2
fi
# autopif4 leaves working files (PIXEL_*.html/json, custom.pif.*) in its cwd —
# none of them may leak into the package.
rm -rf "$SEED_STAGE"
find "$STAGE" -maxdepth 1 -name 'PIXEL_*' -delete 2>/dev/null || true
rm -f "$STAGE/custom.pif.prop" "$STAGE/custom.pif.json" "$STAGE/seed-fetch.log" 2>/dev/null || true
[ "$SEED_OK" = "1" ] && echo "   seed fingerprint included" || echo "   no seed in this build"

# Sanity checks: daemon dex present, both webroots present, module.prop templated,
# and the fingerprint payload actually landed (v3.x REQUIRES it — the reverse of
# the v2.x rule that forbade any PIF payload).
[ -f "$STAGE/teesim-service.dex" ] || [ -f "$STAGE/service.apk" ] || { echo "!! teesim daemon dex missing" >&2; exit 1; }
[ -f "$STAGE/zygisk/arm64-v8a.so" ] || { echo "!! zygisk fingerprint library missing" >&2; exit 1; }
# The payload's hardcoded config dir MUST have been repointed at the fusion
# module: if the path prefix survives, the fingerprint half silently no-ops
# on-device (config never found) and PI is stuck at BASIC. Only the DIRECTORY
# PATH is checked — unrelated identifiers that merely contain "playintegrityfix"
# (libplayintegrityfix.so, es.chiteroman.playintegrityfix.EntryPoint, the
# module's own class/tag names) are expected to stay as they are.
if grep -qa "/data/adb/modules/playintegrityfix" "$STAGE/zygisk/arm64-v8a.so"; then
    echo "!! zygisk payload still points at the standalone PIF module dir" >&2
    exit 1
fi
grep -qa "$PIF_PATH_NEW" "$STAGE/zygisk/arm64-v8a.so" \
    || { echo "!! zygisk payload path repointing failed" >&2; exit 1; }
[ -f "$STAGE/classes.dex" ] || { echo "!! fingerprint classes.dex missing" >&2; exit 1; }
[ -f "$STAGE/autopif4.sh" ] || { echo "!! fingerprint generator script missing" >&2; exit 1; }
[ -f "$STAGE/pif-service.sh" ] || { echo "!! pif-service.sh missing" >&2; exit 1; }
[ -f "$STAGE/post-fs-data.sh" ] || { echo "!! post-fs-data.sh missing" >&2; exit 1; }
# v3.2.3 (audit N2): the upstream console webroot must NOT ship — its log
# export concatenates unmasked pre-0006 log shards into /sdcard/Download.
[ ! -e "$STAGE/webroot/teesim" ] || { echo "!! upstream teesim console must not ship (audit N2)" >&2; exit 1; }
# v3.2.3 (audit N1): engine-check.sh must never print the raw /status JSON.
grep -q 'head -c 1200' "$STAGE/engine-check.sh" \
    && { echo "!! engine-check.sh still prints raw /status output (audit N1)" >&2; exit 1; }
[ -f "$STAGE/webroot/index.html" ] || { echo "!! launcher missing" >&2; exit 1; }
[ -f "$STAGE/webroot/apps.html" ] && [ -f "$STAGE/webroot/js/apps.js" ] || { echo "!! apps page missing" >&2; exit 1; }
[ -f "$STAGE/webroot/logs.html" ] && [ -f "$STAGE/webroot/js/logs.js" ] || { echo "!! logs page missing" >&2; exit 1; }
[ -f "$STAGE/apps-sync.sh" ] || { echo "!! apps-sync.sh missing" >&2; exit 1; }
[ -f "$STAGE/fusion_func.sh" ] || { echo "!! fusion_func.sh missing (overlay rename failed)" >&2; exit 1; }
grep -q "^id=$MODID$" "$STAGE/module.prop" \
    || { echo "!! module.prop id lost during staging (expected '$MODID')" >&2; exit 1; }
grep -q '@FUSION_VERSION@' "$STAGE/module.prop" \
    && { echo "!! module.prop templating did not run (@FUSION_VERSION@ still present)" >&2; exit 1; }
# The overlay must not have regressed to shipping its own root common_func.sh:
# that root name belongs to the fingerprint payload's library now.
if [ -f "$OVERLAY/common_func.sh" ]; then
    echo "!! overlay/common_func.sh must be renamed fusion_func.sh (root name is the fingerprint payload's)" >&2
    exit 1
fi

echo "== Zipping $(basename "$OUT_ZIP")"
mkdir -p "$(dirname "$OUT_ZIP")"
zip_dir "$STAGE" "$OUT_ZIP"
echo "== Done: $OUT_ZIP"
zip_ls() {
    if command -v zip >/dev/null 2>&1; then
        unzip -l "$OUT_ZIP"
    else
        python3 - "$OUT_ZIP" <<'PYEOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for n in z.namelist():
        print(n)
PYEOF
    fi
}
zip_ls | tail -5
