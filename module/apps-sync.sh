#!/system/bin/sh
# Aegis Fusion — keep the protected scope tidy.
#
# Since v2.2.5 the "add new installs" half is RETIRED: TEES has a native
# per-profile "autoIncludeNewApps" field (future-installs only, works across
# all Android users, never pollutes the apps array) and the WebUI toggle now
# drives that field directly. This script keeps two janitor jobs that TEES
# does not do itself:
#
#   1. One-time migration: a legacy /data/adb/teesim/apps-auto-add flag file
#      is folded into the profile's autoIncludeNewApps=true, then deleted.
#   2. Cleanup pass (every run): drop entries that cannot be package names
#      (v2.2.0 pollution self-heal) and entries whose app has been uninstalled
#      (TEES keeps dead names forever and just marks them "未安装").
#
# Constraints (deliberate):
#   - Only a SINGLE-profile config.json is edited. If more than one "apps"
#     array exists (user built custom profiles in the advanced console), we
#     skip rather than guess — a wrong guess would misassign keyboxes.
#   - Pruning compares against the FULL package list (incl. system apps) and
#     only when it passes the same hard validation as every other pm read —
#     a failed `pm` banner can never drive deletions.

MODPATH="${0%/*}"
# AEGIS_TEE_DIR shim: host-side tests redirect the data dir (same pattern as pif-sync.sh).
TEE_DIR="${AEGIS_TEE_DIR:-/data/adb/teesim}"
CONFIG="$TEE_DIR/config.json"
LOG="$TEE_DIR/apps-sync.log"
LEGACY_FLAG="$TEE_DIR/apps-auto-add"
GMS_SEED="$TEE_DIR/.gms-scope-seeded"

[ -f "$CONFIG" ] || exit 0

# busybox awk is the only dependable JSON-slice tool on Android (toybox has no
# awk on many builds). Same manager-provided busybox chain as keybox-fetch.sh.
BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox "$(command -v busybox 2>/dev/null)"; do
    if [ -n "$b" ] && [ -x "$b" ]; then
        BB="$b"
        break
    fi
done
[ -n "$BB" ] || exit 0

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
# Debug channel (v3.0.2): unified debug.log while /data/adb/teesim/.debug exists.
DBG_LOG="$TEE_DIR/debug.log"
dbg() { [ -f "$TEE_DIR/.debug" ] && echo "[$(date '+%F %T')] [appssync] $*" >> "$DBG_LOG"; return 0; }

# Only single-profile configs are safe to auto-edit. Count OCCURRENCES, not
# lines: a compact (one-line) JSON body with two profiles would otherwise read
# as single-profile and get mis-edited.
N=$(tr -d "\n\r" < "$CONFIG" | grep -o '"apps"' | wc -l)
dbg "run start: apps-arrays=$N gms-seed-marker=$([ -f "$GMS_SEED" ] && echo present || echo absent)"
[ "$N" = "1" ] || { dbg "multi-profile config — leaving everything untouched"; exit 0; }

# Flattened config body, shared by the passes below (refreshed after edits).
FLAT=$(tr -d "\n\r" < "$CONFIG")

# ---- 1. one-time migration of the retired add-flag -------------------------
if [ -f "$LEGACY_FLAG" ]; then
    WANT=$(cat "$LEGACY_FLAG" 2>/dev/null)
    rm -f "$LEGACY_FLAG"
    # Authoritative-field check: ANY explicit autoIncludeNewApps value counts,
    # not just `true`. The WebUI writes `false` when the user toggles auto-add
    # off; grepping for `true` only would re-insert the field behind that
    # explicit false — a duplicate JSON key plus the user's "off" silently
    # reverted (window: boot until this migration runs). Only a config that
    # lacks the field entirely still gets the legacy flag folded in.
    if [ "$WANT" = "1" ] && ! tr -d "\n\r" < "$CONFIG" | grep -q '"autoIncludeNewApps"[[:space:]]*:'; then
        # Insert the native field ahead of the (single) apps array. The file is
        # flattened first: JSON.stringify may lay the object out over many lines.
        TMP="$TEE_DIR/.config.tmp.$$"
        if tr -d "\n\r" < "$CONFIG" | sed 's/"apps"[[:space:]]*:/"autoIncludeNewApps": true, "apps":/' > "$TMP" && [ -s "$TMP" ] \
            && grep -q '"autoIncludeNewApps"' "$TMP" && grep -q '"apps"' "$TMP" && grep -q '"profiles"' "$TMP"; then
            mv -f "$TMP" "$CONFIG"
            chmod 0600 "$CONFIG"
            log "migrated legacy auto-add flag -> profile autoIncludeNewApps=true"
        else
            rm -f "$TMP"
            log "ERROR: auto-add migration failed sanity check; flag discarded"
        fi
    else
        log "legacy auto-add flag removed (value=${WANT:-empty}; config field already authoritative)"
    fi
fi

# ---- 2. one-time GMS scope seed (v3.0.1) -----------------------------------
# The Play Integrity DEVICE verdict is produced by DroidGuard inside GMS: it
# generates a key in the hardware keystore and reads back its attestation. If
# GMS is not in the TEE scope, that attestation is the REAL device's (unlocked
# bootloader, no certified chain) and the verdict is stuck at BASIC forever —
# regardless of how clean the keybox is. This is exactly why a standalone
# Integrity-Box + TEES combo scored DEVICE while the fusion scored BASIC: IB
# auto-targets GMS; we relied on the user finding the apps page. Seed GMS once
# per install (marker file), so a user who removes it afterwards is not fought.
# Only single-profile configs are touched (same guard as below).
if [ ! -f "$GMS_SEED" ]; then
    if ! pm path com.google.android.gms >/dev/null 2>&1; then
        dbg "gms seed: com.google.android.gms not installed — skipped"
    elif tr -d "\n\r" < "$CONFIG" | grep -q '"com\.google\.android\.gms"'; then
        dbg "gms seed: already in scope — nothing to do"
    fi
    if pm path com.google.android.gms >/dev/null 2>&1 \
        && ! tr -d "\n\r" < "$CONFIG" | grep -q '"com\.google\.android\.gms"'; then
        TMP="$TEE_DIR/.config.tmp.$$"
        if tr -d "\n\r" < "$CONFIG" | "$BB" awk '
            {
                if (match($0, /"apps"[[:space:]]*:[[:space:]]*\[/)) {
                    head = substr($0, 1, RSTART + RLENGTH - 1)
                    rest = substr($0, RSTART + RLENGTH)
                    # Empty array: insert without a trailing comma; non-empty: prepend.
                    if (rest ~ /^[[:space:]]*\]/)
                        printf "%s\"com.google.android.gms\"%s", head, rest
                    else
                        printf "%s\"com.google.android.gms\", %s", head, rest
                } else {
                    printf "%s", $0
                }
            }' > "$TMP" && [ -s "$TMP" ] \
            && grep -q '"com\.google\.android\.gms"' "$TMP" \
            && grep -q '"apps"' "$TMP" && grep -q '"profiles"' "$TMP"; then
            mv -f "$TMP" "$CONFIG"
            chmod 0600 "$CONFIG"
            FLAT=$(tr -d "\n\r" < "$CONFIG")
            log "seeded com.google.android.gms into the attestation scope (DroidGuard must see the keybox)"
        else
            rm -f "$TMP"
            log "ERROR: gms scope seed failed sanity check; left untouched"
        fi
    fi
    # Mark attempted even when gms was absent or already in scope: re-checking
    # on every run would fight a deliberate removal. The marker lives in TEE_DIR
    # and survives reboots; a user can re-seed by deleting the marker file.
    : > "$GMS_SEED" 2>/dev/null
fi

# ---- 2b. PI core trio: package + raw uid:N pins (Round 12) ------------------
# The AS-TEESIM runtime config (three greens on the K70, 2026-09-10) pins the
# Play Integrity core to their REAL uids on top of the package names: package
# targeting alone can miss GMS/Vending/GSF (multi-user, shared uid, resolution
# timing at boot) and the generateKey then falls through to the real HAL. The
# uid is resolved from packages.list (root-readable, no
# system_server needed; AEGIS_PKG_LIST overrides the path for tests). Idempotent: entries already present are kept, the
# user can still delete them in the WebUI — they re-appear on the next tick
# (delete the marker file $TEE_DIR/.uid-pins-off to disable this pass).
if [ ! -f "$TEE_DIR/.uid-pins-off" ]; then
    PIN_ADDED=""
    PKL_FILE="${AEGIS_PKG_LIST:-/data/system/packages.list}"
    PKL=$(cat "$PKL_FILE" 2>/dev/null)
    # packages.list is the authoritative installed+uid source; without it the
    # pass can neither resolve uids nor install-check the package names (and
    # bare names would then fight the cleanup pass below). Skip cleanly.
    if [ -n "$PKL" ]; then
        FLAT=$(tr -d "\n\r" < "$CONFIG")
        for APP in com.google.android.gms com.android.vending com.google.android.gsf; do
            # Only pin apps that are actually installed (per packages.list).
            printf '%s\n' "$PKL" | grep -q "^$APP " || continue
            # package entry first
            if ! printf '%s' "$FLAT" | grep -q "\"$APP\""; then
                PIN_ADDED="$PIN_ADDED $APP"
            fi
            # raw uid entry
            U=$(printf '%s\n' "$PKL" | sed -n "s/^$APP \([0-9][0-9]*\) .*/\1/p" | head -1)
            case "$U" in
                [0-9]*)
                    if ! printf '%s' "$FLAT" | grep -q "\"uid:$U\""; then
                        PIN_ADDED="$PIN_ADDED uid:$U"
                    fi
                    ;;
            esac
        done
    else
        dbg "uid pins: packages.list unreadable — skipped this run"
    fi
    if [ -n "$PIN_ADDED" ]; then
        TMP="$TEE_DIR/.config.tmp.$$"
        INS=$(printf '%s' "$PIN_ADDED" | sed 's/^ //' | tr ' ' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')
        FIRST=$(printf '%s' "$INS" | cut -d'"' -f2)
        # Empty array -> no trailing comma (JSON validity); non-empty -> comma
        # after the inserted block so the existing entries follow cleanly.
        if printf '%s' "$FLAT" | grep -q '"apps"[[:space:]]*:[[:space:]]*\[\]'; then
            PAT='s/"apps"[[:space:]]*:[[:space:]]*\[\]/"apps": [\n'$INS'\n/'
        else
            PAT='s/"apps"[[:space:]]*:[[:space:]]*\[/"apps": [\n'$INS',\n/'
        fi
        if tr -d "\n\r" < "$CONFIG" | sed "$PAT" > "$TMP" \
            && [ -s "$TMP" ] && grep -q '"apps"' "$TMP" && grep -q '"profiles"' "$TMP" \
            && grep -q "\"$FIRST\"" "$TMP"; then
            mv -f "$TMP" "$CONFIG"
            chmod 0600 "$CONFIG"
            FLAT=$(tr -d "\n\r" < "$CONFIG")
            log "pinned PI core into scope, added:${PIN_ADDED}"
        else
            rm -f "$TMP"
            log "ERROR: uid-pin insert failed sanity check; left untouched"
        fi
    fi
fi

# ---- 3. cleanup pass --------------------------------------------------------
# HARD VALIDATION: `pm list packages` can fail with a text banner on its stdout
# (e.g. "cmd: Failure calling service package: Broken pipe (32)"). Splitting that
# on whitespace once poured tokens like "cmd:", "Failure", "(32)" into
# config.json as "apps" and broke the TEE daemon's scope resolution (v2.2.0
# field report). Every list that drives an edit must therefore pass a strict
# package-name filter: dotted, alphanumeric + ._ only.
ALLPKG=$(pm list packages 2>/dev/null | sed 's/^package://' | grep -E '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' | sort -u)
[ -n "$ALLPKG" ] || { dbg "cleanup skipped: pm list packages unavailable"; exit 0; }

# Current entries of the (one) apps array, one per line. The whole file is
# flattened first because JSON.stringify lays the array out over many lines.
CUR=$(tr -d "\n\r" < "$CONFIG" | sed 's/.*"apps"[[:space:]]*:[[:space:]]*\[//; s/\].*//' \
        | tr ',' '\n' | tr -d '" ' | sort -u)

# Entries to drop: uninstalled apps (TEES keeps dead package names forever and
# just marks them "未安装") plus anything that is not a valid package entry.
# @user-suffixed entries are only pruned when invalid: `pm list packages` here
# reports user 0 only, so pkg@10 may well exist without appearing in it.
# uid:N tokens are NEVER prunable here (they pin the PI core trio).
REMOVES=""
for p in $CUR; do
    case "$p" in
        uid:[0-9]*) continue ;;
        *@*) printf '%s' "$p" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+@[0-9]+$' || REMOVES="$REMOVES $p" ;;
        *)   printf '%s\n' "$ALLPKG" | grep -Fxq "$p" || REMOVES="$REMOVES $p" ;;
    esac
done

# ---- 3b. one-time cleanup of the retired detector exclusion (v3.1.7) --------
# v3.1.6 pulled six detector apps (KeyAttestation, PIAC, ...) out of the scope on
# every run and recorded the drop in .detector-excluded, with .keep-detectors as
# the opt-out. Both are RETIRED: the scope now holds exactly what the user ticks,
# and the real fix for the -66 they were avoiding lives in the engine — upstream
# patch 0005 rewrites the request's ATTESTATION_ID_* tags to the profile's
# identity before the TA's CANNOT_ATTEST_IDS gate sees them, so an ID-attesting
# detector app inside the scope gets served instead of rejected. Leftover marker
# files would keep a stale WebUI note alive, so they go once, loudly.
DET_FILE="$TEE_DIR/.detector-excluded"
DET_OPTOUT="$TEE_DIR/.keep-detectors"
if [ -f "$DET_FILE" ] || [ -f "$DET_OPTOUT" ]; then
    rm -f "$DET_FILE" "$DET_OPTOUT" 2>/dev/null
    log "removed leftover detector-exclusion markers (v3.1.7: protected apps are never auto-removed)"
fi

REMOVES=$(printf '%s' "$REMOVES" | sed 's/^ //' | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')

[ -n "$REMOVES" ] || exit 0

# Rewrite: flatten config, splice the single apps array, keep everything else
# byte-identical. awk rebuilds the array from the surviving entries.
TMP="$TEE_DIR/.config.tmp.$$"
if tr -d "\n\r" < "$CONFIG" | "$BB" awk -v removes="$REMOVES" '
    BEGIN {
        nr = split(removes, rm, " ")
        for (j = 1; j <= nr; j++) if (rm[j] != "") drop[rm[j]] = 1
    }
    {
        if (match($0, /"apps"[[:space:]]*:[[:space:]]*\[[^]]*\]/)) {
            inner = substr($0, RSTART, RLENGTH)
            sub(/^"apps"[[:space:]]*:[[:space:]]*\[/, "", inner)
            sub(/\]$/, "", inner)
            k = 0
            m = split(inner, parts, ",")
            for (i = 1; i <= m; i++) {
                e = parts[i]
                gsub(/[ \t"]/, "", e)
                if (e == "") continue
                # Drop entries that cannot be package names (purges any legacy
                # garbage from the v2.2.0 pollution bug) and entries whose app
                # is no longer installed (prune pass). uid:N pins survive both.
                if (e ~ /^uid:[0-9]+$/) { list[++k] = e; continue }
                if (e !~ /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+(@[0-9]+)?$/) continue
                if (e in drop) continue
                list[++k] = e
            }
            narr = "\"apps\": ["
            for (i3 = 1; i3 <= k; i3++)
                narr = narr (i3 > 1 ? ", " : "") "\"" list[i3] "\""
            printf "%s%s]%s", substr($0, 1, RSTART - 1), narr, substr($0, RSTART + RLENGTH)
        } else {
            # No apps array found — print unchanged so we never truncate.
            printf "%s", $0
        }
    }' > "$TMP" && [ -s "$TMP" ]; then
    # Sanity: the result must still parse as JSON (brace balance + apps count unchanged).
    if grep -q '"apps"' "$TMP" && grep -q '"profiles"' "$TMP"; then
        mv -f "$TMP" "$CONFIG"
        chmod 0600 "$CONFIG"
        # Say WHY, not just what: a bare "cleaned, removed:xxx" reads as random
        # churn. The prefix stays for grep/back-compat. (Since v3.1.7 this is the
        # ONLY removal reason left — detector apps are never touched.)
        log "cleaned, removed:${REMOVES}  (absent from pm list packages — uninstalled or uninstalled for this user)"
    else
        rm -f "$TMP"
        log "ERROR: rewritten config failed sanity check; left untouched"
    fi
else
    rm -f "$TMP"
    log "ERROR: awk merge failed"
fi
