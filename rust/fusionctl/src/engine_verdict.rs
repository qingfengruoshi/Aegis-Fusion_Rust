//! engine-verdict —— 引擎对已部署 keybox 的判定（**纯逻辑，重实现**）
//!
//! 契约：`docs/CONTRACT-verdict-keybox.md`（原 `module/engine-verdict.sh`，389 行）。
//!
//! 本模块移植了 `once` / `watch` / `show` / `reason` / `socket-live` 全部子命令
//! 与状态文件。`watch` 的 SILENT 尾部输出复用 `engine_check::mask_ids`。
//!
//! 退出码：0 = accepted（applied>0, failed=0）| 1 = rejected/partial | 2 = 无 verdict
//! 状态文件 `$TEE_DIR/.engine-verdict` 的键序与字段名与 shell 版逐字一致。

use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;
use std::process::Command;

// ---------------------------------------------------------------------------
// 上下文
// ---------------------------------------------------------------------------

struct Ctx {
    tee_dir: String,
}

impl Ctx {
    fn elog(&self) -> String {
        format!("{}/log/teesim.log", self.tee_dir)
    }
    fn kb(&self) -> String {
        format!("{}/keybox.xml", self.tee_dir)
    }
    fn state(&self) -> String {
        format!("{}/.engine-verdict", self.tee_dir)
    }
}

fn read_bytes(p: &str) -> Vec<u8> {
    fs::read(p).unwrap_or_default()
}

fn log_size(elog: &str) -> u64 {
    fs::metadata(elog).map(|m| m.len()).unwrap_or(0)
}

fn kb_mtime(kb: &str) -> u64 {
    fs::metadata(kb)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// 内容锚点（2026-09-19）：sha256 变化 = 引擎会看到不同字节。
/// 取不到（无文件 / 无 hash）时返回空串，读取方回退 kbtm。
fn kb_hash(kb: &str) -> String {
    let data = fs::read(kb).unwrap_or_default();
    if data.is_empty() {
        return String::new();
    }
    let mut h = Sha256::new();
    h.update(&data);
    format!("{:x}", h.finalize())
}

/// 引擎自己的话 —— 「这个 keybox 为什么坏」的唯一权威答案。
/// 三级回退：`teesim_km_init_ex:` → `Failed to resolve/push config` → `No valid config to push`。
/// 截断到 220 字符并剥掉 \r\n。
fn engine_reason(elog: &str) -> String {
    let text = String::from_utf8_lossy(&read_bytes(elog)).into_owned();
    let picks = [
        ("teesim_km_init_ex:", "teesim_km_init_ex: "),
        ("Failed to resolve/push config", "TEESimulator: "),
        ("No valid config to push", "TEESimulator: "),
    ];
    for (needle, prefix) in picks {
        let hit = text
            .lines()
            .filter(|l| l.contains(needle))
            .last()
            .map(|l| l.to_string());
        if let Some(l) = hit {
            // shell 的 `sed 's/.*<prefix> *//'` 是**贪婪**的：剥到最后一次出现
            let r = match l.rfind(prefix) {
                Some(p) => l[p + prefix.len()..].to_string(),
                None => l.clone(),
            };
            let r = r.replace(['\r', '\n'], "");
            return r.chars().take(220).collect();
        }
    }
    String::new()
}

/// 日志里最后一条 `control: ack` 行（整行）。
fn latest_ack(elog: &str) -> String {
    let text = String::from_utf8_lossy(&read_bytes(elog)).into_owned();
    text.lines().filter(|l| l.contains("control: ack")).last().unwrap_or("").to_string()
}

/// `verdict_from <chunk>`：解析 chunk 里最新的 ack 并判定。
/// 返回 (rc, ACK_LINE, applied, failed)。rc=3 表示 chunk 里没有 ack。
/// **刻意解析计数而非匹配行**：单行匹配会把 partial 当成 through。
fn verdict_from(chunk: &str) -> (i32, String, String, String) {
    let lastack = chunk.lines().filter(|l| l.contains("control: ack")).last();
    let lastack = match lastack {
        Some(l) => l.to_string(),
        None => return (3, String::new(), String::new(), String::new()),
    };
    let grab = |key: &str| -> String {
        // sed -n 's/.*applied=\([0-9]*\).*/\1/p' —— 取最后一个出现的数字
        let mut out = String::new();
        let mut rest = lastack.as_str();
        while let Some(p) = rest.find(key) {
            let tail = &rest[p + key.len()..];
            let digits: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
            if !digits.is_empty() {
                out = digits.clone();
            }
            rest = &tail[digits.len()..];
        }
        out
    };
    let app = grab("applied=");
    let flr = grab("failed=");
    let app = if app.is_empty() { "-1".to_string() } else { app };
    let flr = if flr.is_empty() { "-1".to_string() } else { flr };
    let a: i64 = app.parse().unwrap_or(-1);
    let f: i64 = flr.parse().unwrap_or(-1);
    let rc = if a == 0 {
        1
    } else if a > 0 && f > 0 {
        1
    } else if a > 0 {
        0
    } else {
        2
    };
    (rc, lastack, app, flr)
}

/// `write_state`：reason **只在拒绝时**记录（engine_reason 读的是全轨迹里最新的
/// 错误，可能早于当前 keybox —— 把它带到 ok 判定旁会显示陈旧抱怨）。
fn write_state(ctx: &Ctx, state: &str, applied: &str, failed: &str, ack_line: &str) {
    let reason = match state {
        "rejected" | "partial" => engine_reason(&ctx.elog()),
        _ => String::new(),
    };
    let body = format!(
        "state={state}\nreason={reason}\nack_applied={applied}\nack_failed={failed}\nack={ack_line}\nkbtm={}\n{}ts={}\n",
        kb_mtime(&ctx.kb()),
        match kb_hash(&ctx.kb()) {
            h if h.is_empty() => String::new(),
            h => format!("kbhash={h}\n"),
        },
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
    );
    let tmp = format!("{}.tmp", ctx.state());
    if fs::write(&tmp, body).is_ok() {
        let _ = fs::rename(&tmp, ctx.state());
    }
}

/// admin socket 上的 push/ack 状态（补丁 0007 的 /status 字段）。
/// 输出 `push=…` `ack=…` `applied=…` `failed=…` 四行，取不到则 None。
fn socket_ack_state(ctx: &Ctx) -> Option<String> {
    let uds = format!("{}/teesim-uds", ctx.tee_dir);
    let sock = format!("{}/admin.sock", ctx.tee_dir);
    let tok = format!("{}/admin.token", ctx.tee_dir);
    if !is_exe(&uds) || !Path::new(&sock).exists() {
        return None;
    }
    let token = fs::read_to_string(&tok).ok()?;
    if token.trim().is_empty() {
        return None;
    }
    // 直接 exec 失败（Windows 宿主上 UDS 桩是脚本）→ 回退 `sh <path>`；
    // 设备侧二进制/脚本均直接执行成功，不受影响。
    let out = match Command::new(&uds)
        .args([&sock, "GET", "/status", token.trim()])
        .output()
    {
        Ok(o) => o,
        Err(_) => Command::new("sh")
            .arg(&uds)
            .args([&sock, "GET", "/status", token.trim()])
            .output()
            .ok()?,
    };
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let grab = |obj: &str, field: &str| -> Option<String> {
        // '"push":{…}' / '"ack":{…}' 里抓 '"last":[0-9]+' 等
        let ostart = text.find(obj)?;
        let oend = text[ostart..].find('}')? + ostart;
        let seg = &text[ostart..oend];
        let fstart = seg.find(field)?;
        let tail = &seg[fstart + field.len()..];
        let tail = tail.trim_start_matches([':', ' ', '"']);
        let digits: String = tail
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '-')
            .collect();
        if digits.is_empty() {
            None
        } else {
            Some(digits)
        }
    };
    let spe = grab("\"push\"", "\"last\"")?;
    if spe.is_empty() || spe == "0" {
        return None;
    }
    let sae = grab("\"ack\"", "\"last\"").unwrap_or_else(|| "0".to_string());
    let sap = grab("\"ack\"", "\"applied\"").unwrap_or_else(|| "-1".to_string());
    let sfl = grab("\"ack\"", "\"failed\"").unwrap_or_else(|| "-1".to_string());
    Some(format!("push={spe}\nack={sae}\napplied={sap}\nfailed={sfl}"))
}

fn is_exe(p: &str) -> bool {
    Path::new(p).is_file()
}

/// `socket_verdict`：当 daemon 对**当前** push 报告了 ack 时返回 Some((rc, applied, failed, line))。
/// keybox 的内容锚点在这里**不适用**：该状态描述的是 daemon 此刻正在服务的 config。
fn socket_verdict(ctx: &Ctx) -> Option<(i32, String, String, String)> {
    let s = socket_ack_state(ctx)?;
    let get = |k: &str| -> String {
        s.lines()
            .find_map(|l| l.strip_prefix(k).map(|v| v.to_string()))
            .unwrap_or_default()
    };
    let spe = get("push=");
    let sae = get("ack=");
    let sap = get("applied=");
    let sfl = get("failed=");
    if sae.is_empty() || spe.is_empty() {
        return None;
    }
    let sae_n: i64 = sae.parse().unwrap_or(-1);
    let spe_n: i64 = spe.parse().unwrap_or(-1);
    if sae_n < spe_n {
        return None; // 最后一次 ack 早于最后一次 push
    }
    let line = format!("socket: ack epoch={sae} applied={sap} failed={sfl}");
    let sap_n: i64 = sap.parse().unwrap_or(-1);
    if sap_n > 0 {
        return Some((0, sap.clone(), sfl, line));
    }
    if sap_n == 0 {
        return Some((1, "0".to_string(), sfl, line));
    }
    None
}

/// `report`：人读的判定输出；返回值 = 退出码。
/// rc=1 时带引擎原话块（shell report 原文：engine_reason 为空则打印
/// "engine gave no parse error"）—— `once` 与 `watch` 共用同一份。
fn report(out: &dyn Fn(&str), elog: &str, rc: i32, applied: &str, failed: &str) -> i32 {
    match rc {
        0 => {
            out(&format!(
                "VERDICT: ACCEPTED — ack reports applied={applied} failed={failed}: the engine is serving them."
            ));
            out("         Give the client a moment, then re-run the integrity check; expect DEVICE/STRONG to change.");
            0
        }
        1 => {
            if applied == "0" {
                out(&format!(
                    "VERDICT: REJECTED — ack reports applied=0 failed={failed}: no profile became live."
                ));
            } else {
                out(&format!("VERDICT: PARTIAL — ack reports applied={applied} failed={failed}."));
                out("         The rejected profiles are served by the real hardware HAL.");
            }
            let why = engine_reason(elog);
            if !why.is_empty() {
                out(&format!("         engine's own reason: {why}"));
            } else {
                out("         engine gave no parse error — check the ack and the daemon's push log.");
            }
            out("         Every request falls through to the real HAL, so PI stays at BASIC.");
            1
        }
        _ => {
            out("VERDICT: SILENT — no ack in the trace for this keybox.");
            out("         Either the daemon is not running (probe: pidof teesim), the config");
            out("         itself is invalid (ConfigStore rejects it before any push), or the");
            out("         change has not been observed yet.");
            2
        }
    }
}

/// `show`：打印记录的判定（廉价；WebUI 每小时调一次）。
/// 陈旧判定：kbhash 权威（记录里有且当前可算时），否则回退 kbtm。
fn cmd_show(ctx: &Ctx, out: &dyn Fn(&str)) -> i32 {
    let state_path = ctx.state();
    let text = fs::read_to_string(&state_path).unwrap_or_default();
    if text.trim().is_empty() {
        out("state=unknown");
        out("reason=no verdict recorded yet");
        return 2;
    }
    let get = |k: &str| -> String {
        text.lines()
            .find_map(|l| l.strip_prefix(k).map(|v| v.to_string()))
            .unwrap_or_default()
    };
    let rec = get("kbtm=");
    let rech = get("kbhash=");
    let st = get("state=");
    let curh = kb_hash(&ctx.kb());
    let stale;
    if !rech.is_empty() && !curh.is_empty() {
        stale = curh != rech;
    } else if !rec.is_empty() {
        // shell 用的是字符串比较（[ "$mt" != "$rec" ]），保持一致
        stale = kb_mtime(&ctx.kb()).to_string() != rec;
    } else {
        stale = false;
    }
    if stale {
        out("state=stale");
        out("reason=keybox.xml changed since the last verdict; waiting for the engine");
        return 2;
    }
    out(text.trim_end());
    match st.as_str() {
        "ok" => 0,
        "rejected" | "partial" => 1,
        _ => 2,
    }
}

/// `once`：评估轨迹里最新的 push/ack，记录并打印。
fn cmd_once(ctx: &Ctx, out: &dyn Fn(&str)) -> i32 {
    let elog = ctx.elog();
    let chunk = String::from_utf8_lossy(&read_bytes(&elog)).into_owned();
    let (mut rc, ack_line, applied, failed) = verdict_from(&chunk);
    if rc == 3 {
        // logcat 被禁的设备上 LogTail 镜像结构性为空 → 先问 daemon 再放弃
        if let Some((v, a, f, l)) = socket_verdict(ctx) {
            rc = v;
            return finish_once(ctx, out, rc, &l, &a, &f, &elog);
        }
    }
    finish_once(ctx, out, rc, &ack_line, &applied, &failed, &elog)
}

fn finish_once(
    ctx: &Ctx,
    out: &dyn Fn(&str),
    rc: i32,
    ack_line: &str,
    applied: &str,
    failed: &str,
    elog: &str,
) -> i32 {
    match rc {
        3 => write_state(ctx, "unknown", "", "", ""),
        0 => write_state(ctx, "ok", applied, failed, ack_line),
        1 => write_state(ctx, "rejected", applied, failed, ack_line),
        _ => write_state(ctx, "unknown", "", "", ""),
    }
    if rc == 3 {
        out("VERDICT: NO-ACK — the durable trace holds no ack line.");
        let pushes = String::from_utf8_lossy(&read_bytes(elog))
            .lines()
            .filter(|l| l.contains("control: pushed config"))
            .count();
        out(&format!("         pushes={pushes} — if"));
        out("         pushes>0 with no ack, the push never completed on the wire.");
        return 2;
    }
    report(out, elog, rc, applied, failed)
}

/// `socket-live`：给脚本用（keybox-fetch 的 engine_verifiable）。
fn cmd_socket_live(ctx: &Ctx, out: &dyn Fn(&str)) -> i32 {
    if let Some((rc, _a, _f, line)) = socket_verdict(ctx) {
        out(&format!("state={rc} ack={line}"));
        return 0;
    }
    out("state=none");
    2
}

/// `watch [secs] [from]`：等**下一次** verdict。每秒看一次日志尾部（从
/// 字节偏移 `from` 起，日志被轮转则整读），出现触发行（ack/staged/build 失败）
/// 就解析计数并落盘报告；超时后 admin socket 再给一次机会，仍无 → SILENT。
/// SILENT 的尾部输出走 mask_ids（audit H1/N13：进终端的日志摘录一律脱敏）。
fn cmd_watch(ctx: &Ctx, out: &dyn Fn(&str), secs_arg: Option<&str>, from_arg: Option<&str>) -> i32 {
    let elog = ctx.elog();
    // 数值白名单（audit N17）：非纯数字回落默认 15
    let mut watch_secs: u64 = 15;
    if let Some(s) = secs_arg {
        if !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()) {
            watch_secs = s.parse().unwrap_or(15);
        }
    }
    let from: u64 = match from_arg {
        Some(v) if !v.is_empty() && v.bytes().all(|c| c.is_ascii_digit()) => {
            v.parse().unwrap_or_else(|_| log_size(&elog))
        }
        _ => log_size(&elog),
    };
    let picks = [
        "pushed config",
        "staged profile",
        "failed to build",
        "teesim_km_init_ex",
        "control: ack",
        "connection error",
    ];
    let mut i: u64 = 0;
    while i < watch_secs {
        let now = log_size(&elog);
        let chunk = if now < from {
            // 轮转发生在脚下：整个文件就是「deploy 之后」的内容
            String::from_utf8_lossy(&read_bytes(&elog)).into_owned()
        } else {
            // tail -c +$((from+1))：跳过前 from 字节
            let b = read_bytes(&elog);
            if (from as usize) < b.len() {
                String::from_utf8_lossy(&b[from as usize..]).into_owned()
            } else {
                String::new()
            }
        };
        if chunk.contains("control: ack")
            || chunk.contains("failed to build")
            || chunk.contains("cfg: staged profile")
        {
            out("-- engine log since the deploy --");
            let lines: Vec<&str> = chunk
                .lines()
                .filter(|l| picks.iter().any(|p| l.contains(p)))
                .collect();
            let n = lines.len();
            for l in &lines[n.saturating_sub(12)..] {
                out(l);
            }
            out("");
            let (rc, ack_line, applied, failed) = verdict_from(&chunk);
            if rc == 3 {
                i += 1;
                std::thread::sleep(std::time::Duration::from_secs(1));
                continue;
            }
            match rc {
                0 => write_state(ctx, "ok", &applied, &failed, &ack_line),
                1 => write_state(ctx, "rejected", &applied, &failed, &ack_line),
                _ => write_state(ctx, "unknown", "", "", ""),
            }
            return report(out, &elog, rc, &applied, &failed);
        }
        i += 1;
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    // logcat 全关的设备（见 `once`）：日志永不填 → admin socket 再给一次机会
    if let Some((v, a, f, l)) = socket_verdict(ctx) {
        match v {
            0 => write_state(ctx, "ok", &a, &f, &l),
            1 => write_state(ctx, "rejected", &a, &f, &l),
            _ => {}
        }
        return report(out, &elog, v, &a, &f);
    }
    write_state(ctx, "silent", "", "", "");
    out(&format!("VERDICT: SILENT — nothing in {watch_secs}s. Recent lines:"));
    let b = read_bytes(&elog);
    let start = b.len().saturating_sub(2000);
    let tail = String::from_utf8_lossy(&b[start..]).into_owned();
    let lines: Vec<String> = tail.lines().map(|l| crate::engine_check::mask_ids(l)).collect();
    let n = lines.len();
    for l in &lines[n.saturating_sub(8)..] {
        out(l);
    }
    2
}

/// 入口。支持子命令：once | watch | show | reason | socket-live | help。
pub fn run(args: &[String]) -> i32 {
    let tee_dir = std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string());
    let ctx = Ctx { tee_dir };
    let printer = |s: &str| println!("{s}");
    let sub = args.first().map(String::as_str).unwrap_or("");
    match sub {
        "show" => cmd_show(&ctx, &printer),
        "reason" => {
            println!("{}", engine_reason(&ctx.elog()));
            0
        }
        "once" => cmd_once(&ctx, &printer),
        "watch" => cmd_watch(&ctx, &printer, args.get(1).map(String::as_str), args.get(2).map(String::as_str)),
        "socket-live" => cmd_socket_live(&ctx, &printer),
        "" | "-h" | "--help" => {
            printer("engine-verdict.sh — the engine's own answer about the deployed keybox");
            printer("");
            printer("  engine-verdict.sh once                 judge the newest push/ack now, record it");
            printer("  engine-verdict.sh watch [secs] [from]   wait for the next verdict (default 15s)");
            printer("  engine-verdict.sh show                 print the recorded verdict");
            printer("  engine-verdict.sh reason               print only the engine's own words");
            printer("  engine-verdict.sh socket-live           0 when the admin socket reports an ack");
            printer("");
            printer("  exit 0 = accepted · 1 = rejected/partial · 2 = no verdict");
            0
        }
        other => {
            eprintln!("unknown mode: {other} (try --help)");
            2
        }
    }
}
#[cfg(test)]
mod tests {
    use super::kb_hash;

    #[test]
    fn kb_hash_matches_sha256sum() {
        // 对照 FIPS 180-4 的著名向量：sha256("abc") = ba7816bf…
        let dir = std::env::temp_dir().join("fusionctl-sha-test");
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("kb.xml");
        std::fs::write(&p, b"abc").unwrap();
        let got = kb_hash(p.to_str().unwrap());
        let want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert_eq!(got, want);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
