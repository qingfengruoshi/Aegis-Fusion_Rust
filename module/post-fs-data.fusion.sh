#!/system/bin/sh
# Aegis Fusion — post-fs-data stage (Round 12).
#
# One job: the patch-level alignment runs HERE, at post-fs-data, before any
# app can read the props. This mirrors AlwaysStrong's `sync_patch.sh boot`
# which its docs tie directly to the DEVICE verdict ("missing or stale ->
# the verdict drops"). This early pass runs BEFORE any app can read the props;
# service.sh adds two more call sites (audit L10 closed 2026-09-19): right
# after the boot-stage pif-sync, and after the hourly pif-sync in the tick
# loop — so a profile rotation realigns in the same boot (previously it waited
# for the next reboot).
MODPATH="${0%/*}"
. "$MODPATH"/fusion_func.sh

align_patch_level

exit 0
