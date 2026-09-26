# NOTICE

Aegis Fusion (formerly Integrity Fusion) is a combined distribution of upstream projects,
patched and repackaged into a single root-module zip. It is licensed under the GNU GPL v3
(see LICENSE); each component remains under its own upstream license and copyright.

## Components

### TEESimulator
- Upstream: https://github.com/JingMatrix/TEESimulator (built from the commit pinned in
  `versions.env`, with our patches applied at CI build time)
- License: GNU GPL v3
- Local modifications (see `patches/teesim/`):
  - `0001-fusion-adjustments.patch`: built-in canary self-updater disabled (it would flash
    a standalone `teesim` module alongside the fusion module and double-hook the keystore);
    control-daemon dex renamed `classes.dex` → `teesim-service.dex` (avoids collisions) and
    the module-dir fallback path updated; WebUI served from `webroot/` instead of the
    upstream manager layout.
  - `0002-zh-webui.patch`: Simplified-Chinese localization of the upstream WebUI.
  - `0003-icon-typeface-warmup.patch`: bare `app_process` daemons never inherit zygote's
    initialized default typeface; warm the system font map once before the first icon
    render, or a text-drawing icon drawable aborts the whole daemon.

### Box layer (BL / system-property hiding, keybox retrieval) — scripts
- Techniques and keybox channels adapted from https://github.com/MeowDump/Integrity-Box
  and https://github.com/MeowDump/MeowDump
- License: GNU GPL v3
- Local implementation: `module/service.sh` (resetprop-based fingerprint/BL-state hiding,
  LineageOS trace cleanup) and `module/keybox-fetch.sh` (fetches a keybox from the
  MeowDump channels at runtime and feeds it to the TEESimulator engine).

### AlwaysStrong — adapted techniques
- Source: https://github.com/evoker0/AlwaysStrong (GNU GPL v3)
- Adapted ideas/snippets (all reimplemented or reworked for this module's layout):
  - LineageOS trace cleanup in `module/service.sh` (lineage_ product-name prefix,
    org.lineageos.aperture in camera package lists);
  - DroidGuard (`com.google.android.gms.unstable`) recycling after keybox deployment
    and on a periodic schedule in `module/keybox-fetch.sh` / `module/service.sh`;
  - The two-halves architecture (hardware attestation chain + PIF fingerprint layer)
    and mirroring the PIF config into the TEE profile — `module/pif-sync.sh`.

### Play Integrity Fork — bundled fingerprint layer (v3.0+)
- Upstream: https://github.com/osm0sis/PlayIntegrityFork (by osm0sis & chiteroman), pinned
  official release zip (version + SHA256 in `versions.env`, verified by
  `scripts/fetch-upstreams.sh`)
- License: GNU GPL v3 (same as this fusion)
- Shipped files: `zygisk/`, `classes.dex`, `common_func.sh`, `common_setup.sh`,
  `autopif4.sh`, `killpi.sh`, `migrate.sh`, `action.sh`, `example.pif.prop`,
  `app_replace_list.txt`. Of these, **`autopif4.sh`, `migrate.sh` and
  `action.sh` carry documented modifications** applied on the staging copy at
  assemble time (`scripts/harden-pif.sh`: probe-selected TLS instead of the 8
  hardcoded `--no-check-certificate` flags, the S1 seed-compat fallbacks, the
  R7-2 escaping of values interpolated into sed/JSON, and the PIF v18 → fusion
  `migrate.sh` de-eval; `scripts/assemble.sh`: the action button's `--strong`
  switch and the removal of the boot-time `uninstall.sh` branch). The other
  listed files are shipped verbatim. upstream `service.sh` is sourced by our `service.sh`
  as `pif-service.sh`, upstream `post-fs-data.sh` is adopted as-is. The fusion overlay's
  own helpers were renamed `fusion_func.sh` to yield the root-level `common_func.sh` name
  the payload's scripts source unmodified. Their `module.prop` / `customize.sh` / `META-INF`
  are replaced by the fusion overlay.
- Local integration (`module/service.sh`, `module/customize.sh`, `module/pif-fetch.sh`,
  `module/pif-sync.sh`, `scripts/assemble.sh`): automatic fingerprint generation
  (autopif4 `--strong` preset, 14-day rotation, user-provided fingerprints never touched),
  identity mirroring into the TEE profile, Zygisk environment detection, standalone-module
  migration with adoption of an existing `custom.pif.prop/.json`.

### Historical credit
- Early versions (≤ v1.x) bundled a patched copy of
  https://github.com/KOWX712/PlayIntegrityFix (`inject_s` branch, GNU GPL v3). As of
  v2.0.0 the PIF component is fully removed and replaced by the script-based Box layer
  above; thanks remain due for the ideas borrowed along the way.

Both upstream projects in turn build on additional third-party code (AOSP, BoringSSL,
LSPlt, Dobby, the AOSP reference KeyMint TA, etc.) — see their own NOTICE/README files in
the upstream repositories, which are preserved in the build.
