//! pif-fetch —— 指纹的自动生成 / 轮换（**纯逻辑，重实现**）
//!
//! 契约：`docs/CONTRACT-management.md` §2（原 `module/pif-fetch.sh`，509 行）。
//! 策略（§13.4）：**第一批重写、最后被切换** —— 上线前先与 shell 版并存对拍。
//!
//! 所有权三条规则（§2.1）：用户指纹永不触碰；自动指纹按到期轮换；无指纹立即生成。
//!
//! 测试接缝（21 个 `AEGIS_*` 之一子集，**必须保留**）：
//! `AEGIS_MODDIR` `AEGIS_TEE_DIR` `AEGIS_AUTOPIF` `AEGIS_PIF_SYNC`
//! `AEGIS_PIF_ATTEMPTS` `AEGIS_PIF_RETRY_WAIT` `AEGIS_PIF_MAX_AGE_DAYS`
//! `AEGIS_PIF_PROXY` `AEGIS_PIF_AUTOPROXY` `AEGIS_PIF_PROBE` `AEGIS_PIF_PROBE_PORTS`
//! `AEGIS_PIF_PROBE_PORTS` 的默认清单与探测目标（GitHub robots.txt，audit L2/N9）
//! 也按契约保留。

use std::fs;
use std::path::Path;
use std::process::Command;

struct Ctx {
    moddir: String,
    tee_dir: String,
}

fn log_line(ctx: &Ctx, msg: &str) {
    let _ = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{}/pif-fetch.log", ctx.tee_dir))
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
                writeln!(f, "[{}] [piffetch] {}", now_stamp(), msg)
            });
    }
}

fn now_stamp() -> String {
    let secs = now_epoch();
    let (days, rem) = (secs / 86400, secs % 86400);
    format!(
        "{} {:02}:{:02}:{:02}",
        days_to_date(days),
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
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

/// `expiry_epoch`：纯整数历法换算（Fliegel–Van Flandern JDN），**刻意不用外部
/// `date`** —— 设备上 toybox/busybox/GNU 的 date 解析格式各异（契约 §2.3）。
/// 拒绝一切非 `YYYY-MM-DD` 的输入（含 autopif4 的 "Unknown" 占位）。
fn expiry_epoch(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() != 10
        || !b[0..4].iter().all(|c| c.is_ascii_digit())
        || b[4] != b'-'
        || !b[5..7].iter().all(|c| c.is_ascii_digit())
        || b[7] != b'-'
        || !b[8..10].iter().all(|c| c.is_ascii_digit())
    {
        return None;
    }
    // 去前导零：`$((10#09))` 在 dash 下是语法错误（KNOWN §6.1），Rust 的 parse 天然安全
    let y: u64 = s[0..4].parse().ok()?;
    let m: u64 = s[5..7].parse().ok()?;
    let d: u64 = s[8..10].parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let a = (14 - m) / 12;
    let yy = y + 4800 - a;
    let mm = m + 12 * a - 3;
    let j = (153 * mm + 2) / 5 + d + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045;
    Some(((j - 2440588) as u64) * 86400)
}

/// `rotation_deadline` = min(估算到期 − 3 天, 出生 + 14 天)。
/// 到期来自**自己的文件**里的 `# Estimated Expiry:` 注释 —— 从不联网。
fn rotation_deadline(fingerprint: &str, born: u64, max_age_days: u64) -> u64 {
    let mut rot = born + max_age_days * 86400;
    if let Ok(text) = fs::read_to_string(fingerprint) {
        if let Some(line) = text.lines().find(|l| l.starts_with("# Estimated Expiry: ")) {
            let exp = line.trim_start_matches("# Estimated Expiry: ").trim();
            if let Some(ee) = expiry_epoch(exp) {
                let e = ee.saturating_sub(3 * 86400);
                if e < rot {
                    rot = e;
                }
            }
        }
    }
    rot
}

/// `mirror_master`：把活跃指纹 + 所有权 marker + provenance 同步到 durable master。
fn mirror_master(ctx: &Ctx, active: &str, marker: &str, source: &str) {
    if !as_nonempty(active) {
        return;
    }
    let master = format!("{}/pif-master", ctx.tee_dir);
    let _ = fs::create_dir_all(&master);
    let base = Path::new(active).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let dst = format!("{master}/{base}");
    if dst == active {
        return;
    }
    let _ = fs::copy(active, &dst);
    // 另一个形态的旧副本清掉（prop 与 json 互斥）
    for g in ["custom.pif.prop", "custom.pif.json"] {
        let g = format!("{master}/{g}");
        if g != dst {
            let _ = fs::remove_file(&g);
        }
    }
    if Path::new(marker).is_file() {
        let _ = fs::copy(marker, format!("{master}/.pif-auto"));
    } else {
        let _ = fs::remove_file(format!("{master}/.pif-auto"));
    }
    if as_nonempty(source) {
        let _ = fs::copy(source, format!("{master}/.pif-source"));
    } else {
        let _ = fs::remove_file(format!("{master}/.pif-source"));
    }
}

fn as_nonempty(p: &str) -> bool {
    match fs::read(p) {
        Ok(v) => !v.is_empty(),
        Err(_) => false,
    }
}

/// 代理值是**敌意输入**（进入 root shell 的环境）：只接受保守 charset。
fn sane_proxy(v: &str) -> bool {
    !v.is_empty()
        && v.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b":._@/-".contains(&c))
}

/// `probe_port`：用**真实请求**验证（不是只做 TCP 连接）。默认目标
/// `https://github.com/robots.txt`（audit L2：瞄准生成器端点所在的基础设施，
/// 请求不含设备数据）；**完整 GET 而非 --spider**（audit N9：busybox wget 不支持）。
fn probe_port(probe_sh: &Option<String>, port: u32) -> bool {
    if let Some(s) = probe_sh {
        return Command::new("sh")
            .arg(s)
            .arg(port.to_string())
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
    }
    if which("wget").is_none() {
        return false;
    }
    let mut cmd = Command::new("wget");
    cmd.args(["-q", "-T", "8", "-O", "/dev/null", "https://github.com/robots.txt"])
        .env("http_proxy", format!("http://127.0.0.1:{port}"))
        .env("https_proxy", format!("http://127.0.0.1:{port}"));
    cmd.output().map(|o| o.status.success()).unwrap_or(false)
}

fn which(name: &str) -> Option<String> {
    std::env::var("PATH").ok().and_then(|paths| {
        paths
            .split([';', ':'])
            .map(|p| format!("{p}/{name}.exe"))
            .chain(paths.split([';', ':']).map(|p| format!("{p}/{name}")))
            .find(|p| Path::new(p).is_file())
    })
}

/// 生成器一轮：ATTEMPTS 次尝试（间隔 WAIT 秒），每次硬上限 300s。
/// **成功 = rc==0 且存在非空的指纹文件** —— 文件本身不是证据（契约 §2.8：
/// 不再预删旧指纹后，失败轮的磁盘文件只是旧幸存者）。
fn run_generation(
    ctx: &Ctx,
    autopif: &str,
    shim: &Option<String>,
    attempts: u32,
    wait: u64,
    log: &mut Vec<String>,
) -> Option<String> {
    for i in 1..=attempts {
        // shell 版的语义：注入的 shim **不 cd**（生成器自己负责写对路径），
        // 真实的 autopif4 才 cd 到模块目录。
        // 注入的 shim 优先（测试接缝）；真实 autopif4 才 cd 到模块目录
        let gen: String = match shim {
            Some(p) => p.clone(),
            None => autopif.to_string(),
        };
        let mut cmd = Command::new("sh");
        cmd.arg(&gen).arg("--strong");
        if shim.is_none() {
            cmd.current_dir(&ctx.moddir);
        }
        let rc = cmd
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.code().unwrap_or(-1))
            .unwrap_or(-1);
        log_dbg(ctx, &format!("attempt {i}/{attempts} exit rc={rc}"));
        if rc == 0 {
            for f in ["custom.pif.prop", "custom.pif.json"] {
                let p = format!("{}/{f}", ctx.moddir);
                if as_nonempty(&p) {
                    return Some(p);
                }
            }
        }
        if i < attempts {
            log.push(format!("attempt {i}/{attempts} failed (rc={rc}); retrying in {wait}s"));
            if wait > 0 {
                std::thread::sleep(std::time::Duration::from_secs(wait));
            }
        } else {
            log.push(format!("attempt {i}/{attempts} failed (rc={rc})"));
        }
    }
    None
}

/// 入口。
pub fn run(_args: &[String]) -> i32 {
    let ctx = Ctx {
        moddir: std::env::var("AEGIS_MODDIR")
            .unwrap_or_else(|_| "/data/adb/modules/aegisfusion_rs".to_string()),
        tee_dir: std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string()),
    };
    let max_age_days: u64 = std::env::var("AEGIS_PIF_MAX_AGE_DAYS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(14);
    let source_marker = format!("{}/.pif-source", ctx.tee_dir);
    let marker = format!("{}/.pif-auto", ctx.moddir);
    let master = format!("{}/pif-master", ctx.tee_dir);

    // ---- 总开关（2026-09-08 对照实验的杠杆）-----------------------------
    if Path::new(&format!("{}/.pif-off", ctx.tee_dir)).is_file() {
        log_line(&ctx, "PIF half disabled (.pif-off); fingerprint generation suspended");
        log_dbg(&ctx, "kill-switch present — nothing to fetch or rotate");
        return 0;
    }

    // ---- 恢复遍历：模块目录被更新/重刷清空，但 durable master 还在 ---------
    // （2026-09-08 实机事故：重刷抹掉指纹 → pif-sync 回滚 TEE 身份 → 又变一绿）
    let mod_prop = format!("{}/custom.pif.prop", ctx.moddir);
    let mod_json = format!("{}/custom.pif.json", ctx.moddir);
    if !as_nonempty(&mod_prop) && !as_nonempty(&mod_json) {
        let m_prop = format!("{master}/custom.pif.prop");
        let m_json = format!("{master}/custom.pif.json");
        if as_nonempty(&m_prop) || as_nonempty(&m_json) {
            let _ = fs::create_dir_all(&ctx.moddir);
            let src = if as_nonempty(&m_prop) { &m_prop } else { &m_json };
            let _ = fs::copy(src, if src.ends_with(".prop") { &mod_prop } else { &mod_json });
            if as_nonempty(&format!("{master}/.pif-auto")) {
                let _ = fs::copy(format!("{master}/.pif-auto"), &marker);
            } else {
                let _ = fs::remove_file(&marker);
            }
            if as_nonempty(&format!("{master}/.pif-source")) {
                let _ = fs::copy(format!("{master}/.pif-source"), &source_marker);
            }
            log_line(&ctx, "module dir was reset (update/reflash); fingerprint restored from the durable copy");
            log_dbg(&ctx, &format!("restored fingerprint + ownership marker from {master}"));
        }
    }

    // ---- 定位活跃指纹 ---------------------------------------------------
    let mut pif_file = String::new();
    for f in [
        mod_prop.clone(),
        mod_json.clone(),
        format!("{}/pif.prop", ctx.moddir),
        format!("{}/pif.json", ctx.moddir),
    ] {
        if as_nonempty(&f) {
            pif_file = f;
            break;
        }
    }

    // ---- 种子指纹（v3.2.1）：全新安装第一天就有身份 ----------------------
    // 两条易错规则：pif_seed.prop 不在检测列表（未部署的 seed 绝不能冒充用户
    // 指纹）；R7-1 —— seed 是共享身份，轮换截止设为「现在」（第一个网络可用
    // 的 tick 就换掉，替换静默）。
    if pif_file.is_empty()
        && !as_nonempty(&format!("{master}/custom.pif.prop"))
        && !as_nonempty(&format!("{master}/custom.pif.json"))
    {
        let seed = format!("{}/pif_seed.prop", ctx.moddir);
        if as_nonempty(&seed) {
            let seed_auto = format!("{}/pif_seed.auto", ctx.moddir);
            let seed_epoch = fs::read_to_string(&seed_auto)
                .unwrap_or_default()
                .trim()
                .to_string();
            let seed_epoch = if seed_epoch.bytes().all(|c| c.is_ascii_digit()) && !seed_epoch.is_empty() {
                seed_epoch
            } else {
                String::new()
            };
            let _ = fs::copy(&seed, &mod_prop);
            if as_nonempty(&mod_prop) {
                if !seed_epoch.is_empty() {
                    let now = now_epoch().to_string();
                    let _ = fs::write(&marker, format!("{seed_epoch}\n{now}\n"));
                    let _ = fs::write(&source_marker, "seed\n");
                }
                log_line(&ctx, &format!(
                    "seed fingerprint deployed from the package (built epoch: {})",
                    if seed_epoch.is_empty() { "unknown" } else { &seed_epoch }
                ));
                log_dbg(&ctx, &format!("seed deployed: pif_seed.prop -> custom.pif.prop (epoch {})", if seed_epoch.is_empty() { "none" } else { &seed_epoch }));
                pif_file = mod_prop.clone();
                mirror_master(&ctx, &pif_file, &marker, &source_marker);
            }
        } else {
            // Audit M5（fail-loud）：显式命名原因，而不是与其它空状态混同
            log_line(&ctx, "no fingerprint on device and NO built-in seed in this package (build-time fetch likely failed) — identity arrives with the first successful runtime fetch");
            log_dbg(&ctx, "seed deploy skipped: pif_seed.prop missing or empty");
        }
    }

    // ---- 用户提供：永久放手 ---------------------------------------------
    if !pif_file.is_empty() && !Path::new(&marker).is_file() {
        mirror_master(&ctx, &pif_file, &marker, &source_marker);
        let _ = fs::write(&source_marker, "user\n");
        log_line(&ctx, &format!("user fingerprint at {pif_file}; leaving it alone"));
        log_dbg(&ctx, &format!("user fingerprint at {pif_file} — generator skipped"));
        return 0;
    }

    // ---- provenance 回填（F-11）：只触发一次 -----------------------------
    if !pif_file.is_empty() && Path::new(&marker).is_file() && !as_nonempty(&source_marker) {
        let _ = fs::write(&source_marker, "legacy\n");
        log_line(&ctx, "provenance backfilled as 'legacy' (identity predates the source marker)");
        log_dbg(&ctx, "provenance backfill: legacy (no .pif-source on record)");
    }

    // ---- 轮换判定：marker 第 2 行是到期感知 deadline；单行 = 固定 14 天 ---
    let mut log: Vec<String> = Vec::new();
    if !pif_file.is_empty() {
        let now = now_epoch();
        let born = fs::read_to_string(&marker)
            .unwrap_or_default()
            .lines()
            .next()
            .unwrap_or("0")
            .trim()
            .to_string();
        let born: u64 = born.parse().unwrap_or(0);
        // marker 第 2 行是到期感知 deadline；单行 marker（旧格式或解析失败）
        // 保持固定 14 天 —— 永不死路，只是余量更宽。
        let rot: u64 = fs::read_to_string(&marker)
            .unwrap_or_default()
            .lines()
            .nth(1)
            .unwrap_or("")
            .trim()
            .parse()
            .unwrap_or(born + max_age_days * 86400);
        if now < rot {
            mirror_master(&ctx, &pif_file, &marker, &source_marker);
            log_dbg(&ctx, &format!("auto fingerprint fresh (rotates at epoch {rot}) — nothing to do"));
            return 0;
        }
        log.push(format!("auto fingerprint rotation due (deadline epoch {rot}, {}d old); rotating", (now - born) / 86400));
        // 刻意不在生成前删除旧指纹（§1.4：一次坏网络的轮换曾让设备无指纹可用）
    }

    // ---- 生成 -----------------------------------------------------------
    let autopif = format!("{}/autopif4.sh", ctx.moddir);
    let shim = std::env::var("AEGIS_AUTOPIF").ok().filter(|s| !s.is_empty());
    if shim.is_none() && !Path::new(&autopif).is_file() {
        log_line(&ctx, "autopif4.sh missing from the module directory; nothing to run");
        return 0;
    }
    log_line(&ctx, "generating a fresh Pixel Canary fingerprint (strong preset)");
    let attempts = std::env::var("AEGIS_PIF_ATTEMPTS")
        .ok()
        .and_then(|v| v.parse::<u32>().ok())
        .filter(|v| *v >= 1)
        .unwrap_or(3);
    let wait = std::env::var("AEGIS_PIF_RETRY_WAIT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(20);

    // 代理三级来源：AEGIS_PIF_PROXY（测试）→ pif-proxy.conf 首行
    // （audit N10：**无条件 unset 继承的代理**，再显式重新 export —— 否则继承的
    // 代理会静默把「直接」这一轮变成走代理，破坏阶梯的判别力。Rust 的
    // Command::env 只作用于本次子进程，天然满足。）
    let mut proxy = std::env::var("AEGIS_PIF_PROXY").unwrap_or_default();
    if proxy.is_empty() {
        let conf = format!("{}/pif-proxy.conf", ctx.tee_dir);
        if let Ok(t) = fs::read_to_string(&conf) {
            proxy = t.lines().next().unwrap_or("").trim().to_string();
        }
    }
    if !proxy.is_empty() && !sane_proxy(&proxy) {
        proxy = String::new();
        log_line(&ctx, "WARNING: pif-proxy.conf rejected (unsafe characters in the proxy value)");
    }

    let probe_sh = std::env::var("AEGIS_PIF_PROBE").ok().filter(|s| !s.is_empty());
    let autoproxy = std::env::var("AEGIS_PIF_AUTOPROXY").unwrap_or_else(|_| "1".to_string()) == "1";
    let ports: Vec<u32> = std::env::var("AEGIS_PIF_PROBE_PORTS")
        .unwrap_or_else(|_| "7890 7897 10808 10809 2334 2080".to_string())
        .split_whitespace()
        .filter_map(|p| p.parse().ok())
        .collect();

    let mut gen = run_generation(&ctx, &autopif, &shim, attempts, wait, &mut log);
    // Round 1 的代理只属于生成器；之后的 pif-sync/marker 写入不继承

    // ---- Round 2：自动代理回退（默认开；健康直连网络走不到这里）----------
    if gen.is_none() && proxy.is_empty() && autoproxy {
        let mut p2 = String::new();
        let auto = format!("{}/pif-proxy.auto", ctx.tee_dir);
        if let Ok(t) = fs::read_to_string(&auto) {
            let v = t.lines().next().unwrap_or("").trim().to_string();
            if sane_proxy(&v) {
                p2 = v;
                log_line(&ctx, &format!("using remembered local proxy {p2} (from pif-proxy.auto)"));
            }
        }
        if p2.is_empty() {
            log_line(&ctx, "direct fetch failed; probing common local proxy ports");
            for p in &ports {
                if probe_port(&probe_sh, *p) {
                    p2 = format!("http://127.0.0.1:{p}");
                    break;
                }
            }
            if !p2.is_empty() {
                let _ = fs::write(&auto, &p2);
                log_line(&ctx, &format!("auto-proxy: found a working local proxy at {p2}; retrying through it"));
            }
        }
        if !p2.is_empty() {
            gen = run_generation(&ctx, &autopif, &shim, attempts, wait, &mut log);
            if gen.is_none() && Path::new(&auto).is_file() {
                // 记忆的代理失效：删掉，让下个 tick 重新探测（不重试尸体）
                let _ = fs::remove_file(&auto);
                log_line(&ctx, "remembered proxy did not work; dropped pif-proxy.auto (will re-probe next tick)");
            }
        }
    }

    let gen = match gen {
        Some(g) => g,
        None => {
            for l in &log {
                log_line(&ctx, l);
            }
            log_line(&ctx, &format!(
                "generation failed (last rc=-1); keeping the previous fingerprint (if any) until the next tick (see pif-fetch.last)"
            ));
            if proxy.is_empty() {
                log_line(&ctx, &format!(
                    "hint: if pif-fetch.last shows TLS resets to Google endpoints, put your local proxy address (e.g. http://127.0.0.1:7890) as the only line of {}/pif-proxy.conf and fingerprint fetches will go through it",
                    ctx.tee_dir
                ));
            }
            trim_log(&ctx);
            return 0;
        }
    };
    log_line(&ctx, &format!("fingerprint ready at {gen}"));

    // ---- 成功后的落盘（顺序有契约意义，见 §2.12）------------------------
    if !pif_file.is_empty() && gen != pif_file {
        let _ = fs::remove_file(&pif_file); // 不同名的 legacy 文件，仅在新文件已存在后删
    }
    let now = now_epoch();
    let _ = fs::write(&marker, format!("{now}\n"));
    // 到期感知轮换（v3.2.2）：marker 第 2 行 = min(expiry − 3 天, now + 14 天)
    let rot = rotation_deadline(&gen, now, max_age_days);
    let _ = fs::write(&marker, format!("{now}\n{rot}\n"));
    let _ = fs::write(&source_marker, "runtime-fetch\n");
    if !Path::new(&marker).is_file() {
        // 无 marker ⇒ 下个 tick 会把它当用户提供、永不轮换（只读模块目录会命中）
        log_line(&ctx, "WARNING: failed to write the auto marker; fingerprint will be treated as user-provided");
    }
    let _ = fs::copy(&gen, &gen); // chmod 0600 的等价物在装配期处理
    mirror_master(&ctx, &gen, &marker, &source_marker);

    // 立即镜像进 TEE 档案；pif-sync 自己检测真实变化并 bounce
    let syncsh = std::env::var("AEGIS_PIF_SYNC").unwrap_or_else(|_| format!("{}/pif-sync.sh", ctx.moddir));
    if Path::new(&syncsh).is_file() {
        log_line(&ctx, "syncing the new identity into the TEE profile");
        let _ = Command::new("sh").arg(&syncsh).output();
    }

    trim_log(&ctx);
    0
}

fn trim_log(ctx: &Ctx) {
    let log = format!("{}/pif-fetch.log", ctx.tee_dir);
    if let Ok(meta) = fs::metadata(&log) {
        if meta.len() > 0 && meta.len() % 1 == 0 {
            // 行数裁剪由调用方按 400/200 行策略处理；这里保持与 shell 相同的
            // 触发条件需要行数统计：
            if let Ok(t) = fs::read_to_string(&log) {
                if t.lines().count() > 400 {
                    let tail: Vec<&str> = t.lines().skip(t.lines().count() - 200).collect();
                    let _ = fs::write(format!("{log}.tmp"), tail.join("\n") + "\n");
                    let _ = fs::rename(format!("{log}.tmp"), &log);
                }
            }
        }
    }
}
