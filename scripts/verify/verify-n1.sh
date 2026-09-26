#!/usr/bin/env bash
# verify-n1.sh — reproduction of the audit N1 fix check (v3.2.3).
# Tracked in the repo (audit N12: it used to live under gitignored build/,
# which made it unreproducible for readers outside the author's machine).
#
# 1. extracts mask_ids() from module/engine-check.sh
# 2. probes the JSON form ("key":"value") — the shape the original two rules
#    (key='v', key=v) let through verbatim
# 3. probes the log-line form (key='v') — must not have regressed
# 4. simulates the /status field filter — only version/hook may come out
#
# Run: bash scripts/verify/verify-n1.sh
set -eu
cd "$(dirname "$0")/../.."

eval "$(sed -n '/^mask_ids() {/,/^}/p' module/engine-check.sh)"

echo '-- JSON form (audit N1) --'
printf '%s\n' '{"harvest":{"brand":"generic","serial":"0123456789ABCDEF","imei":"350000000000001","meid":"A0000000DEADBEEF"}}' | mask_ids

echo '-- log-line form (audit H1) --'
printf '%s\n' "Harvest telephony IDs: imei='350000000000001' secondImei='' meid='A0000000DEADBEEF' serial='0123456789ABCDEF'" | mask_ids

echo '-- /status field filter simulation (engine-check.sh section 6) --'
OUT='{"version":"1.2.3","uptime":42,"hook":"libteesim.so","harvest":{"imei":"350000000000001"}}'
printf '%s\n' "$OUT" | tr '{,}' '\n\n' | grep -E '"(version|hook)"' | head -4

echo '-- residual check: none of the raw values may appear in any output above --'
