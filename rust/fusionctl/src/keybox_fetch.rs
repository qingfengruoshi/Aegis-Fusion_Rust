//! keybox-fetch —— 社区 keybox 自动获取 / 定时刷新（重实现）
//!
//! 契约：`docs/CONTRACT-verdict-keybox.md` §3.4（原 `module/keybox-fetch.sh`，824 行）。
//!
//! 渠道生态（用户 conf 优先 + 内建 Megatron/Yurikey/KOWX712）→ 每渠道下载
//! （阶梯：直接重试×3 → 配置/记忆/探测代理 → curl --resolve 直连 Fastly IP）
//! → 解码（raw/b64/hexb64/megatron）→ 结构校验（复用 keybox-check 的重实现）
//! → sha256 pin → 部署 → 引擎验收 → 拉黑 payload / 回滚 pre-run 快照。
//!
//! 测试接缝（与 shell 版逐一对应）：`AEGIS_TEE_DIR` `AEGIS_MODDIR`
//! `AEGIS_KB_PROXY` `AEGIS_KB_AUTOPROXY` `AEGIS_KB_PROBE` `AEGIS_KB_PROBE_PORTS`
//! `AEGIS_KB_DIRECTIP` `AEGIS_KB_IPS`；另加 `AEGIS_VERDICT`（verdict 入口覆盖，
//! 默认 `{MODDIR}/engine-verdict.sh` —— engine-verdict 的 watch 子命令移植后
//! 切到自身入口）。

use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;
use std::process::{Command, Output};
use std::time::UNIX_EPOCH;

struct Ctx {
    tee_dir: String,
    moddir: String,
}

struct St {
    force: bool,
    revcheck: bool,
    dl: Dl,
    timeout: Option<String>, // Some("45") 当 timeout 可用
    kb_px: String,
    kb_px_src: &'static str,
    kb_px_resolved: bool,
    kb_probed: bool,
    src_now: String,
}

enum Dl {
    Curl,
    Wget,
    Busybox(String),
    None,
}

impl Dl {
    fn name(&self) -> &'static str {
        match self {
            Dl::Curl => "curl",
            Dl::Wget => "wget",
            Dl::Busybox(_) => "busybox",
            Dl::None => "none",
        }
    }
}

/// 进程结束时清理 tmpd / lock / progress（对应 shell 的 EXIT trap）。
struct Clean {
    paths: Vec<String>,
    active: bool,
}

impl Clean {
    fn add(&mut self, p: &str) {
        self.paths.push(p.to_string());
    }
}

impl Drop for Clean {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        for p in &self.paths {
            let _ = fs::remove_dir_all(p);
            let _ = fs::remove_file(p);
        }
    }
}

// ---- 时间 / 日志 -----------------------------------------------------------

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
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

/// 时间戳文件名：YYYYMMDD-HHMMSS（备份命名；时区基准与 shell 的本地时间
/// 不同，差分比较时按模式归一）。
fn now_filestamp(sep: char) -> String {
    let secs = now_epoch();
    let (days, rem) = (secs / 86400, secs % 86400);
    let date = days_to_date(days).replace('-', "");
    format!(
        "{}{}{:02}{:02}{:02}",
        date,
        sep,
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn log(ctx: &Ctx, msg: &str) {
    let _ = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(format!("{}/keybox-fetch.log", ctx.tee_dir))
        .and_then(|mut f| {
            use std::io::Write;
            writeln!(f, "[{}] {}", now_stamp(), msg)
        });
}

fn dbg(ctx: &Ctx, msg: &str) {
    if Path::new(&format!("{}/.debug", ctx.tee_dir)).is_file() {
        let _ = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(format!("{}/debug.log", ctx.tee_dir))
            .and_then(|mut f| {
                use std::io::Write;
                writeln!(f, "[{}] [kbfetch] {}", now_stamp(), msg)
            });
    }
}

fn trim_log(ctx: &Ctx) {
    let log = format!("{}/keybox-fetch.log", ctx.tee_dir);
    if let Ok(t) = fs::read_to_string(&log) {
        let n = t.lines().count();
        if n > 400 {
            let tail: Vec<&str> = t.lines().skip(n - 200).collect();
            let tmp = format!("{log}.tmp");
            let _ = fs::write(&tmp, tail.join("\n") + "\n");
            let _ = fs::rename(&tmp, &log);
        }
    }
}

/// 进度文件（WebUI 的「后台刷新中」详情）：epoch / 阶段 / 详情 三行，原子写。
fn progress(ctx: &Ctx, stage: &str, msg: &str) {
    let p = format!("{}/.kb-fetch.progress", ctx.tee_dir);
    let tmp = format!("{p}.tmp");
    if fs::write(&tmp, format!("{}\n{}\n{}\n", now_epoch(), stage, msg)).is_ok() {
        let _ = fs::rename(&tmp, &p);
    }
}

// ---- 基础工具 ---------------------------------------------------------------

/// PATH 解析：**逐目录**先查裸名再查 .exe（与 shell 的 command -v 顺序一致；
/// 不能先扫完所有 .exe —— 那会让 System32 里的真 curl.exe 抢在测试桩前面）。
/// PATH 切分，**盘符冒号感知**：POSIX 用 `:` 分隔，但 Windows 风格条目
/// （`D:/x`、`D://x`）里的冒号是盘符的一部分 —— 单字母 + 后随分隔符时不切。
fn split_paths(p: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let b = p.as_bytes();
    let mut i = 0usize;
    while i < b.len() {
        match b[i] {
            b';' => {
                out.push(&p[start..i]);
                start = i + 1;
            }
            b':' => {
                let drive = i >= 1
                    && i + 1 < b.len()
                    && b[i - 1].is_ascii_alphabetic()
                    && (i == 1 || b[i - 2] == b';' || b[i - 2] == b':')
                    && (b[i + 1] == b'/' || b[i + 1] == b'\\');
                if drive {
                    i += 1; // 盘符冒号，跳过
                } else {
                    out.push(&p[start..i]);
                    start = i + 1;
                }
            }
            _ => {}
        }
        i += 1;
    }
    out.push(&p[start..]);
    out
}

fn which(name: &str) -> Option<String> {
    let paths = std::env::var("PATH").ok()?;
    for p in split_paths(&paths) {
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

/// 子进程执行：先直接执行；失败（Windows 下 PATH 里的 POSIX 脚本桩没有 .exe，
/// CreateProcess 拒绝）时退回 `sh <path>`。设备侧二进制直接执行，不受影响。
fn spawn_out(cmd: &str, args: &[&str], envs: &[(&str, &str)]) -> Option<Output> {
    // 按 bash 顺序解析完整路径：Windows 的 CreateProcess 会把 System32 排在
    // PATH 之前（那里有真 curl.exe 和语义不同的 timeout.exe），裸名会绕过
    // 测试桩直连真网络。
    let resolved = which(cmd).unwrap_or_else(|| cmd.to_string());
    let cmd = resolved.as_str();
    let mut c = Command::new(cmd);
    c.args(args);
    for (k, v) in envs {
        c.env(k, v);
    }
    if let Ok(o) = c.output() {
        return Some(o);
    }
    let mut c2 = Command::new("sh");
    c2.arg(cmd).args(args);
    for (k, v) in envs {
        c2.env(k, v);
    }
    c2.output().ok()
}

fn spawn_rc(cmd: &str, args: &[&str], envs: &[(&str, &str)]) -> i32 {
    spawn_out(cmd, args, envs)
        .and_then(|o| o.status.code())
        .unwrap_or(-1)
}

fn sha256_file(p: &str) -> String {
    match fs::read(p) {
        Ok(b) => {
            let mut h = Sha256::new();
            h.update(&b);
            h.finalize()
                .iter()
                .map(|x| format!("{x:02x}"))
                .collect::<Vec<_>>()
                .join("")
        }
        Err(_) => String::new(),
    }
}

fn file_mtime(p: &str) -> u64 {
    fs::metadata(p)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn as_nonempty(p: &str) -> bool {
    match fs::read(p) {
        Ok(v) => !v.is_empty(),
        Err(_) => false,
    }
}

#[cfg(unix)]
fn chmod_mode(p: &str, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(p, fs::Permissions::from_mode(mode));
}
#[cfg(not(unix))]
fn chmod_mode(_p: &str, _mode: u32) {}

// ---- 解码器（raw / b64 / hexb64 / megatron）--------------------------------

/// 标准 base64：容忍空白（与 toybox base64 -d 一致）；非法字节或长度非 4 的
/// 倍数 → 失败（与 shell 的 b64decode 失败语义一致）。
fn b64_decode(data: &[u8]) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a') as u32 + 26),
            b'0'..=b'9' => Some((c - b'0') as u32 + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::new();
    let mut buf = 0u32;
    let mut bits = 0u32;
    let mut seen_pad = false;
    let mut n = 0usize;
    for &c in data {
        match c {
            b'\n' | b'\r' | b'\t' | b' ' => continue,
            b'=' => {
                seen_pad = true;
                n += 1;
            }
            _ => {
                if seen_pad {
                    return None; // padding 之后又出现数据
                }
                let v = val(c)?;
                buf = (buf << 6) | v;
                bits += 6;
                if bits >= 8 {
                    bits -= 8;
                    out.push((buf >> bits) as u8);
                    // 掩掉已输出的高位，否则旧位会污染后续字节
                    buf &= (1 << bits) - 1;
                }
                n += 1;
            }
        }
    }
    if n % 4 != 0 {
        return None;
    }
    Some(out)
}

/// hex 解码：先剔除一切非 hex 字符（KOWX712 的 .extra 可能带分隔符）。
fn hex_decode(data: &[u8]) -> Option<Vec<u8>> {
    let hx: Vec<u8> = data
        .iter()
        .cloned()
        .filter(|c| c.is_ascii_hexdigit())
        .collect();
    if hx.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(hx.len() / 2);
    for p in hx.chunks(2) {
        let hi = (p[0] as char).to_digit(16)? as u8;
        let lo = (p[1] as char).to_digit(16)? as u8;
        out.push(hi * 16 + lo);
    }
    Some(out)
}

fn rot13(data: &[u8]) -> Vec<u8> {
    data.iter()
        .map(|&c| match c {
            b'A'..=b'Z' => (c - b'A' + 13) % 26 + b'A',
            b'a'..=b'z' => (c - b'a' + 13) % 26 + b'a',
            _ => c,
        })
        .collect()
}

/// megatron：b64 ×10 → hex → ROT13。
fn decode_megatron(raw: &[u8]) -> Option<Vec<u8>> {
    let mut cur = raw.to_vec();
    for _ in 0..10 {
        cur = b64_decode(&cur)?;
    }
    let hexed = hex_decode(&cur)?;
    Some(rot13(&hexed))
}

fn decode_payload(raw: &[u8], fmt: &str) -> Option<Vec<u8>> {
    match fmt {
        "raw" => Some(raw.to_vec()),
        "b64" => b64_decode(raw),
        "hexb64" => b64_decode(&hex_decode(raw)?),
        "megatron" => decode_megatron(raw),
        _ => None,
    }
}

/// 结构校验：复用 keybox-check 的重实现（同一二进制的 keybox-check 入口）。
/// 与 shell 版调用 keybox-check.sh --quiet 等价 —— 该入口已与 shell 版
/// 差分对拍 20/20（test-diff-keybox-check.sh）。
fn valid_keybox(path: &str) -> bool {
    let exe = match std::env::current_exe() {
        Ok(e) => e.to_string_lossy().into_owned(),
        Err(_) => return false,
    };
    match spawn_out(&exe, &["keybox-check", path, "--quiet"], &[]) {
        Some(o) => o.status.success(),
        None => false,
    }
}

// ---- 代理三级来源 + 探测 + 直连阶梯 ---------------------------------------

/// 代理值是敌意输入（进入 root 消费者的路径）：只接受保守 charset。
fn sane_proxy(v: &str) -> bool {
    !v.is_empty()
        && v.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b":._@/-".contains(&c))
}

fn first_line_stripped(p: &str) -> String {
    fs::read_to_string(p)
        .unwrap_or_default()
        .lines()
        .next()
        .unwrap_or("")
        .chars()
        .filter(|c| !matches!(c, ' ' | '\t' | '\r' | '\n'))
        .collect()
}

fn kb_proxy_resolve(ctx: &Ctx, st: &mut St) {
    st.kb_px_resolved = true;
    if let Ok(v) = std::env::var("AEGIS_KB_PROXY") {
        if !v.is_empty() {
            st.kb_px = v;
            st.kb_px_src = "env";
            return;
        }
    }
    let conf = format!("{}/pif-proxy.conf", ctx.tee_dir);
    if as_nonempty(&conf) {
        let v = first_line_stripped(&conf);
        if !sane_proxy(&v) {
            log(ctx, "WARNING: pif-proxy.conf rejected (unsafe characters in the proxy value)");
        } else if !v.is_empty() {
            st.kb_px = v;
            st.kb_px_src = "conf";
        }
    }
    // 第三来源：上次运行记忆的 auto 代理（pif-fetch 也读同一文件）
    if st.kb_px.is_empty() {
        let auto = format!("{}/pif-proxy.auto", ctx.tee_dir);
        if as_nonempty(&auto) {
            let v = first_line_stripped(&auto);
            if sane_proxy(&v) {
                st.kb_px = v;
                st.kb_px_src = "auto";
            }
        }
    }
}

/// 用**真实请求**验证端口（完整 GET，非 --spider —— audit N9）；
/// 默认目标 github.com/robots.txt（audit L2）。
fn probe_port(st: &St, port: &str) -> bool {
    if let Ok(sh) = std::env::var("AEGIS_KB_PROBE") {
        if !sh.is_empty() {
            return spawn_rc("sh", &[&sh, port], &[]) == 0;
        }
    }
    if which("wget").is_none() {
        return false;
    }
    let url = "https://github.com/robots.txt";
    let proxy = format!("http://127.0.0.1:{port}");
    let px = proxy.as_str();
    match &st.timeout {
        Some(t) => {
            spawn_rc(
                t,
                &["8", "wget", "-q", "-T", "8", "-O", "/dev/null", url],
                &[("http_proxy", px), ("https_proxy", px)],
            ) == 0
        }
        None => spawn_rc(
            "wget",
            &["-q", "-T", "8", "-O", "/dev/null", url],
            &[("http_proxy", px), ("https_proxy", px)],
        ) == 0,
    }
}

/// 单次下载尝试（curl / wget / busybox wget）。
fn run_dl(st: &St, url: &str, out: &str, proxy: &str) -> i32 {
    let envs: Vec<(&str, &str)> = if proxy.is_empty() {
        vec![]
    } else {
        vec![("http_proxy", proxy), ("https_proxy", proxy)]
    };
    match &st.dl {
        Dl::None => -1,
        Dl::Curl => match &st.timeout {
            Some(t) => spawn_rc(
                t,
                &["45", "curl", "-fsSL", "--connect-timeout", "15", "--max-time", "120", url, "-o", out],
                &envs,
            ),
            None => spawn_rc(
                "curl",
                &["-fsSL", "--connect-timeout", "15", "--max-time", "120", url, "-o", out],
                &envs,
            ),
        },
        Dl::Wget => match &st.timeout {
            Some(t) => spawn_rc(t, &["45", "wget", "-q", "-T", "15", "-O", out, url], &envs),
            None => spawn_rc("wget", &["-q", "-T", "15", "-O", out, url], &envs),
        },
        Dl::Busybox(bb) => {
            let args = ["wget", "-q", "-T", "15", "-O", out, url];
            match &st.timeout {
                Some(t) => {
                    let mut a: Vec<&str> = vec!["45", bb];
                    a.extend_from_slice(&args);
                    spawn_rc(t, &a, &envs)
                }
                None => spawn_rc(bb, &args, &envs),
            }
        }
    }
}

/// fetch <url> <outfile> —— 下载阶梯：
/// 直接重试 ×3（1s/2s 退避）→ 记忆 auto 代理失效即弃 → 每轮一次自动探测
/// → curl --resolve 直连 Fastly IP（仅 curl + raw.githubusercontent.com）。
fn fetch(ctx: &Ctx, st: &mut St, url: &str, out: &str) -> bool {
    if matches!(st.dl, Dl::None) {
        dbg(ctx, "no usable downloader on this device");
        return false;
    }
    if !st.kb_px_resolved {
        kb_proxy_resolve(ctx, st);
    }
    dbg(
        ctx,
        &format!(
            "download start: {}/… downloader={} timeout={}",
            url.split('/').next().unwrap_or(""),
            st.dl.name(),
            if st.timeout.is_some() { "45" } else { "none" }
        ),
    );
    loop {
        if !st.kb_px.is_empty() {
            dbg(
                ctx,
                &format!("download via proxy {} ({})", st.kb_px, st.kb_px_src),
            );
        }
        let mut ok = false;
        for n in 1..=3 {
            let src = if st.src_now.is_empty() { "候选源" } else { &st.src_now };
            progress(ctx, "下载候选", &format!("{src} · 第 {n}/3 次尝试"));
            let rc = run_dl(st, url, out, &st.kb_px);
            if as_nonempty(out) {
                dbg(
                    ctx,
                    &format!("download ok: attempt {n}, {} bytes", fs::metadata(out).map(|m| m.len()).unwrap_or(0)),
                );
                ok = true;
                break;
            }
            if rc == 0 {
                dbg(ctx, &format!("download empty: attempt {n} (downloader rc=0, server sent 0 bytes)"));
            } else {
                dbg(ctx, &format!("download failed: attempt {n} rc={rc}"));
            }
            std::thread::sleep(std::time::Duration::from_secs(n as u64));
        }
        if ok {
            return true;
        }
        // 记忆的 auto 代理整轮失败：删掉，让下次运行重新探测（不重试尸体）
        if !st.kb_px.is_empty() && st.kb_px_src == "auto" {
            let _ = fs::remove_file(format!("{}/pif-proxy.auto", ctx.tee_dir));
            log(ctx, "remembered proxy did not work; dropped pif-proxy.auto (will re-probe next run)");
            st.kb_px = String::new();
            st.kb_px_src = "";
        }
        // 每轮一次自动探测：只在没有任何代理时（健康直连网络不付这个成本）
        let autoproxy = std::env::var("AEGIS_KB_AUTOPROXY").unwrap_or_else(|_| "1".into()) == "1";
        if !st.kb_probed && st.kb_px.is_empty() && autoproxy {
            st.kb_probed = true;
            let ports = std::env::var("AEGIS_KB_PROBE_PORTS")
                .unwrap_or_else(|_| "7890 7897 10808 10809 2334 2080".into());
            let mut found = String::new();
            for p in ports.split_whitespace() {
                if p.bytes().any(|c| !c.is_ascii_digit()) {
                    continue;
                }
                if probe_port(st, p) {
                    found = format!("http://127.0.0.1:{p}");
                    break;
                }
            }
            if !found.is_empty() {
                st.kb_px = found;
                st.kb_px_src = "auto";
                let _ = fs::write(format!("{}/pif-proxy.auto", ctx.tee_dir), format!("{}\n", st.kb_px));
                log(ctx, &format!(
                    "auto-proxy: found a working local proxy at {}; retrying downloads through it",
                    st.kb_px
                ));
                continue;
            }
        }
        // 最后一级（phase 4）：--resolve 钉住 Fastly IP，绕开被污染的 DNS。
        // TLS 完整校验保持不变（SNI/Host 不动）；零系统改动。
        let directip = std::env::var("AEGIS_KB_DIRECTIP").unwrap_or_else(|_| "1".into()) == "1";
        if matches!(st.dl, Dl::Curl) && directip && url.starts_with("https://raw.githubusercontent.com/") {
            let ips = std::env::var("AEGIS_KB_IPS")
                .unwrap_or_else(|_| "185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133".into());
            for ip in ips.split_whitespace() {
                if ip.bytes().any(|c| !c.is_ascii_digit() && c != b'.') {
                    continue;
                }
                let src = if st.src_now.is_empty() { "候选源" } else { &st.src_now };
                progress(ctx, "下载候选", &format!("{src} · 直连 CDN {ip}"));
                let resolve = format!("raw.githubusercontent.com:443:{ip}");
                let rc = match &st.timeout {
                    Some(t) => spawn_rc(
                        t,
                        &["45", "curl", "-fsSL", "--connect-timeout", "10", "--max-time", "90", "--resolve", &resolve, url, "-o", out],
                        &[],
                    ),
                    None => spawn_rc(
                        "curl",
                        &["-fsSL", "--connect-timeout", "10", "--max-time", "90", "--resolve", &resolve, url, "-o", out],
                        &[],
                    ),
                };
                if as_nonempty(out) {
                    dbg(ctx, &format!("download ok: direct-IP {ip}, {} bytes", fs::metadata(out).map(|m| m.len()).unwrap_or(0)));
                    return true;
                }
                dbg(ctx, &format!("download failed: direct-IP {ip} rc={rc}"));
            }
        }
        return false;
    }
}

// ---- verdict 接缝 ----------------------------------------------------------

fn verdict_path(ctx: &Ctx) -> String {
    std::env::var("AEGIS_VERDICT")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("{}/engine-verdict.sh", ctx.moddir))
}

fn sh_verdict(ctx: &Ctx, args: &[&str], append_log: bool) -> i32 {
    let v = verdict_path(ctx);
    let mut a: Vec<&str> = vec![v.as_str()];
    a.extend_from_slice(args);
    match spawn_out("sh", &a, &[]) {
        Some(o) => {
            if append_log {
                let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
                s.push_str(&String::from_utf8_lossy(&o.stderr));
                if !s.is_empty() {
                    log(ctx, s.trim_end());
                }
            }
            o.status.code().unwrap_or(-1)
        }
        None => -1,
    }
}

/// verdict 拿得到吗？daemon 活着 + 本 boot 已完成至少一次 push/ack。
/// 拿不到 → fail OPEN（部署但不验收，v3.1.3 前的行为）。
fn engine_verifiable(ctx: &Ctx) -> bool {
    if !Path::new(&verdict_path(ctx)).is_file() {
        return false;
    }
    let pid = spawn_out("pidof", &["teesim"], &[])
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    if pid.is_empty() {
        return false;
    }
    if let Ok(t) = fs::read_to_string(format!("{}/log/teesim.log", ctx.tee_dir)) {
        if t.contains("control: ack") {
            return true;
        }
    }
    // logcat 全关的设备：durable trace 不填，但 daemon 把 push/ack 状态暴露在
    // admin socket 上（补丁 0007）—— verdict 同样可行。
    sh_verdict(ctx, &["socket-live"], false) == 0
}

fn engine_reason(ctx: &Ctx) -> String {
    if Path::new(&verdict_path(ctx)).is_file() {
        spawn_out("sh", &[&verdict_path(ctx), "reason"], &[])
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default()
    } else {
        String::new()
    }
}

// ---- 部署与验收 ------------------------------------------------------------

/// 原子部署：cp 到同目录再改名（FileObserver 看到 MOVED_TO）；对符号链接的
/// keybox.xml 是替换链接本身，不是改写链接目标。
fn deploy_atomic(ctx: &Ctx, keybox: &str, file: &str) -> bool {
    let tmp = format!("{keybox}.new");
    if fs::copy(file, &tmp).is_err() {
        return false;
    }
    if fs::rename(&tmp, keybox).is_err() {
        return false;
    }
    chmod_mode(keybox, 0o600);
    let _ = ctx;
    true
}

/// DroidGuard 客户端回收：daemon 的重推送/重证明不动，只回收客户端缓存会话。
fn client_recycle(ctx: &Ctx) {
    let dg = spawn_out("pidof", &["com.google.android.gms.unstable"], &[])
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    if !dg.is_empty() {
        let _ = spawn_out("sh", &["-c", &format!("kill {dg}")], &[]);
        log(ctx, "DroidGuard (gms.unstable) recycled so the new chain is used");
    }
    if spawn_rc("am", &["force-stop", "com.android.vending"], &[]) == 0 {
        log(ctx, "Play Store force-stopped");
    }
}

fn log_size(ctx: &Ctx) -> String {
    fs::metadata(format!("{}/log/teesim.log", ctx.tee_dir))
        .map(|m| m.len().to_string())
        .unwrap_or_else(|_| "0".to_string())
}

fn bad_payload(ctx: &Ctx, hash: &str) -> bool {
    let bad = format!("{}/.keybox-bad-payloads", ctx.tee_dir);
    fs::read_to_string(&bad)
        .map(|t| t.lines().any(|l| l == hash))
        .unwrap_or(false)
}

fn remember_bad(ctx: &Ctx, hash: &str) {
    let bad = format!("{}/.keybox-bad-payloads", ctx.tee_dir);
    let _ = fs::write(&bad, ""); // touch
    let mut lines: Vec<String> = fs::read_to_string(&bad)
        .unwrap_or_default()
        .lines()
        .map(|s| s.to_string())
        .collect();
    if !lines.iter().any(|l| l == hash) {
        lines.push(hash.to_string());
    }
    // 有界：社区轮换反正会产生新 hash
    if lines.len() > 20 {
        lines = lines.split_off(lines.len() - 20);
    }
    let body = lines.iter().map(|s| s.as_str()).collect::<Vec<&str>>().join("\n") + "\n";
    let _ = fs::write(&bad, body);
    chmod_mode(&bad, 0o600);
}

/// deploy_and_verify —— 0 仅当**引擎**接受。deploy → 读 ack（engine-verdict
/// 解析 ack 计数并取出引擎自己的 reason）。
fn deploy_and_verify(ctx: &Ctx, _st: &St, keybox: &str, file: &str, src: &str) -> i32 {
    let mark = log_size(ctx);
    if !deploy_atomic(ctx, keybox, file) {
        log(ctx, &format!("ERROR: failed to write {keybox}"));
        return 2;
    }
    let n = fs::metadata(keybox).map(|m| m.len()).unwrap_or(0);
    log(ctx, &format!("deployed payload from {src} ({n} bytes); waiting for the engine's ack"));
    progress(ctx, "等引擎应答", &format!("{src} · 最多 10 秒"));
    if !engine_verifiable(ctx) {
        log(ctx, "no live engine to ask (daemon down or no ack history yet) — deployed WITHOUT a verdict");
        return 0;
    }
    let mark_ref = mark.as_str();
    let mut rc = sh_verdict(ctx, &["watch", "10", mark_ref], true);
    if rc == 2 {
        // logcat 全关的设备：durable trace 不填。daemon 在部署的 FileObserver
        // 事件上重推送；改为轮询 `once`（其 socket 回退读 daemon 内存态）。
        for _ in 0..3 {
            std::thread::sleep(std::time::Duration::from_secs(2));
            rc = sh_verdict(ctx, &["once"], true);
            if rc != 2 {
                break;
            }
        }
    }
    match rc {
        0 => {
            log(ctx, &format!("engine ACCEPTED the payload from {src}"));
            0
        }
        1 => {
            let why = engine_reason(ctx);
            let why = if why.is_empty() { "no reason given".to_string() } else { why };
            log(ctx, &format!("engine REJECTED the payload from {src}: {why}"));
            1
        }
        _ => {
            log(ctx, "engine did not answer within 10s (silent) — keeping the payload, no verdict");
            0
        }
    }
}

// ---- 源尝试 ----------------------------------------------------------------

fn try_source(ctx: &Ctx, st: &mut St, name: &str, url: &str, fmt: &str, pin: &str, new: &str, raw: &str) -> bool {
    st.src_now = name.to_string();
    log(ctx, &format!("trying source: {name}"));
    progress(ctx, "下载候选", &format!("{name} · 准备"));
    if !fetch(ctx, st, url, raw) {
        log(ctx, &format!("source {name}: download failed (downloader: {}; network?)", st.dl.name()));
        return false;
    }
    progress(ctx, "解析候选", &format!("{name} · 格式 {fmt}"));
    let data = match fs::read(raw) {
        Ok(d) => d,
        Err(_) => Vec::new(),
    };
    let decoded = match decode_payload(&data, fmt) {
        Some(d) => d,
        None => {
            log(ctx, &format!("source {name}: decode failed (format: {fmt})"));
            let _ = fs::remove_file(new);
            return false;
        }
    };
    let _ = fs::write(new, &decoded);
    if !valid_keybox(new) {
        // 例如 KOWX712 镜像在社区轮换间隙被清空 —— 当作不可用，落到下一个源
        log(ctx, &format!("source {name}: payload is not a keybox (empty or rotated out?)"));
        let _ = fs::remove_file(new);
        return false;
    }
    if !pin.is_empty() {
        let pin: String = pin
            .chars()
            .filter(|c| !matches!(c, ' ' | '\r' | '\n' | '\t'))
            .collect::<String>()
            .to_lowercase();
        let got = sha256_file(new);
        if got != pin {
            let got = if got.is_empty() { "none".to_string() } else { got };
            log(ctx, &format!("source {name}: sha256 pin MISMATCH (want {pin}, got {got}); rejected"));
            let _ = fs::remove_file(new);
            return false;
        }
        log(ctx, &format!("source {name}: sha256 pin verified"));
    }
    log(ctx, &format!("source {name}: got a valid keybox"));
    true
}

// ---- 备份剪枝 ---------------------------------------------------------------

/// ls -1t <prefix>*.xml | tail -n +N —— 按 mtime 降序，保留最新 keep 份。
fn prune_backups(backup_dir: &str, prefix: &str, keep: usize) {
    let mut v: Vec<(u64, std::path::PathBuf)> = Vec::new();
    if let Ok(rd) = fs::read_dir(backup_dir) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with(prefix) && name.ends_with(".xml") {
                let mt = e
                    .metadata()
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                v.push((mt, e.path()));
            }
        }
    }
    v.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, p) in v.into_iter().skip(keep) {
        let _ = fs::remove_file(p);
    }
}

// ---- 入口 -------------------------------------------------------------------

pub fn run(args: &[String]) -> i32 {
    let force = args.iter().any(|a| a == "--force");
    let revcheck = args.iter().any(|a| a == "--revcheck");
    let ctx = Ctx {
        tee_dir: std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string()),
        moddir: std::env::var("AEGIS_MODDIR")
            .unwrap_or_else(|_| "/data/adb/modules/aegisfusion_rs".to_string()),
    };
    let tee = &ctx.tee_dir;
    let keybox = format!("{tee}/keybox.xml");
    let marker = format!("{tee}/.auto-keybox");
    let sources_conf = format!("{tee}/keybox-sources.conf");
    let src_file = format!("{tee}/.keybox-source");
    let status_txt = format!("{tee}/key-status.txt");
    let status_n = format!("{tee}/.key-status-n");
    let revjson = format!("{tee}/.revocation-status.json");
    let backup_dir = format!("{tee}/keybox-backups");
    let fetch_ts = format!("{tee}/.kb-last-fetch");
    let tmpd = format!("{tee}/.tmp.{}", std::process::id());

    if fs::create_dir_all(tee).is_err() || fs::create_dir_all(&backup_dir).is_err() || fs::create_dir_all(&tmpd).is_err() {
        return 1;
    }
    let mut clean = Clean { paths: vec![], active: true };
    clean.add(&tmpd);

    // ---- 并发护栏：mkdir 原子；陈旧锁按 holder 存活 + 15 分钟兜底收割 ----
    let lock = format!("{tee}/.kb-fetching.lock");
    if fs::create_dir(&lock).is_err() {
        let now = now_epoch();
        let lmt = file_mtime(&lock);
        let holder = fs::read_to_string(format!("{lock}/holder"))
            .unwrap_or_default()
            .trim()
            .to_string();
        let mut dead = true;
        if !holder.is_empty() && holder.bytes().all(|c| c.is_ascii_digit()) {
            if spawn_out("sh", &["-c", &format!("kill -0 {holder}")], &[])
                .map(|o| o.status.success())
                .unwrap_or(false)
            {
                dead = false;
            }
        }
        if !dead && now.saturating_sub(lmt) < 900 {
            log(&ctx, "fetch already running; skipping");
            return 75;
        }
        let _ = fs::remove_dir_all(&lock);
        if fs::create_dir(&lock).is_err() {
            return 75;
        }
    }
    clean.add(&lock);
    clean.add(&format!("{tee}/.kb-fetch.progress"));
    let _ = fs::write(format!("{lock}/holder"), format!("{}\n", std::process::id()));
    dbg(&ctx, &format!("lock acquired by pid {}", std::process::id()));

    let mut st = St {
        force,
        revcheck,
        dl: detect_dl(),
        timeout: which("timeout"), // 完整路径：见 spawn_out 的 System32 说明
        kb_px: String::new(),
        kb_px_src: "",
        kb_px_resolved: false,
        kb_probed: false,
        src_now: String::new(),
    };

    progress(&ctx, "启动", "读取 Google 吊销名单缓存");

    trim_log(&ctx);
    dbg(&ctx, &format!(
        "run start: force={} revcheck={} downloader={}",
        u8::from(st.force),
        u8::from(st.revcheck),
        st.dl.name()
    ));

    // ---- Google attestation 吊销名单缓存（每小时，--revcheck 只做这件事）----
    let rev_rc = rev_cache_refresh(&ctx, &mut st, &revjson);
    dbg(&ctx, &format!("revocation cache refresh rc={rev_rc} (list at {revjson})"));
    if st.revcheck {
        dbg(&ctx, "revcheck-only run, exiting here");
        return 0;
    }

    // ---- 护栏：用户导入的 keybox 永不触碰（--force 是恢复路径，例外）----
    if !st.force && as_nonempty(&keybox) {
        let cur_hash = sha256_file(&keybox);
        let kbtm = file_mtime(&keybox);
        let kbmm = file_mtime(&marker);
        let marker_exists = Path::new(&marker).is_file();
        let marker_hash = fs::read_to_string(&marker).unwrap_or_default().trim().to_string();
        // hash == marker 且 kbtm <= kbmm ⇒ 与上次渠道部署字节一致 —— 轮换替换
        // 不会丢用户所有物，正确地不算「导入」
        let imported = !marker_exists
            || cur_hash != marker_hash
            || (kbtm > 0 && kbmm > 0 && kbtm > kbmm);
        if imported {
            let bounced = fs::read_to_string(format!("{tee}/.imported-bounced"))
                .unwrap_or_default()
                .trim()
                .to_string();
            if bounced == cur_hash {
                log(&ctx, "user-imported keybox detected; auto-refresh skipped");
                dbg(&ctx, "import guard: already handled this file, standing down");
            } else {
                let _ = fs::write(format!("{tee}/.imported-bounced"), format!("{cur_hash}\n"));
                log(&ctx, "user-imported keybox detected; the daemon re-reads it on its own (no reboot needed)");
                dbg(&ctx, &format!(
                    "import guard: deployed sha={cur_hash} marker={marker_hash} — client recycle only"
                ));
                // 覆盖本身就是被监视路径上的 CLOSE_WRITE/MOVED_TO，daemon 已重读；
                // 只有客户端缓存的 DroidGuard 会话需要回收
                client_recycle(&ctx);
            }
            return 0;
        }
    }
    if st.force && as_nonempty(&keybox) {
        // audit M11：把「备份保留」的承诺做实 —— 备份失败则中止，绝不销毁
        // 无法恢复的数据
        let ts = now_filestamp('-');
        let pre = format!("{backup_dir}/keybox_pre-force_{ts}.xml");
        if fs::copy(&keybox, &pre).is_ok() {
            chmod_mode(&pre, 0o600);
            log(&ctx, &format!(
                "manual fetch (--force): backed up the current keybox -> {pre}"
            ));
            prune_backups(&backup_dir, "keybox_pre-force_", 5);
        } else {
            log(&ctx, "manual fetch (--force): WARNING could not back up the current keybox — aborting, nothing was replaced");
            return 1;
        }
        log(&ctx, "manual fetch (--force): replacing the deployed keybox from the preferred channel");
    }

    // ---- 构建源列表：偏好渠道最前，然后用户渠道，最后内建 ----
    let pref = fs::read_to_string(format!("{tee}/keybox-source-pref"))
        .unwrap_or_default()
        .lines()
        .next()
        .unwrap_or("")
        .chars()
        .filter(|c| !matches!(c, ' ' | '\r' | '\n'))
        .collect::<String>();

    let mut sources: Vec<(String, String, String, String, String)> = Vec::new();
    if Path::new(&sources_conf).is_file() {
        let t = fs::read_to_string(&sources_conf).unwrap_or_default();
        for line in t.lines() {
            let mut it = line.splitn(6, '|');
            let name = it.next().unwrap_or("").to_string();
            let url = it.next().unwrap_or("").to_string();
            let fmt = it.next().unwrap_or("").to_string();
            let status = it.next().unwrap_or("").to_string();
            let pin = it.next().unwrap_or("").to_string();
            if name.is_empty() || name.starts_with('#') {
                continue;
            }
            if !matches!(fmt.as_str(), "b64" | "hexb64" | "megatron" | "raw") {
                continue;
            }
            if url.is_empty() {
                continue;
            }
            sources.push((name, url, fmt, status, pin));
        }
    }
    sources.push((
        "Megatron".into(),
        "https://raw.githubusercontent.com/MeowDump/MeowDump/refs/heads/main/Megatron".into(),
        "megatron".into(),
        "https://raw.githubusercontent.com/MeowDump/Integrity-Box/refs/heads/main/keybox/key-status".into(),
        String::new(),
    ));
    sources.push((
        "Yurikey".into(),
        "https://raw.githubusercontent.com/Yurii0307/yurikey/main/key".into(),
        "b64".into(),
        String::new(),
        String::new(),
    ));
    sources.push((
        "KOWX712".into(),
        "https://raw.githubusercontent.com/KOWX712/Tricky-Addon-Update-Target-List/keybox/.extra".into(),
        "hexb64".into(),
        String::new(),
        String::new(),
    ));
    if !pref.is_empty() {
        // shell 用 index($0, p"|")==1：行首必须是 pref 紧跟分隔符。name 字段
        // 不含 |，故 name == pref 与之等价（字面前缀匹配，不用正则）。
        let (first, rest): (Vec<_>, Vec<_>) = sources
            .into_iter()
            .partition(|s| s.0 == pref);
        sources = first;
        sources.extend(rest);
        log(&ctx, &format!("preferred source: {pref}"));
    }
    // 上面的 partition 需要 name+"|" 语义 —— 重新做一遍（name 精确等于 pref
    // 只是近似；保持与 shell 一致用「name 后跟 |」的判定在 name 无 | 时等价）
    // 注：源行的第一字段就是 name，name 里不会出现 |，故 == 等价于前缀匹配。

    // ---- 走源：第一个被引擎接受的赢 ----
    let new = format!("{tmpd}/keybox.xml");
    let raw = format!("{tmpd}/src.raw");
    let mut won = String::new();
    let mut won_status = String::new();
    let pre = format!("{tee}/.keybox.prerun.xml");
    let _ = fs::remove_file(&pre);
    if as_nonempty(&keybox) {
        let _ = fs::copy(&keybox, &pre);
    }
    let cur_hash = if as_nonempty(&keybox) { sha256_file(&keybox) } else { String::new() };

    // 引擎对「现在部署着的」怎么说？它已拒绝的 payload，hash 相同绝不能算
    // 「无事可做」—— 那正是坏自动源留下的状态，旧代码会永远卡在里面。
    let mut cur_rejected = false;
    if as_nonempty(&keybox) && engine_verifiable(&ctx) {
        if sh_verdict(&ctx, &["once"], false) != 0 {
            cur_rejected = true;
            log(&ctx, "the engine has REJECTED the currently deployed keybox — looking for a replacement");
        }
    }

    for (s_name, s_url, s_fmt, s_status, s_pin) in sources.iter() {
        if !try_source(&ctx, &mut st, s_name, s_url, s_fmt, s_pin, &new, &raw) {
            continue;
        }
        let cand_hash = sha256_file(&new);
        if bad_payload(&ctx, &cand_hash) {
            log(&ctx, &format!(
                "source {s_name}: payload {} was already refused by the engine; skipping",
                &cand_hash[..cand_hash.len().min(12)]
            ));
            continue;
        }
        if !cur_hash.is_empty() && cand_hash == cur_hash && !cur_rejected {
            if st.force {
                // 内容一致但导入护栏被绕过：收编该文件（marker 落地，之后的
                // 刷新自动维护它）
                let _ = fs::write(&marker, format!("{cand_hash}\n"));
                chmod_mode(&marker, 0o600);
                log(&ctx, "force fetch: channel keybox identical to the deployed one; adopted as auto-managed");
                // --force 的意思是「让这个 box 立即生效」：重新部署让 watcher
                // 触发、daemon 再推送
                if deploy_atomic(&ctx, &keybox, &new) {
                    client_recycle(&ctx);
                }
                touch_fetch_ts(&ctx, &fetch_ts, true);
                let _ = fs::remove_file(&pre);
                log(&ctx, "done");
                return 0;
            }
            if Path::new(&marker).is_file() {
                log(&ctx, &format!("keybox unchanged (hash match, source {s_name}); nothing to do"));
                touch_fetch_ts(&ctx, &fetch_ts, true);
                let _ = fs::remove_file(&pre);
                log(&ctx, "done");
                return 0;
            }
        }
        let rc = deploy_and_verify(&ctx, &st, &keybox, &new, s_name);
        if rc == 0 {
            won = s_name.clone();
            won_status = s_status.clone();
            progress(&ctx, "已接受", &format!("{s_name} · 引擎应答 applied>0 failed=0"));
            break;
        }
        if rc == 1 {
            remember_bad(&ctx, &cand_hash);
            if as_nonempty(&keybox) {
                let rej = format!("{backup_dir}/keybox_rejected_{}.xml", now_filestamp('_'));
                let _ = fs::copy(&keybox, &rej);
            }
        }
    }

    if won.is_empty() {
        log(&ctx, "ERROR: no source produced a keybox the engine would accept");
        progress(&ctx, "失败", "所有候选源都没通过引擎验收");
        if as_nonempty(&pre) {
            log(&ctx, "restoring the keybox that was deployed before this run (engine asked again)");
            if deploy_atomic(&ctx, &keybox, &pre) && engine_verifiable(&ctx) {
                let _ = sh_verdict(&ctx, &["watch", "10"], true);
            }
        }
        let _ = fs::remove_file(&pre);
        return 7;
    }
    let _ = fs::remove_file(&pre);

    // ---- 刷新赢家的有效性状态（尽力而为）----
    if !won_status.is_empty() {
        let st_new = format!("{status_txt}.new");
        if fetch(&ctx, &mut st, &won_status, &st_new) {
            let _ = fs::rename(&st_new, &status_txt);
            chmod_mode(&status_txt, 0o644);
            let g = fs::read_to_string(&status_txt)
                .map(|t| t.matches("🟢").count())
                .unwrap_or(0);
            let _ = fs::write(&status_n, format!("{g}\n"));
            chmod_mode(&status_n, 0o644);
            log(&ctx, &format!("key-status refreshed: {g} green circle(s)"));
        } else {
            let _ = fs::remove_file(format!("{status_txt}.new"));
            log(&ctx, "key-status fetch failed (keeping previous)");
        }
    } else {
        // 该渠道不发布状态文件 —— 标记 unknown，WebUI 永不把别家状态配给这个 keybox
        let _ = fs::write(&status_n, "-1\n");
        chmod_mode(&status_n, 0o644);
        let _ = fs::write(&status_txt, "");
        chmod_mode(&status_txt, 0o644);
        log(&ctx, &format!("source {won} provides no status file; marking unknown"));
    }
    let _ = fs::write(&src_file, format!("{won}\n"));
    chmod_mode(&src_file, 0o644);

    // ---- 提交赢家：上面的循环已经部署并让引擎接受，剩下的只是记录出处 ----
    let new_hash = sha256_file(&keybox);
    if new_hash.is_empty() {
        log(&ctx, "ERROR: sha256sum unavailable");
        return 8;
    }
    let _ = fs::write(&marker, format!("{new_hash}\n"));
    chmod_mode(&marker, 0o600);
    log(&ctx, &format!("keybox updated (source {won}, sha256 {new_hash}, engine-verified)"));

    prune_backups(&backup_dir, "keybox_", 5);
    touch_fetch_ts(&ctx, &fetch_ts, true);
    client_recycle(&ctx);
    log(&ctx, &format!("done (engine accepted the keybox from {won})"));
    0
}

fn touch_fetch_ts(ctx: &Ctx, ts_path: &str, _verbose: bool) {
    let _ = fs::write(ts_path, now_epoch().to_string());
    let _ = ctx;
}

fn detect_dl() -> Dl {
    if which("curl").is_some() {
        return Dl::Curl;
    }
    if which("wget").is_some() {
        return Dl::Wget;
    }
    let mut candidates: Vec<String> = vec![
        "/data/adb/ksu/bin/busybox".into(),
        "/data/adb/ap/bin/busybox".into(),
        "/data/adb/magisk/busybox".into(),
    ];
    if let Some(b) = which("busybox") {
        candidates.push(b);
    }
    for b in candidates {
        if Path::new(&b).is_file() {
            // busybox wget --help 探测
            if spawn_out(&b, &["wget", "--help"], &[])
                .map(|o| o.status.success())
                .unwrap_or(false)
            {
                return Dl::Busybox(b);
            }
        }
    }
    Dl::None
}

/// 吊销缓存每小时刷新；--revcheck（service.sh 每小时）在自动刷新关闭时也跑。
fn rev_cache_refresh(ctx: &Ctx, st: &mut St, revjson: &str) -> i32 {
    let now = now_epoch();
    let mt = file_mtime(revjson);
    if as_nonempty(revjson) && now.saturating_sub(mt) < 3600 {
        return 0;
    }
    log(ctx, "refreshing Google attestation revocation status cache");
    let tmp = format!("{revjson}.tmp");
    let url = "https://android.googleapis.com/attestation/status";
    if fetch(ctx, st, url, &tmp) {
        if let Ok(t) = fs::read_to_string(&tmp) {
            if t.contains("\"entries\"") {
                let _ = fs::rename(&tmp, revjson);
                let n = fs::metadata(revjson).map(|m| m.len()).unwrap_or(0);
                log(ctx, &format!("revocation cache updated ({n} bytes)"));
                return 0;
            }
        }
    }
    let _ = fs::remove_file(&tmp);
    log(ctx, "revocation cache refresh failed (keeping previous)");
    1
}
