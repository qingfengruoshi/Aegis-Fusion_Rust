//! service 的环境 / BL 隐藏层（**纯逻辑，重实现**）
//!
//! 契约：`docs/CONTRACT-management.md` §5.3–5.6（原 `module/service.sh:60-242`）。
//!
//! 与 shell 版一致的行为：
//! * `resetprop_if_diff` 只在真不同时写（避免开机唤醒 property_service 上百次）；
//! * 构建信号（`ro.*.build.tags` / `ro.*.build.type`）是**遍历**而非硬编码列表；
//! * ROM pixel-imitation 钩子的**二分语义**（v3.0.14）：真 hook ROM → 上游中和；
//!   其它一切 → 整个 `persist.sys.*` 家族按残留清除（**内存 + 持久化记录都删**）。
//!
//! 未包含（见模块尾注释）：`/proc/cmdline` 掩蔽（opt-in，需要 mount）、
//! DroidGuard 回收的时序、tick 循环（架构变化，另做）。

use std::fs;
use std::path::Path;
use std::process::Command;

fn rp_bin() -> &'static str {
    for c in [
        "/data/adb/ksu/bin/resetprop",
        "/data/adb/ap/bin/resetprop",
        "/data/adb/magisk/resetprop",
    ] {
        if Path::new(c).is_file() {
            return c;
        }
    }
    "resetprop"
}

fn rp(bin: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(bin).args(args).output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn rp_list(bin: &str) -> Vec<String> {
    rp(bin, &[])
        .unwrap_or_default()
        .lines()
        .map(|l| l.split('=').next().unwrap_or("").trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn rp_read(bin: &str, name: &str) -> Option<String> {
    rp(bin, &[name])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// `resetprop_if_diff`：当前值**为空**或**已等于** expected → 跳过（audit N16：
/// 属性缺失时**不创建** —— 凭空造 OEM 从未写的属性本身就是异常信号）。
fn rp_if_diff(bin: &str, name: &str, expected: &str) -> bool {
    let cur = rp_read(bin, name).unwrap_or_default();
    if cur.is_empty() || cur == expected {
        return false;
    }
    let _ = rp(bin, &["-n", name, expected]);
    true
}

/// `resetprop_if_match`：仅当当前值包含 substring 时改写。
fn rp_if_match(bin: &str, name: &str, substring: &str, new_value: &str) -> bool {
    let cur = rp_read(bin, name).unwrap_or_default();
    if cur.contains(substring) {
        let _ = rp(bin, &["-n", name, new_value]);
        return true;
    }
    false
}

/// `resetprop_if_diff` 的持久化变体（ROM 中和写入用 `-n -p`）。
fn rp_if_diff_p(bin: &str, name: &str, expected: &str) -> bool {
    let cur = rp_read(bin, name).unwrap_or_default();
    if cur.is_empty() || cur == expected {
        return false;
    }
    let _ = rp(bin, &["-n", "-p", name, expected]);
    true
}

/// 构建信号遍历的正则 `ro.*.build.tags` / `ro.*.build.type` 的等价判定：
/// 以 `ro` 开头、以 `.build.tags` / `.build.type` 结尾（`ro.build.tags` 自身也匹配）。
fn matches_build_suffix(name: &str, suffix: &str) -> bool {
    name.starts_with("ro") && name.len() >= 2 + suffix.len() && name.ends_with(suffix)
}

/// 入口：环境 / BL 隐藏层（`service.sh:60-242` 的等价实现）。
/// `tee_dir` 用于 `.cmdline-spoof` marker 的判定（该掩蔽本体需要 mount，
/// 宿主/单元环境自然跳过 —— 与 shell 的失败路径一致）。
pub fn run_env_hiding(tee_dir: &str) -> i32 {
    let bin = rp_bin();

    // ---- BL / VBMeta 核心组（Integrity-Box 的"隐藏解锁 BL"集合）-----------
    rp_if_diff(&bin, "ro.boot.vbmeta.device_state", "locked");
    rp_if_diff(&bin, "vendor.boot.vbmeta.device_state", "locked");
    rp_if_diff(&bin, "ro.boot.verifiedbootstate", "green");
    rp_if_diff(&bin, "vendor.boot.verifiedbootstate", "green");
    rp_if_diff(&bin, "ro.boot.flash.locked", "1");
    rp_if_diff(&bin, "ro.boot.veritymode", "enforcing");
    rp_if_diff(&bin, "ro.secureboot.lockstate", "locked"); // MIUI

    // ---- 保修 / 调试（Samsung / 通用）------------------------------------
    for p in [
        "ro.boot.warranty_bit",
        "ro.vendor.boot.warranty_bit",
        "ro.vendor.warranty_bit",
        "ro.warranty_bit",
    ] {
        rp_if_diff(&bin, p, "0");
    }
    rp_if_diff(&bin, "ro.debuggable", "0");
    rp_if_diff(&bin, "ro.force.debuggable", "0");
    rp_if_diff(&bin, "ro.secure", "1");
    rp_if_diff(&bin, "ro.adb.secure", "1");
    rp_if_diff(&bin, "sys.oem_unlock_allowed", "0");
    rp_if_diff(&bin, "ro.oem_unlock_supported", "0");

    // ---- OEM 专属 --------------------------------------------------------
    rp_if_diff(&bin, "ro.boot.realmebootstate", "green"); // Realme
    rp_if_diff(&bin, "ro.boot.realme.lockstate", "1"); // Realme
    rp_if_diff(&bin, "ro.is_ever_orange", "0"); // OnePlus

    // ---- 构建信号（**遍历**，非硬编码列表）-------------------------------
    let all = rp_list(&bin);
    for p in &all {
        if matches_build_suffix(p, ".build.tags") {
            rp_if_diff(&bin, p, "release-keys");
        }
    }
    for p in &all {
        if matches_build_suffix(p, ".build.type") {
            rp_if_diff(&bin, p, "user");
        }
    }

    // ---- 自定义 recovery 隐藏（"recovery" bootmode 是 root 的破绽）-------
    rp_if_match(&bin, "ro.bootmode", "recovery", "unknown");
    rp_if_match(&bin, "ro.boot.bootmode", "recovery", "unknown");
    rp_if_match(&bin, "vendor.boot.bootmode", "recovery", "unknown");

    // ---- 杂项环境噪音 ----------------------------------------------------
    rp_if_diff(&bin, "ro.hardware.virtual_device", "0");

    // ---- ROM pixel-imitation 钩子：中和 OR 清残留（v3.0.14 二分语义）-----
    // 背景：上游 PIFork 写 `persist.sys.*` 开关（**持久化 -p**）来中和自定义
    // ROM 的钩子 —— 一旦写入就自锁、重刷/卸载后存活，并作为 world-readable
    // 的破绽留在属性区（2026-09-09：K70 命中 5 次）。
    let gms_json = std::env::var("AEGIS_GMS_JSON")
        .unwrap_or_else(|_| "/data/system/gms_certified_props.json".to_string());
    let hook_rom = all.iter().any(|p| {
        p.contains("ro.aospa.version")
            || p.contains("net.pixelos.version")
            || p.contains("ro.afterlife.version")
    }) || Path::new(&gms_json).is_file()
        || rp_read(&bin, "persist.sys.pihooks.first_api_level").is_some()
        || rp_read(&bin, "persist.sys.pihooks.security_patch").is_some();

    if hook_rom {
        // 真 hook ROM：上游中和，不变
        if all.iter().any(|p| {
            p.contains("ro.aospa.version")
                || p.contains("net.pixelos.version")
                || p.contains("ro.afterlife.version")
        }) || Path::new(&gms_json).is_file()
        {
            rp_if_diff(&bin, "persist.sys.pihooks.first_api_level", "");
            rp_if_diff(&bin, "persist.sys.pihooks.security_patch", "");
        }
        if all
            .iter()
            .any(|p| p.contains("persist.sys.pihooks") || p.contains("persist.sys.entryhooks") || p.contains("persist.sys.pixelprops"))
            || Path::new(&gms_json).is_file()
        {
            // 上游的中和开关（**持久化 -p**）+ 上下文缓存清理
            for (prop, value) in [
                ("persist.sys.pihooks.disable.gms_props", "true"),
                ("persist.sys.pihooks.disable.gms_key_attestation_block", "true"),
                ("persist.sys.entryhooks_enabled", "false"),
                ("persist.sys.pixelprops.gms", "false"),
                ("persist.sys.pixelprops.gapps", "false"),
                ("persist.sys.pixelprops.google", "false"),
                ("persist.sys.pixelprops.pi", "false"),
                ("persist.sys.pp.gms", "false"),
                ("persist.sys.pp.vending", "false"),
            ] {
                let _ = rp(&bin, &["-n", "-p", prop, value]);
                if let Some(z) = rp(&bin, &["-Z", prop]) {
                    let z = z.trim().to_string();
                    let _ = rp(&bin, &["-c", &z]);
                }
            }
        }
        // LeafOS "gmscompat: Dynamically spoof props for GMS"
        if Path::new(&gms_json).is_file()
            && rp_read(&bin, "persist.sys.spoof.gms").as_deref() != Some("false")
        {
            let _ = rp(&bin, &["persist.sys.spoof.gms", "false"]);
            if let Some(z) = rp(&bin, &["-Z", "persist.sys.spoof.gms"]) {
                let z = z.trim().to_string();
                let _ = rp(&bin, &["-c", &z]);
            }
        }
    } else {
        // 非 hook ROM：整个家族都是**残留** —— 内存副本与持久化记录都删
        // （`--delete` 清内存；`-p --delete` 清 /data/property 里的记录，
        //   让它下次开机不再复活）
        let residue = [
            "persist.sys.pihooks.first_api_level",
            "persist.sys.pihooks.security_patch",
            "persist.sys.pihooks.disable.gms_props",
            "persist.sys.pihooks.disable.gms_key_attestation_block",
            "persist.sys.entryhooks_enabled",
            "persist.sys.pixelprops.gms",
            "persist.sys.pixelprops.gapps",
            "persist.sys.pixelprops.google",
            "persist.sys.pixelprops.pi",
            "persist.sys.pp.gms",
            "persist.sys.pp.vending",
            "persist.sys.spoof.gms",
        ];
        let mut removed = 0;
        for p in &residue {
            let exists = rp_read(&bin, p).is_some()
                || rp(&bin, &["-p", p])
                    .map(|s| !s.trim().is_empty())
                    .unwrap_or(false);
            if exists {
                let _ = rp(&bin, &["--delete", p]);
                let _ = rp(&bin, &["-p", "--delete", p]);
                removed += 1;
            }
        }
        if removed > 0 {
            log_dbg(tee_dir, &format!("props: cleaned {removed} persist.sys spoof-tell residue props (no hook ROM detected)"));
        }
    }

    let _ = rp(&bin, &["-c"]); // 清属性缓存
    0
}

fn log_dbg(tee_dir: &str, msg: &str) {
    if Path::new(&format!("{tee_dir}/.debug")).is_file() {
        let _ = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{tee_dir}/debug.log"))
            .and_then(|mut f| {
                use std::io::Write;
                writeln!(f, "[service] {msg}")
            });
    }
}

/// 入口（`fusionctl env-hiding`）。
pub fn run(_args: &[String]) -> i32 {
    let tee_dir = std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string());
    run_env_hiding(&tee_dir)
}
