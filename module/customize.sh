# Aegis Fusion installer — TEESimulator + fingerprint spoofing (bundled
# Play Integrity Fork) + shell-level environment/BL hiding in one module.
# Runs under Magisk / KernelSU / APatch.

# ---------- i18n: follow the system locale (English fallback) ----------
# persist.sys.locale is the live user language; ro.product.locale is the
# fallback for fresh boot / restricted contexts. Anything that is not zh*
# (zh-CN, zh-TW, zh-HK ...) falls back to English. Recovery cannot be
# relied on for getprop, but recovery installs are aborted right below anyway.
_LOCALE=$(getprop persist.sys.locale 2>/dev/null)
[ -z "$_LOCALE" ] && _LOCALE=$(getprop ro.product.locale 2>/dev/null)
case "$_LOCALE" in
    zh*) IS_ZH=1 ;;
    *)   IS_ZH="" ;;
esac
# Data dir (0700, root-only). This file previously NEVER defined it, so the few
# "$TEE_DIR/..." references silently targeted "/" instead (mkdir -p "" is a
# no-op and every write is 2>/dev/null) - which broke the R7-1 durable-master
# guard and the provenance marker. Same convention as the other scripts.
# (Review finding 2026-09-19, caught by a real v3.2.3 -> v1.0.1 update install.)
TEE_DIR="${AEGIS_TEE_DIR:-/data/adb/teesim}"

# msg <english> <chinese> — print via ui_print in the system language
msg() {
    if [ -n "$IS_ZH" ]; then
        ui_print "$2"
    else
        ui_print "$1"
    fi
}

# ---------- Install-time checks ----------

# Don't flash in recovery!
if ! $BOOTMODE; then
    ui_print "*********************************************************"
    msg "! Install from recovery is NOT supported" "! 不支持在 Recovery 中刷入"
    msg "! Please install from Magisk / KernelSU / APatch app" "! 请通过 Magisk / KernelSU / APatch 管理器安装"
    abort    "*********************************************************"
fi

# Error on < Android 8
if [ "$API" -lt 26 ]; then
    msg "! You can't use this module on Android < 8.0" "! 无法在 Android 8.0 以下的系统上使用本模块"
    exit 1
fi

# The TEE interceptor is a 64-bit library injected into the keystore daemon, which is 64-bit
# on every supported device; refuse 32-bit-only devices rather than fail silently.
# (No Zygisk requirement — v2.x ships no Zygisk payload at all.)
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x64" ]; then
    msg "! Aegis Fusion requires a 64-bit device (TEE component)" "! Aegis Fusion 需要 64 位设备（TEE 组件）"
    exit 1
fi

# ---------- Fingerprint half: Zygisk environment check ----------
# The bundled fingerprint payload is a Zygisk module: it must be injected into
# the GMS process, which only happens when a Zygisk implementation is active.
# The TEE half works without Zygisk, so this is a warning, not an abort — but
# without it the verdict ceiling is BASIC.
ZYGISK_OK=""
for zm in zygisknext zygisksu rezygisk neozygisk; do
    if [ -d "/data/adb/modules/$zm" ] && [ ! -f "/data/adb/modules/$zm/remove" ]; then
        ZYGISK_OK=1
        break
    fi
done
if [ -z "$ZYGISK_OK" ] && command -v magisk >/dev/null 2>&1; then
    if magisk --sqlite "SELECT value FROM settings WHERE key='zygisk'" 2>/dev/null | grep -q 'zygisk|1$'; then
        ZYGISK_OK=1
    fi
fi
if [ -n "$ZYGISK_OK" ]; then
    msg "- Zygisk environment detected (fingerprint layer active)" "- 检测到 Zygisk 环境（指纹层已激活）"
else
    msg "! Zygisk not detected — the built-in fingerprint layer needs it" "! 未检测到 Zygisk —— 内置指纹层依赖它"
    msg "  (Magisk: enable Zygisk, or install Zygisk Next on KSU/APatch)" "  （Magisk：打开 Zygisk 开关；KSU/APatch：安装 Zygisk Next）"
    msg "  Without it the TEE half still works but PI stays at BASIC" "  缺少它时 TEE 部分仍可工作，但 Play Integrity 最高只有 BASIC"
fi

# ---------- Disable modules that would double-hook ----------

# Standalone upstream modules: the TEE component is bundled here, so a leftover standalone
# install would hook the keystore a second time. Integrity-Box ships under the
# playintegrityfix id since v28 and is disabled for the same reason; the
# standalone 'Integrity-Box' id (older/manual installs) hooks EVERY app process
# and breaks app-level device identity (WeChat forced-logout class reports),
# so it is disabled on sight too.
for old in playintegrityfix teesim Integrity-Box; do
    for d in /data/adb/modules/$old /data/adb/modules_update/$old; do
        if [ -d "$d" ] && [ ! -f "$d/disable" ] && [ ! -f "$d/remove" ]; then
            msg "- Disabling standalone '$old' (bundled inside Aegis Fusion)" "- 正在禁用独立安装的 '$old' 模块（功能已内置到 Aegis Fusion）"
            msg "  Uninstall it from your root manager to keep things tidy" "  建议在 root 管理器中将其卸载，保持环境整洁"
            touch "$d/disable"
        fi
    done
done

# The fingerprint layer is bundled too: a standalone PlayIntegrityFix/Fork install
# would hook the GMS process a second time. ADOPT its fingerprint first so a
# private custom.pif.prop/.json the user curated survives the migration — the
# bundled payload reads the same filenames from this module's directory.
if [ ! -f "$MODPATH/custom.pif.prop" ] && [ ! -f "$MODPATH/custom.pif.json" ] \
   && [ ! -f "$MODPATH/pif.json" ]; then
    for f in custom.pif.prop custom.pif.json pif.json; do
        if [ -s "/data/adb/modules/playintegrityfix/$f" ]; then
            msg "- Adopting the fingerprint from standalone PIF ($f)" "- 正在从独立 PIF 模块继承指纹（$f）"
            cp -af "/data/adb/modules/playintegrityfix/$f" "$MODPATH/$f"
            break
        fi
    done
fi

# TrickyStore intercepts the same keystore path as the TEE component; running both would
# double-hook it.
for ts in /data/adb/modules/tricky_store /data/adb/modules_update/tricky_store; do
    if [ -d "$ts" ] && [ ! -f "$ts/disable" ]; then
        msg "- Disabling TrickyStore (it hooks the same keystore path)" "- 正在禁用 TrickyStore（它与本模块挂钩同一个 keystore 路径）"
        touch "$ts/disable"
    fi
done

# safetynet-fix is obsolete and hooks the same GMS surface our environment layer cleans up.
SNFix="/data/adb/modules/safetynet-fix"
if [ -d "$SNFix" ]; then
    msg "! safetynet-fix module is obsolete and incompatible, it will be removed on next reboot" "! safetynet-fix 模块已过时且不兼容，重启后将被移除"
    touch "$SNFix"/remove
fi

# Prop-spoofing helpers would fight our environment/BL hiding layer.
if [ -d "/data/adb/modules/MagiskHidePropsConf" ]; then
    msg "! WARNING, MagiskHidePropsConf may conflict with the environment hiding layer." "! 警告：MagiskHidePropsConf 可能与环境隐藏层冲突"
fi

# ---------- Migration ----------

# Preserve previous Aegis Fusion customization (fusion id).
if [ -f "/data/adb/modules/aegisfusion_rs/system.prop" ]; then
    cp -af /data/adb/modules/aegisfusion_rs/system.prop "$MODPATH/system.prop"
fi

# v3.2.3 (audit N2/N7): logs written by versions <= v3.2.2 contain the upstream
# harvest line with PLAINTEXT IMEI/IMEI2/MEID/serial. Patch 0006 masks new
# lines at the source, but rotated shards on an upgraded device still hold the
# old plaintext. Mask them in place — never delete: the diagnosis value is
# kept, the identifiers are not. Shards were the export fodder of the upstream
# console (removed from the bundle this version), and the durable log feeds
# engine-check.sh.
# v3.2.3 (audit r5): this is the third of the four mask copies (the others are
# engine-check.sh, engine-verdict.sh and webroot/js/logs.js); the rules are kept
# identical on purpose and scripts/test-mask-ids.sh asserts all four still
# agree. The widening covers a hyphenated or short value, a space-separated
# value and the `serialno` key — old shards are exactly where a stale spelling
# is most likely to be found.
for _tlog in /data/adb/teesim/log/teesim.log /data/adb/teesim/log/teesim.*.log; do
    [ -f "$_tlog" ] || continue
    sed -i -E \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)='[^']*'/\1='<redacted>'/g" \
        -e "s/\"(secondImei|imei2|imei|meid|serialno|serial)\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"\1\":\"<redacted>\"/g" \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)[[:space:]]*=[[:space:]]*[^[:space:]'\",;)}]+/\1=<redacted>/g" \
        -e "s/(secondImei|imei2|imei|meid|serialno|serial)[[:space:]]+[^[:space:]'\",;)}]{4,}/\1 <redacted>/g" \
        "$_tlog" 2>/dev/null
done

# ---------- TEE component: seed the configuration ----------

# Seed the configuration on first install without clobbering existing files.
mkdir -p /data/adb/teesim
# The auto-fetch interval is read ONCE, here, before anything else touches the
# keybox: the "existing installation detected" line below and the end-of-install
# summary must both quote the same number the runtime loop (service.sh) will
# actually use. There is no second place that interprets this file in the
# installer - scripts/test-interval-rule.sh extracts these very lines and pins
# their behaviour against the executor's identical rule in service.sh.
_kbiv="$(cat /data/adb/teesim/keybox-refresh 2>/dev/null | tr -d ' \t\r\n')"
case "$_kbiv" in ''|*[!0-9]*) _kbiv="24" ;; esac
# Did a keybox exist BEFORE this install started? Only then may the installer
# claim "your settings are kept" - a first install that adopts TrickyStore's
# keybox has nothing of the user's to keep, and saying so would be a lie.
_kbpre=no
{ [ -f /data/adb/teesim/keybox.xml ] || [ -L /data/adb/teesim/keybox.xml ]; } && _kbpre=yes
# Adopt a keybox the user already set up for TrickyStore when we have none of our own.
# The hash marker marks it as auto-managed, so the scheduled community-keybox refresh
# takes it over (and replaces it once Google revokes it) instead of skipping forever.
#
# A SYMLINKED keybox.xml must be materialised. `/data/adb/teesim/keybox.xml ->
# /data/adb/tricky_store/keybox.xml` is a real, field-observed state (TrickyStore's own
# tooling writes it), and it defeats every existence test below: `[ -f link ]` follows
# the link, so once the target exists the adoption is skipped forever and a reflash can
# never repair it. Worse, the symlink silently re-points the engine at whatever
# TrickyStore has at that moment — including a keybox the engine cannot parse.
if [ -L "/data/adb/teesim/keybox.xml" ]; then
    _tgt=$(readlink "/data/adb/teesim/keybox.xml" 2>/dev/null)
    if [ -f "$_tgt" ]; then
        msg "- keybox.xml was a symlink to $_tgt — materialising a real copy" "- keybox.xml 原是指向 $_tgt 的符号链接 —— 正在实体化为真实副本"
        cp -f "$_tgt" /data/adb/teesim/keybox.xml.real 2>/dev/null \
            && mv -f /data/adb/teesim/keybox.xml.real /data/adb/teesim/keybox.xml
        h=$(sha256sum /data/adb/teesim/keybox.xml 2>/dev/null | cut -d' ' -f1)
        [ -n "$h" ] && echo "$h" > /data/adb/teesim/.auto-keybox
    else
        msg "! keybox.xml points at $_tgt which does not exist — removing the dead link" "! keybox.xml 指向不存在的 $_tgt —— 正在移除失效链接"
        rm -f /data/adb/teesim/keybox.xml
    fi
fi
if [ ! -f "/data/adb/teesim/keybox.xml" ] && [ -f "/data/adb/tricky_store/keybox.xml" ]; then
    msg "- Adopting the keybox from TrickyStore" "- 正在从 TrickyStore 继承已有 keybox"
    cp /data/adb/tricky_store/keybox.xml /data/adb/teesim/keybox.xml
    h=$(sha256sum /data/adb/teesim/keybox.xml 2>/dev/null | cut -d' ' -f1)
    if [ -n "$h" ]; then
        echo "$h" > /data/adb/teesim/.auto-keybox
        chmod 0600 /data/adb/teesim/.auto-keybox
    fi
fi
# Validate whatever we ended up with. A keybox the engine cannot build a TA from is
# strictly worse than no keybox at all: the engine accepts the push, then drops every
# profile, and the device reports one-green with every indicator looking healthy. Fail
# loudly at install time instead, and drop the poison so the fetch loop can replace it.
if [ -f "/data/adb/teesim/keybox.xml" ] && [ -f "$MODPATH/keybox-check.sh" ]; then
    if ! sh "$MODPATH/keybox-check.sh" /data/adb/teesim/keybox.xml > /dev/null 2>&1; then
        msg "! The keybox at /data/adb/teesim/keybox.xml cannot be used by the TEE engine:" "! /data/adb/teesim/keybox.xml 处的 keybox 无法被 TEE 引擎使用："
        sh "$MODPATH/keybox-check.sh" /data/adb/teesim/keybox.xml 2>/dev/null \
            | while IFS= read -r _l; do ui_print "    $_l"; done
        msg "! Symptom if left in place: PI stays at BASIC (一绿) while nothing else looks wrong." "! 若保留该文件：表现为 Play Integrity 卡在 BASIC（一绿），其余一切看似正常。"
        msg "! Moving it aside; the scheduled fetch will install a working one after boot." "! 先将其移开；开机后的定时抓取会自动换上可用的 keybox。"
        mv -f /data/adb/teesim/keybox.xml "/data/adb/teesim/keybox.rejected.$(date +%s).xml" 2>/dev/null
        rm -f /data/adb/teesim/.auto-keybox
    else
        msg "- TEE keybox validated (engine-usable)" "- TEE keybox 验证通过（引擎可用）"
        # Say explicitly what an UPDATING user most wants to know: nothing they
        # configured was replaced. The number is the same $_kbiv the summary and
        # the runtime loop use - never a second value. Skipped for a first install
        # (nothing to keep; the adoption path printed its own line already).
        if [ "$_kbpre" = yes ]; then
            case "$_kbiv" in
                0) msg "- Existing installation detected: your keybox and WebUI settings are kept (auto-fetch is OFF)" "- 检测到已有安装：保留你的 keybox 与 WebUI 设置（自动获取已关闭），本次未覆盖" ;;
                *) msg "- Existing installation detected: your keybox and WebUI settings are kept (auto-fetch every ${_kbiv}h)" "- 检测到已有安装：保留你的 keybox 与 WebUI 设置（自动获取每 ${_kbiv} 小时），本次未覆盖" ;;
            esac
        fi
    fi
fi
if [ ! -f "/data/adb/teesim/config.json" ]; then
    cp "$MODPATH/config.default.json" /data/adb/teesim/config.json
fi

# ---------- TEE component: provision device attestation IDs ----------
# 上游 TA 在 App 请求带设备 ID 字段的证明密钥时,会用 profile 预置的
# brand/device/... 与请求比对,不一致(或为空)即拒绝(CANNOT_ATTEST_IDS)。
# 默认配置这些字段全空 → GMS 的证明请求失败 → PI 只剩 BASIC(RS 引擎因自动
# 采集设备 ID 而无此问题)。这里用本机真实属性回填,让证明链完整。
# IMEI 为尽力而为:厂商属性优先,再尝试 iphonesubinfo(版本相关),取不到留空。
msg "- Provisioning device attestation IDs into TEE config" "- 正在将设备证明 ID 写入 TEE 配置"
CFG=/data/adb/teesim/config.json
fill_id() { # <field> <value> — 只回填空字段(兼容有无空格的 JSON 格式),sed 特殊字符先转义
    [ -n "$2" ] || return 0
    local esc
    # 剥掉换行(换行会截断 sed 表达式/破坏 JSON),再三层转义(M6,2026-09-16):
    # 目标是 JSON 字符串——`"` 须落盘为 `\"`、`\` 须落盘为 `\\`;esc 还要过一层
    # sed replacement(会吃掉一层反斜杠),故每个反斜杠都预翻倍:`\`→4 个、
    # `"`→2 个+引号、`&`/`/` 加前置。顺序不可换,否则新增反斜杠被再次翻倍。
    esc=$(printf '%s' "$2" | tr -d '\n\r' \
        | sed -e 's/\\/\\\\\\\\/g' -e 's/"/\\\\"/g' -e 's/[&/]/\\&/g')
    sed -i "s/\"$1\":[[:space:]]*\"\"/\"$1\": \"$esc\"/" "$CFG" 2>/dev/null || true
}
fill_id brand "$(getprop ro.product.brand)"
fill_id device "$(getprop ro.product.device)"
# keystore2 的 ATTESTATION_ID_PRODUCT 读的是 ro.product.name（ro.product.product
# 在 Android 上不存在，getprop 返回空会让 product 字段留空）
fill_id product "$(getprop ro.product.name)"
fill_id manufacturer "$(getprop ro.product.manufacturer)"
fill_id model "$(getprop ro.product.model)"
fill_id serial "$(getprop ro.serialno)"
IMEI=""
for p in ro.ril.oem.imei persist.vendor.radio.imei vendor.ril.imei ro.vendor.ril.imei; do
    v=$(getprop "$p" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) IMEI="$v"; break ;; esac
done
if [ -z "$IMEI" ]; then
    sc=$(service call iphonesubinfo 1 s16 com.android.shell 2>/dev/null)
    IMEI=$(printf '%s' "$sc" | grep -oE "'[0-9]+'" | tr -d "'\n " | head -c 15)
    [ ${#IMEI} -ge 14 ] || IMEI=""
fi
fill_id imei "$IMEI"
IMEI2=""
for p in ro.ril.oem.imei2 persist.vendor.radio.imei2 vendor.ril.imei2; do
    v=$(getprop "$p" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) ;; *) IMEI2="$v"; break ;; esac
done
fill_id imei2 "$IMEI2"

# ---------- Exec perms and stale artifact cleanup ----------

chmod +x "$MODPATH/keybox-fetch.sh" "$MODPATH/pif-fetch.sh" "$MODPATH/autopif4.sh" \
    "$MODPATH/killpi.sh" "$MODPATH/migrate.sh" "$MODPATH/action.sh" \
    "$MODPATH/engine-check.sh" "$MODPATH/keybox-check.sh" "$MODPATH/keybox-swap.sh" \
    "$MODPATH/engine-verdict.sh" 2>/dev/null

# ---------- Fingerprint: one bounded install-time fetch (R7-1, 2026-09-19) ----------
# Author-locked design (baseline: docs/design/pif-source-preview-20260916.html):
# try ONCE for a device-specific random identity with a ~20 s budget, BEFORE the
# first boot, so the device starts with its own fingerprint and the first boot
# needs no network at all. Offline / failure / timeout falls back to the
# package's baked seed via a zero-interruption `|| true`; pif-fetch then swaps
# that shared seed at the first tick whose network works (see the seed block in
# pif-fetch.sh). A user-placed custom.pif.prop outranks everything and skips
# this block entirely. 60-90 s installer waits were explicitly rejected by the
# author; 20 s is the agreed ceiling.
# Guard 1 (review finding, 2026-09-19): a module UPDATE/reflash wipes the module
# dir but the durable master ($TEE_DIR/pif-master) survives, and pif-fetch's
# restore pass copies that identity back at boot — including a user-curated
# one. Fetching here would put a fresh random file in the module dir first, the
# restore pass would then be skipped (it only runs when the module dir has no
# fingerprint), and the surviving identity would be SHADOWED. So: only fetch
# when neither the module dir NOR the master holds an identity.
if [ ! -f "$MODPATH/custom.pif.prop" ] && [ ! -f "$MODPATH/custom.pif.json" ] \
   && [ ! -s "$TEE_DIR/pif-master/custom.pif.prop" ] && [ ! -s "$TEE_DIR/pif-master/custom.pif.json" ] \
   && [ -f "$MODPATH/autopif4.sh" ]; then
    msg "- Fetching a device-specific fingerprint (~20 s; falls back to the built-in seed)" "- 正在获取本机专属指纹（约 20 秒，失败自动回退内置指纹）…"
    _fp_rc=0
    if command -v timeout >/dev/null 2>&1; then
        (cd "$MODPATH" && timeout 20 sh ./autopif4.sh --strong) >/dev/null 2>&1 || _fp_rc=$?
    else
        (cd "$MODPATH" && sh ./autopif4.sh --strong) >/dev/null 2>&1 || _fp_rc=$?
    fi
    # Guard 2: accept only the canonical outputs (custom.pif.prop/.json - what
    # autopif4 + the bundled migrate.sh produce), matching pif-fetch.sh's own
    # success criterion. A bare pif.prop/pif.json is a pre-migrate leftover and
    # must not be labelled as this fetch's result.
    _fp_file=""
    for f in custom.pif.prop custom.pif.json; do
        [ -s "$MODPATH/$f" ] && { _fp_file="$f"; break; }
    done
    if [ -n "$_fp_file" ]; then
        # Display-only hardening: the value comes from a downloaded file; keep
        # it to a printable whitelist and cap the length so the installer log
        # and the WebUI cannot be fed terminal escapes or junk.
        _fp_model="$(sed -n 's/^MODEL=//p' "$MODPATH/$_fp_file" 2>/dev/null | head -n 1 \
            | tr -cd 'A-Za-z0-9 ._+-' | cut -c1-40)"
        [ -n "$_fp_model" ] || _fp_model="Pixel Beta"
        date +%s > "$MODPATH/.pif-auto" 2>/dev/null
        chmod 0600 "$MODPATH/$_fp_file" 2>/dev/null
        mkdir -p "$TEE_DIR" 2>/dev/null
        printf 'install-fetch\n' > "$TEE_DIR/.pif-source" 2>/dev/null
        msg "  acquired: $_fp_model (device-specific)" "  已获取本机专属指纹：$_fp_model ✓"
        msg "    random per device, unlike the built-in seed; active from the next reboot" "  本机随机，与内置种子不同；重启后立即生效"
    elif [ "$_fp_rc" = "124" ]; then
        msg "  fetch timed out - using the built-in seed" "  联网抓取超时，将使用包内内置指纹"
        msg "    later fetches randomise it automatically; nothing to do" "  之后每次联网抓取都会随机更换，无需操作"
        msg "  (this install was not affected - the module is complete)" "  （本次未影响安装，模块功能完整）"
    else
        msg "  fetch failed - using the built-in seed" "  联网抓取失败，将使用包内内置指纹"
        msg "    later fetches randomise it automatically; nothing to do" "  之后每次联网抓取都会随机更换，无需操作"
        msg "  (this install was not affected - the module is complete)" "  （本次未影响安装，模块功能完整）"
    fi
fi

# v3.2.3 (audit R8-4): upstream PIF treats a `skippersistprop` marker file as
# "skip persist-prop writes" — and, before the R8-4 fix, its stock branch also
# ran uninstall.sh on EVERY boot (in a fusion build: keybox wiped). That
# branch is stripped at assemble time; if a user carried the marker over from
# standalone PIF, tell them what the marker does (and no longer does) here.
if [ -f "$MODPATH/skippersistprop" ]; then
    msg "- skippersistprop marker found: persist-prop writes are skipped (upstream semantics); the old boot-time uninstall behavior is removed, your keybox is safe" "- 检测到 skippersistprop 标记：本版起该标记仅表示「不写入 persist 伪装属性」（与上游语义一致）；旧版本「该标记导致开机清空 keybox」的行为已移除"
fi

# Debug mode defaults to OFF (security review 2026-09-11): debug.log narrates
# the full decision chain (channels, URLs, identity sync, engine reasons) and
# the diagnostic export can carry it out of the device — verbose logging is a
# privacy surface, not a default. Flip it on from the logs page when chasing a
# field problem; the flag file is checked per call so the toggle is live.
mkdir -p "$TEE_DIR" 2>/dev/null
msg "- Debug 日志默认关闭（排障时在日志页打开）" "- Debug 日志默认关闭（排障时在日志页打开）"
# v3.2.3 (audit L11): v3.0.2–v3.1.x shipped the debug flag ON by default
# ("since flash"), so an upgrade would keep verbose logging running forever
# while this message claims OFF. Clear the stale flag once at upgrade; the
# logs-page toggle recreates it when the user deliberately wants it back.
if [ -f "/data/adb/teesim/.debug" ]; then
    rm -f "/data/adb/teesim/.debug"
    msg "- 已关闭旧版本遗留的 Debug 详细日志（需要时在日志页重新打开）" "- 已关闭旧版本遗留的 Debug 详细日志（需要时在日志页重新打开）"
fi

# Clean up injection artifacts left behind by PIF-family modules (including fusion v1.x).
for pkg in com.google.android.gms com.android.vending; do
    for dir in "/data/user_de/0/$pkg" "/data/data/$pkg"; do
        [ -d "$dir" ] || continue
        for artifact in libinject.so classes.dex pif.prop; do
            [ -f "$dir/$artifact" ] && rm -f "$dir/$artifact"
        done
    done
done

# ---------- TEE component: ABI pruning and permissions ----------

# Ship only the TEE component ABI this device runs; the other ABI's native libraries are
# dead weight here.
case "$ARCH" in
  arm64) rm -rf "$MODPATH/x86_64" ;;
  x64) rm -rf "$MODPATH/arm64-v8a" ;;
esac

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/daemon" 0 0 0755
for abi in arm64-v8a x86_64; do
    [ -f "$MODPATH/$abi/inject" ] && set_perm "$MODPATH/$abi/inject" 0 0 0755
    [ -f "$MODPATH/$abi/teesim-uds" ] && set_perm "$MODPATH/$abi/teesim-uds" 0 0 0755
done

msg "- Aegis Fusion installed: just reboot, everything is automatic" "- Aegis Fusion 安装完成：重启即可，其余全自动"
msg "  Both PI halves are bundled: TEE attestation + device fingerprint" "  两套 PI 能力均已内置：TEE 证明 + 设备指纹"
msg "  Fingerprint: fetched for THIS device at install when online (built-in seed otherwise;" "  指纹：联网时安装即抓取本机专属（离线则用包内内置指纹；联网后自动更换）；"
msg "  no Zygisk = BASIC only); later fetches randomise it automatically" "  无 Zygisk 时最高仅 BASIC）"
msg "  a custom.pif.prop you place in the module dir always takes priority" "  你放入模块目录的 custom.pif.prop 始终具有最高优先级"
# Report the interval the user actually configured. $_kbiv was parsed ONCE at
# the top of the TEE section (before the keybox handling) and is reused here and
# in the "existing installation detected" line, so every number the installer
# prints comes from the same read the runtime loop performs. The WebUI's own
# scale is 0/12/24/72/168 (0 = off) — a hardcoded "24h" contradicted a setting
# of 12h on the author's device, and claiming a 24h cadence while the user has
# it switched OFF would be the same lie twice.
if [ "$_kbiv" = "0" ]; then
    msg "  Community-keybox auto-fetch is OFF (your WebUI setting; the current keybox stays);" "  社区 keybox 自动获取已关闭（沿用你在 WebUI 的设置；现有 keybox 继续使用）；"
    msg "  turn it back on any time from the module's WebUI" "  需要时可在模块 WebUI 里随时重新开启"
else
    msg "  A community keybox is auto-fetched every ${_kbiv}h (STRONG integrity);" "  社区 keybox 每 ${_kbiv} 小时自动获取（STRONG 级完整性）；"
fi
msg "  interval configurable in the WebUI; user-imported keyboxes are protected" "  周期可在 WebUI 调整；用户手动导入的 keybox 自动刷新永不覆盖 ——"
msg "  from auto-refresh; the WebUI manual fetch replaces them (backed up first)" "  仅 WebUI 的\"手动获取\"会替换，且替换前自动备份到 keybox-backups/"
msg "  Pick target apps in the WebUI — they get TEE attestation + environment hiding" "  在 WebUI 中勾选目标应用 —— 它们将获得 TEE 证明 + 环境隐藏"
