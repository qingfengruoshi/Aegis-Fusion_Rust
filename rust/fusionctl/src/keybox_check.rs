//! keybox-check —— keybox.xml 结构校验器（**纯逻辑，重实现**）
//!
//! 行为契约：`docs/CONTRACT-management.md`（原 `module/keybox-check.sh`，264 行）。
//! 校验器是**引擎的复刻而非启发式**：镜像上游 `rust/teesim-km/src/attest.rs` 的
//! `CertSignInfo::new` → `parse_algo` → `decode_pem`，以及 `base64` crate 的
//! STANDARD 规则，按 TA 的求值顺序。措辞与引擎对齐（`docs/CONTRACT-management.md`）。
//!
//! Usage: keybox-check <file> [--quiet]
//! Exit : 0 usable | 1 unusable | 2 missing / unreadable / not a regular file

use std::fs;
use std::path::Path;

struct Out {
    quiet: bool,
}

impl Out {
    fn say(&self, s: &str) {
        if !self.quiet {
            println!("{s}");
        }
    }
}

/// 全文（含每行末尾补 `\n`），与 shell 版 `{ all = all $0 "\n" }` 等价。
fn read_all(path: &Path) -> Result<Vec<u8>, ()> {
    fs::read(path).map_err(|_| ())
}

/// 0-based 查找，找不到返回 None（对应 awk 的 `index()` 0 值）。
fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if from > hay.len() || needle.is_empty() {
        return None;
    }
    hay[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|p| from + p)
}

/// shell 版 `find_cert`：找到 `<Certificate` 且其后一个字符是 `>` / 空白之一
/// （排除 `<CertificateChain` 的前缀误配）。
fn find_cert(all: &[u8], from: usize) -> Option<usize> {
    let mut pos = from;
    loop {
        let hit = find(all, b"<Certificate", pos)?;
        let next = all.get(hit + 12).copied()?;
        if next == b'>' || next == b' ' || next == b'\t' || next == b'\n' || next == b'\r' {
            return Some(hit);
        }
        pos = hit + 12;
    }
}

/// shell 版 `last_algo`：取元素**之前**的文本里最后一个 `<Key`，并抽出它的
/// `algorithm="…"` 值。找不到 `<Key` 或没有该属性 → `?`。
fn last_algo(prefix: &[u8]) -> String {
    let needle = b"<Key";
    let mut found: Option<usize> = None;
    let mut pos = 0;
    loop {
        match find(prefix, needle, pos) {
            Some(p) => {
                found = Some(p);
                pos = p + 4;
            }
            None => break,
        }
    }
    let start = match found {
        Some(p) => p,
        None => return "?".to_string(),
    };
    // 在 `<Key` 起始处开始找 `algorithm="…"`
    let attr = b"algorithm=\"";
    let a = match find(&prefix[start..], attr, 0) {
        Some(p) => start + p + attr.len(),
        None => return "?".to_string(),
    };
    let mut end = a;
    while end < prefix.len() && prefix[end] != b'"' {
        end += 1;
    }
    String::from_utf8_lossy(&prefix[a..end]).into_owned()
}

/// shell 版 `pget` 用的行内修剪：去掉首尾的空格 / `\t` / `\r`（**不含** `\n`，
/// 因为按 `\n` split 之后行内不会再有）。
fn trim_line(s: &str) -> &str {
    s.trim_matches(|c| c == ' ' || c == '\t' || c == '\r')
}

/// 解码前对 base64 体做与引擎同序的审计（`attest.rs` 的 decode_pem 语义）。
/// 返回：`Err(lines)` 时 lines 为要打印的 FAIL 行，`Ok(n)` 为体长。
fn audit(tag: &str, acc: &[u8]) -> Result<usize, Vec<String>> {
    let n = acc.len();
    if n == 0 {
        return Err(vec![format!(
            "FAIL: {tag}: empty body — the TA reports this as \"empty Certificate\""
        )]);
    }
    if n % 4 != 0 {
        return Err(vec![format!(
            "FAIL: {tag}: InvalidLength — the accumulated base64 is {n} chars, not a multiple of 4 (truncated file?)"
        )]);
    }
    let mut seen = false;
    for (idx, c) in acc.iter().enumerate() {
        if *c == b'=' {
            // `i <= n - 4`（awk 的 1-based i）等价于 0-based `idx < n - 4`。
            if idx + 4 < n {
                return Err(vec![
                    format!(
                        "FAIL: {tag}: InvalidByte({idx}, 61) — an interior \"=\" (body length {n})"
                    ),
                    format!(
                        "      context around the offset {idx}: (redacted — this element can be key material, v3.2.3)"
                    ),
                    "      an \"=\" only closes the FINAL 4-char group, so this body holds more than one blob"
                        .to_string(),
                ]);
            }
            seen = true;
        } else if !c.is_ascii_alphanumeric() && *c != b'+' && *c != b'/' {
            return Err(vec![
                format!(
                    "FAIL: {tag}: InvalidByte({idx}, {c}) — a non-base64 byte (ord={c}) at this offset"
                ),
                format!(
                    "      context around the offset {idx}: (redacted — this element can be key material, v3.2.3)"
                ),
            ]);
        } else if seen {
            return Err(vec![
                format!("FAIL: {tag}: InvalidByte({idx}, {c}) — data follows a padding \"=\""),
            ]);
        }
    }
    Ok(n)
}

/// `extract_body`：行级提取（与 shell 版逐行语义一致）。
fn extract_body(text: &str, tag: &str) -> String {
    let open_tag = format!("<{tag}");
    let close = format!("</{tag}>");
    let mut out = String::new();
    let mut inb = false;
    for line in text.split('\n') {
        if !inb {
            // shell 正则 `$0 ~ "<"T"[ >]"`：`<PrivateKey` 之后紧跟 `>` 或空格
            if let Some(p) = line.find(&open_tag) {
                if let Some(b'>') | Some(b' ') = line.as_bytes().get(p + open_tag.len()).copied() {
                    inb = true;
                }
            }
            continue;
        }
        if line.contains(&close) {
            inb = false;
            continue;
        }
        let t = trim_line(line);
        if t.is_empty() || t.starts_with("-----") {
            continue;
        }
        out.push_str(&t.replace([' ', '\t', '\r'], ""));
    }
    out
}

/// `check_body`：宽松兜底（字符集 + 长度 %4）。返回 true = 通过。
fn check_body(quiet: &Out, text: &str, tag: &str) -> bool {
    let body = extract_body(text, tag);
    if body.is_empty() {
        quiet.say(&format!(
            "warn: could not extract a <{tag}> body (unusual layout?) — not counted as a failure"
        ));
        return true;
    }
    if !body.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'+' || c == b'/' || c == b'=') {
        quiet.say(&format!(
            "FAIL: <{tag}> body is not base64 (truncated, encrypted or still obfuscated payload?)"
        ));
        return false;
    }
    if body.len() % 4 != 0 {
        quiet.say(&format!(
            "FAIL: <{tag}> base64 body length {} is not a multiple of 4 (truncated file?)",
            body.len()
        ));
        return false;
    }
    true
}

/// 入口。返回 shell 的退出码（0 / 1 / 2）。
pub fn run(args: &[String]) -> i32 {
    let file = args.first().map(String::as_str).unwrap_or("");
    let quiet = args.iter().skip(1).any(|a| a == "--quiet");
    let out = Out { quiet };

    let o = &out;

    // [ -n "$F" ] || usage; exit 2
    if file.is_empty() {
        o.say("usage: keybox-check <file> [--quiet]");
        return 2;
    }
    let path = Path::new(file);

    // [ -e "$F" ] → FAIL: not found
    if !path.exists() {
        o.say(&format!("FAIL: not found: {file}"));
        return 2;
    }
    // [ -L "$F" ] → note（不判失败）
    if path.is_symlink() {
        let tgt = fs::read_link(path)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        o.say(&format!("note: {file} is a symlink -> {tgt}"));
    }
    // [ -f "$F" ]（跟随链接，符号链接到普通文件会通过）
    if !path.is_file() {
        o.say(&format!("FAIL: not a regular file: {file}"));
        return 2;
    }
    if path.metadata().map(|m| m.len() == 0).unwrap_or(true) {
        o.say(&format!("FAIL: empty file: {file}"));
        return 2;
    }

    let all = match read_all(path) {
        Ok(v) => v,
        Err(_) => {
            o.say(&format!("FAIL: unreadable: {file}"));
            return 2;
        }
    };
    let text = String::from_utf8_lossy(&all).into_owned();

    // ---- Rule 1: 文档形状 ---------------------------------------------------
    if !text.contains("<Keybox") {
        o.say("FAIL: no <Keybox> root element (not a keybox document)");
        return 1;
    }
    if !text.contains("</Keybox>") {
        o.say("FAIL: <Keybox> is never closed — truncated download?");
        return 1;
    }
    let head: String = String::from_utf8_lossy(&all[..all.len().min(200)]).into_owned();
    let lower = head.to_lowercase();
    if lower.contains("<!doctype html") || lower.contains("<html") {
        o.say("FAIL: file is an HTML page, not a keybox (failed download saved as XML)");
        return 1;
    }

    // ---- Rule 2/3: 每个 <Key> 块的 algorithm 与证书数 ----------------------
    // 逐行状态机：`<Key` + 空白/`>` 开块；`</Key>` 闭块；块内数 `<Certificate`。
    struct KeyBlock {
        algo: String,
        certs: usize,
    }
    let mut blocks: Vec<KeyBlock> = Vec::new();
    let mut in_key = false;
    let mut cur = KeyBlock { algo: "-".to_string(), certs: 0 };
    for line in text.split('\n') {
        let is_key_open = {
            let m = line.find("<Key");
            match m {
                Some(p) => match line.as_bytes().get(p + 4) {
                    Some(b' ') | Some(b'\t') | Some(b'>') => true,
                    _ => false,
                },
                None => false,
            }
        };
        if is_key_open {
            if in_key {
                blocks.push(KeyBlock { algo: cur.algo.clone(), certs: cur.certs });
            }
            in_key = true;
            cur = KeyBlock { algo: "-".to_string(), certs: 0 };
            // `match($0, /algorithm="[^"]*"/)` —— 只看这一行
            if let Some(p) = line.find("algorithm=\"") {
                let s = p + 11;
                if let Some(e) = line[s..].find('"') {
                    cur.algo = line[s..s + e].to_string();
                }
            }
            continue;
        }
        if !in_key {
            continue;
        }
        if line.contains("</Key>") {
            blocks.push(KeyBlock { algo: cur.algo.clone(), certs: cur.certs });
            in_key = false;
            continue;
        }
        // `/<Certificate[ >]/`
        if let Some(p) = line.find("<Certificate") {
            if let Some(b'>') | Some(b' ') = line.as_bytes().get(p + 12).copied() {
                cur.certs += 1;
            }
        }
    }
    if in_key {
        blocks.push(KeyBlock { algo: cur.algo.clone(), certs: cur.certs });
    }

    if blocks.is_empty() {
        o.say(
            "FAIL: no <Key> element found ('keybox: no <Key algorithm=\"rsa\"> or <Key algorithm=\"ecdsa\">')",
        );
        return 1;
    }

    let mut usable = false;
    let mut broken = false;
    for b in &blocks {
        match b.algo.as_str() {
            "rsa" | "ecdsa" => {
                if b.certs >= 2 {
                    o.say(&format!(
                        "ok  : <Key algorithm=\"{}\"> carries {} certificate(s)",
                        b.algo, b.certs
                    ));
                    usable = true;
                } else {
                    o.say(&format!(
                        "FAIL: <Key algorithm=\"{}\"> chain has {} certificate(s); the TA needs at least 2 ('{}: expected at least 2 certificates')",
                        b.algo, b.certs, b.algo
                    ));
                    broken = true;
                }
            }
            _ => o.say(&format!(
                "warn: <Key algorithm=\"{}\"> is not one the TA reads (only rsa / ecdsa are)",
                b.algo
            )),
        }
    }

    if !usable {
        if !broken {
            o.say("FAIL: no <Key algorithm=\"rsa\"> or <Key algorithm=\"ecdsa\"> with a usable chain");
        }
        o.say("      -> the engine will log 'keymint: profile <id> failed to build (bad keybox?)'");
        o.say("         and drop every profile: PI stays at BASIC no matter what else is configured.");
        return 1;
    }

    // ---- Rule 4/5: 按文档顺序审计每个体 ------------------------------------
    // 与 shell 版一致：全文压平成 `行 + \n`（对字节数组而言 = 原文件本身）。
    let flat: &[u8] = &all;
    let mut bad = 0usize;
    let mut any = false;
    let mut total = 0usize;
    let mut ncert = 0usize;
    let mut lines_out: Vec<String> = Vec::new();

    let mut pos: usize = 0;
    while pos < flat.len() {
        let i1 = find(flat, b"<PrivateKey", pos).map(|p| p);
        let i2 = find_cert(flat, pos);
        let (start, kind) = match (i1, i2) {
            (Some(a), Some(b)) => {
                if a < b { (a, "PrivateKey") } else { (b, "Certificate") }
            }
            (Some(a), None) => (a, "PrivateKey"),
            (None, Some(b)) => (b, "Certificate"),
            (None, None) => break,
        };
        // 元素名之后必须紧跟 `>` 才算开标签
        let gt_rel = match flat[start..].iter().position(|c| *c == b'>') {
            Some(g) => g,
            None => break,
        };
        let body_start = start + gt_rel + 1;
        let ctag = format!("</{kind}>");
        let ce = match find(flat, ctag.as_bytes(), body_start) {
            Some(p) => p - body_start,
            None => {
                lines_out.push(format!("FAIL: <{kind}> is never closed (truncated file?)"));
                bad += 1;
                break;
            }
        };
        let body = String::from_utf8_lossy(&flat[body_start..body_start + ce]).into_owned();
        pos = body_start + ce + ctag.len();

        let algo = last_algo(&flat[..start]);
        let tag = if kind == "Certificate" {
            ncert += 1;
            format!("{algo} / Certificate #{ncert}")
        } else {
            format!("{algo} / PrivateKey")
        };
        any = true;
        total += 1;

        // decode_pem 复刻：逐行 trim、跳过空行与 PEM 壳、去内部空白
        let mut acc: Vec<u8> = Vec::new();
        for ln in body.split('\n') {
            let t = trim_line(ln);
            if t.is_empty() || t.starts_with("-----") {
                continue;
            }
            acc.extend(t.bytes().filter(|c| *c != b' ' && *c != b'\t' && *c != b'\r'));
        }
        match audit(&tag, &acc) {
            Ok(_) => {}
            Err(lines) => {
                lines_out.extend(lines);
                bad += 1;
            }
        }
    }

    for l in &lines_out {
        o.say(l);
    }
    if !any {
        o.say("warn: no <PrivateKey>/<Certificate> body could be read (unusual layout?)");
        return 0;
    }
    if bad == 0 {
        o.say(&format!(
            "ok  : {total} base64 body(ies) decode cleanly (replicated decode_pem)"
        ));
    } else {
        o.say("      -> the engine cannot build a TA from this keybox.");
        return 1;
    }

    // ---- Belt and braces: 宽松兜底 ----------------------------------------
    let mut rc = 0;
    for tag in ["PrivateKey", "Certificate"] {
        if !check_body(o, &text, tag) {
            rc = 1;
        }
    }
    if rc != 0 {
        o.say("      -> the engine cannot build a TA from this keybox.");
        return 1;
    }

    o.say("PASS: this keybox is usable by the engine");
    0
}
