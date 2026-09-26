//! keybox-swap —— 部署 keybox 并读取引擎的判定（**纯逻辑，重实现**）
//!
//! 契约：`docs/CONTRACT-verdict-keybox.md`（原 `module/keybox-swap.sh`，226 行）。
//!
//! 移植范围：`deploy`（备份 + 原子替换 + 剪枝）、`validate`、`--list`、
//! `--restore`、单候选部署。`--watch` / `--auto` 依赖 `engine-verdict` 的
//! `watch` 子命令（依赖 mask_ids 与轮询），随 `watch` 一起移植。
//!
//! 关键语义（§2 的 WHY）：
//! * **原子替换**：cp 到同目录的 `keybox.xml.new` 再 `mv` 覆盖 —— 对 daemon 的
//!   目录级 FileObserver 这是一次 MOVED_TO（本身就是重推触发器），且**替换的是
//!   符号链接本身**而不是写穿它（写穿会静默改写 TrickyStore 自己的副本）；
//! * **备份 fail-closed**（audit N15/M11）：无法备份（目录不可写/磁盘满）⇒
//    **什么都不替换** —— 旧行为只警告然后照样替换，会静默毁掉用户不可再生的 keybox；
//! * 备份用 `cp -fL`（**跟随符号链接、保留字节**）；
//! * 备份目录只保留最新 10 份。

use std::fs;
use std::path::Path;
use std::process::Command;

struct Ctx {
    tee_dir: String,
    moddir: String,
}

impl Ctx {
    fn kb(&self) -> String {
        format!("{}/keybox.xml", self.tee_dir)
    }
    fn bkdir(&self) -> String {
        format!("{}/keybox-backups", self.tee_dir)
    }
    fn check(&self) -> String {
        format!("{}/keybox-check.sh", self.moddir)
    }
}

fn now_stamp_compact() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // date +%Y%m%d-%H%M%S 的等价物（UTC；备份名只要求唯一与可排序）
    let (days, rem) = (secs / 86400, secs % 86400);
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z % 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let yy = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        yy,
        m,
        d,
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// `watch_verdict <byte-offset> <seconds>`：判定解析的唯一权威是
/// engine-verdict（它读 ack **计数**——单行匹配会把 partial 当成 through），
/// 结果同时落盘 `$TEE_DIR/.engine-verdict` 给 WebUI 显示。
fn watch_verdict(ctx: &Ctx, from: u64, secs: u64, out: &mut Vec<String>) -> i32 {
    let verdict = format!("{}/engine-verdict.sh", ctx.moddir);
    if !Path::new(&verdict).is_file() {
        out.push(format!(
            "VERDICT: SILENT — {verdict} is missing, so the trace cannot be read."
        ));
        out.push("         (reinstall/upgrade the module: engine-verdict.sh ships with it)".to_string());
        return 2;
    }
    let resolved = which_cmd("sh").unwrap_or_else(|| "sh".to_string());
    let run = |c: &mut Command| -> Option<std::process::Output> {
        match c.output() {
            Ok(o) => return Some(o),
            Err(_) => None,
        }
    };
    let mut c1 = Command::new(&resolved);
    c1.args([&verdict, "watch", &secs.to_string(), &from.to_string()]);
    let o = match run(&mut c1) {
        Some(o) => Some(o),
        None => {
            let mut c2 = Command::new("sh");
            c2.arg(&verdict)
                .args(["watch", &secs.to_string(), &from.to_string()]);
            c2.output().ok()
        }
    };
    match o {
        Some(o) => {
            for l in String::from_utf8_lossy(&o.stdout).lines() {
                out.push(l.to_string());
            }
            o.status.code().unwrap_or(-1)
        }
        None => 2,
    }
}

fn which_cmd(name: &str) -> Option<String> {
    let paths = std::env::var("PATH").ok()?;
    for p in paths.split([';', ':']) {
        if p.is_empty() {
            continue;
        }
        let plain = format!("{p}/{name}");
        if Path::new(&plain).is_file() {
            return Some(plain);
        }
        let exe = format!("{plain}.exe");
        if Path::new(&exe).is_file() {
            return Some(exe);
        }
    }
    None
}

fn elog_size(tee_dir: &str) -> u64 {
    fs::metadata(format!("{tee_dir}/log/teesim.log"))
        .map(|m| m.len())
        .unwrap_or(0)
}

/// `deploy`：备份当前（`cp -fL` 跟随符号链接保留字节）→ 剪枝到 10 份 →
/// `cp` 到同目录 `.new` → `mv` 原子替换 → `chmod 0600` → 清 `.auto-keybox`。
/// **备份失败 = fail-closed**（audit N15/M11）：什么都不替换。
fn deploy(ctx: &Ctx, candidate: &str, out: &mut Vec<String>) -> Result<(), i32> {
    let kb = ctx.kb();
    let bkdir = ctx.bkdir();
    let _ = fs::create_dir_all(&bkdir);
    if Path::new(&kb).is_file() {
        let ts = now_stamp_compact();
        // `cp -fL`：跟随符号链接，保留字节（不是链接本身）
        let backed_up = match fs::read(&kb) {
            Ok(bytes) => fs::write(format!("{bkdir}/keybox.{ts}.xml"), bytes).is_ok(),
            Err(_) => false,
        };
        if backed_up {
            out.push(format!("backed up current keybox -> {bkdir}/keybox.{ts}.xml"));
            // 剪枝：只保留最新 10 份
            let mut backups: Vec<String> = fs::read_dir(&bkdir)
                .map(|rd| {
                    rd.filter_map(|e| e.ok())
                        .map(|e| e.path().to_string_lossy().into_owned())
                        .filter(|p| p.ends_with(".xml"))
                        .collect()
                })
                .unwrap_or_default();
            backups.sort();
            backups.reverse(); // 名字含时间戳 ⇒ 字典序 = 新→旧
            for old in backups.iter().skip(10) {
                out.push(format!("pruning old backup: {}", Path::new(old).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()));
                let _ = fs::remove_file(old);
            }
        } else {
            out.push(format!("abort: could not back up the current keybox — nothing was replaced"));
            out.push(format!(
                "       (check that {bkdir} is writable and the disk has space), then retry"
            ));
            return Err(2);
        }
        if Path::new(&kb).is_symlink() {
            let tgt = fs::read_link(&kb).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
            out.push(format!(
                "note: current keybox.xml is a symlink -> {tgt} (its bytes, not the link, are what was backed up)"
            ));
        }
    }
    // 原子替换：同目录 .new + mv
    let new_path = format!("{kb}.new");
    if fs::copy(candidate, &new_path).is_err() {
        out.push(format!("deploy failed: cannot write {kb}.new"));
        return Err(2);
    }
    if fs::rename(&new_path, &kb).is_err() {
        out.push(format!("deploy failed: cannot replace {kb}"));
        return Err(2);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&kb, fs::Permissions::from_mode(0o600));
    }
    let size = fs::metadata(&kb).map(|m| m.len()).unwrap_or(0);
    out.push(format!("deployed {candidate} -> {kb} ({size} bytes)"));
    // 部署的是用户/候选 keybox ⇒ 自动管理的哈希标记作废
    let _ = fs::remove_file(format!("{}/.auto-keybox", ctx.tee_dir));
    Ok(())
}

/// `validate`：与安装器/抓取器同一个结构预检（keybox-check）。它不能证明可用
/// （只有引擎能），但能拦下明显的浪费。
fn validate(ctx: &Ctx, candidate: &str, force: bool, out: &mut Vec<String>) -> bool {
    let check = ctx.check();
    if !Path::new(&check).is_file() {
        out.push(format!("warn: {check} not found; deploying unvalidated"));
        return true;
    }
    // shell 用 `sh "$CHECK" "$_c"`：keybox-check 的 stdout **原样透传**（无
    // --quiet）。Windows 下直接 exec 脚本会失败 → 先 sh 兜底（与 shell 行为一致）。
    let resolved = which_cmd("sh").unwrap_or_else(|| "sh".to_string());
    let outp = {
        let mut c1 = Command::new(&resolved);
        c1.args([&check, candidate]);
        match c1.output() {
            Ok(o) => Some(o),
            Err(_) => {
                let mut c2 = Command::new("sh");
                c2.arg(&check).arg(candidate);
                c2.output().ok()
            }
        }
    };
    let (ok, vtext) = match outp {
        Some(o) => (o.status.success(), String::from_utf8_lossy(&o.stdout).into_owned()),
        None => (false, String::new()),
    };
    for l in vtext.lines() {
        out.push(l.to_string());
    }
    if ok {
        return true;
    }
    out.push("".to_string());
    if force {
        out.push("(--force) deploying anyway so the engine can be heard from directly.".to_string());
        return true;
    }
    out.push("REFUSING to deploy: the validator says the engine cannot use this keybox.".to_string());
    out.push("Re-run with -f to deploy it anyway and read the engine's own verdict.".to_string());
    false
}

/// `--list`：列出备份。
fn cmd_list(ctx: &Ctx, out: &mut Vec<String>) {
    let bkdir = ctx.bkdir();
    match fs::read_dir(&bkdir) {
        Ok(rd) => {
            for e in rd.filter_map(|e| e.ok()) {
                let meta = e.metadata().ok();
                let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
                out.push(format!(
                    "-rw------- {} {}",
                    size,
                    e.path().file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
                ));
            }
        }
        Err(_) => out.push(format!("no backups yet ({bkdir})")),
    }
}

/// `--restore`：把最新的备份放回去。
fn cmd_restore(ctx: &Ctx, out: &mut Vec<String>) -> i32 {
    let bkdir = ctx.bkdir();
    let mut backups: Vec<String> = fs::read_dir(&bkdir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .map(|e| e.path().to_string_lossy().into_owned())
                .filter(|p| p.ends_with(".xml"))
                .collect()
        })
        .unwrap_or_default();
    backups.sort();
    backups.reverse();
    let newest = match backups.first() {
        Some(p) => p.clone(),
        None => {
            out.push(format!("no backup to restore in {bkdir}"));
            return 2;
        }
    };
    out.push(format!("restoring {newest}"));
    let kb = ctx.kb();
    let new_path = format!("{kb}.new");
    if fs::copy(&newest, &new_path).is_ok() && fs::rename(&new_path, &kb).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&kb, fs::Permissions::from_mode(0o600));
        }
        0
    } else {
        2
    }
}

/// 入口。支持：--list / --restore / <candidate> [-f]。
/// （`--watch` / `--auto` 依赖 engine-verdict 的 watch 子命令，随 watch 移植。）
pub fn run(args: &[String]) -> i32 {
    let tee_dir = std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string());
    let moddir = std::env::var("AEGIS_MODDIR")
        .unwrap_or_else(|_| "/data/adb/modules/aegisfusion_rs".to_string());
    let ctx = Ctx { tee_dir, moddir };
    let mut out: Vec<String> = Vec::new();

    let sub = args.first().map(String::as_str).unwrap_or("");
    let rc = match sub {
        "--list" => {
            cmd_list(&ctx, &mut out);
            0
        }
        "--restore" => cmd_restore(&ctx, &mut out),
        "--watch" => {
            // 数值白名单：非纯数字回落默认 15
            let mut secs: u64 = 15;
            if let Some(v) = args.get(1) {
                if !v.is_empty() && v.bytes().all(|c| c.is_ascii_digit()) {
                    secs = v.parse().unwrap_or(15);
                }
            }
            out.push(format!(
                "watching {}/log/teesim.log for the next push/ack (up to {secs}s, nothing changed)…",
                ctx.tee_dir
            ));
            out.push("hint: touch a keybox or edit config.json from another shell to force a re-push".to_string());
            let from = elog_size(&ctx.tee_dir);
            watch_verdict(&ctx, from, secs, &mut out)
        }
        "--auto" => cmd_auto(&ctx, &args[1..], &mut out),
        "" | "-h" | "--help" => {
            out.push("keybox-swap — deploy a keybox and read the engine's verdict, live".to_string());
            out.push("".to_string());
            out.push("  keybox-swap <candidate.xml>      validate, back up, deploy".to_string());
            out.push("  keybox-swap <candidate.xml> -f   deploy even if validation fails".to_string());
            out.push("  keybox-swap --list               list backups".to_string());
            out.push("  keybox-swap --restore            put the newest backup back".to_string());
            out.push("".to_string());
            out.push("  backups live in $TEE_DIR/keybox-backups (newest 10 kept)".to_string());
            0
        }
        _ => {
            let candidate = sub;
            let force = args.get(1).map(|a| a == "-f" || a == "--force").unwrap_or(false);
            if !Path::new(candidate).is_file() {
                out.push(format!("not a file: {candidate}"));
                2
            } else if !validate(&ctx, candidate, force, &mut out) {
                1
            } else {
                // MARK 在替换**前**取：watch 只看 deploy 之后 daemon 自己写的日志
                let mark = elog_size(&ctx.tee_dir);
                if let Err(rc) = deploy(&ctx, candidate, &mut out) {
                    return rc;
                }
                out.push(
                    "waiting for the engine to re-push (the watch triggers on this rename)…"
                        .to_string(),
                );
                let rc = watch_verdict(&ctx, mark, 15, &mut out);
                if rc == 0 {
                    out.push("".to_string());
                    out.push("note: the committed push also re-attests the target apps' existing".to_string());
                    out.push("      attest keys (the daemon does it on the ack), so their next request".to_string());
                    out.push("      is served from this keybox.".to_string());
                }
                rc
            }
        }
    };
    for l in &out {
        println!("{l}");
    }
    rc
}


/// `--auto <c1> [c2...]`：逐候选 validate → deploy → watch，第一个被**引擎**
/// 接受的赢。pre-run 快照保证「全军覆没」时能原样恢复部署前状态。
fn cmd_auto(ctx: &Ctx, candidates: &[String], out: &mut Vec<String>) -> i32 {
    if candidates.is_empty() {
        out.push("usage: keybox-swap.sh --auto <c1.xml> [c2.xml ...]".to_string());
        return 2;
    }
    let kb = ctx.kb();
    let bkdir = ctx.bkdir();
    // pre-run 快照：「最新备份」在这里是错的 —— deploy 对每个候选都先备份，
    // 最新备份是上一个候选，不是本轮开始时的部署状态。
    let pre = format!("{}/.keybox.prerun.xml", ctx.tee_dir);
    let _ = fs::remove_file(&pre);
    if Path::new(&kb).is_file() {
        let _ = fs::copy(&kb, &pre);
    }
    let mut n = 0usize;
    let mut tried = 0usize;
    for c in candidates {
        n += 1;
        out.push("".to_string());
        out.push(format!("=== candidate {n}: {c} ==="));
        if !Path::new(c).is_file() {
            out.push(format!("not a file: {c} (skipped)"));
            continue;
        }
        if !validate(ctx, c, false, out) {
            out.push(
                "skipped: failed the structural pre-check (use -f on a single candidate to override)"
                    .to_string(),
            );
            continue;
        }
        tried += 1;
        let mark = elog_size(&ctx.tee_dir);
        if deploy(ctx, c, out).is_err() {
            continue;
        }
        out.push(
            "waiting for the engine to re-push (the watch triggers on this rename)…".to_string(),
        );
        let rc = watch_verdict(ctx, mark, 15, out);
        if rc == 0 {
            out.push("".to_string());
            out.push(format!(
                "ACCEPTED: {c} is now the deployed keybox and the engine is serving it."
            ));
            let _ = fs::remove_file(&pre);
            return 0;
        }
        out.push(format!(
            "not usable — trying the next candidate (current file kept in {bkdir})"
        ));
    }
    out.push("".to_string());
    out.push(format!(
        "FAILED: none of the {n} candidate(s) was accepted by the engine ({tried} reached the engine)."
    ));
    if Path::new(&pre).is_file() {
        out.push("restoring the keybox that was deployed before this run".to_string());
        let ts = now_stamp_compact();
        let _ = fs::copy(&pre, format!("{bkdir}/keybox.prerun.{ts}.xml"));
        let _ = fs::copy(&pre, format!("{kb}.new"));
        let _ = fs::rename(format!("{kb}.new"), &kb);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&kb, fs::Permissions::from_mode(0o600));
        }
        let _ = fs::remove_file(&pre);
        let mark = elog_size(&ctx.tee_dir);
        std::thread::sleep(std::time::Duration::from_secs(1));
        watch_verdict(ctx, mark, 15, out);
    } else {
        out.push("(nothing to restore: no keybox was deployed before this run)".to_string());
    }
    1
}
