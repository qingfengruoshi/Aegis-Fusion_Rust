//! ui-probe —— WebUI 数据源（重实现）
//!
//! 契约：`docs/CONTRACT-webui.md` §1（原 `launcher.js` / `logs.js` 的两段内联
//! shell 探针）。JS 侧只消费 `KEY=VALUE` 行，本命令逐键复刻取值来源（§1.4
//! 的逐键表），键集 ⊇ 两页全部 95 键。
//!
//! 两个入口：
//!   `fusionctl ui-probe launcher` —— 仪表盘 37 键（DAEMON 走 /status）
//!   `fusionctl ui-probe logs`     —— 日志页 77 键（DAEMON 走 pidof）
//!
//! 判定规则（§2）在这里是**功能**不是细节：
//!   * KBEV/EISTATE 的陈旧判定 kbhash 优先 / kbtm 兜底（与 engine-verdict show
//!     分支同一规则，三处实现必须一致）；
//!   * KBG 的 -1（渠道未提供状态）与 0（零绿圈）语义不同；
//!   * 用户导入判定：hash ≠ marker 或 kbtm > kbmm。

use std::fs;
use std::path::Path;
use std::process::Command;

struct Ctx {
    tee: String,
    moddir: String,
    proc_name: String,
}

impl Ctx {
    fn elog(&self) -> String {
        format!("{}/log/teesim.log", self.tee)
    }
}

// ---- 与其它入口相同的子进程工具（bash 顺序 PATH 解析 + 脚本回退）-----------

fn which_cmd(name: &str) -> Option<String> {
    let paths = std::env::var("PATH").ok()?;
    let b = paths.as_bytes();
    let mut start = 0usize;
    let mut i = 0usize;
    while i <= b.len() {
        let is_sep = i < b.len()
            && (b[i] == b';'
                || (b[i] == b':' && !(i >= 1 && i + 1 < b.len()
                    && b[i - 1].is_ascii_alphanumeric()
                    && (i == 1 || b[i - 2] == b';' || b[i - 2] == b':')
                    && (b[i + 1] == b'/' || b[i + 1] == b'\\'))));
        if i == b.len() || is_sep {
            let p = &paths[start..i];
            if !p.is_empty() {
                let plain = format!("{p}/{name}");
                if Path::new(&plain).is_file() {
                    return Some(plain);
                }
                let exe = format!("{plain}.exe");
                if Path::new(&exe).is_file() {
                    return Some(exe);
                }
            }
            start = i + 1;
        }
        i += 1;
    }
    None
}

/// 先直接执行；失败（POSIX 脚本桩）回退 `sh <path>`。
fn spawn_out(cmd: &str, args: &[&str]) -> Option<std::process::Output> {
    let resolved = which_cmd(cmd).unwrap_or_else(|| cmd.to_string());
    let mut c = Command::new(&resolved);
    c.args(args);
    if let Ok(o) = c.output() {
        return Some(o);
    }
    let mut c2 = Command::new("sh");
    c2.arg(&resolved).args(args);
    c2.output().ok()
}

fn stdout_of(o: std::process::Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

// ---- 文件/时间小工具 --------------------------------------------------------

fn read_trim(p: &str) -> String {
    fs::read_to_string(p).unwrap_or_default().trim().to_string()
}

fn lines_of(p: &str) -> Vec<String> {
    fs::read_to_string(p)
        .map(|t| t.lines().map(|s| s.to_string()).collect())
        .unwrap_or_default()
}

fn mtime(p: &str) -> u64 {
    fs::metadata(p)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn is_socket(p: &str) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;
        fs::metadata(p).map(|m| m.file_type().is_socket()).unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        let _ = p;
        false
    }
}

fn now_days_to_date(z: u64) -> String {
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

/// 与 shell `stat -c %Y` 一致的十进制秒字符串。
fn mtime_str(p: &str) -> String {
    mtime(p).to_string()
}

// ---- 通用取值 ---------------------------------------------------------------

fn pidof(ctx: &Ctx) -> String {
    spawn_out("pidof", &[&ctx.proc_name])
        .map(|o| stdout_of(o).trim().to_string())
        .unwrap_or_default()
}

fn getprop(prop: &str) -> String {
    spawn_out("getprop", &[prop])
        .map(|o| stdout_of(o).trim().to_string())
        .unwrap_or_default()
}

/// launcher 的 DAEMON：/status 往返成功 → yes（不是 pidof）。
/// 返回 (daemon, hook, dver)。
fn daemon_via_status(ctx: &Ctx) -> (String, String, String) {
    let uds = format!("{}/teesim-uds", ctx.tee);
    let sock = format!("{}/admin.sock", ctx.tee);
    let tok = read_trim(&format!("{}/admin.token", ctx.tee));
    let mut daemon = "no".to_string();
    let mut hook = String::new();
    let mut dver = String::new();
    if is_exe(&uds) && !tok.is_empty() {
        if let Some(o) = spawn_out(&uds, &[&sock, "GET", "/status", &tok]) {
            if o.status.success() {
                daemon = "yes".to_string();
                // shell：tr "{,}" "\n\n" | grep hook | head -n1 | cut -d\" -f4
                let st = stdout_of(o);
                let seg = |key: &str| -> String {
                    st.split(['{', ',', '}'])
                        .find(|s| s.contains(key))
                        .unwrap_or("")
                        .split('"')
                        .nth(3)
                        .unwrap_or("")
                        .to_string()
                };
                hook = seg("hook");
                dver = seg("version");
            }
        }
    }
    (daemon, hook, dver)
}

fn is_exe(p: &str) -> bool {
    Path::new(p).is_file()
}

/// KBEV 的陈旧判定（与 engine-verdict show / logs.js 三处同规则）：
/// kbhash 优先（内容锚），kbtm 仅兜底 2026-09-19 前的记录。
fn verdict_state(ctx: &Ctx) -> (String, String) {
    let st_path = format!("{}/.engine-verdict", ctx.tee);
    let text = fs::read_to_string(&st_path).unwrap_or_default();
    if text.trim().is_empty() {
        return ("unknown".to_string(), String::new());
    }
    let get = |k: &str| -> String {
        text.lines()
            .find_map(|l| l.strip_prefix(k).map(|v| v.to_string()))
            .unwrap_or_default()
    };
    let st = get("state=");
    let rs = get("reason=");
    let rec = get("kbtm=");
    let rech = get("kbhash=");
    let kb = format!("{}/keybox.xml", ctx.tee);
    let cur = mtime_str(&kb);
    let curh = sha256_hex(&kb);
    let stale = if !rech.is_empty() && !curh.is_empty() {
        curh != rech
    } else if !rec.is_empty() {
        cur != rec
    } else {
        false
    };
    if stale {
        ("stale".to_string(), String::new())
    } else {
        (if st.is_empty() { "unknown".to_string() } else { st }, rs)
    }
}

fn sha256_hex(p: &str) -> String {
    use sha2::{Digest, Sha256};
    let data = fs::read(p).unwrap_or_default();
    if data.is_empty() {
        return String::new();
    }
    let mut h = Sha256::new();
    h.update(&data);
    h.finalize().iter().map(|x| format!("{x:02x}")).collect()
}

/// KBCERTS：各 <Certificate> 体（去 PEM 壳、去空白）以 `;` 连接。
fn kb_certs(ctx: &Ctx) -> String {
    let kb = format!("{}/keybox.xml", ctx.tee);
    let raw = match fs::read_to_string(&kb) {
        Ok(t) if !t.is_empty() => t,
        _ => return String::new(),
    };
    let flat: String = raw.chars().filter(|c| *c != '\n' && *c != '\r').collect();
    let mut parts: Vec<String> = Vec::new();
    let mut rest = flat.as_str();
    while let Some(p) = rest.find("<Certificate") {
        let after = &rest[p..];
        let close = match after.find("</Certificate>") {
            Some(c) => c,
            None => break,
        };
        let inner = &after[..close];
        // 去掉开标签本身
        let body = match inner.find('>') {
            Some(g) => &inner[g + 1..],
            None => "",
        };
        let body: String = body
            .chars()
            .filter(|c| !matches!(c, ' ' | '\t'))
            .collect();
        let body = body
            .replace("-----BEGIN CERTIFICATE-----", "")
            .replace("-----END CERTIFICATE-----", "");
        parts.push(body);
        rest = &after[close + "</Certificate>".len()..];
    }
    parts.join(";")
}

/// PIFSRC：候选清单顺序敏感，**含第三方模块路径**（tricky_store 是别人的）。
fn pif_src(ctx: &Ctx) -> String {
    let cands = [
        format!("{}/custom.pif.prop", ctx.moddir),
        format!("{}/custom.pif.json", ctx.moddir),
        "/data/adb/pif.json".to_string(),
        "/data/adb/modules/playintegrityfix/custom.pif.prop".to_string(),
        "/data/adb/modules/playintegrityfix/custom.pif.json".to_string(),
        "/data/adb/modules/playintegrityfix/pif.json".to_string(),
        "/data/adb/modules/playintegrityfork/pif.json".to_string(),
        "/data/adb/modules/Integrity-Box/pif.json".to_string(),
        "/data/adb/modules/tricky_store/pif.json".to_string(),
    ];
    for c in &cands {
        if as_nonempty(c) {
            return c.clone();
        }
    }
    String::new()
}

fn as_nonempty(p: &str) -> bool {
    fs::read(p).map(|v| !v.is_empty()).unwrap_or(false)
}

/// PIFST/PIFD/PIFAUTO：轮换相位。只有自动管理的指纹（.pif-auto 存在且
/// PIFSRC 是我们模块目录的 custom.pif.{prop,json}）才评相位。
fn pif_phase(ctx: &Ctx, pifsrc: &str, now: u64) -> (String, String, String, String) {
    let mut pifauto = "no".to_string();
    let mut pifst = "ok".to_string();
    let mut pifd = "-1".to_string();
    let mut pifexp = String::new();
    let marker = format!("{}/.pif-auto", ctx.moddir);
    let own_prop = format!("{}/custom.pif.prop", ctx.moddir);
    let own_json = format!("{}/custom.pif.json", ctx.moddir);
    if as_nonempty(&marker) && (*pifsrc == own_prop || *pifsrc == own_json) {
        pifauto = "yes".to_string();
        let lines: Vec<String> = fs::read_to_string(&marker)
            .unwrap_or_default()
            .lines()
            .map(|l| l.chars().filter(|c| !matches!(c, ' ' | '\t' | '\r' | '\n')).collect())
            .collect();
        // shell：空/非纯数字 → pb=0；pr 空/非数字 → pb + 1209600（14 天）
        let pb_raw = lines.first().map(|s| s.as_str()).unwrap_or("");
        let pb: u64 = if !pb_raw.is_empty() && pb_raw.bytes().all(|c| c.is_ascii_digit()) {
            pb_raw.parse().unwrap_or(0)
        } else {
            0
        };
        let pr_raw = lines.get(1).map(|s| s.as_str()).unwrap_or("");
        let pr: u64 = if !pr_raw.is_empty() && pr_raw.bytes().all(|c| c.is_ascii_digit()) {
            pr_raw.parse().unwrap_or(pb + 1_209_600)
        } else {
            pb + 1_209_600
        };
        if now >= pr {
            pifst = "expired".to_string();
            pifd = ((now - pr) / 86400).to_string();
        } else if (pr - now) / 86400 <= 7 {
            pifst = "soon".to_string();
            pifd = ((pr - now) / 86400).to_string();
        }
        if !pifsrc.is_empty() {
            for l in lines_of(pifsrc) {
                if let Some(v) = l.strip_prefix("# Estimated Expiry: ") {
                    pifexp = v.chars().filter(|c| *c != '\r').collect();
                    break;
                }
            }
        }
    }
    (pifauto, pifst, pifd, pifexp)
}

// ---- launcher 探针（37 键）--------------------------------------------------

fn probe_launcher(ctx: &Ctx) {
    let tee = &ctx.tee;
    let mut o: Vec<(String, String)> = Vec::new();
    let mut push = |k: &str, v: String| o.push((k.to_string(), v));

    // UID：id -u，失败回退 1
    let uid = spawn_out("id", &["-u"])
        .map(|x| stdout_of(x).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "1".to_string());
    push("UID", uid);

    let (daemon, hook, dver) = daemon_via_status(ctx);
    push("DAEMON", daemon.to_string());
    push("HOOK", hook);
    push("DVER", dver);

    // PG：pidof 旁证（pidof，不是 pgrep -f —— app_process 改写 argv[0]）
    let pg = if pidof(ctx).is_empty() { "no" } else { "yes" };
    push("PG", pg.to_string());

    // DEX：引擎的 dex/apk 在模块目录
    let dex = if Path::new(&format!("{}/teesim-service.dex", ctx.moddir)).is_file()
        || Path::new(&format!("{}/service.apk", ctx.moddir)).is_file()
    {
        "yes"
    } else {
        "no"
    };
    push("DEX", dex.to_string());

    // SOCK：admin socket 文件（[ -S ]）
    let sock = if is_socket(&format!("{}/admin.sock", ctx.tee)) { "yes" } else { "no" };
    push("SOCK", sock.to_string());

    // VER：module.prop 的 version=
    let ver = lines_of(&format!("{}/module.prop", ctx.moddir))
        .into_iter()
        .find(|l| l.starts_with("version="))
        .map(|l| l["version=".len()..].to_string())
        .unwrap_or_default();
    push("VER", ver);

    // KEYBOX：[ -s ]
    let keybox = if as_nonempty(&format!("{tee}/keybox.xml")) { "yes" } else { "no" };
    push("KEYBOX", keybox.to_string());

    // KBMARK：marker 存在 **且** kbmm >= kbtm —— 两条件缺一不可
    let kb_path = format!("{tee}/keybox.xml");
    let marker = format!("{tee}/.auto-keybox");
    let kbtm = mtime(&kb_path);
    let kbmm = mtime(&marker);
    let kbmark = if Path::new(&marker).is_file() && kbmm >= kbtm { "yes" } else { "no" };
    push("KBMARK", kbmark.to_string());

    push("KBSRC", read_trim(&format!("{tee}/.keybox-source")));
    push("KBPREF", lines_of(&format!("{tee}/keybox-source-pref")).first().cloned().unwrap_or_default());

    // REF：空 → 24
    let mut refv = read_trim(&format!("{tee}/keybox-refresh"));
    if refv.is_empty() {
        refv = "24".to_string();
    }
    push("REF", refv);

    // KBG：缺省 -1（≠0：渠道未提供状态 vs 零绿圈，语义不同）
    let kbg_path = format!("{tee}/.key-status-n");
    let kbg = if as_nonempty(&kbg_path) { read_trim(&kbg_path) } else { "-1".to_string() };
    push("KBG", kbg);

    // KBAGE：(.kb-last-fetch mtime，回退 keybox.xml mtime) 距 now，小时
    let now = now();
    let mut mt = mtime(&format!("{tee}/.kb-last-fetch"));
    if mt == 0 {
        mt = mtime(&kb_path);
    }
    let age = if mt > 0 { (now - mt) / 3600 } else { 0 };
    push("KBAGE", age.to_string());

    // KBS：key-status.txt 去掉换行
    let kbs: String = fs::read_to_string(&format!("{tee}/key-status.txt"))
        .unwrap_or_default()
        .chars()
        .filter(|c| *c != '\n')
        .collect();
    push("KBS", kbs);

    // KBERR：keybox-fetch.log 里最后一行含 ERROR，截前 140 字符
    let kberr = lines_of(&format!("{tee}/keybox-fetch.log"))
        .into_iter()
        .filter(|l| l.contains("ERROR"))
        .last()
        .map(|l| l.chars().take(140).collect::<String>())
        .unwrap_or_default();
    push("KBERR", kberr);

    // KBRUN：锁目录（[ -d ]）
    let kbrun = if Path::new(&format!("{tee}/.kb-fetching.lock")).is_dir() { "yes" } else { "no" };
    push("KBRUN", kbrun.to_string());

    // KBEV/KBRS：引擎判定 + 陈旧判定（kbhash 优先）
    let (kbev, kbrs) = verdict_state(ctx);
    push("KBEV", kbev);
    push("KBRS", kbrs);

    // KBPROG/KBPROGT：进度文件 1=epoch 2=阶段 3=详情（` · ` 连接）
    let prog_path = format!("{tee}/.kb-fetch.progress");
    let mut kbprog = String::new();
    let mut kbprogt = "0".to_string();
    if as_nonempty(&prog_path) {
        let pl = lines_of(&prog_path);
        kbprogt = pl.first().cloned().unwrap_or_default();
        let kbp1 = pl.get(1).cloned().unwrap_or_default();
        let kbp2 = pl.get(2).cloned().unwrap_or_default();
        kbprog = if kbp2.is_empty() { kbp1 } else { format!("{kbp1} · {kbp2}") };
    }
    if kbprogt.is_empty() || kbprogt.bytes().any(|c| !c.is_ascii_digit()) {
        kbprogt = "0".to_string();
    }
    push("KBPROG", kbprog);
    push("KBPROGT", kbprogt);

    push("KBCERTS", kb_certs(ctx));

    // REVJ/REVA：吊销缓存
    let revj = if as_nonempty(&format!("{tee}/.revocation-status.json")) { "yes" } else { "no" };
    push("REVJ", revj.to_string());
    let rmtv = mtime(&format!("{tee}/.revocation-status.json"));
    let reva = if rmtv > 0 { (now - rmtv) / 3600 } else { 0 };
    let reva = if rmtv > 0 { reva.to_string() } else { "-1".to_string() };
    push("REVA", reva);

    // BL1-4：bootloader/verified-boot 实况
    push("BL1", getprop("ro.boot.vbmeta.device_state"));
    push("BL2", getprop("ro.boot.verifiedbootstate"));
    push("BL3", getprop("ro.build.tags"));
    push("BL4", getprop("ro.boot.flash.locked"));

    // PIFSRC + ZYG + 相位
    let pifsrc = pif_src(ctx);
    push("PIFSRC", pifsrc.clone());
    let mut zyg = "no".to_string();
    for zm in ["zygisknext", "zygisksu", "rezygisk", "neozygisk"] {
        if Path::new(&format!("/data/adb/modules/{zm}")).is_dir() {
            zyg = "yes".to_string();
        }
    }
    if zyg == "no" {
        // magisk --sqlite 命中 *zygisk|1*
        if let Some(o) = spawn_out(
            "magisk",
            &["--sqlite", "SELECT value FROM settings WHERE key='zygisk'"],
        ) {
            let v = stdout_of(o);
            if v.contains("zygisk") && v.contains('1') {
                zyg = "yes".to_string();
            }
        }
    }
    push("ZYG", zyg);

    let (pifauto, pifst, pifd, pifexp) = pif_phase(ctx, &pifsrc, now);
    push("PIFST", pifst);
    push("PIFD", pifd);
    push("PIFAUTO", pifauto);
    push("PIFEXP", pifexp);

    // PIFPROV/PIFMODEL（R7-1：来源分解）
    push(
        "PIFPROV",
        lines_of(&format!("{tee}/.pif-source"))
            .first()
            .map(|l| l.chars().filter(|c| !matches!(c, ' ' | '\t' | '\r' | '\n')).collect())
            .unwrap_or_default(),
    );
    push(
        "PIFMODEL",
        lines_of(&format!("{}/custom.pif.prop", ctx.moddir))
            .into_iter()
            .filter(|l| l.starts_with("MODEL="))
            .map(|l| l["MODEL=".len()..].chars().filter(|c| *c != '\r').collect::<String>())
            .next()
            .unwrap_or_default(),
    );

    for (k, v) in &o {
        println!("{k}={v}");
    }
    let _ = now_days_to_date(0);
}


// ---- logs 探针（77 键；输出顺序按原脚本的 echo 顺序，含中段插印的
// ET1ALL/ET0ALL 与 EIREASON/EISTATE/EIHIST）------------------------------

fn count_lines_containing(elog: &str, pat: &str) -> u64 {
    lines_of(elog).into_iter().filter(|l| l.contains(pat)).count() as u64
}

/// `grep -cE "p1|p2"`：任一模式命中即计一行。
fn count_lines_any(elog: &str, pats: &[&str]) -> u64 {
    lines_of(elog).into_iter().filter(|l| pats.iter().any(|p| l.contains(p))).count() as u64
}

fn mounts_file() -> String {
    // 测试接缝：宿主上 Windows 侧读不到 MSYS 的 /proc/self/mounts，
    // harness 把 shell 侧看到的快照经 AEGIS_MOUNTS_FILE 喂给 rust。
    std::env::var("AEGIS_MOUNTS_FILE").unwrap_or_else(|_| "/proc/self/mounts".to_string())
}

fn probe_logs(ctx: &Ctx) {
    let tee = &ctx.tee;
    let elog = ctx.elog();
    let kb = format!("{tee}/keybox.xml");
    let now = now();
    let mut o: Vec<(String, String)> = Vec::new();
    let mut push = |k: &str, v: String| o.push((k.to_string(), v));

    let uid = spawn_out("id", &["-u"])
        .map(|x| stdout_of(x).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "1".to_string());
    let ver = lines_of(&format!("{}/module.prop", ctx.moddir))
        .into_iter()
        .find(|l| l.starts_with("version="))
        .map(|l| l["version=".len()..].to_string())
        .unwrap_or_default();
    let arel = getprop("ro.build.version.release");
    let api = getprop("ro.build.version.sdk");
    let model = getprop("ro.product.model");
    let abi = getprop("ro.product.cpu.abi");
    // shell 是三条独立 if 顺序覆盖：最后命中的赢
    let mut mgr = "unknown".to_string();
    if Path::new("/data/adb/ksu").is_dir() {
        mgr = "KernelSU".to_string();
    }
    if Path::new("/data/adb/ap").is_dir() {
        mgr = "APatch".to_string();
    }
    if Path::new("/data/adb/magisk").is_dir() {
        mgr = "Magisk".to_string();
    }
    let keybox = if as_nonempty(&kb) { "yes" } else { "no" };
    let kbsha: String = sha256_hex(&kb).chars().take(12).collect();
    let kbmark = if Path::new(&format!("{tee}/.auto-keybox")).is_file() { "yes" } else { "no" };

    // 结构校验：跑 keybox-check --quiet 只看退出码（na = 校验器缺失）
    let kbc = format!("{}/keybox-check.sh", ctx.moddir);
    let mut kbchk = "na".to_string();
    if Path::new(&kbc).is_file() {
        let rc = spawn_out("sh", &[&kbc, &kb, "--quiet"])
            .map(|x| x.status.code().unwrap_or(-1))
            .unwrap_or(-1);
        kbchk = if rc == 0 { "ok" } else { "bad" }.to_string();
    }
    let kbbad = if Path::new(&format!("{tee}/.keybox-bad")).is_file() { "yes" } else { "no" };
    let kblink = if Path::new(&kb).is_symlink() {
        fs::read_link(&kb).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
    } else {
        "no".to_string()
    };
    let mut refv = read_trim(&format!("{tee}/keybox-refresh"));
    if refv.is_empty() {
        refv = "24".to_string();
    }
    // ⚠️ 与 launcher 不同：这里 **无 -1 缺省**（缺失 = 空串）
    let kbg = read_trim(&format!("{tee}/.key-status-n"));
    let mt = mtime(&kb);
    let age = if mt > 0 { (now - mt) / 3600 } else { 0 };
    let kbrun = if Path::new(&format!("{tee}/.kb-fetching.lock")).is_dir() { "yes" } else { "no" };
    let mut kbrunm = "0".to_string();
    if kbrun == "yes" {
        let lmt = mtime(&format!("{tee}/.kb-fetching.lock"));
        if lmt > 0 {
            kbrunm = ((now - lmt) / 60).to_string();
        }
    }
    let revj = if as_nonempty(&format!("{tee}/.revocation-status.json")) { "yes" } else { "no" };
    let rmtv = mtime(&format!("{tee}/.revocation-status.json"));
    let reva = if rmtv > 0 { (now - rmtv) / 3600 } else { 0 };
    let reva = if rmtv > 0 { reva.to_string() } else { "-1".to_string() };

    // PIFSRC：logs 页的候选清单比 launcher 多两项（pif.prop / pif.json）
    let pifsrc = {
        let cands = [
            format!("{}/custom.pif.prop", ctx.moddir),
            format!("{}/custom.pif.json", ctx.moddir),
            format!("{}/pif.prop", ctx.moddir),
            format!("{}/pif.json", ctx.moddir),
            "/data/adb/pif.json".to_string(),
            "/data/adb/modules/playintegrityfix/custom.pif.prop".to_string(),
            "/data/adb/modules/playintegrityfix/custom.pif.json".to_string(),
            "/data/adb/modules/playintegrityfix/pif.json".to_string(),
            "/data/adb/modules/playintegrityfork/pif.json".to_string(),
            "/data/adb/modules/Integrity-Box/pif.json".to_string(),
            "/data/adb/modules/tricky_store/pif.json".to_string(),
        ];
        cands.into_iter().find(|c| as_nonempty(c)).unwrap_or_default()
    };
    let mut zyg = "no".to_string();
    for zm in ["zygisknext", "zygisksu", "rezygisk", "neozygisk"] {
        if Path::new(&format!("/data/adb/modules/{zm}")).is_dir() {
            zyg = "yes".to_string();
        }
    }
    if zyg == "no" {
        if let Some(o) = spawn_out("magisk", &["--sqlite", "SELECT value FROM settings WHERE key='zygisk'"]) {
            let v = stdout_of(o);
            if v.contains("zygisk") && v.contains('1') {
                zyg = "yes".to_string();
            }
        }
    }

    // DAEMON：pidof（⚠️ 与 launcher 的 /status 判定不同——契约 §1.5）
    let dp = pidof(ctx);
    let daemon = if dp.is_empty() { "stopped" } else { "running" };
    let ctlsock = if Path::new("/data/misc/keystore/.teesim-ctl").exists() { "present" } else { "missing" };
    // INJECTED/PIFMAP：无 keystore2/GMS 进程 → -1（桩环境即此）
    let kpid = spawn_out("pidof", &["keystore2"])
        .map(|x| stdout_of(x).lines().next().unwrap_or("").trim().to_string())
        .unwrap_or_default();
    let inj = if kpid.is_empty() {
        "-1".to_string()
    } else {
        lines_of(&format!("/proc/{kpid}/maps"))
            .into_iter()
            .filter(|l| l.contains("libteesim"))
            .count()
            .to_string()
    };
    let modid = Path::new(&ctx.moddir)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let gp = spawn_out("pidof", &["com.google.android.gms"])
        .map(|x| stdout_of(x).lines().next().unwrap_or("").trim().to_string())
        .unwrap_or_default();
    let pifmap = if gp.is_empty() {
        "-1".to_string()
    } else {
        lines_of(&format!("/proc/{gp}/maps"))
            .into_iter()
            .filter(|l| l.contains(&modid))
            .count()
            .to_string()
    };

    // 引擎轨迹计数
    let elogsz = fs::metadata(&elog).map(|m| m.len()).unwrap_or(0);
    let epush = count_lines_containing(&elog, "control: pushed config");
    let eack = count_lines_containing(&elog, "control: ack");
    let estaged = count_lines_containing(&elog, "cfg: staged profile");
    let ebuild = count_lines_containing(&elog, "failed to build");
    let enever = count_lines_containing(&elog, "never pushed a config");
    let eresolve = count_lines_any(&elog, &["Failed to resolve/push config", "No valid config to push"]);
    let et1all = count_lines_containing(&elog, "target=1");
    let et0all = count_lines_containing(&elog, "target=0");
    // Era split（v3.1.5）：从最后一次 ack 的**行号**起算——上一次 keybox 的
    // 计数不混进来；ET1ALL/ET0ALL 保留终生值
    let mut et1 = "0".to_string();
    let mut et0 = "0".to_string();
    let eackno: usize = lines_of(&elog)
        .into_iter()
        .enumerate()
        .filter(|(_, l)| l.contains("control: ack"))
        .last()
        .map(|(i, _)| i + 1)
        .unwrap_or(0);
    if eackno > 0 {
        let all = lines_of(&elog);
        let tail = &all[eackno - 1..];
        et1 = tail.iter().filter(|l| l.contains("target=1")).count().to_string();
        et0 = tail.iter().filter(|l| l.contains("target=0")).count().to_string();
    }
    let grab_last = |pat: &str| -> String {
        lines_of(&elog)
            .into_iter()
            .filter_map(|l| {
                // grep -o "applied=[0-9]*" | tail -1 —— 每行取最后一个匹配
                let mut last = String::new();
                let mut rest = l.as_str();
                while let Some(p) = rest.find(pat) {
                    let tail = &rest[p + pat.len()..];
                    let digits: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
                    if !digits.is_empty() {
                        last = format!("{pat}{digits}");
                    }
                    rest = &tail[digits.len()..];
                }
                if last.is_empty() { None } else { Some(last) }
            })
            .last()
            .map(|m| m[pat.len()..].to_string())
            .unwrap_or_else(|| "-1".to_string())
    };
    let eapp = grab_last("applied=");
    let efail = grab_last("failed=");

    // 引擎判定 + 锚定（v3.1.5）：权威是 .engine-verdict；原始日志行只作 EIHIST
    let ev_text = fs::read_to_string(&format!("{tee}/.engine-verdict")).unwrap_or_default();
    let ev_get = |k: &str| -> String {
        ev_text
            .lines()
            .find_map(|l| l.strip_prefix(k).map(|v| v.to_string()))
            .unwrap_or_default()
    };
    let eistate = if as_nonempty(&format!("{tee}/.engine-verdict")) { ev_get("state=") } else { String::new() };
    let evr = ev_get("reason=");
    let ehist = lines_of(&elog)
        .into_iter()
        .filter(|l| l.contains("teesim_km_init_ex:"))
        .last()
        .map(|l| match l.rfind("teesim_km_init_ex: ") {
            Some(idx) => l[idx + "teesim_km_init_ex: ".len()..].to_string(),
            None => l.clone(),
        })
        .unwrap_or_default();
    let efail_n: i64 = efail.parse().unwrap_or(-1);
    let eireason = match eistate.as_str() {
        "rejected" | "partial" => evr,
        _ => {
            if efail_n > 0 {
                ehist.clone()
            } else {
                String::new()
            }
        }
    };

    // 进度文件（同 launcher）
    let prog_path = format!("{tee}/.kb-fetch.progress");
    let mut kbprog = String::new();
    let mut kbprogt = "0".to_string();
    if as_nonempty(&prog_path) {
        let pl = lines_of(&prog_path);
        kbprogt = pl.first().cloned().unwrap_or_default();
        let kbp1 = pl.get(1).cloned().unwrap_or_default();
        let kbp2 = pl.get(2).cloned().unwrap_or_default();
        kbprog = if kbp2.is_empty() { kbp1 } else { format!("{kbp1} · {kbp2}") };
    }
    if kbprogt.is_empty() || kbprogt.bytes().any(|c| !c.is_ascii_digit()) {
        kbprogt = "0".to_string();
    }

    // ⚠️ 输出顺序 = 原脚本 echo 顺序（ET1ALL/ET0ALL 与 EIREASON/EISTATE/EIHIST
    // 是计算段中段插印的，先于主块）
    push("ET1ALL", et1all.to_string());
    push("ET0ALL", et0all.to_string());
    push("EIREASON", eireason);
    push("EISTATE", eistate);
    push("EIHIST", ehist);
    push("KBPROG", kbprog);
    push("KBPROGT", kbprogt);
    push("UID", uid);
    push("VER", ver);
    push("AREL", arel);
    push("API", api);
    push("MODEL", model);
    push("ABI", abi);
    push("MGR", mgr);
    push("DAEMON", daemon.to_string());
    push("CTL_SOCK", ctlsock.to_string());
    push("INJECTED", inj);
    push("PIFMAP", pifmap);
    push("KBCHK", kbchk.to_string());
    push("KBBAD", kbbad.to_string());
    push("KBLINK", kblink);
    push("ELOGSZ", elogsz.to_string());
    push("EPUSH", epush.to_string());
    push("EACK", eack.to_string());
    push("ESTAGED", estaged.to_string());
    push("EBUILD", ebuild.to_string());
    push("ENEVER", enever.to_string());
    push("ERESOLVE", eresolve.to_string());
    push("ET1", et1);
    push("ET0", et0);
    push("EAPP", eapp);
    push("EFAIL", efail);
    push("KEYBOX", keybox.to_string());
    push("KBSHA", kbsha);
    push("KBMARK", kbmark.to_string());
    push("REF", refv);
    push("KBG", kbg);
    push("KBAGE", age.to_string());
    push("KBRUN", kbrun.to_string());
    push("KBRUNM", kbrunm.to_string());
    push("REVJ", revj.to_string());
    push("REVA", reva);
    let dbg = if Path::new(&format!("{tee}/.debug")).is_file() { "yes" } else { "no" };
    push("DBG", dbg.to_string());
    push("PIFSRC", pifsrc.clone());
    push("ZYG", zyg);

    let (pifauto, pifst, pifd, pifexp) = pif_phase(ctx, &pifsrc, now);
    // logs 页的 pifexp 多一层日期格式白名单
    let pifexp = if pifexp.len() == 10
        && pifexp.as_bytes()[4] == b'-'
        && pifexp.as_bytes()[7] == b'-'
        && pifexp.bytes().all(|c| c.is_ascii_digit() || c == b'-')
    {
        pifexp
    } else {
        String::new()
    };
    push("PIFST", pifst);
    push("PIFD", pifd);
    push("PIFAUTO", pifauto);
    push("PIFEXP", pifexp);
    let piffail = lines_of(&format!("{tee}/pif-fetch.log"))
        .into_iter()
        .filter(|l| l.contains("generation failed"))
        .last()
        .unwrap_or_default();
    push("PIFFAIL", piffail);
    push(
        "PF_OFF",
        if Path::new(&format!("{tee}/.pif-off")).is_file() { "yes" } else { "no" }.to_string(),
    );
    push(
        "PF_SYNCOFF",
        if Path::new(&format!("{tee}/.pif-sync-off")).is_file() { "yes" } else { "no" }.to_string(),
    );
    push("SW_PATCH", getprop("ro.build.version.security_patch"));
    push("VEN_PATCH", getprop("ro.vendor.build.version.security_patch"));

    // CFG_*：10 个动态键（grep -o '"ck":…' 的第一个匹配，剥壳取值）
    let cfg = fs::read_to_string(&format!("{tee}/config.json")).unwrap_or_default();
    for ck in [
        "mode",
        "osVersion",
        "system",
        "vendor",
        "boot",
        "brand",
        "device",
        "product",
        "manufacturer",
        "model",
    ] {
        let needle = format!("\"{ck}\"");
        let cv = match cfg.find(&needle) {
            Some(p) => {
                let rest = &cfg[p..];
                match rest.find(',') {
                    Some(c) => &rest[..c],
                    None => rest,
                }
            }
            None => "",
        };
        // sed 's/.*:[[:space:]]*"//;s/"$//'
        let cv = match cv.find(':') {
            Some(c) => cv[c + 1..].trim().trim_matches('"').to_string(),
            None => String::new(),
        };
        let key = format!("CFG_{}", ck.to_uppercase());
        push(&key, cv);
    }

    push("BL_VBMETA", getprop("ro.boot.vbmeta.device_state"));
    push("BL_VBVENDOR", getprop("vendor.boot.vbmeta.device_state"));
    push("BL_VBOOT", getprop("ro.boot.verifiedbootstate"));
    push("BL_FLASH", getprop("ro.boot.flash.locked"));
    push("BL_VERITY", getprop("ro.boot.veritymode"));
    push("BL_LOCKSTATE", getprop("ro.secureboot.lockstate"));
    push("BL_TAGS", getprop("ro.build.tags"));
    push("BL_BTYPE", getprop("ro.build.type"));
    push("BL_DEBUGGABLE", getprop("ro.debuggable"));
    push("BL_OEMUNLOCK", getprop("sys.oem_unlock_allowed"));

    let mntf = mounts_file();
    let mnt = lines_of(&mntf);
    push("MNT_TOTAL", mnt.len().to_string());
    let adb: Vec<String> = mnt.into_iter().filter(|l| l.contains("/data/adb")).collect();
    push("MNT_ADB", adb.len().to_string());
    let mut pts: Vec<String> = adb
        .iter()
        .filter_map(|l| l.split(' ').nth(1).map(|s| s.to_string()))
        .collect();
    pts.sort();
    pts.dedup();
    pts.truncate(5);
    push("MNT_ADB_PATHS", pts.join("|"));

    for (k, v) in &o {
        println!("{k}={v}");
    }
}


// ---- 入口 -------------------------------------------------------------------

pub fn run(args: &[String]) -> i32 {
    let ctx = Ctx {
        tee: std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string()),
        moddir: std::env::var("AEGIS_MODDIR")
            .unwrap_or_else(|_| "/data/adb/modules/aegisfusion_rs".to_string()),
        proc_name: std::env::var("AEGIS_PROC").unwrap_or_else(|_| "teesim".to_string()),
    };
    match args.first().map(String::as_str) {
        Some("launcher") => {
            probe_launcher(&ctx);
            0
        }
        Some("logs") => {
            probe_logs(&ctx);
            0
        }
        other => {
            eprintln!("usage: fusionctl ui-probe launcher|logs (got: {other:?})");
            2
        }
    }
}
