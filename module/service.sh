#!/system/bin/sh
# Aegis Fusion boot service.
#
# v3.x composition (fingerprint payload bundled):
#   1. Environment/BL hiding layer ("box" layer) — resetprop-based spoofing of the
#      bootloader, verified-boot, warranty and build signals, merged from Integrity-Box
#      and PlayIntegrityFix's early-boot property fixes.
#   2. The fingerprint half's late-boot prop resets (pif-service.sh, the bundled
#      Play Integrity Fork service script, sourced below).
#   3. Scheduled community-keybox refresh for the TEE layer.
#   4. Scheduled fingerprint generation/refresh (pif-fetch.sh) and identity
#      mirroring into the TEE profile (pif-sync.sh).
#   5. TEESimulator control daemon — software KeyMint/keybox attestation.
MODPATH="${0%/*}"
. "$MODPATH"/fusion_func.sh

# Debug channel (v3.0.2): while /data/adb/teesim/.debug exists (default ON
# since flash; toggled from the logs page) the boot sequence and the hourly
# tick narrate themselves into the unified debug.log.
DBG_FLAG=/data/adb/teesim/.debug
DBG_LOG=/data/adb/teesim/debug.log
dbg() { [ -f "$DBG_FLAG" ] && echo "[$(date '+%F %T')] [service] $*" >> "$DBG_LOG" 2>/dev/null; return 0; }
dbg "boot: service.sh started"

# ---------- Patch-level alignment (R4, formalized) ----------
# align_patch_level() lives in fusion_func.sh and is called ONCE per boot,
# from post-fs-data.fusion.sh (appended into post-fs-data.sh at assemble
# time, AlwaysStrong sync_patch.sh-boot parity). There is deliberately NO
# service-stage or hourly-tick call (audit L10, 2026-09-16 — earlier
# comments here claimed both existed; they never did). Consequence: after a
# fingerprint profile rotation the patch-date props realign at the NEXT
# reboot. Adding the service-stage call is an open decision that needs
# on-device verification before it ships.

# ---------- Fingerprint half: late-boot property resets (bundled payload) ----------
# The bundled Play Integrity Fork ships its own service script: sensitive-prop
# resets that must run at service time (SELinux state, recovery mode, compact)
# plus a boot_completed-gated late pass. Sourcing it runs its top level inline
# and leaves its background block running alongside ours. It sources the root
# common_func.sh (the payload's own helpers — supersets of fusion_func.sh's).
if [ -f "$MODPATH/zygisk/arm64-v8a.so" ] || [ -f "$MODPATH/zygisk/x86_64.so" ] \
   || [ -f "$MODPATH/zygisk/armeabi-v7a.so" ]; then
    . "$MODPATH"/pif-service.sh
fi

# ---------- Root-hiding hygiene: keep GMS out of DenyList enforcement ----------

# Remove Play Services and Play Store from Magisk DenyList when set to Enforce in normal mode
if magisk --denylist status 2>/dev/null; then
    magisk --denylist rm com.google.android.gms
else
    # Check if Shamiko is installed and whitelist feature isn't enabled
    if [ -d "/data/adb/modules/zygisk_shamiko" ] && [ ! -f "/data/adb/shamiko/whitelist" ]; then
        magisk --denylist add com.google.android.gms com.google.android.gms
        magisk --denylist add com.google.android.gms com.google.android.gms.unstable
        magisk --denylist add com.android.vending
    fi
fi

# ---------- Early boot: bootloader / verified-boot / build signal hiding ----------

# Bootloader / VBMeta state — the core "hide unlocked BL" set (Integrity-Box).
resetprop_if_diff ro.boot.vbmeta.device_state locked
resetprop_if_diff vendor.boot.vbmeta.device_state locked
resetprop_if_diff ro.boot.verifiedbootstate green
resetprop_if_diff vendor.boot.verifiedbootstate green
resetprop_if_diff ro.boot.flash.locked 1
resetprop_if_diff ro.boot.veritymode enforcing
resetprop_if_diff ro.secureboot.lockstate locked   # MIUI

# Warranty / debug (Samsung / general)
resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.vendor.boot.warranty_bit 0
resetprop_if_diff ro.vendor.warranty_bit 0
resetprop_if_diff ro.warranty_bit 0
resetprop_if_diff ro.debuggable 0
resetprop_if_diff ro.force.debuggable 0
resetprop_if_diff ro.secure 1
resetprop_if_diff ro.adb.secure 1
resetprop_if_diff sys.oem_unlock_allowed 0
resetprop_if_diff ro.oem_unlock_supported 0

# OEM-specific
resetprop_if_diff ro.boot.realmebootstate green    # Realme
resetprop_if_diff ro.boot.realme.lockstate 1       # Realme
resetprop_if_diff ro.is_ever_orange 0              # OnePlus

# Build signals
for PROP in $(resetprop | grep -oE 'ro.*.build.tags'); do
    resetprop_if_diff "$PROP" release-keys
done
for PROP in $(resetprop | grep -oE 'ro.*.build.type'); do
    resetprop_if_diff "$PROP" user
done

# Custom recovery hiding — a "recovery" bootmode is a root/custom-recovery tell.
resetprop_if_match ro.bootmode recovery unknown
resetprop_if_match ro.boot.bootmode recovery unknown
resetprop_if_match vendor.boot.bootmode recovery unknown

# Misc environment noise
resetprop_if_diff ro.hardware.virtual_device 0

# ---------- /proc/cmdline masking (experiment lever: .cmdline-spoof) ----------
# resetprop rewrites the property area, but /proc/cmdline is a procfs file the
# kernel assembled at boot: the androidboot.* entries there still carry the
# REAL unlocked/orange boot state, and no property fix can touch them. This is
# the strongest remaining suspect for the one-green gap (the Integrity-Box
# hook layer covers it in-process; we cover it globally with a bind mount).
# Opt-in via marker file so the default stays byte-identical to plain upstream.
CMD_SPOOF_FLAG=/data/adb/teesim/.cmdline-spoof
CMD_SPOOF_FILE=/data/adb/teesim/cmdline.spoofed
if [ -f "$CMD_SPOOF_FLAG" ] && [ -r /proc/cmdline ]; then
    if grep -q "cmdline.spoofed" /proc/self/mountinfo 2>/dev/null; then
        dbg "cmdline: spoof mount already active"
    else
        # Fake cmdline = real one except the BL-state entries; every other
        # boot parameter stays truthful. sed is safe on the single NUL-tolerant
        # procfs line; value ranges stop at the separator.
        sed -e 's/androidboot\.verifiedbootstate=[a-z]*/androidboot.verifiedbootstate=green/g' \
            -e 's/androidboot\.vbmeta\.device_state=[a-z]*/androidboot.vbmeta.device_state=locked/g' \
            -e 's/androidboot\.flash\.locked=[01]/androidboot.flash.locked=1/g' \
            -e 's/androidboot\.veritymode=[a-z]*/androidboot.veritymode=enforcing/g' \
            -e 's/androidboot\.warranty_bit=[01]/androidboot.warranty_bit=0/g' \
            /proc/cmdline > "$CMD_SPOOF_FILE" 2>/dev/null
        if [ -s "$CMD_SPOOF_FILE" ] && mount -o bind "$CMD_SPOOF_FILE" /proc/cmdline 2>/dev/null; then
            dbg "cmdline: /proc/cmdline masked via bind mount (androidboot BL entries -> locked/green)"
        else
            dbg "cmdline: bind mount failed (kernel/namespace restriction); real cmdline stays visible"
        fi
    fi
fi

# Derivative-ROM scrub — hide lineage markers that Play Integrity's DroidGuard
# can read from props (adapted from AlwaysStrong). The Health HAL tell is the
# property NAME (it carries "lineage"), not the running service, so dropping
# the prop hides the ROM marker without breaking charge limiting.
LV=$(getprop ro.product.vendor.name 2>/dev/null)
case "$LV" in
    lineage_*) resetprop -n ro.product.vendor.name "${LV#lineage_}" ;;
esac
for LP in vendor.camera.aux.packagelist persist.vendor.camera.privapp.list; do
    LCV=$(getprop "$LP" 2>/dev/null)
    case "$LCV" in
        *org.lineageos.aperture*)
            LCV=$(echo "$LCV" | sed -e 's/,org\.lineageos\.aperture//g' \
                                    -e 's/org\.lineageos\.aperture,//g' \
                                    -e 's/^org\.lineageos\.aperture$//')
            resetprop -n "$LP" "$LCV"
            ;;
    esac
done

# ---------- ROM pixel-imitation hooks: neutralize OR clean residue (v3.0.14) ----------
# Upstream PIFork neutralizes custom-ROM PropImitationHooks/PixelPropsUtils by
# writing persist.sys.* toggles — PERSISTENTLY (-p). Once written the toggles
# keep their own trigger condition true forever (self-locking loop), survive
# reflash/uninstall, and sit in the world-readable property area as a
# "persist.sys.spoof/pixelprops" tell that native forensics checkers flag via
# __system_property_get (2026-09-09: 5 hits on the K70). Semantics now:
#   - genuine hook ROM (build-prop markers, the LeafOS json, or ROM-authored
#     non-empty pihooks values) -> upstream neutralization, unchanged;
#   - anything else -> the whole family is residue: delete both the persistent
#     records and the in-memory copies. Re-run is a no-op once clean.
GMS_JSON="${AEGIS_GMS_JSON:-/data/system/gms_certified_props.json}"
HOOK_ROM=no
if resetprop | grep -qE "ro\.aospa\.version|net\.pixelos\.version|ro\.afterlife\.version" \
   || [ -f "$GMS_JSON" ] \
   || [ -n "$(resetprop persist.sys.pihooks.first_api_level 2>/dev/null)" ] \
   || [ -n "$(resetprop persist.sys.pihooks.security_patch 2>/dev/null)" ]; then
    HOOK_ROM=yes
fi

if [ "$HOOK_ROM" = yes ]; then
    # Work around custom ROM PropImitationHooks conflict when their persist props don't exist
    if resetprop | grep -qE "ro\.aospa\.version|net\.pixelos\.version|ro\.afterlife\.version" || [ -f "$GMS_JSON" ]; then
        resetprop_if_diff persist.sys.pihooks.first_api_level ""
        resetprop_if_diff persist.sys.pihooks.security_patch ""
    fi

    # Work around supported custom ROM PropImitationHooks/PixelPropsUtils (and hybrids) conflict when spoofProvider is disabled
    if resetprop | grep -qE "persist.sys.pihooks|persist.sys.entryhooks|persist.sys.pixelprops" || [ -f "$GMS_JSON" ]; then
        PROPS="
        persist.sys.pihooks.disable.gms_props true
        persist.sys.pihooks.disable.gms_key_attestation_block true
        persist.sys.entryhooks_enabled false
        persist.sys.pixelprops.gms false
        persist.sys.pixelprops.gapps false
        persist.sys.pixelprops.google false
        persist.sys.pixelprops.pi false
        persist.sys.pp.gms false
        persist.sys.pp.vending false
        "
        echo "$PROPS" | while read -r prop value; do
            if [ -n "$prop" ]; then
                resetprop -n -p "$prop" "$value"
                resetprop -c $(resetprop -Z "$prop") >/dev/null 2>&1 || true
            fi
        done
    fi

    # LeafOS "gmscompat: Dynamically spoof props for GMS"
    # https://review.leafos.org/c/LeafOS-Project/android_frameworks_base/+/4416
    # https://review.leafos.org/c/LeafOS-Project/android_frameworks_base/+/4417/5
    if [ -f "$GMS_JSON" ] && [ ! "$(resetprop persist.sys.spoof.gms)" = "false" ]; then
        resetprop persist.sys.spoof.gms false
        resetprop -c $(resetprop -Z persist.sys.spoof.gms) >/dev/null 2>&1 || true
    fi
else
    # Not a hook ROM: every persist.sys toggle ever written (by us, by the
    # standalone PIF this fusion migrated from, or by any PIFork-class module)
    # is pure detection residue. --delete clears the in-memory copy;
    # -p --delete clears the record in /data/property/persistent_properties
    # so it stops respawning on the next boot.
    RESIDUE_PROPS="
    persist.sys.pihooks.first_api_level
    persist.sys.pihooks.security_patch
    persist.sys.pihooks.disable.gms_props
    persist.sys.pihooks.disable.gms_key_attestation_block
    persist.sys.entryhooks_enabled
    persist.sys.pixelprops.gms
    persist.sys.pixelprops.gapps
    persist.sys.pixelprops.google
    persist.sys.pixelprops.pi
    persist.sys.pp.gms
    persist.sys.pp.vending
    persist.sys.spoof.gms
    "
    REMOVED=0
    for RP in $RESIDUE_PROPS; do
        if resetprop "$RP" >/dev/null 2>&1 || resetprop -p "$RP" >/dev/null 2>&1; then
            resetprop --delete "$RP" 2>/dev/null || true
            resetprop -p --delete "$RP" 2>/dev/null || true
            REMOVED=$((REMOVED+1))
        fi
    done
    if [ "$REMOVED" -gt 0 ]; then
        dbg "props: cleaned $REMOVED persist.sys spoof-tell residue props (no hook ROM detected)"
    fi
fi

resetprop -c >/dev/null 2>&1 || true

# ---------- GMS hygiene: recycle DroidGuard so stale verdicts never linger ----------
# DroidGuard (com.google.android.gms.unstable) produces the device judgement PI
# reads. Its session outlives our changes: after a keybox swap, a fingerprint
# re-sync, or a module flash, the cached session keeps answering with the OLD
# device picture until the process is recycled. Killing it is invisible to the
# user (the process respawns on demand) — this is what makes the module
# install-and-go instead of "flash, then manually kill GMS, then test".
# Three trigger paths keep every layer of the stack fresh:
#   1. once ~3 min after boot (after the daemon and the first keybox pass settle);
#   2. every keybox deployment (keybox-fetch.sh does this in client_recycle — the
#      daemon re-pushes and re-attests on its own, only the client needs a nudge);
#   3. every 12 h in the hourly loop below (AlwaysStrong semantics).

(
    sleep 180
    dg=$(pidof com.google.android.gms.unstable 2>/dev/null)
    if [ -n "$dg" ]; then
        kill $dg 2>/dev/null
        date +%s > /data/adb/teesim/.gms-recycle 2>/dev/null
    fi
) &

# ---------- TEE keybox: validate it BEFORE the daemon consumes it ----------
# A keybox the engine cannot build a TA from is worse than no keybox at all: the daemon
# pushes it happily, the interceptor answers `applied=0 failed=1`, drops EVERY profile,
# and from then on every request is logged `target=0` and forwarded to the real HAL — so
# the device reports one-green (BASIC only) while every other indicator looks healthy.
# That exact state shipped to the debug device (keybox.xml symlinked to TrickyStore's
# copy) and cost this project two days of misdirected analysis. Name it here instead.
#
# Non-destructive on purpose: unlike the installer (which moves a rejected keybox aside
# because the module provably cannot work with it), boot must not touch user data. We
# record the verdict and let the WebUI / engine-check.sh / the scheduled fetch act on it.
#
# ORDERING CONTRACT (2026-09-19): this block must stay ABOVE the boot-time engine
# verdict. The symlink materialisation below REWRITES keybox.xml, so a verdict taken
# before it is stale the instant it is written, and nothing re-takes it until the next
# deploy - the WebUI then sits on "待引擎确认（keybox 刚变更）" forever (field report after
# a v3.2.3 -> v1.0.1 update). verify-artifact.sh asserts the order.
KB=/data/adb/teesim/keybox.xml
if [ -L "$KB" ]; then
    # Never let the engine read through a symlink: the target can be swapped under us,
    # and TrickyStore's own tooling is known to write exactly this link.
    _kbtgt=$(readlink "$KB" 2>/dev/null)
    if [ -f "$_kbtgt" ]; then
        if cp -f "$_kbtgt" "$KB.real" 2>/dev/null && mv -f "$KB.real" "$KB" 2>/dev/null; then
            dbg "keybox: symlink -> $_kbtgt materialised into a real file"
        fi
    fi
fi
if [ -f "$KB" ] && [ -f "$MODPATH/keybox-check.sh" ]; then
    if sh "$MODPATH/keybox-check.sh" "$KB" >/dev/null 2>&1; then
        rm -f /data/adb/teesim/.keybox-bad 2>/dev/null
    else
        {
            echo "[$(date '+%F %T')] keybox INVALID — the engine cannot build a TA from it,"
            echo "  so every profile is dropped and PI stays at BASIC. Reasons:"
            sh "$MODPATH/keybox-check.sh" "$KB" 2>/dev/null | sed 's/^/  /'
        } > /data/adb/teesim/keybox-bad.log 2>/dev/null
        date +%s > /data/adb/teesim/.keybox-bad 2>/dev/null
        dbg "keybox: INVALID — see keybox-bad.log; profiles will be dropped until it is replaced"
    fi
fi

# ---------- boot-time engine verdict: record what the ENGINE says ----------
# Runs AFTER the keybox block above on purpose - the anchor it records must describe
# the keybox as the daemon is about to read it, not an earlier revision of the file.
# The structural check above runs BEFORE the daemon starts, so it cannot know the
# one thing that matters: whether the TA can actually build a profile from this
# keybox. The engine answers within a second or two of the first push, so wait
# briefly and record that answer in one place (/data/adb/teesim/.engine-verdict)
# for the WebUI, engine-check.sh and the scheduled fetch to read. A refusal is
# logged loudly, with the engine's own words — the engine names the real cause
# (teesim_km_init_ex), where the C++ side only says "(bad keybox?)".
(
    i=0
    while [ "$i" -lt 60 ]; do
        grep -q "control: ack" /data/adb/teesim/log/teesim.log 2>/dev/null && break
        i=$((i + 2))
        sleep 2
    done
    if [ -f "$MODPATH/engine-verdict.sh" ]; then
        if sh "$MODPATH/engine-verdict.sh" once >/dev/null 2>&1; then
            dbg "engine verdict: the engine ACCEPTED the deployed keybox"
        else
            _why=$(sh "$MODPATH/engine-verdict.sh" reason 2>/dev/null)
            dbg "engine verdict: the engine REFUSED the deployed keybox (${_why:-no reason given})"
            {
                echo "[$(date '+%F %T')] the ENGINE refused the deployed keybox — every profile is"
                echo "  dropped and PI stays at BASIC. Engine's reason: ${_why:-none given}"
            } >> /data/adb/teesim/keybox-bad.log 2>/dev/null
        fi
    fi
) &

# ---------- Fusion: scheduled keybox auto-refresh ----------

# Community keyboxes get revoked over time, so keep a fresh one coming. The loop ticks
# hourly and re-fetches whenever the elapsed hours reach the interval stored in
# /data/adb/teesim/keybox-refresh (default 24, write 0 to disable) — so changing the
# interval in the WebUI applies without a reboot. keybox-fetch.sh itself guards against
# overwriting a user-imported keybox. tick starts high so the first pass runs right
# after boot (the sleep below lets the network settle first).
(
    sleep 90
    gcount=0
    dbg "hourly loop started (interval file: /data/adb/teesim/keybox-refresh)"
    while true; do
        iv=$(cat /data/adb/teesim/keybox-refresh 2>/dev/null)
        case "$iv" in ''|*[!0-9]*) iv=24 ;; esac
        # Inheritance (2026-09-20): the anchor is .kb-last-fetch - the last
        # SUCCESSFUL fetch (updated/unchanged/adopted all stamp it). The schedule
        # therefore survives reboots and upgrades, a WebUI manual fetch re-arms it
        # from that moment, and the old in-memory counter's deep-sleep drift is
        # gone. No timestamp (fresh install) => due immediately, which keeps the
        # old "fetch once shortly after boot" safety net. Failures never stamp the
        # file, so an offline device retries on every tick until it succeeds.
        now=$(date +%s)
        lfts=$(stat -c %Y /data/adb/teesim/.kb-last-fetch 2>/dev/null || echo 0)
        case "$lfts" in ''|*[!0-9]*) lfts=0 ;; esac
        dbg "tick: interval=$iv last=$lfts now=$now gcount=$gcount"
        if [ "$iv" -gt 0 ] && [ "$((now - lfts))" -ge "$((iv * 3600))" ]; then
            dbg "tick: running keybox-fetch.sh (due: ${iv}h since the last success)"
            sh "$MODPATH/keybox-fetch.sh" >/dev/null 2>&1
        fi
        # Google revocation-status cache: kept fresh hourly even when the
        # auto-refresh interval is 0 (disabled) — the WebUI's local "已被
        # Google 吊销?" verdict reads this cache, and it must not go stale
        # just because full keybox fetching is off. --revcheck only refreshes
        # the cached list (1h TTL inside the script) and never touches
        # keybox.xml; right after a full fetch it is a no-op (cache fresh).
        sh "$MODPATH/keybox-fetch.sh" --revcheck >/dev/null 2>&1
        # Engine-verdict convergence (2026-09-19). The recorded verdict is anchored
        # on the keybox CONTENT (sha256), and anything that re-writes keybox.xml
        # afterwards - a deploy, a rollback restore, a symlink materialisation, a
        # re-copy during an update install - invalidates it. Until a new verdict is
        # taken, the WebUI shows "待引擎确认（keybox 刚变更）"; the deploy paths do
        # record one, but a write with no verdict after it would leave the state
        # stuck until the next reboot (field report: v3.2.3 -> v1.0.1 update, stuck
        # after a reboot). One cheap read per tick makes it self-healing: `show` is
        # silent while the verdict matches the keybox on disk, so only a stale or
        # absent verdict costs a re-take.
        if [ -f "$MODPATH/engine-verdict.sh" ]; then
            _vstate=$(sh "$MODPATH/engine-verdict.sh" show 2>/dev/null | sed -n 's/^state=//p')
            case "$_vstate" in
                ok|rejected|partial) ;;   # a verdict that describes the keybox on disk
                *) sh "$MODPATH/engine-verdict.sh" once >/dev/null 2>&1 ;;
            esac
        fi
        # Fingerprint half: generate on first boot / refresh the auto-generated
        # Pixel Canary fingerprint when it nears expiry (pif-fetch.sh no-ops
        # unless needed and never touches a user-provided fingerprint).
        sh "$MODPATH/pif-fetch.sh" >/dev/null 2>&1
        # PIF-class modules rotate their fingerprint periodically; re-mirror it
        # into the TEE profile hourly so the two halves never drift apart.
        sh "$MODPATH/pif-sync.sh" >/dev/null 2>&1
        # audit L10 closed (2026-09-19): a rotation also moves the attested
        # patch level, so realign the global patch-date props in the SAME boot
        # rather than waiting for the next reboot (the pre-fix behaviour).
        # resetprop_if_diff writes only on an actual change, so a no-op tick
        # costs two greps.
        align_patch_level
        # Recycle DroidGuard every 12 h so a long-lived session never keeps
        # attesting with a device picture we have already replaced.
        gcount=$((gcount + 1))
        if [ "$gcount" -ge 12 ]; then
            gcount=0
            dg=$(pidof com.google.android.gms.unstable 2>/dev/null)
            if [ -n "$dg" ]; then
                dbg "12h DroidGuard recycle (pid $dg)"
                kill $dg 2>/dev/null
                date +%s > /data/adb/teesim/.gms-recycle 2>/dev/null
            else
                dbg "12h DroidGuard recycle: not running"
            fi
        fi
        sleep 3600
    done
) &

# ---------- Scope janitor: apps-sync.sh every 5 minutes ----------
# Retired its old "auto-add" job: the WebUI toggle now drives TEES' native
# autoIncludeNewApps field directly. apps-sync.sh keeps the one-time legacy
# flag migration plus the cleanup pass (invalid entries / uninstalled apps),
# which is safe to run unconditionally — it validates every pm read and
# no-ops unless there is something to clean.
(
    sleep 150
    while true; do
        sh "$MODPATH/apps-sync.sh" >/dev/null 2>&1
        sleep 300
    done
) &

# ---------- TEESimulator: launch the control daemon ----------

# admin.token is the WebUI's key-management credential; keep it root-only. The whole data dir holds
# the token and the admin socket, so keep it 0700 too — the socket is then unreachable to other apps.
chmod 0700 /data/adb/teesim 2>/dev/null
chmod 0600 /data/adb/teesim/admin.token 2>/dev/null

# Stage the WebUI's admin-socket client at a fixed, root-only path, so the WebUI can invoke it without
# knowing the module's runtime path or the device ABI. Only the device's own ABI dir survives install,
# so the glob matches one file; refreshed every boot so a module update always stages the current one.
for f in "$MODPATH"/*/teesim-uds; do
    if [ -f "$f" ]; then
        cp "$f" /data/adb/teesim/teesim-uds && chmod 0700 /data/adb/teesim/teesim-uds
        break
    fi
done

# Sync the PIF fingerprint layer's identity into the TEE profile BEFORE the
# daemon reads config.json: a DEVICE/STRONG verdict needs the attestation
# identity and DroidGuard's spoofed fingerprint to agree (see pif-sync.sh).
# pif-fetch runs FIRST: with a fingerprint present it no-ops in milliseconds,
# and after a module update/reflash (which resets the module dir) it restores
# the working copy from the durable master in /data/adb/teesim/pif-master —
# without it, pif-sync would see "no fingerprint source" and roll the TEE
# identity back to the real device right at boot.
sh "$MODPATH/pif-fetch.sh" >/dev/null 2>&1
sh "$MODPATH/pif-sync.sh" >/dev/null 2>&1

# audit L10 closed (2026-09-19): pif-sync may have just rewritten the profile's
# patch level (rotation, master restore, or a PIF-class module appearing), and
# the post-fs-data pass ran before that. Realign here so the props match the
# profile the daemon is about to read.
align_patch_level

# The Kotlin control daemon does the real work — it harvests the device's attestation parameters,
# resolves config.json into per-profile settings (including the per-app scope the WebUI's
# app picker edits), injects the interceptor into keystore/keystore2, and pushes the resolved
# config over the control socket, re-injecting and re-pushing as things change. This loop only
# launches the daemon and respawns it if it ever exits.
#
# v3.1.2 (test-build logging): the daemon's stdout/stderr is appended to a durable file. SystemLogger
# goes to logcat, which rotates within minutes under load — and a crash-looping daemon was invisible
# because of it (the very failure mode this project spent a day hunting: "the daemon never pushed a
# config" while every other indicator looked healthy). A stack trace on stderr is now preserved.
# Trimmed to the newest 200 KB so it can never grow without bound.
: > "/data/adb/teesim/daemon.log" 2>/dev/null || true
while true; do
    "$MODPATH/daemon" "$MODPATH" >> "/data/adb/teesim/daemon.log" 2>&1
    echo "[$(date '+%F %T')] daemon exited rc=$? — respawning in 2s" >> "/data/adb/teesim/daemon.log" 2>/dev/null
    if [ "$(wc -c < "/data/adb/teesim/daemon.log" 2>/dev/null || echo 0)" -gt 204800 ]; then
        tail -c 102400 "/data/adb/teesim/daemon.log" > "/data/adb/teesim/daemon.log.tmp" 2>/dev/null \
            && mv -f "/data/adb/teesim/daemon.log.tmp" "/data/adb/teesim/daemon.log" 2>/dev/null
    fi
    sleep 2
done &
