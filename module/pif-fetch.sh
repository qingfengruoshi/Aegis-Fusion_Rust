#!/system/bin/sh
# Aegis Fusion — pif-fetch: auto-generate / refresh the fingerprint for the
# bundled Play Integrity Fork payload. This is the "install-and-go" piece of
# the fingerprint half: PIFork ships no fingerprint on purpose (public ones
# get banned within days), so without this script the user would have to hunt
# one down manually. We generate a random latest-Pixel-Canary fingerprint via
# the payload's own autopif4.sh in --strong mode — the configuration matched
# to a hardware-attestation stack (our TEE half): spoofProvider stays
# disabled and the security patch comes from the fingerprint itself, which
# pif-sync.sh mirrors into the TEES profile so both halves agree.
#
# Ownership rules (the whole point of the marker file):
#   - custom.pif.prop/.json present WITHOUT our marker  -> user-provided,
#     NEVER touched. The user's private fingerprint always wins.
#   - fingerprint present WITH our marker               -> auto-generated;
#     regenerated once it nears expiry (Canary prints last ~6 weeks, we
#     rotate at 14 days of age with wide margin).
#   - no fingerprint at all                             -> generate now.
#
# Runs from service.sh's hourly loop (also covers the failed-boot-network
# retry: autopif4 needs the network, and the loop simply tries again).
# After a successful generation pif-sync.sh runs immediately so the TEE
# profile picks the identity up (and bounces the daemon + DroidGuard when
# the values actually changed).
#
# All paths are overridable for the test harness.

MODDIR="${AEGIS_MODDIR:-/data/adb/modules/aegisfusion_rs}"
TEE_DIR="${AEGIS_TEE_DIR:-/data/adb/teesim}"
LOG="$TEE_DIR/pif-fetch.log"
# R7-1 (2026-09-19): where the ACTIVE fingerprint came from, for the WebUI's
# source breakdown. Values: install-fetch | seed | runtime-fetch.
PIF_SOURCE="$TEE_DIR/.pif-source"
MAX_AGE_DAYS="${AEGIS_PIF_MAX_AGE_DAYS:-14}"
# Durable master copy of the active fingerprint, OUTSIDE the module dir. A
# module update/reflash replaces the whole module directory and wipes every
# runtime file in it (seen live 2026-09-08: a reflash erased custom.pif.prop
# + .pif-auto at boot, pif-sync then rolled the TEE identity back to the real
# device, and the device went one-green again). /data/adb/teesim — where the
# keybox already lives — survives reflashes, so it holds the master; the
# module dir holds the working copy PIFork reads.
MASTER="$TEE_DIR/pif-master"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }
# Debug channel (v3.0.2): unified debug.log while /data/adb/teesim/.debug exists.
DBG_LOG="$TEE_DIR/debug.log"
dbg() { [ -f "$TEE_DIR/.debug" ] && echo "[$(date '+%F %T')] [piffetch] $*" >> "$DBG_LOG" 2>/dev/null; return 0; }
trim_log() {
    [ -f "$LOG" ] || return 0
    if [ "$(wc -l < "$LOG")" -gt 400 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
}

# expiry_epoch <YYYY-MM-DD> — epoch seconds for that date (noon UTC), PURE
# shell integer math (Fliegel–Van Flandern JDN). No external date call: device
# date applets (toybox vs busybox vs GNU) parse formats differently, and this
# must never be the reason a rotation clock breaks. Rejects anything that is
# not exactly YYYY-MM-DD — including autopif4's "Unknown" placeholder — so the
# caller can fall back to the fixed 14-day clock.
expiry_epoch() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) return 1 ;;
    esac
    # Strip leading zeros by hand: $((10#09)) (bash/ksh base#) is a SYNTAX
    # ERROR under dash — and CI's /bin/sh is dash (seen live: the expiry-aware
    # deadline silently fell back to 14 days there while Git Bash's sh=bash
    # passed locally). Plain $(( 09 )) would be an invalid octal too.
    _ed_y=${1%%-*}
    _ed_md=${1#*-}
    _ed_m=${_ed_md%%-*}
    _ed_d=${_ed_md#*-}
    while [ "${_ed_y#0}" != "$_ed_y" ] && [ -n "${_ed_y#0}" ]; do _ed_y=${_ed_y#0}; done
    while [ "${_ed_m#0}" != "$_ed_m" ] && [ -n "${_ed_m#0}" ]; do _ed_m=${_ed_m#0}; done
    while [ "${_ed_d#0}" != "$_ed_d" ] && [ -n "${_ed_d#0}" ]; do _ed_d=${_ed_d#0}; done
    [ "$_ed_m" -ge 1 ] && [ "$_ed_m" -le 12 ] && [ "$_ed_d" -ge 1 ] && [ "$_ed_d" -le 31 ] || return 1
    _ed_a=$(( (14 - _ed_m) / 12 ))
    _ed_yy=$(( _ed_y + 4800 - _ed_a ))
    _ed_mm=$(( _ed_m + 12 * _ed_a - 3 ))
    _ed_j=$(( (153 * _ed_mm + 2) / 5 + _ed_d + 365 * _ed_yy + _ed_yy / 4 - _ed_yy / 100 + _ed_yy / 400 - 32045 ))
    echo $(( (_ed_j - 2440588) * 86400 ))
}

# rotation_deadline <fingerprint-file> <born-epoch> — the epoch second at
# which the fingerprint should rotate: min(estimated expiry - 3 days,
# born + MAX_AGE_DAYS). The expiry line is a plain comment autopif4 appends
# to every prop it produces ("# Estimated Expiry: YYYY-MM-DD"); it is read
# from our own file, never from the network — zero added cost per tick.
# Any missing/garbled expiry falls back to the fixed 14-day clock.
rotation_deadline() {
    _rd_rot=$(( ${2:-0} + MAX_AGE_DAYS * 86400 ))
    _rd_exp="$(sed -n 's/^# Estimated Expiry: //p' "$1" 2>/dev/null | head -n 1 | tr -d ' \r')"
    if [ -n "$_rd_exp" ]; then
        _rd_ee=$(expiry_epoch "$_rd_exp") && {
            _rd_e=$(( _rd_ee - 3 * 86400 ))
            [ "$_rd_e" -lt "$_rd_rot" ] && _rd_rot=$_rd_e
        }
    fi
    echo "$_rd_rot"
}

# Master kill-switch for the fingerprint half. When /data/adb/teesim/.pif-off
# exists, generation is suspended and pif-sync.sh restores the TEE profile to
# the device's REAL identity — the exact state a standalone TEESimulator runs
# in. Purpose (2026-09-08): the controlled experiment where the same keybox on
# the same device passes DEVICE on a standalone module but only reaches BASIC
# under this fusion. With the PIF half parked, every remaining fusion-vs-
# standalone difference is out of the equation; whichever verdict comes back
# pins the poison to one half.
if [ -f "$TEE_DIR/.pif-off" ]; then
    log "PIF half disabled (.pif-off); fingerprint generation suspended"
    dbg "kill-switch present — nothing to fetch or rotate"
    exit 0
fi

# Restore pass — runs before the fingerprint is located. If the module dir
# lost its fingerprint (update/reflash reset it) but the durable master
# survived, put the working copy (and its ownership marker) back in place
# first, so the detection below sees the restored identity.
if [ ! -s "$MODDIR/custom.pif.prop" ] && [ ! -s "$MODDIR/custom.pif.json" ] \
   && { [ -s "$MASTER/custom.pif.prop" ] || [ -s "$MASTER/custom.pif.json" ]; }; then
    mkdir -p "$MODDIR" 2>/dev/null
    cp "$MASTER/custom.pif.prop" "$MODDIR/" 2>/dev/null
    cp "$MASTER/custom.pif.json" "$MODDIR/" 2>/dev/null
    if [ -f "$MASTER/.pif-auto" ]; then
        cp "$MASTER/.pif-auto" "$MODDIR/.pif-auto" 2>/dev/null
    else
        rm -f "$MODDIR/.pif-auto" 2>/dev/null
    fi
    # R7-1 follow-up: bring the provenance back with the identity (otherwise the
    # WebUI falls back to printing the path and the source breakdown is lost).
    if [ -s "$MASTER/.pif-source" ]; then
        cp "$MASTER/.pif-source" "$PIF_SOURCE" 2>/dev/null
    fi
    log "module dir was reset (update/reflash); fingerprint restored from the durable copy"
    dbg "restored fingerprint + ownership marker from $MASTER"
fi

PIF_FILE=""
for f in "$MODDIR/custom.pif.prop" "$MODDIR/custom.pif.json" \
         "$MODDIR/pif.prop" "$MODDIR/pif.json"; do
    if [ -s "$f" ]; then PIF_FILE="$f"; break; fi
done
MARKER="$MODDIR/.pif-auto"

# Package-baked seed (v3.2.1): assemble.sh bakes a fresh fingerprint built on
# the CI runner into the zip. Fresh installs boot with a working identity on
# day one — no empty window before the first successful runtime fetch (the
# gap that left 3.2.0 users without a fingerprint for hours). The seed's
# epoch (pif_seed.auto, written at build time) starts the 14-day rotation
# clock at the build date; from then on the normal fetch/rotate cycle owns
# the identity, and a user-imported fingerprint still outranks everything.
# Note pif_seed.prop is deliberately NOT in the PIF_FILE detection list: an
# undeployed seed must never masquerade as a user fingerprint.
SEED_EPOCH=""
if [ -z "$PIF_FILE" ] && [ ! -s "$MASTER/custom.pif.prop" ] && [ ! -s "$MASTER/custom.pif.json" ]; then
    if [ -s "$MODDIR/pif_seed.prop" ]; then
        if [ -s "$MODDIR/pif_seed.auto" ]; then
            SEED_EPOCH="$(cat "$MODDIR/pif_seed.auto" 2>/dev/null | tr -d ' \t\r\n')"
            case "$SEED_EPOCH" in ''|*[!0-9]*) SEED_EPOCH="" ;; esac
        fi
        cp "$MODDIR/pif_seed.prop" "$MODDIR/custom.pif.prop" 2>/dev/null
        if [ -s "$MODDIR/custom.pif.prop" ]; then
            if [ -n "$SEED_EPOCH" ]; then
                # R7-1 (author design, 2026-09-19): a baked seed is a SHARED
                # identity — everyone who installs this package carries the same
                # model — so it must NOT sit for the full 14-day window. Park
                # the rotation deadline at NOW: the first tick whose network
                # works replaces it with a device-specific random fetch. Until
                # that succeeds the seed keeps the device working (no empty
                # window), and the swap is silent by design (debug.log only).
                _sd_now="$(date +%s 2>/dev/null)"
                case "$_sd_now" in ''|*[!0-9]*) _sd_now="$SEED_EPOCH" ;; esac
                printf '%s\n%s\n' "$SEED_EPOCH" "$_sd_now" > "$MARKER" 2>/dev/null
                printf 'seed\n' > "$PIF_SOURCE" 2>/dev/null
            fi
            log "seed fingerprint deployed from the package (built epoch: ${SEED_EPOCH:-unknown})"
            dbg "seed deployed: pif_seed.prop -> custom.pif.prop (epoch ${SEED_EPOCH:-none})"
            PIF_FILE="$MODDIR/custom.pif.prop"
            mirror_master "$PIF_FILE"
        fi
    else
        # Audit M5 (fail-loud, 2026-09-16): a package can ship without a seed
        # when the build-time fetch failed (assemble.sh warns but does not
        # fail). That used to be indistinguishable from any other empty state
        # here — the user saw "no fingerprint / PI at BASIC" with zero reason
        # in the log. Name the cause explicitly; the runtime fetch layer owns
        # the recovery either way.
        log "no fingerprint on device and NO built-in seed in this package (build-time fetch likely failed) — identity arrives with the first successful runtime fetch"
        dbg "seed deploy skipped: pif_seed.prop missing or empty"
    fi
fi

# mirror_master <active-file> — keep the durable copy in step with the module
# dir (file + ownership marker). Cheap enough to run at every decision point.
mirror_master() {
    [ -s "$1" ] || return 0
    mkdir -p "$MASTER" 2>/dev/null || return 0
    if [ "$1" = "$MASTER/custom.pif.prop" ] || [ "$1" = "$MASTER/custom.pif.json" ]; then
        return 0
    fi
    cp "$1" "$MASTER/" 2>/dev/null || return 0
    for g in "$MASTER/custom.pif.prop" "$MASTER/custom.pif.json"; do
        [ "$g" = "$MASTER/$(basename "$1")" ] || rm -f "$g" 2>/dev/null
    done
    if [ -f "$MARKER" ]; then
        cp "$MARKER" "$MASTER/.pif-auto" 2>/dev/null
    else
        rm -f "$MASTER/.pif-auto" 2>/dev/null
    fi
    # R7-1 follow-up (2026-09-19): mirror the provenance too, so a restore after
    # a module update keeps reporting where the identity actually came from.
    if [ -s "$PIF_SOURCE" ]; then
        cp "$PIF_SOURCE" "$MASTER/.pif-source" 2>/dev/null
    else
        rm -f "$MASTER/.pif-source" 2>/dev/null
    fi
}

# User-provided fingerprint: hands off, permanently.
if [ -n "$PIF_FILE" ] && [ ! -f "$MARKER" ]; then
    mirror_master "$PIF_FILE"
    printf 'user\n' > "$PIF_SOURCE" 2>/dev/null
    log "user fingerprint at $PIF_FILE; leaving it alone"
    dbg "user fingerprint at $PIF_FILE — generator skipped"
    exit 0
fi

# Provenance backfill (F-11 follow-up, 2026-09-20): identities created before
# the source marker existed (upgrades from builds whose install-time fetch
# wrote it to the filesystem root) have no provenance on record. Label them
# honestly - the WebUI shows 已有身份（升级前继承，来源未记录） instead of a raw
# path. Only auto-managed identities reach this point (user files got their own
# marker above), and everything that GENERATES an identity writes its own, so
# this fires at most once per identity.
if [ -n "$PIF_FILE" ] && [ -f "$MARKER" ] && [ ! -s "$PIF_SOURCE" ]; then
    printf 'legacy\n' > "$PIF_SOURCE" 2>/dev/null
    log "provenance backfilled as 'legacy' (identity predates the source marker)"
    dbg "provenance backfill: legacy (no .pif-source on record)"
fi

if [ -n "$PIF_FILE" ]; then
    # Auto-generated: rotate once the rotation deadline passes. The marker's
    # second line (when present) is the expiry-aware deadline written at the
    # last successful fetch — min(estimated expiry - 3 days, born + 14 days).
    # A single-line marker (older format, or a parse failure at write time)
    # keeps the fixed 14-day clock: never a dead end, only a wider margin.
    now=$(date +%s 2>/dev/null)
    born=$(sed -n '1p' "$MARKER" 2>/dev/null | tr -d ' \t\r\n')
    case "$born" in ''|*[!0-9]*) born=0 ;; esac
    rot=$(sed -n '2p' "$MARKER" 2>/dev/null | tr -d ' \t\r\n')
    case "$rot" in ''|*[!0-9]*) rot=$(( born + MAX_AGE_DAYS * 86400 )) ;; esac
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    age_days=$(( (now - born) / 86400 ))
    if [ "$now" -lt "$rot" ]; then
        mirror_master "$PIF_FILE"
        dbg "auto fingerprint fresh (rotates at epoch $rot) — nothing to do"
        exit 0
    fi
    log "auto fingerprint rotation due (deadline epoch $rot, ${age_days}d old); rotating"
    # Deliberately do NOT delete the old fingerprint here. The generator only
    # writes custom.pif.prop after every network fetch succeeded, so a failed
    # run leaves the previous fingerprint (and its marker) intact — the device
    # keeps a working identity and the next tick simply retries. Deleting
    # first meant one bad-network rotation left the device with NO fingerprint
    # at all (seen live 2026-09-08: rotation -> wget reset -> one-green).
fi

# Generate. autopif4.sh --strong writes custom.pif.prop into its own
# directory and needs root + network; a failure here is retried several
# times within the same tick (ATTEMPTS tries, WAIT seconds apart) and then
# again on the next hourly tick. The generator is shim-able for the test
# harness.
if [ ! -f "$MODDIR/autopif4.sh" ]; then
    log "autopif4.sh missing from the module directory; nothing to run"
    exit 0
fi
log "generating a fresh Pixel Canary fingerprint (strong preset)"
# Hard cap per attempt: autopif4 talks to Google endpoints; on a blackholed
# route its internal downloader can stall far longer than any useful wait.
# Worst case per tick is now ATTEMPTS x 300s (default 3 x 300s = 15 min),
# still well under the hourly loop's period, so runs cannot pile up.
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 300"
# Success-rate lever (v3.2.1): one attempt per hourly tick meant a flaky
# route — VPN handoff, captive portal, one bad Google edge, a throttled
# exit node — burned a whole hour per failure, and a brand-new install with
# no fallback fingerprint stayed without one for hours. Try several times
# in the same tick with a short settling gap instead. Both knobs are
# env-overridable for the test harness.
ATTEMPTS="${AEGIS_PIF_ATTEMPTS:-3}"
WAIT="${AEGIS_PIF_RETRY_WAIT:-20}"
case "$ATTEMPTS" in ''|*[!0-9]*) ATTEMPTS=3 ;; esac
[ "$ATTEMPTS" -lt 1 ] 2>/dev/null && ATTEMPTS=1
case "$WAIT" in ''|*[!0-9]*) WAIT=20 ;; esac

# Optional proxy passthrough (v3.2.1): seen live 2026-09-12 — autopif4's
# wget got its TLS handshake reset mid-flight ("bad TLS record / Connection
# reset by peer") while the keybox channels on other endpoints worked fine:
# the fetch runs as a root shell process and gets no per-app proxy routing,
# and rule-based split-tunnel VPNs commonly leave the Android Developers
# endpoints on the direct (blocked) path. If $TEE_DIR/pif-proxy.conf exists,
# its first line (e.g. "http://127.0.0.1:7890", the local proxy's mixed/http
# port) is exported as http_proxy/https_proxy around the generator loop
# ONLY (unset right after, so pif-sync and everything later run proxy-free).
# AEGIS_PIF_PROXY overrides for the test harness. NOTE: plain `export`, NOT
# an `env VAR=...` command prefix — env-prefixed spawns have been seen to
# silently no-op under some host shells (Git Bash/MSYS), and export is the
# more portable form on device shells anyway.
PX=""
if [ -n "$AEGIS_PIF_PROXY" ]; then
    PX="$AEGIS_PIF_PROXY"
elif [ -s "$TEE_DIR/pif-proxy.conf" ]; then
    PX="$(head -n 1 "$TEE_DIR/pif-proxy.conf" 2>/dev/null | tr -d ' \t\r\n')"
fi
if [ -n "$PX" ]; then
    # The value becomes part of the root shell's environment, so treat the
    # config file as hostile input: accept only a conservative URL/host:port
    # charset and reject anything with shell metacharacters.
    case "$PX" in
        *[!A-Za-z0-9:._@/-]*) PX=""; log "WARNING: pif-proxy.conf rejected (unsafe characters in the proxy value)" ;;
    esac
fi
# v3.2.3 (audit N10): a root shell can inherit http_proxy/https_proxy from the
# invoking environment (desktop debugging, some manager contexts). "Round 1:
# direct" must mean DIRECT — clear the inherited variables UNCONDITIONALLY
# here, then re-export the configured proxy (if any) explicitly. The old
# conditional (`[ -n "$PX" ] && unset …`) only cleaned up when a proxy was
# configured, so an inherited proxy silently turned the "direct" round into a
# proxied one and broke the ladder's discrimination (and the generator log's
# "proxy=none|none" honesty).
unset http_proxy https_proxy
if [ -n "$PX" ]; then
    export http_proxy="$PX" https_proxy="$PX"
    log "proxy passthrough active for the generator ($PX)"
    dbg "proxy passthrough: http_proxy/https_proxy=$PX"
fi

GEN=""
run_generation() {
    # Runs ATTEMPTS generator attempts with whatever http_proxy/https_proxy is
    # in the environment right now; sets GEN on success, rc = last exit code.
    GEN=""
    i=1
    while [ "$i" -le "$ATTEMPTS" ]; do
        if [ -n "$AEGIS_AUTOPIF" ]; then
            dbg "attempt $i/$ATTEMPTS: shim generator $AEGIS_AUTOPIF --strong (cap ${TO:-none})"
            $TO sh "$AEGIS_AUTOPIF" --strong > "$TEE_DIR/pif-fetch.last" 2>&1
        else
            dbg "attempt $i/$ATTEMPTS: autopif4.sh --strong in $MODDIR (cap ${TO:-none})"
            (cd "$MODDIR" && $TO sh "$MODDIR/autopif4.sh" --strong > "$TEE_DIR/pif-fetch.last" 2>&1)
        fi
        rc=$?
        dbg "attempt $i/$ATTEMPTS exit rc=$rc"
        if [ "$rc" = "0" ]; then
            # A run counts as successful only if the generator said so AND a
            # fingerprint file exists. The file alone is not proof: since the
            # previous fingerprint is no longer deleted up front, a file on
            # disk after a failed run is just the old survivor, and treating
            # it as fresh output would wrongly restart the rotation clock on
            # a stale identity.
            for f in "$MODDIR/custom.pif.prop" "$MODDIR/custom.pif.json"; do
                if [ -s "$f" ]; then GEN="$f"; break; fi
            done
            [ -n "$GEN" ] && break
        fi
        if [ "$i" -lt "$ATTEMPTS" ]; then
            log "attempt $i/$ATTEMPTS failed (rc=$rc); retrying in ${WAIT}s"
            [ "$WAIT" -gt 0 ] && sleep "$WAIT"
        else
            log "attempt $i/$ATTEMPTS failed (rc=$rc)"
        fi
        i=$((i + 1))
    done
}

# probe_port <port> — rc 0 when something at 127.0.0.1:<port> actually
# proxies HTTP (checked with a real request, not just a TCP connect).
# Shim-able via AEGIS_PIF_PROBE for the test harness.
probe_port() {
    if [ -n "$AEGIS_PIF_PROBE" ]; then
        sh "$AEGIS_PIF_PROBE" "$1" >/dev/null 2>&1
        return $?
    fi
    command -v wget >/dev/null 2>&1 || return 1
    T3=""; command -v timeout >/dev/null 2>&1 && T3="timeout 8"
    # NOTE: export inside a subshell, NOT an `env VAR=...` command prefix —
    # see the comment above; env-prefixed spawns can silently no-op on some
    # host shells (Git Bash/MSYS).
    ( export http_proxy="http://127.0.0.1:$1" https_proxy="http://127.0.0.1:$1"
      # v3.2.3 (audit L2): probe against GitHub itself, not a third-party search
      # domain — the request leaves the device through the candidate proxy, so
      # aim it at the infrastructure the generator endpoints live behind.
      # robots.txt answers 200 unauthenticated. No device data in the request.
      # v3.2.3 (audit N9): full GET, NOT --spider — busybox wget cannot do
      # --spider, which made this probe fail forever on those devices and the
      # auto-proxy rescue path unreachable. Same reasoning as harden-pif N4.
      $T3 wget -q -T 8 -O /dev/null https://github.com/robots.txt ) 2>/dev/null
}

# Round 1: direct, or through the configured proxy (pif-proxy.conf / env).
run_generation
# The proxy was for the generator only; nothing after this point (pif-sync,
# marker writes) should inherit it.
[ -n "$PX" ] && unset http_proxy https_proxy

# Round 2 (auto-proxy fallback, default on): direct failed with no proxy
# configured. Seen live 2026-09-12: the fetch runs as a root shell and gets
# no per-app VPN routing, so split-tunnel users' fetches die on blocked
# Google endpoints while a fully capable local proxy sits one port away.
# Probe the common local proxy ports, remember the winner in
# $TEE_DIR/pif-proxy.auto (reflash-safe), and retry the whole round through
# it. Healthy direct networks never get here (round 1 succeeds), so the
# probe costs everyone else nothing — which is why this is safe to default
# on where a hardcoded default port would not be. AEGIS_PIF_AUTOPROXY=0
# disables; a manually created pif-proxy.conf always wins over the
# auto-detected one.
if [ -z "$GEN" ] && [ -z "$PX" ] && [ "${AEGIS_PIF_AUTOPROXY:-1}" = "1" ]; then
    P2=""
    if [ -s "$TEE_DIR/pif-proxy.auto" ]; then
        P2="$(head -n 1 "$TEE_DIR/pif-proxy.auto" 2>/dev/null | tr -d ' \t\r\n')"
        case "$P2" in
            ''|*[!A-Za-z0-9:._@/-]*) P2="" ;;
        esac
        [ -n "$P2" ] && log "using remembered local proxy $P2 (from pif-proxy.auto)"
    fi
    if [ -z "$P2" ]; then
        log "direct fetch failed; probing common local proxy ports"
        for p in ${AEGIS_PIF_PROBE_PORTS:-7890 7897 10808 10809 2334 2080}; do
            case "$p" in *[!0-9]*) continue ;; esac
            if probe_port "$p"; then P2="http://127.0.0.1:$p"; break; fi
        done
        if [ -n "$P2" ]; then
            echo "$P2" > "$TEE_DIR/pif-proxy.auto" 2>/dev/null
            log "auto-proxy: found a working local proxy at $P2; retrying through it"
        fi
    fi
    if [ -n "$P2" ]; then
        export http_proxy="$P2" https_proxy="$P2"
        run_generation
        unset http_proxy https_proxy
        if [ -z "$GEN" ] && [ -s "$TEE_DIR/pif-proxy.auto" ]; then
            # The remembered proxy no longer works (VPN off / port changed):
            # drop it so the next tick re-probes instead of retrying a corpse.
            rm -f "$TEE_DIR/pif-proxy.auto" 2>/dev/null
            log "remembered proxy did not work; dropped pif-proxy.auto (will re-probe next tick)"
        fi
    fi
fi

if [ -z "$GEN" ]; then
    log "generation failed (last rc=$rc); keeping the previous fingerprint (if any) until the next tick (see pif-fetch.last)"
    # Discoverability (v3.2.1): this exact failure signature is what users on
    # split-tunnel VPNs / censored networks hit with no idea a remedy exists.
    # The hint lands in pif-fetch.log — the same file the WebUI logs page and
    # the diagnostics export show — right where the user will look. With the
    # auto-probe above this now only fires when no common proxy port answered
    # either, i.e. a nonstandard proxy port the user must name explicitly.
    if [ -z "$PX" ]; then
        log "hint: if pif-fetch.last shows TLS resets to Google endpoints, put your local proxy address (e.g. http://127.0.0.1:7890) as the only line of $TEE_DIR/pif-proxy.conf and fingerprint fetches will go through it"
    fi
    trim_log
    exit 0
fi
log "fingerprint ready at $GEN"
# Rotation replaces a differently-named legacy file only after the new one
# exists; the marker is overwritten below so the retry clock restarts.
if [ -n "$PIF_FILE" ] && [ "$GEN" != "$PIF_FILE" ]; then
    rm -f "$PIF_FILE" 2>/dev/null
fi
date +%s > "$MARKER" 2>/dev/null
# Expiry-aware rotation (v3.2.2): read the "# Estimated Expiry" comment the
# generator just wrote into the fresh prop, and park the next rotation at
# min(expiry - 3 days, now + 14 days) as the marker's second line. If the
# line is missing or malformed ("Unknown", a future format change), the
# single-line marker remains and the tick falls back to the fixed 14 days.
_now="$(date +%s 2>/dev/null)"
case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
_rot="$(rotation_deadline "$GEN" "$_now")"
case "$_rot" in ''|*[!0-9]*) _rot="" ;; esac
if [ -n "$_rot" ]; then
    printf '%s\n%s\n' "$_now" "$_rot" > "$MARKER" 2>/dev/null
    dbg "rotation deadline: epoch $_rot (expiry-aware)"
fi
# R7-1: record the provenance for the WebUI (install-fetch is written by
# customize.sh; anything generated here is a runtime fetch).
printf 'runtime-fetch\n' > "$PIF_SOURCE" 2>/dev/null
if [ -s "$MARKER" ]; then
    dbg "auto marker written ($MARKER)"
else
    # Without the marker the next tick reads the file as USER-provided and
    # never rotates it — make this visible instead of failing silently (a
    # read-only module dir under some KSU mounters would hit this).
    log "WARNING: failed to write the auto marker; fingerprint will be treated as user-provided"
fi
chmod 0600 "$GEN" 2>/dev/null
# Durable master: the fresh fingerprint must survive the next module update.
mirror_master "$GEN"

# Mirror the fresh identity into the TEE profile right away; pif-sync
# detects real changes and bounces the daemon + DroidGuard itself.
syncsh="${AEGIS_PIF_SYNC:-$MODDIR/pif-sync.sh}"
if [ -f "$syncsh" ]; then
    log "syncing the new identity into the TEE profile"
    sh "$syncsh" >/dev/null 2>&1
fi

trim_log
exit 0
