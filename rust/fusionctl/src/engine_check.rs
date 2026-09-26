//! engine-check —— TEE 半区的一次性健康报告（重实现）
//!
//! 契约：`docs/CONTRACT-management.md` §4（原 `module/engine-check.sh`，258 行）。
//! 回答一个问题：引擎真的在服务请求吗？（进程活着但从不 push 的 daemon 从外面
//! 看完全健康，而每个 app 拿到的仍是真实硬件证明。）
//!
//! 输出纯文本（可整段粘贴）：不打印 keybox 内容；IMEI/IMEI2/MEID/serial 在每段
//! 日志尾里被 mask_ids 脱敏（audit H1）；/status 的 JSON 不原文打印（audit N1）。
//!
//! mask_ids 是 4 条 sed -E 规则的**纯 Rust 复刻**（无 regex crate）——逐条按
//! sed 的顺序应用：单引号形式 → JSON 形式 → 无引号形式 → 空白分隔形式。
//! POSIX ERE 的最左最长语义在这里退化为：最左位置 + 该位置最长的 key
//! （"imei2" 内的 "imei" 因定界符不匹配天然不会误选）。

use std::fs;
use std::io::Write as _;
use std::path::Path;
use std::process::Command;

// ---- PATH 解析（与 keybox_fetch 相同：bash 顺序 + 盘符冒号感知 + 脚本回退）----

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
                    i += 1;
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

/// 先按解析出的完整路径执行；失败（Windows 下 POSIX 脚本桩）回退 `sh <path>`。
fn spawn_out(cmd: &str, args: &[&str]) -> Option<std::process::Output> {
    let resolved = which(cmd).unwrap_or_else(|| cmd.to_string());
    let mut c = Command::new(&resolved);
    c.args(args);
    if let Ok(o) = c.output() {
        return Some(o);
    }
    let mut c2 = Command::new("sh");
    c2.arg(&resolved).args(args);
    c2.output().ok()
}

// ---- 基础工具 ---------------------------------------------------------------

fn say(msg: &str) {
    let _ = writeln!(std::io::stdout(), "{msg}");
}

fn head_(title: &str) {
    let _ = writeln!(std::io::stdout());
    let _ = writeln!(std::io::stdout(), "== {title} ==");
}

fn have(name: &str) -> bool {
    which(name).is_some()
}

fn read_lines(p: &str) -> Vec<String> {
    fs::read_to_string(p)
        .map(|t| t.lines().map(|s| s.to_string()).collect())
        .unwrap_or_default()
}

fn file_bytes(p: &str) -> Option<u64> {
    fs::metadata(p).ok().map(|m| m.len())
}

fn as_nonempty(p: &str) -> bool {
    match fs::read(p) {
        Ok(v) => !v.is_empty(),
        Err(_) => false,
    }
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

fn is_executable(p: &str) -> bool {
    if !Path::new(p).is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(p)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn pidof(name: &str) -> String {
    spawn_out("pidof", &[name])
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

/// grep -c 的安全版：缺失文件 → 0，绝不出两行。
fn count_pat(p: &str, pat: &str) -> usize {
    read_lines(p).into_iter().filter(|l| l.contains(pat)).count()
}

// ---- mask_ids：4 条 sed -E 规则的复刻 --------------------------------------

const MASK_KEYS: &[&str] = &["secondImei", "imei2", "imei", "meid", "serialno", "serial"];

/// 在 pos 处尝试所有 key（最长优先），返回命中的 key。
fn key_at(line: &[u8], pos: usize) -> Option<&'static str> {
    for k in MASK_KEYS {
        if line[pos..].starts_with(k.as_bytes()) {
            return Some(k);
        }
    }
    None
}

/// 值字符类：`[^[:space:]'\",;)}]`（sed 规则 3/4 的值类）。
fn is_value_char(c: u8) -> bool {
    !c.is_ascii_whitespace() && !b"'\",;)}".contains(&c)
}

/// 跳过空白，返回 (新位置, 是否至少有一个空白)。`*` 语义（可零个）。
fn skip_ws_opt(line: &[u8], mut pos: usize) -> usize {
    while pos < line.len() && (line[pos] as char).is_ascii_whitespace() {
        pos += 1;
    }
    pos
}

/// `+` 语义（至少一个）。
fn skip_ws_plus(line: &[u8], mut pos: usize) -> Option<usize> {
    let start = pos;
    while pos < line.len() && (line[pos] as char).is_ascii_whitespace() {
        pos += 1;
    }
    if pos > start {
        Some(pos)
    } else {
        None
    }
}

/// 规则 1：key='value' → key='<redacted>'（字节级：多字节字符原样保留）
fn mask_rule1(line: &str) -> Vec<u8> {
    let b = line.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0usize;
    while i < b.len() {
        if let Some(k) = key_at(b, i) {
            // sed 规则是 (key)='value'：**等号在引号前**，不可省
            let mut p = i + k.len();
            if p + 1 < b.len() && b[p] == b'=' && b[p + 1] == b'\'' {
                p += 2;
                while p < b.len() && b[p] != b'\'' {
                    p += 1;
                }
                if p < b.len() {
                    out.extend_from_slice(k.as_bytes());
                    out.extend_from_slice(b"='<redacted>'");
                    i = p + 1;
                    continue;
                }
            }
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

/// 规则 2：JSON 形式 "key"[[:space:]]*:[[:space:]]*"value" → "key":"<redacted>"
fn mask_rule2(line: &[u8]) -> Vec<u8> {
    let b = line;
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0usize;
    while i < b.len() {
        if b[i] == b'"' {
            let ks = i + 1;
            let mut j = ks;
            while j < b.len() && b[j] != b'"' {
                j += 1;
            }
            if j < b.len() {
                let key = std::str::from_utf8(&b[ks..j]).unwrap_or("");
                if MASK_KEYS.contains(&key) {
                    let mut p = skip_ws_opt(b, j + 1);
                    if p < b.len() && b[p] == b':' {
                        p = skip_ws_opt(b, p + 1);
                        if p < b.len() && b[p] == b'"' {
                            let mut q = p + 1;
                            while q < b.len() && b[q] != b'"' {
                                q += 1;
                            }
                            if q < b.len() {
                                out.extend_from_slice(format!("\"{key}\":\"<redacted>\"").as_bytes());
                                i = q + 1;
                                continue;
                            }
                        }
                    }
                }
            }
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

/// 规则 3：key[[:space:]]*=[[:space:]]*值(≥1 个值类字符) → key=<redacted>
fn mask_rule3(line: &[u8]) -> Vec<u8> {
    let b = line;
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0usize;
    while i < b.len() {
        if let Some(k) = key_at(b, i) {
            let mut p = i + k.len();
            p = skip_ws_opt(b, p);
            if p < b.len() && b[p] == b'=' {
                let mut p2 = skip_ws_opt(b, p + 1);
                let vs = p2;
                while p2 < b.len() && is_value_char(b[p2]) {
                    p2 += 1;
                }
                if p2 > vs {
                    out.extend_from_slice(k.as_bytes());
                    out.extend_from_slice(b"=<redacted>");
                    i = p2;
                    continue;
                }
            }
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

/// 规则 4：key[[:space:]]+值(≥4 个值类字符) → key <redacted>
fn mask_rule4(line: &[u8]) -> Vec<u8> {
    let b = line;
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0usize;
    while i < b.len() {
        if let Some(k) = key_at(b, i) {
            if let Some(p2) = skip_ws_plus(b, i + k.len()) {
                let mut q = p2;
                let mut n = 0usize;
                while q < b.len() && is_value_char(b[q]) {
                    q += 1;
                    n += 1;
                }
                if n >= 4 {
                    out.extend_from_slice(k.as_bytes());
                    out.extend_from_slice(b" <redacted>");
                    i = q;
                    continue;
                }
            }
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

/// mask_ids —— 按 sed -e 的顺序逐条应用。
pub(crate) fn mask_ids(line: &str) -> String {
    let l = mask_rule1(line);
    let l = mask_rule2(&l);
    let l = mask_rule3(&l);
    String::from_utf8_lossy(&mask_rule4(&l)).into_owned()
}

fn mask_lines(lines: &[String]) {
    for l in lines {
        say(&mask_ids(l));
    }
}

// ---- 各节 -------------------------------------------------------------------

fn sec1_module_daemon(moddir: &str, tee: &str) {
    head_("1. module / daemon process");
    say(&format!("module dir : {moddir}"));
    let prop = format!("{moddir}/module.prop");
    if Path::new(&prop).is_file() {
        for l in read_lines(&prop) {
            if l.starts_with("version=") || l.starts_with("versionCode=") {
                say(&l);
            }
        }
    }
    // pidof, NOT pgrep -f：app_process 把进程名改写成 "teesim"，cmdline 里永远
    // 找不到 java 类名（v3.1.2 的错误信号 bug）。
    let dpid = pidof("teesim");
    if !dpid.is_empty() {
        say(&format!("daemon pid : {dpid} (alive)"));
        let cmdline = fs::read(format!("/proc/{dpid}/cmdline"))
            .map(|b| b.iter().map(|&c| if c == 0 { ' ' } else { c as char }).collect::<String>())
            .unwrap_or_default();
        say(&format!("daemon cmd : {cmdline}"));
        let up = spawn_out("ps", &["-o", "etime=", "-p", &dpid])
            .map(|o| {
                // tr -d ' ' 只删空格；尾部换行由 $() 剥掉
                let s: String = String::from_utf8_lossy(&o.stdout)
                    .trim_end_matches(['\r', '\n'])
                    .chars()
                    .filter(|c| *c != ' ')
                    .collect();
                s
            })
            .unwrap_or_default();
        say(&format!("daemon up  : {up}"));
    } else {
        say("daemon pid : NONE — the control daemon is NOT running");
        say("  -> the respawn loop in service.sh restarts it within ~2s; if it keeps");
        say("     dying, section 7 (daemon.log) holds the stack trace.");
    }
    let dlog = format!("{tee}/daemon.log");
    say(&format!(
        "daemon.log : {}",
        if Path::new(&dlog).is_file() {
            format!("{} bytes", file_bytes(&dlog).unwrap_or(0))
        } else {
            "MISSING".to_string()
        }
    ));
}

fn sec2_interceptor() {
    head_("2. interceptor injection into keystore2");
    let kpid = pidof("keystore2");
    if !kpid.is_empty() {
        // head -1 取第一行（pidof 一行多 pid 时空格分隔）
        let kpid = kpid.lines().next().unwrap_or("").to_string();
        say(&format!("keystore2 pid : {kpid}"));
        let n = fs::read_to_string(format!("/proc/{kpid}/maps"))
            .map(|t| t.lines().filter(|l| l.contains("libteesim")).count())
            .unwrap_or(0);
        // 缺失文件时 grep -c 在 $() 里输出空 —— 这里保序：文件缺失也输出计数前缀
        let maps_disp = if Path::new(&format!("/proc/{kpid}/maps")).exists() {
            n.to_string()
        } else {
            String::new()
        };
        say(&format!("libteesim maps: {maps_disp}"));
    } else {
        say("keystore2 pid : NOT RUNNING");
    }
}

fn sec3_ctl_sock(sock_ctl: &str) {
    head_("3. control socket (daemon <-> interceptor)");
    if is_socket(sock_ctl) {
        // ls -la 的输出宿主/设备形态不同，但只在 socket 存在时走到
        if let Some(o) = spawn_out("ls", &["-la", sock_ctl]) {
            print!("{}", String::from_utf8_lossy(&o.stdout));
        }
        say("socket: present");
    } else {
        say(&format!("socket: MISSING ({sock_ctl})"));
        say("  -> the interceptor never came up far enough to listen: keystore2 may");
        say("     have started before the lib was injected, or the bind failed.");
    }
}

/// `"mode"[^,]*` / `"keybox"[^,]*` 的 grep -o head -1 复刻。
fn json_field_first(config: &str, field: &str) -> String {
    let needle = format!("\"{field}\"");
    for l in read_lines(config) {
        if let Some(p) = l.find(&needle) {
            let rest = &l[p..];
            let end = rest.find(',').unwrap_or(rest.len());
            return rest[..end].to_string();
        }
    }
    String::new()
}

/// config.json 里全部 keybox 字段值（sed 剥壳后的纯值），排序去重。
fn keybox_refs(config: &str) -> Vec<String> {
    let mut out = std::collections::BTreeSet::new();
    let Ok(t) = fs::read_to_string(config) else {
        return Vec::new();
    };
    for l in t.lines() {
        let b = l.as_bytes();
        let mut i = 0usize;
        while let Some(p) = l[i..].find("\"keybox\"") {
            let mut pos = i + p + "\"keybox\"".len();
            let ws = |x: usize| -> bool { b.get(x).map(|c| c.is_ascii_whitespace()).unwrap_or(false) };
            while ws(pos) {
                pos += 1;
            }
            if b.get(pos) != Some(&b':') {
                i += p + "\"keybox\"".len();
                continue;
            }
            pos += 1;
            while ws(pos) {
                pos += 1;
            }
            if b.get(pos) == Some(&b'"') {
                let vs = pos + 1;
                let mut q = vs;
                while q < b.len() && b[q] != b'"' {
                    q += 1;
                }
                if q < b.len() {
                    out.insert(l[vs..q].to_string());
                    i = q;
                    continue;
                }
            }
            i += p + "\"keybox\"".len();
        }
    }
    out.into_iter().collect()
}

fn sec4_config(moddir: &str, tee: &str) {
    head_("4. config the daemon would push");
    let config = format!("{tee}/config.json");
    if Path::new(&config).is_file() {
        say(&format!(
            "config.json : {} bytes",
            file_bytes(&config).unwrap_or(0)
        ));
        say(&json_field_first(&config, "mode"));
        say(&json_field_first(&config, "keybox"));
        say(&format!(
            "profiles    : {}",
            read_lines(&config).into_iter().filter(|l| l.contains("\"mode\"")).count()
        ));
        let apps = fs::read_to_string(&config)
            .map(|t| t.matches("\"apps\"").count())
            .unwrap_or(0);
        say(&format!("apps entries: {apps} apps[] array(s)"));
    } else {
        say("config.json : MISSING — the daemon pushes nothing without it");
    }
    // config 点名的每个 keybox 都过一遍结构校验器 —— 引擎建不起 TA 的 keybox
    // 只产生一行 "failed to build (bad keybox?)" 然后静默拖垮所有 profile。
    let kbc = format!("{moddir}/keybox-check.sh");
    for kb in keybox_refs(&config) {
        let f = format!("{tee}/{kb}");
        if as_nonempty(&f) {
            let n = file_bytes(&f).unwrap_or(0);
            say(&format!("keybox      : {kb} ({n} bytes)"));
            let meta = fs::symlink_metadata(&f);
            if meta.map(|m| m.file_type().is_symlink()).unwrap_or(false) {
                let tgt = fs::read_link(&f)
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default();
                say(&format!("  note: symlink -> {tgt} (a link can be re-pointed under the engine)"));
            }
            if Path::new(&kbc).is_file() {
                let vsh = spawn_out("sh", &[&kbc, &f]);
                let text = vsh
                    .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                    .unwrap_or_default();
                for l in text.lines() {
                    say(&format!("  {l}"));
                }
            } else {
                let looks = fs::read(&f)
                    .map(|b| {
                        let head: Vec<u8> = b.into_iter().take(400).collect();
                        String::from_utf8_lossy(&head).to_lowercase().contains("<keybox")
                    })
                    .unwrap_or(false);
                if !looks {
                    say("  ! does not look like a Keybox XML document — the engine drops the profile");
                }
            }
        } else {
            say(&format!(
                "keybox      : {kb} MISSING/EMPTY ({f}) — ConfigStore rejects the whole config"
            ));
        }
    }
    let marker = format!("{tee}/.auto-keybox");
    if Path::new(&marker).is_file() {
        let h: String = fs::read_to_string(&marker)
            .unwrap_or_default()
            .chars()
            .take(12)
            .collect();
        say(&format!("keybox mgmt : auto-managed (sha {h})"));
    }
    let bad = format!("{tee}/.keybox-bad");
    if Path::new(&bad).is_file() {
        let ep = fs::read_to_string(&bad).unwrap_or_default().trim().to_string();
        let stamp = epoch_to_local_stamp(&ep);
        say(&format!(
            "keybox flag : .keybox-bad present (boot validation rejected the live keybox {stamp})"
        ));
        let blog = format!("{tee}/keybox-bad.log");
        if Path::new(&blog).is_file() {
            for l in read_lines(&blog).into_iter().take(8) {
                say(&format!("  {l}"));
            }
        }
    }
}

/// `date -d @epoch '+%F %T'` 的复刻（UTC 历法；本地时区差在差分夹具里避开）。
fn epoch_to_local_stamp(ep: &str) -> String {
    let secs: u64 = ep.parse().unwrap_or(0);
    let (days, rem) = (secs / 86400, secs % 86400);
    let date = days_to_date(days);
    format!("{date} {:02}:{:02}:{:02}", rem / 3600, (rem % 3600) / 60, rem % 60)
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

fn tail_n(mut lines: Vec<String>, n: usize) -> Vec<String> {
    if lines.len() <= n {
        lines
    } else {
        lines.split_off(lines.len() - n)
    }
}

fn filter_tail(elog: &str, pats: &[&str], n: usize) -> Vec<String> {
    let v: Vec<String> = read_lines(elog)
        .into_iter()
        .filter(|l| pats.iter().any(|p| l.contains(p)))
        .collect();
    tail_n(v, n)
}

fn sec5_trace(elog: &str) {
    head_("5. engine trace (durable)");
    if as_nonempty(elog) {
        let bytes = file_bytes(elog).unwrap_or(0);
        let nlines = read_lines(elog).len();
        say(&format!("trace : {elog} ({bytes} bytes, {nlines} lines)"));
        say(&format!(
            "  pushes={} acks={} staged={} build-failed={} never-pushed={}",
            count_pat(elog, "control: pushed config"),
            count_pat(elog, "control: ack"),
            count_pat(elog, "cfg: staged profile"),
            count_pat(elog, "failed to build"),
            count_pat(elog, "never pushed a config"),
        ));
        say(&format!(
            "  target=1 served={} target=0 forwarded={}",
            count_pat(elog, "target=1"),
            count_pat(elog, "target=0"),
        ));
        // 引擎自己的诊断：C++ 侧只说 "(bad keybox?)"，Rust TA 的 keybox 解析器
        // 会打出具体原因 —— keybox 不可用时全报告最有用的一行。
        let ireason = read_lines(elog)
            .into_iter()
            .filter(|l| l.contains("teesim_km_init_ex:"))
            .last()
            .map(|l| {
                match l.rfind("teesim_km_init_ex:") {
                    Some(idx) => {
                        let r = &l[idx + "teesim_km_init_ex:".len()..];
                        r.trim_start_matches(' ').to_string()
                    }
                    None => String::new(),
                }
            })
            .unwrap_or_default();
        if !ireason.is_empty() {
            say("  keybox verdict from the engine (teesim_km_init_ex):");
            say(&format!("    {ireason}"));
        }
        say("-- last ack / staged / failure lines --");
        for l in filter_tail(
            elog,
            &[
                "control: ack",
                "cfg: staged profile",
                "failed to build",
                "teesim_km_init_ex",
                "Failed to resolve/push config",
                "No valid config to push",
            ],
            12,
        ) {
            say(&l);
        }
        say("-- last resolve-side lines --");
        for l in filter_tail(
            elog,
            &["Scope[", "config.json invalid", "No valid config", "pushed config"],
            8,
        ) {
            say(&l);
        }
    } else {
        say(&format!("trace : EMPTY/MISSING ({elog})"));
        say("  -> the daemon never got far enough to start LogTail, or it is not");
        say("     the upstream daemon at all. Fall back to logcat below.");
    }
}

/// UDS /status 的字段过滤（audit N1：/status 内嵌 harvest 明文标识，只放行
/// version/hook 两个诊断字段）。
fn status_fields(out: &str) -> Vec<String> {
    let expanded: Vec<&str> = out
        .split(['{', ',', '}'])
        .filter(|s| !s.is_empty())
        .collect();
    expanded
        .into_iter()
        .filter(|s| s.contains("\"version\"") || s.contains("\"hook\""))
        .take(4)
        .map(|s| s.trim().to_string())
        .collect()
}

fn sec6_admin(tee: &str) {
    head_("6. daemon admin endpoint (live)");
    let uds = format!("{tee}/teesim-uds");
    let sock_admin = format!("{tee}/admin.sock");
    let token = format!("{tee}/admin.token");
    if is_executable(&uds) && is_socket(&sock_admin) && Path::new(&token).is_file() {
        let tok = fs::read_to_string(&token).unwrap_or_default().trim().to_string();
        let status = spawn_out(&uds, &[&sock_admin, "GET", "/status", &tok])
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        if !status.is_empty() {
            let sf = status_fields(&status);
            if !sf.is_empty() {
                for l in sf {
                    say(&l);
                }
            } else {
                say("status endpoint reachable (fields withheld — /status embeds harvest identifiers)");
            }
        } else {
            say("teesim-uds returned nothing (daemon busy or endpoint moved)");
        }
        let logs = spawn_out(&uds, &[&sock_admin, "GET", "/logs?after=0&max=200", &tok])
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        if !logs.is_empty() {
            say("-- /logs tail (in-memory ring, survives logcat rotation) --");
            let tail: String = {
                let b = logs.as_bytes();
                let start = b.len().saturating_sub(2000);
                String::from_utf8_lossy(&b[start..]).into_owned()
            };
            for l in tail.lines() {
                say(&mask_ids(l));
            }
            say("");
        }
    } else {
        say("skipped: helper/socket/token not all present");
        if !is_executable(&uds) {
            say(&format!("  helper missing: {uds} (service.sh stages it each boot)"));
        }
        if !is_socket(&sock_admin) {
            say(&format!("  admin socket missing: {sock_admin}"));
        }
    }
}

fn sec7_daemon_log(tee: &str) {
    head_("7. daemon stdout/stderr (crash traces)");
    let dlog = format!("{tee}/daemon.log");
    if as_nonempty(&dlog) {
        mask_lines(&tail_n(read_lines(&dlog), 40));
    } else {
        say("(empty — the daemon has not written a line to stderr/stdout)");
    }
}

fn logcat_tail() -> Vec<String> {
    let out = spawn_out("logcat", &["-d", "-s", "TEESimulator"])
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    tail_n(out.lines().map(|s| s.to_string()).collect(), 40)
}

fn sec8_logcat() {
    head_("8. logcat fallback (last 40 lines, tag TEESimulator)");
    mask_lines(&logcat_tail());
}

fn sec9_verdict(moddir: &str, elog: &str) {
    head_("9. verdict");
    // 唯一权威：engine-verdict 读 ack 计数（单行匹配会把 partial 报成 through）。
    let vsh = format!("{moddir}/engine-verdict.sh");
    if Path::new(&vsh).is_file() {
        if let Some(o) = spawn_out("sh", &[&vsh, "once"]) {
            print!("{}", String::from_utf8_lossy(&o.stdout));
        }
        say("");
    }
    let mut logs = fs::read_to_string(elog).unwrap_or_default();
    while logs.ends_with('\n') {
        logs.pop();
    }
    let lc = spawn_out("logcat", &["-d", "-s", "TEESimulator"])
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let lc = lc.trim_end_matches('\n').to_string();
    logs.push('\n');
    logs.push_str(&lc);
    let count = |pat: &str| logs.lines().filter(|l| l.contains(pat)).count();
    let push_n = count("control: pushed config");
    let staged_n = count("cfg: staged profile");
    let build_n = count("failed to build");
    let never_n = count("never pushed a config");
    let t1 = count("target=1");
    let t0 = count("target=0");
    if staged_n > 0 && t1 > 0 {
        say(&format!(
            "OK  : engine is live — {staged_n} staged profile(s), {t1} request(s) served by the engine"
        ));
    } else if staged_n > 0 {
        say(&format!(
            "WARN: config reached the interceptor ({staged_n} staged) but 0 requests matched"
        ));
        say("      -> profile apps/uids do not line up with the real callers");
        say(&format!("         served={t1} forwarded={t0}"));
    } else if never_n > 0 || t0 > 0 {
        say("FAIL: the engine is NOT serving — every request falls through to the real HAL");
        if build_n > 0 {
            say("      cause: the interceptor rejected profile(s) it could not build:");
            for l in logs
                .lines()
                .filter(|l| l.contains("failed to build"))
                .collect::<Vec<_>>()
                .iter()
                .rev()
                .take(3)
                .rev()
            {
                say(l);
            }
            say("      -> the keybox cannot be used by the engine. The reason is printed");
            say("         above as a teesim_km_init_ex line; swap the keybox with");
            say(&format!(
                "         'sh {moddir}/keybox-swap.sh --auto <a.xml> <b.xml>' (it reads the"
            ));
            say("         engine's answer for each candidate) and re-run this script.");
        } else if push_n == 0 {
            say("      cause: the daemon never pushed a config (pushes=0). See section 9's");
            say("             daemon.log for the resolve/push exception, or a silent crash.");
        } else {
            say(&format!("      cause: pushed={push_n} but staged=0 — the push never completed on the"));
            say("             wire. Check CTL_SOCK and the control: connection error lines.");
        }
    } else if push_n > 0 {
        say(&format!(
            "WARN: pushed={push_n} but no staged/never-pushed marker found — buffer rotated."
        ));
        say("      Re-run within a minute of a reboot to catch the verdict lines.");
    } else {
        say("??  : no verdict line found — neither the durable trace nor logcat has one.");
        say("      Reboot and re-run this script within a minute of boot.");
    }
}

// ---- 入口 -------------------------------------------------------------------

pub fn run(_args: &[String]) -> i32 {
    let moddir = std::env::var("AEGIS_MODDIR")
        .unwrap_or_else(|_| "/data/adb/modules/aegisfusion_rs".to_string());
    let tee = std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string());
    let elog = format!("{tee}/log/teesim.log");
    let sock_ctl = "/data/misc/keystore/.teesim-ctl".to_string();

    sec1_module_daemon(&moddir, &tee);
    sec2_interceptor();
    sec3_ctl_sock(&sock_ctl);
    sec4_config(&moddir, &tee);
    sec5_trace(&elog);
    sec6_admin(&tee);
    sec7_daemon_log(&tee);
    sec8_logcat();
    sec9_verdict(&moddir, &elog);

    say("");
    say("== done ==");
    0
}

#[cfg(test)]
mod t {
    #[test]
    fn rule1_smoke() {
        let m = super::mask_ids("harvest imei='860711051234567' serial='AAA'");
        assert_eq!(m, "harvest imei='<redacted>' serial='<redacted>'", "got: {m}");
    }
}
