//! apps-sync —— 受保护作用域的 janitor（**纯逻辑，重实现**）
//!
//! 契约：`docs/CONTRACT-management.md` §4（原 `module/apps-sync.sh`，301 行）。
//!
//! 与 shell 版的差异（按契约）：
//! * **不需要 busybox** —— shell 版依赖 busybox awk 做 JSON 切片（toybox 在很多
//!   构建上没有 awk），Rust 版原生处理，少了「找不到 busybox 就整体退出」的分支；
//! * JSON 编辑是**定点编辑**：`config.json` 除 apps 数组外逐字节保持不变
//!   （契约 §3.11 的「保留顺序的定点编辑」决策）。
//!
//! 两条刻意约束（契约 §4.1，不要优化掉）：
//! * 只编辑**单 profile** 的 config（数 `"apps"` 出现次数，不是行数）；
//! * 修剪只比对**完整包列表**，且列表必须过硬校验 —— 一个失败的 pm banner
//!   绝不能驱动删除。
//!
//! 测试接缝：`AEGIS_TEE_DIR` / `AEGIS_PKG_LIST` / `AEGIS_MODPATH`。

use std::fs;
use std::path::Path;
use std::process::Command;

struct Ctx {
    tee_dir: String,
    modpath: String,
    pkg_list: String,
}

/// 单行日志（`apps-sync.log`）。
fn log_line(ctx: &Ctx, msg: &str) {
    let _ = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{}/apps-sync.log", ctx.tee_dir))
        .and_then(|mut f| {
            use std::io::Write;
            writeln!(f, "[{}] {}", now_stamp(), msg)
        });
}

fn now_stamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (days, rem) = (secs / 86400, secs % 86400);
    format!(
        "{} {:02}:{:02}:{:02}",
        days_to_date(days),
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn days_to_date(z: u64) -> String {
    let z = z + 719_468;
    let era = z / 146_097;
    let doe = z % 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    format!("{:04}-{:02}-{:02}", if m <= 2 { y + 1 } else { y }, m, d)
}

// ---------------------------------------------------------------------------
// config.json 的「apps 数组」定点操作
// ---------------------------------------------------------------------------

/// 找到 `"apps"` 数组的 `[` 与 `]`（0-based，`[` 含、`]` 含）。
fn apps_span(text: &str) -> Option<(usize, usize)> {
    let key = "\"apps\"";
    let kp = text.find(key)?;
    let after = &text[kp + key.len()..];
    let colon = after.find(':')?;
    let rest = &after[colon + 1..];
    let open_rel = rest.find('[')?;
    let open = kp + key.len() + colon + 1 + open_rel;
    // 配对的 `]`：从 `[` 往后找第一个 `]`（apps 数组是字符串数组，无嵌套）
    let close_rel = text[open..].find(']')?;
    Some((open, open + close_rel))
}

/// 数 `"apps"` 在**压平文本**里的出现次数（不是行数）。
fn count_apps_keys(text: &str) -> usize {
    text.matches("\"apps\"").count()
}

/// 展开 apps 数组的当前条目（去引号与空白；`uid:N` 与 `pkg@user` 原样保留）。
fn apps_entries(text: &str) -> Vec<String> {
    let (open, close) = match apps_span(text) {
        Some(s) => s,
        None => return Vec::new(),
    };
    text[open + 1..close]
        .split(',')
        .map(|e| e.trim().trim_matches('"').trim().to_string())
        .filter(|e| !e.is_empty())
        .collect()
}

/// 重建 apps 数组：`"apps": ["a", "b"]`。其余字节保持不变。
fn rebuild_apps(text: &str, entries: &[String]) -> String {
    let (open, close) = match apps_span(text) {
        Some(s) => s,
        None => return text.to_string(),
    };
    let inner = entries
        .iter()
        .map(|e| format!("\"{e}\""))
        .collect::<Vec<_>>()
        .join(", ");
    // text[..open] 已含 `"apps": ` 前缀 —— 这里只替换数组内容，避免重复键
    format!("{}[{}]{}", &text[..open], inner, &text[close + 1..])
}

/// 在 apps 数组**头部**插入若干条目（GMS 播种 / uid pin）。
/// 空数组 → 不带尾逗号；非空 → 前插并补逗号。除插入区外逐字节不变。
fn prepend_apps(text: &str, entries: &[String]) -> String {
    let (open, close) = match apps_span(text) {
        Some(s) => s,
        None => return text.to_string(),
    };
    let inner = entries
        .iter()
        .map(|e| format!("\"{e}\""))
        .collect::<Vec<_>>()
        .join(", ");
    let existing = &text[open + 1..close];
    let tail = if existing.trim().is_empty() {
        existing.to_string()
    } else {
        format!(", {existing}")
    };
    format!("{}[{inner}{tail}]{}", &text[..open], &text[close + 1..])
}

/// 在 `"apps"` 之前插入 `"autoIncludeNewApps": true, `（迁移）。
/// 注意：只插入前缀，`"apps"` 本身保留 —— 否则会产出重复键。
fn insert_auto_include(text: &str) -> String {
    let key = "\"apps\"";
    let kp = match text.find(key) {
        Some(p) => p,
        None => return text.to_string(),
    };
    format!(
        "{}\"autoIncludeNewApps\": true, \"apps\"{}",
        &text[..kp],
        &text[kp + key.len()..]
    )
}

fn is_valid_pkg_name(s: &str) -> bool {
    let b = s.as_bytes();
    if b.is_empty() || !(b[0].is_ascii_alphabetic()) {
        return false;
    }
    let mut dot = false;
    for (i, c) in b.iter().enumerate() {
        match c {
            b'.' => {
                if i == b.len() - 1 || b[i + 1] == b'.' || b[i + 1] == b'.' {
                    return false;
                }
                dot = true;
            }
            c if c.is_ascii_alphanumeric() || *c == b'_' => {}
            _ => return false,
        }
    }
    dot
}

fn is_valid_user_entry(s: &str) -> bool {
    match s.rfind('@') {
        Some(p) => {
            let (pkg, user) = (&s[..p], &s[p + 1..]);
            is_valid_pkg_name(pkg) && !user.is_empty() && user.bytes().all(|c| c.is_ascii_digit())
        }
        None => is_valid_pkg_name(s),
    }
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

pub fn run(_args: &[String]) -> i32 {
    let tee_dir =
        std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string());
    let modpath = std::env::var("AEGIS_MODPATH")
        .unwrap_or_else(|_| "/data/adb/modules/aegisfusion_rs".to_string());
    let pkg_list = std::env::var("AEGIS_PKG_LIST")
        .unwrap_or_else(|_| "/data/system/packages.list".to_string());
    let ctx = Ctx { tee_dir, modpath, pkg_list };

    let config_path = format!("{}/config.json", ctx.tee_dir);
    if !Path::new(&config_path).is_file() {
        return 0; // 无 config → 静默退出
    }
    let mut text = fs::read_to_string(&config_path).unwrap_or_default();

    // ---- 单 profile 守卫：数出现次数，不是行数 ----------------------------
    if count_apps_keys(&text) != 1 {
        log_line(&ctx, "multi-profile config — leaving everything untouched");
        return 0;
    }

    // ---- 1. legacy auto-add 标志的迁移 -----------------------------------
    let legacy = format!("{}/apps-auto-add", ctx.tee_dir);
    if Path::new(&legacy).is_file() {
        let want = fs::read_to_string(&legacy).unwrap_or_default().trim().to_string();
        let _ = fs::remove_file(&legacy);
        // 权威字段检查：**任何**显式的 autoIncludeNewApps 值都算（WebUI 关掉时
        // 写 false）—— 只认 true 会把用户显式的 false 静默回滚成重复键。
        let has_field = text.contains("\"autoIncludeNewApps\"");
        if want == "1" && !has_field {
            let candidate = insert_auto_include(&text);
            if candidate.contains("\"autoIncludeNewApps\"")
                && candidate.contains("\"apps\"")
                && candidate.contains("\"profiles\"")
            {
                text = candidate;
                let _ = fs::write(&config_path, &text);
                log_line(&ctx, "migrated legacy auto-add flag -> profile autoIncludeNewApps=true");
            } else {
                log_line(&ctx, "ERROR: auto-add migration failed sanity check; flag discarded");
            }
        } else {
            log_line(&ctx, &format!(
                "legacy auto-add flag removed (value={}; config field already authoritative)",
                if want.is_empty() { "<empty>" } else { &want }
            ));
        }
    }

    // ---- 2. GMS 作用域播种（v3.0.1，"一绿元凶"）--------------------------
    let gms_seed = format!("{}/.gms-scope-seeded", ctx.tee_dir);
    if !Path::new(&gms_seed).is_file() {
        let installed = pm_path("com.google.android.gms").is_some();
        if !installed {
            log_dbg(&ctx, "gms seed: com.google.android.gms not installed — skipped");
        } else if text.contains("\"com.google.android.gms\"") {
            log_dbg(&ctx, "gms seed: already in scope — nothing to do");
        }
        if installed && !text.contains("\"com.google.android.gms\"") {
            let candidate = prepend_apps(&text, &["com.google.android.gms".to_string()]);
            if candidate.contains("\"com.google.android.gms\"")
                && candidate.contains("\"apps\"")
                && candidate.contains("\"profiles\"")
            {
                text = candidate;
                let _ = fs::write(&config_path, &text);
                log_line(&ctx, "seeded com.google.android.gms into the attestation scope (DroidGuard must see the keybox)");
            } else {
                log_line(&ctx, "ERROR: gms scope seed failed sanity check; left untouched");
            }
        }
        // marker 即使 gms 缺席/已在作用域也要写：每次重检会与用户的刻意移除对抗
        let _ = fs::write(&gms_seed, "");
    }

    // ---- 2b. PI 核心三件套的 uid pin（Round 12）--------------------------
    let uid_pins_off = format!("{}/.uid-pins-off", ctx.tee_dir);
    if !Path::new(&uid_pins_off).is_file() {
        let pkl = fs::read_to_string(&ctx.pkg_list).unwrap_or_default();
        if pkl.trim().is_empty() {
            log_dbg(&ctx, "uid pins: packages.list unreadable — skipped this run");
        } else {
            let mut pin_added: Vec<String> = Vec::new();
            for app in [
                "com.google.android.gms",
                "com.android.vending",
                "com.google.android.gsf",
            ] {
                // 只 pin 实际安装了的（按 packages.list）
                let installed = pkl
                    .lines()
                    .any(|l| l.starts_with(app) && l.as_bytes().get(app.len()) == Some(&b' '));
                if !installed {
                    continue;
                }
                if !text.contains(&format!("\"{app}\"")) {
                    pin_added.push(app.to_string());
                }
                // uid 取该行第二个字段
                let uid = pkl
                    .lines()
                    .find(|l| l.starts_with(app) && l.as_bytes().get(app.len()) == Some(&b' '))
                    .and_then(|l| l.split_whitespace().nth(1))
                    .filter(|u| !u.is_empty() && u.bytes().all(|c| c.is_ascii_digit()));
                if let Some(u) = uid {
                    let key = format!("uid:{u}");
                    if !text.contains(&format!("\"{key}\"")) {
                        pin_added.push(key);
                    }
                }
            }
            if !pin_added.is_empty() {
                let candidate = prepend_apps(&text, &pin_added);
                let first = pin_added[0].clone();
                if candidate.contains("\"apps\"")
                    && candidate.contains("\"profiles\"")
                    && candidate.contains(&format!("\"{first}\""))
                {
                    text = candidate;
                    let _ = fs::write(&config_path, &text);
                    log_line(&ctx, &format!(
                        "pinned PI core into scope, added:{}",
                        pin_added.iter().map(|e| format!(" {e}")).collect::<String>()
                    ));
                } else {
                    log_line(&ctx, "ERROR: uid-pin insert failed sanity check; left untouched");
                }
            }
        }
    }

    // ---- 3. 清理 pass（硬校验：pm banner 绝不能驱动删除）-----------------
    let allpkg: Vec<String> = pm_list()
        .lines()
        .filter_map(|l| l.strip_prefix("package:"))
        .filter(|l| is_valid_pkg_name(l))
        .map(|s| s.to_string())
        .collect();
    if allpkg.is_empty() {
        log_dbg(&ctx, "cleanup skipped: pm list packages unavailable");
        return 0;
    }

    let cur = apps_entries(&text);
    let mut removes: Vec<String> = Vec::new();
    for p in &cur {
        if p.starts_with("uid:") {
            continue; // uid:N 永不修剪（它们 pin PI 核心三件套）
        }
        if p.contains('@') {
            // pkg@user 只在无效时修剪：这里的 pm 只报用户 0
            if !is_valid_user_entry(p) {
                removes.push(p.clone());
            }
        } else if !allpkg.iter().any(|a| a == p) {
            removes.push(p.clone());
        }
    }
    removes.sort();
    removes.dedup();

    // ---- 3b. 退役的检测类应用排除标记：响亮地清一次 ----------------------
    let det = format!("{}/.detector-excluded", ctx.tee_dir);
    let det_opt = format!("{}/.keep-detectors", ctx.tee_dir);
    if Path::new(&det).is_file() || Path::new(&det_opt).is_file() {
        let _ = fs::remove_file(&det);
        let _ = fs::remove_file(&det_opt);
        log_line(&ctx, "removed leftover detector-exclusion markers (v3.1.7: protected apps are never auto-removed)");
    }

    if removes.is_empty() {
        return 0;
    }

    // ---- 重写：apps 数组按存活条目重建，其余字节不变 ---------------------
    let keep: Vec<String> = cur
        .iter()
        .filter(|e| !removes.iter().any(|r| r == *e))
        .cloned()
        .collect();
    let candidate = rebuild_apps(&text, &keep);
    if candidate.contains("\"apps\"") && candidate.contains("\"profiles\"") {
        text = candidate;
        let _ = fs::write(&config_path, &text);
        log_line(&ctx, &format!(
            "cleaned, removed:{}  (absent from pm list packages — uninstalled or uninstalled for this user)",
            removes.iter().map(|e| format!(" {e}")).collect::<String>()
        ));
    } else {
        log_line(&ctx, "ERROR: rewritten config failed sanity check; left untouched");
    }
    0
}

// --- pm 接缝（测试用桩放 PATH 上）------------------------------------------

fn pm_path(pkg: &str) -> Option<String> {
    let out = Command::new("pm").args(["path", pkg]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn pm_list() -> String {
    match Command::new("pm").args(["list", "packages"]).output() {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => String::new(),
    }
}

fn log_dbg(ctx: &Ctx, msg: &str) {
    if Path::new(&format!("{}/.debug", ctx.tee_dir)).is_file() {
        let _ = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{}/debug.log", ctx.tee_dir))
            .and_then(|mut f| {
                use std::io::Write;
                writeln!(f, "[{}] [appssync] {}", now_stamp(), msg)
            });
    }
}
