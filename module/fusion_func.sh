#!/system/bin/sh
# Aegis Fusion shared shell helpers — self-contained. Adapted from the
# equivalents in PlayIntegrityFix / Integrity-Box, trimmed to what the fusion
# uses. (v3.x note: the ROOT-level common_func.sh name belongs to the bundled
# Play Integrity Fork payload — its scripts source it unmodified — so the
# fusion's own helpers live under this fusion_func.sh name. The bundled
# common_func.sh defines functions with the same names as supersets; it is
# sourced after this file by pif-service.sh and safely takes precedence.)

# KernelSU and APatch ship their own resetprop in per-solution bin dirs; make sure it is
# on PATH before any helper runs (harmless no-op elsewhere).
for _bin in /data/adb/ksu/bin /data/adb/ap/bin; do
    [ -d "$_bin" ] && case ":$PATH:" in
        *":$_bin:"*) ;;
        *) PATH="$_bin:$PATH" ;;
    esac
done

# resetprop_if_diff <prop> <expected>
# Set (non-persistent) only when the current value differs, so boot doesn't rewrite props
# and wake property_service listeners a hundred times for nothing.
#
# v3.2.3 (audit N16 — intent made explicit): a MISSING prop is deliberately
# SKIPPED, not created. This mirrors the upstream common_func.sh this helper
# was adapted from byte for byte, and it is the right call for what the
# callers do (service.sh's verified-boot/BL state props, align_patch_level's
# patch-date props): those props exist on every device they are meaningful
# on, and fabricating one that the OEM never set would itself be an anomaly
# signal (a verifiedbootstate that the bootloader never wrote). If a prop is
# missing, the honest state is "nothing to align", not "invent a value".
resetprop_if_diff() {
    local NAME="$1"
    local EXPECTED="$2"
    local CURRENT
    CURRENT="$(resetprop "$NAME" 2>/dev/null)"
    if [ -z "$CURRENT" ] || [ "$CURRENT" = "$EXPECTED" ]; then
        return 0
    fi
    resetprop -n "$NAME" "$EXPECTED" 2>/dev/null
}

# resetprop_if_match <prop> <substring> <new_value>
# Rewrite only when the current value contains <substring> (e.g. bootmode=recovery -> unknown).
resetprop_if_match() {
    local NAME="$1"
    local MATCH="$2"
    local VALUE="$3"
    local CURRENT
    CURRENT="$(resetprop "$NAME" 2>/dev/null)"
    case "$CURRENT" in
        *"$MATCH"*) resetprop -n "$NAME" "$VALUE" 2>/dev/null ;;
    esac
}

# delprop_if_exist <prop>
delprop_if_exist() {
    [ -n "$(resetprop "$1" 2>/dev/null)" ] && resetprop --delete "$1" 2>/dev/null
    return 0
}

# align_patch_level — keep the global patch-date props on the TEE profile's
# ATTESTED value (R4 semantics, formalized in Round 12; AlwaysStrong v1.0.4
# ships the same fix: "keep the system security-patch date equal to the
# attested one"). Reads patchLevel.system from the resolved TEES config —
# "today" resolves to the boot date — legacy plain-string patchLevel forms are
# accepted too. Called from three places (audit L10 closed 2026-09-19):
# post-fs-data.fusion.sh (early, AS sync_patch.sh-boot parity), and service.sh
# twice — once right after the boot-stage pif-sync, and once after the hourly
# pif-sync inside the tick loop. A profile rotation therefore realigns these
# props in the same boot instead of waiting for the next reboot. Cheap: the
# only writes go through resetprop_if_diff.
align_patch_level() {
    _TEE=/data/adb/teesim
    # TEES schema: patchLevel is an object { system, vendor, boot }; also
    # accept a legacy plain-string date so a hand-edited config can't be
    # silently skipped (though pif-sync rewrites that form to the object).
    _pl=$(sed -n 's/.*"patchLevel"[[:space:]]*:[[:space:]]*{[^}]*"system"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
          "$_TEE/config.json" 2>/dev/null | head -n 1)
    [ -z "$_pl" ] && _pl=$(sed -n 's/.*"patchLevel"[[:space:]]*:[[:space:]]*"\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)".*/\1/p' \
          "$_TEE/config.json" 2>/dev/null | head -n 1)
    case "$_pl" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        today) _pl=$(date +%F) ;;
        *) return 0 ;;
    esac
    resetprop_if_diff ro.build.version.security_patch "$_pl"
    resetprop_if_diff ro.vendor.build.security_patch "$_pl"
    # This runs from post-fs-data, before the RTC/time daemon has necessarily set
    # the wall clock. A bare `date` there stamped the line "1970-02-14 ..." in a
    # field debug.log, which reads as if the entry were out of order. Name the
    # condition instead of printing a timestamp that is not one.
    _stamp=$(date '+%F %T' 2>/dev/null)
    case "$_stamp" in 19*|20[01][0-9]*) _stamp='boot-early (RTC 未就绪)' ;; esac
    [ -f "$_TEE/.debug" ] && echo "[$_stamp] [patch] system props aligned to attested $_pl" >> "$_TEE/debug.log" 2>/dev/null
    return 0
}
