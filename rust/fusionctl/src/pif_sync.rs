//! pif-sync —— 把活跃的 PIF 指纹**镜像进 TEE 档案**（**纯逻辑，重实现**）
//!
//! 契约：`docs/CONTRACT-management.md` §3（原 `module/pif-sync.sh`，282 行）。
//!
//! ⚠️ 方向是**证据驱动的反转**（v3.1.0 / Round 12）：档案跟随 PIF。
//! 前提是引擎补丁 0005 已生效（见 `KNOWN-FAILURE-MODES.md` §2）。
//!
//! 与 shell 版的差异（按契约 §3.11 的重写决策）：
//! * JSON 编辑用**定点替换**，转义只做 JSON 层一次（`\`→`\\`、`"`→`\"`）——
//!   shell 的「三层转义」是 sed replacement 吃反斜杠的怪癖，Rust 不需要；
//! * 数据目录遵守 `AEGIS_TEE_DIR`（与其它脚本一致）。
//!
//! 测试接缝：`AEGIS_TEE_DIR` / `AEGIS_ADB` / `AEGIS_PROP_FILE`。

use std::fs;
use std::path::Path;
use std::process::Command;

struct Ctx {
    adb: String,
    tee_dir: String,
}

fn log_line(ctx: &Ctx, msg: &str) {
    let _ = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{}/pif-sync.log", ctx.tee_dir))
        .and_then(|mut f| {
            use std::io::Write;
            writeln!(f, "[{}] {}", now_stamp(), msg)
        });
}

fn log_dbg(ctx: &Ctx, msg: &str) {
    if Path::new(&format!("{}/.debug", ctx.tee_dir)).is_file() {
        let _ = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{}/debug.log", ctx.tee_dir))
            .and_then(|mut f| {
                use std::io::Write;
                writeln!(f, "[{}] [pifsync] {}", now_stamp(), msg)
            });
    }
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
// PIF 源探测（9 个候选，第一个非空者胜）
// ---------------------------------------------------------------------------

fn pif_source(ctx: &Ctx) -> Option<String> {
    let candidates = [
        format!("{}/modules/aegisfusion_rs/custom.pif.prop", ctx.adb),
        format!("{}/modules/aegisfusion_rs/custom.pif.json", ctx.adb),
        format!("{}/pif.json", ctx.adb),
        format!("{}/modules/playintegrityfix/custom.pif.prop", ctx.adb),
        format!("{}/modules/playintegrityfix/custom.pif.json", ctx.adb),
        format!("{}/modules/playintegrityfix/pif.json", ctx.adb),
        format!("{}/modules/playintegrityfork/pif.json", ctx.adb),
        format!("{}/modules/Integrity-Box/pif.json", ctx.adb),
        format!("{}/modules/tricky_store/pif.json", ctx.adb),
    ];
    candidates
        .iter()
        .find(|c| as_nonempty(c))
        .cloned()
}

fn as_nonempty(p: &str) -> bool {
    match fs::read(p) {
        Ok(v) => !v.is_empty(),
        Err(_) => false,
    }
}

/// `pget`：同时读两种格式 —— `key=value` 行与 legacy JSON 的 `"key":"value"`。
fn pget(pif: &str, key: &str) -> String {
    if let Some(text) = fs::read_to_string(pif).ok() {
        for line in text.lines() {
            if let Some(rest) = line.strip_prefix(key) {
                let rest = rest.strip_prefix('=').unwrap_or(rest);
                let v: String = rest.chars().take_while(|c| *c != '\r').collect();
                let v = v.trim().trim_matches('"').trim().to_string();
                if !v.is_empty() {
                    return v;
                }
            }
        }
        // JSON 形态：'"key"\s*:\s*"value"'（取第一个）
        let pat = format!("\"{key}\"");
        if let Some(p) = text.find(&pat) {
            let tail = &text[p + pat.len()..];
            if let Some(cp) = tail.find(':') {
                let tail = tail[cp + 1..].trim_start();
                if let Some(q) = tail.strip_prefix('"') {
                    let v: String = q.chars().take_while(|c| *c != '"').collect();
                    if !v.is_empty() {
                        return v;
                    }
                }
            }
        }
    }
    String::new()
}

// ---------------------------------------------------------------------------
// 定点 JSON 编辑
// ---------------------------------------------------------------------------

/// JSON 字符串转义（只做 JSON 层一次）。
fn json_escape(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    for c in v.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' | '\r' => {}
            other => out.push(other),
        }
    }
    out
}

/// `set_id`：定点替换 `"<key>": "<old>"` → `"<key>": "<new>"`（值相等 ⇒ 不算改动）。
/// 返回 (新文本, 是否变了)。
fn set_id(text: &str, key: &str, value: &str) -> (String, bool) {
    let key_pat = format!("\"{key}\"");
    let kp = match text.find(&key_pat) {
        Some(p) => p,
        None => return (text.to_string(), false),
    };
    let after = &text[kp + key_pat.len()..];
    let colon = match after.find(':') {
        Some(c) => c,
        None => return (text.to_string(), false),
    };
    let after_colon = &after[colon + 1..];
    let lead_ws = after_colon.len() - after_colon.trim_start().len();
    let q = after_colon.trim_start();
    let q = match q.strip_prefix('"') {
        Some(q) => q,
        None => return (text.to_string(), false),
    };
    let vstart = kp + key_pat.len() + colon + 1 + lead_ws + 1;
    let vend = match text[vstart..].find('"') {
        Some(p) => vstart + p,
        None => return (text.to_string(), false),
    };
    let cur = &text[vstart..vend];
    if cur == value {
        return (text.to_string(), false); // 幂等：相等不算改动
    }
    let esc = json_escape(value);
    (
        format!("{text_prefix}\"{key}\": \"{esc}\"{text_suffix}", text_prefix = &text[..kp], text_suffix = &text[vend + 1..]),
        true,
    )
}

/// `ensure_patch_object`：legacy 纯字符串形态 → 对象形态（ConfigStore 用
/// `optJSONObject()` 读，字符串形式**静默丢弃**）。
/// vendor / boot 用 `YYYY-MM-05` 占位（shell 版同值）。
fn ensure_patch_object(text: &str, system_value: &str) -> (String, bool) {
    let flat = text.replace(['\n', '\r'], "");
    if !flat.contains("\"patchLevel\": \"") && !flat.contains("\"patchLevel\":\"") {
        return (text.to_string(), false);
    }
    let esc = json_escape(system_value);
    let key = "\"patchLevel\"";
    let kp = match text.rfind(key) {
        Some(p) => p,
        None => return (text.to_string(), false),
    };
    // 找这个字符串值的结束引号
    let after = &text[kp + key.len()..];
    let colon = match after.find(':') {
        Some(c) => c,
        None => return (text.to_string(), false),
    };
    let after_colon = &after[colon + 1..];
    let q = match after_colon.trim_start().strip_prefix('"') {
        Some(q) => q,
        None => return (text.to_string(), false),
    };
    let vstart = kp + key.len() + colon + 1 + (after_colon.len() - after_colon.trim_start().len()) + 1;
    let vend = match text[vstart..].find('"') {
        Some(p) => vstart + p,
        None => return (text.to_string(), false),
    };
    let out = format!(
        "{}\"patchLevel\": {{ \"system\": \"{esc}\", \"vendor\": \"YYYY-MM-05\", \"boot\": \"YYYY-MM-05\" }}{}",
        &text[..kp],
        &text[vend + 1..]
    );
    (out, true)
}

// ---------------------------------------------------------------------------
// 属性读取（getprop / AEGIS_PROP_FILE 桩）
// ---------------------------------------------------------------------------

fn get_prop(prop_file: &Option<String>, name: &str) -> String {
    if let Some(pf) = prop_file {
        let text = fs::read_to_string(pf).unwrap_or_default();
        let pat = format!("\"{name}\"");
        if let Some(p) = text.find(&pat) {
            let tail = &text[p + pat.len()..];
            if let Some(cp) = tail.find(':') {
                let tail = tail[cp + 1..].trim_start();
                if let Some(q) = tail.strip_prefix('"') {
                    let v: String = q.chars().take_while(|c| *c != '"').collect();
                    return v;
                }
            }
        }
        return String::new();
    }
    Command::new("getprop")
        .arg(name)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

pub fn run(_args: &[String]) -> i32 {
    let ctx = Ctx {
        adb: std::env::var("AEGIS_ADB").unwrap_or_else(|_| "/data/adb".to_string()),
        tee_dir: std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string()),
    };
    let prop_file = std::env::var("AEGIS_PROP_FILE").ok().filter(|s| !s.is_empty());
    let cfg = format!("{}/config.json", ctx.tee_dir);

    if !Path::new(&cfg).is_file() {
        return 0; // 无 config → 静默退出
    }
    let mut text = fs::read_to_string(&cfg).unwrap_or_default();
    let pif = pif_source(&ctx);
    let mut changed = false;

    let pif_off = format!("{}/.pif-off", ctx.tee_dir);
    let sync_off = format!("{}/.pif-sync-off", ctx.tee_dir);
    let synced = format!("{}/.pif-synced", ctx.tee_dir);
    let has_synced = Path::new(&synced).is_file();
    let suppress = Path::new(&sync_off).is_file();

    if suppress {
        log_line(&ctx, ".pif-sync-off set: profile mirroring suppressed (payload flag health check still runs)");
    }

    if Path::new(&pif_off).is_file() {
        // 回滚路径：身份与补丁日期都恢复真机
        log_dbg(&ctx, "PIF half disabled via .pif-off — restoring the real device state");
        if has_synced {
            log_line(&ctx, ".pif-off set: restoring the real device identity and patch level");
            let (t1, c1) = set_id(&text, "brand", &get_prop(&prop_file, "ro.product.brand"));
            text = t1;
            let (t2, c2) = set_id(&text, "device", &get_prop(&prop_file, "ro.product.device"));
            text = t2;
            // product ← ro.product.name（Android 没有 ro.product.product，v3.0.15 修）
            let product = {
                let p = get_prop(&prop_file, "ro.product.name");
                if p.is_empty() { get_prop(&prop_file, "ro.build.product") } else { p }
            };
            let (t3, c3) = set_id(&text, "product", &product);
            text = t3;
            let (t4, c4) = set_id(&text, "manufacturer", &get_prop(&prop_file, "ro.product.manufacturer"));
            text = t4;
            let (t5, c5) = set_id(&text, "model", &get_prop(&prop_file, "ro.product.model"));
            text = t5;
            let (t6, c6) = set_id(&text, "system", &get_prop(&prop_file, "ro.build.version.security_patch"));
            text = t6;
            let (t7, c7) = set_id(&text, "vendor", &get_prop(&prop_file, "ro.vendor.build.security_patch"));
            text = t7;
            let (t8, c8) = set_id(&text, "boot", &get_prop(&prop_file, "ro.vendor.build.security_patch"));
            text = t8;
            changed = c1 || c2 || c3 || c4 || c5 || c6 || c7 || c8;
            let _ = fs::remove_file(&synced);
        } else {
            log_dbg(&ctx, "profile already real — nothing to revert");
        }
    } else if pif.is_none() {
        log_dbg(
            &ctx,
            &format!(
                "no fingerprint source found (synced marker: {})",
                if has_synced { "yes" } else { "no" }
            ),
        );
        if has_synced {
            log_line(&ctx, "fingerprint source no longer present; restoring the real device identity");
            let (t1, c1) = set_id(&text, "brand", &get_prop(&prop_file, "ro.product.brand"));
            text = t1;
            let (t2, c2) = set_id(&text, "device", &get_prop(&prop_file, "ro.product.device"));
            text = t2;
            let product = {
                let p = get_prop(&prop_file, "ro.product.name");
                if p.is_empty() { get_prop(&prop_file, "ro.build.product") } else { p }
            };
            let (t3, c3) = set_id(&text, "product", &product);
            text = t3;
            let (t4, c4) = set_id(&text, "manufacturer", &get_prop(&prop_file, "ro.product.manufacturer"));
            text = t4;
            let (t5, c5) = set_id(&text, "model", &get_prop(&prop_file, "ro.product.model"));
            text = t5;
            changed = c1 || c2 || c3 || c4 || c5;
            let _ = fs::remove_file(&synced);
        }
    } else {
        // PIF 层激活：档案跟随 PIF（Round 12），STRONG 标志保持断言
        let pif_path = pif.as_ref().unwrap();
        if !suppress {
            // mirror_pif：身份字段缺失时从 FINGERPRINT 的 / 分量回退
            let fp = pget(pif_path, "FINGERPRINT");
            let mut brand = pget(pif_path, "BRAND");
            if brand.is_empty() && !fp.is_empty() {
                brand = fp.split('/').next().unwrap_or("").to_string();
            }
            let mut device = pget(pif_path, "DEVICE");
            if device.is_empty() && !fp.is_empty() {
                device = fp.split('/').nth(1).unwrap_or("").to_string();
            }
            let mut product = pget(pif_path, "PRODUCT");
            if product.is_empty() && !fp.is_empty() {
                product = fp.split('/').nth(2).unwrap_or("").to_string();
            }
            let manu = pget(pif_path, "MANUFACTURER");
            let model = pget(pif_path, "MODEL");
            let (t1, c1) = set_id(&text, "brand", &brand);
            text = t1;
            let (t2, c2) = set_id(&text, "device", &device);
            text = t2;
            let (t3, c3) = set_id(&text, "product", &product);
            text = t3;
            let (t4, c4) = set_id(&text, "manufacturer", &manu);
            text = t4;
            let (t5, c5) = set_id(&text, "model", &model);
            text = t5;
            // patchLevel.system 跟随 pif；非日期退化为 today
            let sp = pget(pif_path, "SECURITY_PATCH");
            let sp = if is_yyyy_mm_dd(&sp) { sp } else { "today".to_string() };
            let (t6, c6) = ensure_patch_object(&text, &sp);
            text = t6;
            let (t7, c7) = set_id(&text, "system", &sp);
            text = t7;
            changed = c1 || c2 || c3 || c4 || c5 || c6 || c7;

            // assert_flags：只动我们自己的载荷（standalone PIF 保持自主）
            if pif_path.starts_with(&format!("{}/modules/aegisfusion_rs/", ctx.adb))
                && pif_path.ends_with(".prop")
            {
                let spoof_conf = format!("{}/spoof.conf", ctx.tee_dir);
                let conf = fs::read_to_string(&spoof_conf).unwrap_or_default();
                let payload = fs::read_to_string(pif_path).unwrap_or_default();
                let mut new_payload = payload.clone();
                let mut flag_changed = false;
                for kv in [
                    ("spoofBuild", "1"),
                    ("spoofProps", "1"),
                    ("spoofVendingFinger", "1"),
                    ("spoofProvider", "0"),
                ] {
                    let mut v = kv.1.to_string();
                    // spoof.conf 的逐键覆盖
                    for cl in conf.lines() {
                        if let Some(rest) = cl.strip_prefix(&format!("{}=", kv.0)) {
                            let o = rest.trim().trim_matches('\r').to_string();
                            if !o.is_empty() {
                                v = o;
                            }
                        }
                    }
                    let mut replaced = false;
                    let mut out_lines: Vec<String> = Vec::new();
                    for pl in new_payload.lines() {
                        if let Some(rest) = pl.strip_prefix(&format!("{}=", kv.0)) {
                            let cur = rest.trim().trim_matches('\r').to_string();
                            if cur == v {
                                out_lines.push(pl.to_string());
                                replaced = true;
                            } else {
                                out_lines.push(format!("{}={}", kv.0, v));
                                replaced = true;
                                flag_changed = true;
                            }
                        } else {
                            out_lines.push(pl.to_string());
                        }
                    }
                    if !replaced {
                        out_lines.push(format!("{}={}", kv.0, v));
                        flag_changed = true;
                    }
                    new_payload = out_lines.join("\n");
                    if new_payload.ends_with('\n') {
                        new_payload.pop();
                    }
                }
                if flag_changed {
                    let _ = fs::write(pif_path, &new_payload);
                    changed = true;
                }
            }
            log_line(&ctx, &format!(
                "PIF active ({}): identity + patchLevel.system mirrored, flags asserted",
                pif_path
            ));
            let _ = fs::write(&synced, "");
        } else {
            log_line(&ctx, &format!(
                "PIF active ({}): mirroring suppressed, payload flags asserted",
                pif_path
            ));
        }
    }

    // ★ 只有 config 真变了才写盘 + bounce（值相等不算改动，幂等）。
    //   shell 版用 sed -i 原地写盘；这里必须显式写回，否则改动只停留在内存。
    if changed {
        let _ = fs::write(&cfg, &text);
        log_dbg(&ctx, "profile/pif changed — bouncing teesim + DroidGuard");
        // teesim daemon：service.sh 的重生循环 ~2s 拉起，重读配置重推
        let _ = Command::new("pidof").arg("teesim").output().map(|o| {
            let pid = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !pid.is_empty() {
                let _ = Command::new("kill").arg(&pid).output();
                log_line(&ctx, "teesim daemon restarted to re-push the synced profile");
            } else {
                log_dbg(&ctx, "teesim not running (respawn loop will pick up the new config)");
            }
        });
        // DroidGuard：回收缓存会话，强制重读（PIF 伪装后的）属性
        let _ = Command::new("pidof")
            .arg("com.google.android.gms.unstable")
            .output()
            .map(|o| {
                let dg = String::from_utf8_lossy(&o.stdout).trim().to_string();
                if !dg.is_empty() {
                    let _ = Command::new("kill").arg(&dg).output();
                    log_line(&ctx, "DroidGuard (gms.unstable) recycled after the profile change");
                } else {
                    log_dbg(&ctx, "gms.unstable not running — nothing to recycle");
                }
            });
        let _ = fs::write(format!("{}/.gms-recycle", ctx.tee_dir), now_epoch().to_string());
    } else {
        log_dbg(&ctx, "profile unchanged — no bounce needed");
    }
    0
}

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn is_yyyy_mm_dd(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 10
        && b[0..4].iter().all(|c| c.is_ascii_digit())
        && b[4] == b'-'
        && b[5..7].iter().all(|c| c.is_ascii_digit())
        && b[7] == b'-'
        && b[8..10].iter().all(|c| c.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_id_replaces_system() {
        let t = r#"{"patchLevel":{"system":"2026-08-01","vendor":"2026-08-01"}}"#;
        let (out, changed) = set_id(t, "system", "2026-09-05");
        assert!(changed, "应当有改动");
        assert!(out.contains("2026-09-05"), "out={out}");
    }
    #[test]
    fn set_id_idempotent() {
        let t = r#"{"system":"2026-09-05"}"#;
        let (out, changed) = set_id(t, "system", "2026-09-05");
        assert!(!changed);
        assert_eq!(out, t);
    }
    #[test]
    fn extracts_patch_from_prop() {
        let t = "SECURITY_PATCH=2026-09-05\nFINGERPRINT=google/x\n";
        // pget 的 prop 路径
        std::fs::write("pif_test.tmp", t).unwrap();
        assert_eq!(pget("pif_test.tmp", "SECURITY_PATCH"), "2026-09-05");
        let _ = std::fs::remove_file("pif_test.tmp");
    }
}
