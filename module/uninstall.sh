#!/system/bin/sh
# Aegis Fusion uninstall cleanup.
#
# v3.1.9 (author decision 2026-09-11): uninstall = FULL removal. /data/adb/teesim
# is wiped entirely — config, keybox, backups, logs, markers, the staged helper
# and the admin socket. Nothing of the module survives on the device.
#
# Upstream TEESimulator users: copy your keybox.xml out BEFORE uninstalling —
# it is deleted with everything else.
#
# The module's prop spoofing is non-persistent and dies with the boot service;
# the TEE interceptor lives in the keystore process memory and is gone at the
# reboot that follows the uninstall.

# Stop the control daemon first so it cannot re-create files mid-deletion.
kill $(pidof teesim 2>/dev/null) 2>/dev/null

# The whole data dir (0700 root-only): config.json, keybox.xml, keybox-backups,
# pif-master, logs, markers, teesim-uds, the admin socket.
rm -rf /data/adb/teesim

# Injection artifacts PIF-family modules historically dropped into GMS/Vending.
for pkg in com.google.android.gms com.android.vending; do
    for dir in "/data/user_de/0/$pkg" "/data/data/$pkg"; do
        [ -d "$dir" ] || continue
        for artifact in libinject.so classes.dex pif.prop; do
            [ -f "$dir/$artifact" ] && rm -f "$dir/$artifact"
        done
    done
done

# ---------- Persistent spoof-tell props (audit R8-5, 2026-09-16) ----------
# On hook ROMs the payload's common_setup.sh persists persist.sys.pihooks.* /
# pixelprops.* / pp.* / spoof.gms toggles via resetprop -p — they survive
# reboots and outlive the module. Upstream appends restore lines to ITS OWN
# uninstall.sh, but the fusion ships this script instead, so without this
# block those props survived the uninstall forever (the very residue
# service.sh:211-235 treats as detection tells at every boot). The module is
# going away, so nothing needs them anymore: delete unconditionally, same
# list as service.sh's RESIDUE_PROPS.
if command -v resetprop >/dev/null 2>&1; then
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
    for RP in $RESIDUE_PROPS; do
        # --delete clears the in-memory copy; -p --delete clears the record in
        # /data/property/persistent_properties so it stops respawning.
        if resetprop "$RP" >/dev/null 2>&1 || resetprop -p "$RP" >/dev/null 2>&1; then
            resetprop --delete "$RP" 2>/dev/null || true
            resetprop -p --delete "$RP" 2>/dev/null || true
        fi
    done
fi

exit 0
