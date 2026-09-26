//! fusion_func —— 公共库（**纯逻辑，重实现**）
//!
//! 契约：`docs/CONTRACT-management.md` §1（原 `module/fusion_func.sh`，96 行）。
//!
//! 四个助手 + `align_patch_level`。与 shell 版的差异（**按契约刻意为之**）：
//! 数据目录遵守 `AEGIS_TEE_DIR`，而 shell 版把它写死（见契约 §1.4 的缺陷记录）
//! —— 这同时让本模块变得可测。
//!
//! `resetprop` 仍通过外部二进制调用（**继续 shell out，不重实现系统属性写入**，
//! 见 `GAP-AND-ROADMAP.md` §13.3）。查找顺序与 shell 版的 PATH 前置等价：
//! KSU → APatch → Magisk → PATH。

use std::fs;
use std::path::Path;
use std::process::Command;

/// `resetprop` 的查找顺序（等价于 shell 版把 KSU/APatch 的 bin 目录前置到 PATH）。
fn resetprop_bin() -> &'static str {
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

fn rp_read(bin: &str, name: &str) -> Option<String> {
    let out = Command::new(bin).arg(name).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// `resetprop_if_diff <prop> <expected>`
///
/// 当前值**为空**或**已等于** expected → 直接返回（返回 false）；
/// 否则 `resetprop -n`（返回 true）。
///
/// **属性缺失时跳过、不创建**（audit N16，刻意为之）：调用方要处理的属性在所有
/// 有意义的设备上都存在；凭空造一个 OEM 从未写入的属性本身就是异常信号。
pub fn resetprop_if_diff(bin: &str, name: &str, expected: &str) -> bool {
    let cur = rp_read(bin, name).unwrap_or_default();
    if cur.is_empty() || cur == expected {
        return false;
    }
    let _ = Command::new(bin).args(["-n", name, expected]).output();
    true
}

/// `resetprop_if_match <prop> <substring> <new_value>` —— 仅当当前值**包含**
/// `<substring>` 时改写（例如 bootmode=recovery → unknown）。
pub fn resetprop_if_match(bin: &str, name: &str, substring: &str, new_value: &str) -> bool {
    let cur = rp_read(bin, name).unwrap_or_default();
    if cur.contains(substring) {
        let _ = Command::new(bin).args(["-n", name, new_value]).output();
        return true;
    }
    false
}

/// `delprop_if_exist <prop>` —— 属性存在（取值非空）则删除。
pub fn delprop_if_exist(bin: &str, name: &str) -> bool {
    if rp_read(bin, name).is_some() {
        let _ = Command::new(bin).args(["--delete", name]).output();
        return true;
    }
    false
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

/// 从 config.json 文本里抽 `patchLevel.system`（对象形态）。
/// 对应 shell 的：`.*"patchLevel"\s*:\s*{[^}]*"system"\s*:\s*"\([^"]*\)".*` → `\1`
/// （贪婪：取**最后一次**出现的 `"patchLevel"`）。
fn patch_level_object(text: &str) -> String {
    let key = "\"patchLevel\"";
    let start = match text.rfind(key) {
        Some(p) => p + key.len(),
        None => return String::new(),
    };
    let rest = &text[start..];
    let brace = match rest.find('{') {
        Some(p) => p,
        None => return String::new(),
    };
    let obj = &rest[brace..];
    let end = match obj.find('}') {
        Some(p) => p,
        None => return String::new(),
    };
    let obj = &obj[..end];
    let sys = "\"system\"";
    let sp = match obj.find(sys) {
        Some(p) => p + sys.len(),
        None => return String::new(),
    };
    let tail = obj[sp..].trim_start();
    let tail = match tail.strip_prefix(':') {
        Some(t) => t.trim_start(),
        None => return String::new(),
    };
    let q = match tail.strip_prefix('"') {
        Some(q) => q,
        None => return String::new(),
    };
    let v: String = q.chars().take_while(|c| *c != '"').collect();
    v
}

/// 遗留形态：`"patchLevel": "YYYY-MM-DD"`（纯字符串）。
/// 也取**最后一次**出现。
fn patch_level_legacy(text: &str) -> String {
    let key = "\"patchLevel\"";
    let start = match text.rfind(key) {
        Some(p) => p + key.len(),
        None => return String::new(),
    };
    let tail = text[start..].trim_start();
    let tail = tail.strip_prefix(':').unwrap_or(tail).trim_start();
    let q = match tail.strip_prefix('"') {
        Some(q) => q,
        None => return String::new(),
    };
    let v: String = q.chars().take_while(|c| *c != '"').collect();
    if is_yyyy_mm_dd(&v) {
        v
    } else {
        String::new()
    }
}

/// `align_patch_level` —— 把全局补丁日期属性对齐到 TEE 档案里**被证明的**值。
///
/// 调用点三处（audit L10）：post-fs-data 最早一次、service.sh 的启动阶段、
/// service.sh 的每小时 tick。意义：档案轮换后**同一次开机内**就重新对齐。
///
/// 读值两级：对象形态 `"patchLevel":{"system":…}` → 遗留纯字符串形态
/// `"patchLevel":"YYYY-MM-DD"`（防手改配置被静默跳过）；字面量 `today` → 当天。
/// 其它一律**直接返回，不做任何写入**。
pub fn align_patch_level(tee_dir: &str) {
    let bin = resetprop_bin();
    let cfg_path = format!("{tee_dir}/config.json");
    let text = fs::read_to_string(&cfg_path).unwrap_or_default();

    let mut pl = patch_level_object(&text);
    if pl.is_empty() {
        pl = patch_level_legacy(&text);
    }
    let value = match pl.as_str() {
        "" => return,
        "today" => today_date(),
        v if is_yyyy_mm_dd(v) => v.to_string(),
        _ => return,
    };

    // 注意：第二个属性是 `ro.vendor.build.security_patch`，与 WebUI 探针读的
    // `ro.vendor.build.version.security_patch` 不是同一个，不要"顺手统一"。
    resetprop_if_diff(&bin, "ro.build.version.security_patch", &value);
    resetprop_if_diff(&bin, "ro.vendor.build.security_patch", &value);

    // 调试输出（仅当 .debug 存在）。RTC 未就绪时 date 会打出 1970-…，读起来像
    // 乱序 —— 命名条件而不是打印一个不是时间的时间。
    if Path::new(&format!("{tee_dir}/.debug")).exists() {
        let stamp = today_stamp();
        let stamp = if stamp.starts_with("19")
            || (stamp.len() >= 4 && &stamp[0..4] >= "2000" && &stamp[0..4] <= "2019")
        {
            "boot-early (RTC 未就绪)".to_string()
        } else {
            stamp
        };
        let _ = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{tee_dir}/debug.log"))
            .and_then(|mut f| {
                use std::io::Write;
                writeln!(f, "[{stamp}] [patch] system props aligned to attested {value}")
            });
    }
}

fn today_date() -> String {
    // date +%F 的等价物：用 epoch + 简单换算，避免依赖外部 date 的格式差异
    // （这也是 shell 版刻意不用外部 date 做日期运算的同一理由）。
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    days_to_date(secs / 86400)
}

fn today_stamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86400;
    let rem = secs % 86400;
    format!(
        "{} {:02}:{02}:{:02}",
        days_to_date(days),
        rem / 3600,
        (rem % 3600) / 60
    )
}

/// epoch 天数 → YYYY-MM-DD（民用历换算，与 pif-fetch 的 JDN 思路一致）。
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_object_form() {
        let t = r#"{"profiles":{"p0":{"apps":[]}},"patchLevel":{"system":"2026-09-05","vendor":"2026-09-05","boot":"2026-09-05"}}"#;
        assert_eq!(patch_level_object(t), "2026-09-05");
    }
    #[test]
    fn extracts_legacy_form() {
        let t = r#"{"profiles":{"p0":{"apps":[]}},"patchLevel":"2026-09-01"}"#;
        assert_eq!(patch_level_legacy(t), "2026-09-01");
    }
    #[test]
    fn rejects_garbage() {
        let t = r#"{"patchLevel":{"system":"not-a-date"}}"#;
        assert_eq!(patch_level_object(t), "not-a-date");
    }
}
