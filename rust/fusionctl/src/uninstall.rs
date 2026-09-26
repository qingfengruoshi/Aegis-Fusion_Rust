//! uninstall —— 卸载清理（重实现）
//!
//! 契约：`docs/CONTRACT-management.md`（原 `module/uninstall.sh`，66 行）。
//! 卸载 = **完全移除**（v3.1.9 作者决定）：/data/adb/teesim 整个抹掉 —— 配置、
//! keybox、备份、日志、marker、staged helper、admin socket，模块在设备上不剩
//! 任何东西。keybox 想留就先拷出去。
//!
//! 结构（与 shell 版一一对应）：
//!   1. 先杀控制 daemon（防它边删边重建文件）
//!   2. `rm -rf` 数据目录
//!   3. 清 PIF 家族注入物（GMS/Vending 的 libinject.so / classes.dex / pif.prop）
//!   4. 清 hook ROM 持久化的 spoof-tell props（audit R8-5：--delete 内存 +
//!      -p --delete 持久化记录，与服务屑 RESIDUE_PROPS 同一清单）
//!
//! 测试接缝：`AEGIS_TEE_DIR`（默认 /data/adb/teesim —— 设备上不设 env 时行为
//! 与 shell 版的硬编码路径一致；harness 用它把删除重定向到一次性目录）。

use std::fs;
use std::path::Path;

const RESIDUE_PROPS: &[&str] = &[
    "persist.sys.pihooks.first_api_level",
    "persist.sys.pihooks.security_patch",
    "persist.sys.pihooks.disable.gms_props",
    "persist.sys.pihooks.disable.gms_key_attestation_block",
    "persist.sys.entryhooks_enabled",
    "persist.sys.pixelprops.gms",
    "persist.sys.pixelprops.gapps",
    "persist.sys.pixelprops.google",
    "persist.sys.pixelprops.pi",
    "persist.sys.pp.gms",
    "persist.sys.pp.vending",
    "persist.sys.spoof.gms",
];

fn which(name: &str) -> Option<String> {
    // 与其它入口相同的 bash 顺序 PATH 解析（盘符冒号感知 + .exe 回退）
    let paths = std::env::var("PATH").ok()?;
    let b = paths.as_bytes();
    let mut start = 0usize;
    let mut i = 0usize;
    while i <= b.len() {
        let is_sep = i < b.len() && (b[i] == b';' || (b[i] == b':' && !(i >= 1 && i + 1 < b.len()
            && b[i - 1].is_ascii_alphabetic()
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

fn spawn_rc(cmd: &str, args: &[&str]) -> i32 {
    // 完整路径解析（避免 Windows 把 System32 排在测试桩前）+ 脚本回退 sh
    let resolved = which(cmd).unwrap_or_else(|| cmd.to_string());
    let mut c = std::process::Command::new(&resolved);
    c.args(args);
    if let Ok(o) = c.output() {
        return o.status.code().unwrap_or(-1);
    }
    let mut c2 = std::process::Command::new("sh");
    c2.arg(&resolved).args(args);
    c2.output().ok().and_then(|o| o.status.code()).unwrap_or(-1)
}

fn pidof(name: &str) -> String {
    spawn_rc_out("pidof", &[name])
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn spawn_rc_out(cmd: &str, args: &[&str]) -> Option<String> {
    let resolved = which(cmd).unwrap_or_else(|| cmd.to_string());
    let mut c = std::process::Command::new(&resolved);
    c.args(args);
    match c.output() {
        Ok(o) => return Some(String::from_utf8_lossy(&o.stdout).into_owned()),
        Err(_) => {}
    }
    let mut c2 = std::process::Command::new("sh");
    c2.arg(&resolved).args(args);
    c2.output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
}

pub fn run(_args: &[String]) -> i32 {
    let tee = std::env::var("AEGIS_TEE_DIR").unwrap_or_else(|_| "/data/adb/teesim".to_string());

    // 1) 先停 daemon：它不能在删除过程中把文件建回来
    let dpid = pidof("teesim");
    if !dpid.is_empty() {
        let _ = spawn_rc("sh", &["-c", &format!("kill {dpid}")]);
    }

    // 2) 整个数据目录（0700 root-only）：config.json、keybox.xml、keybox-backups、
    //    pif-master、日志、marker、teesim-uds、admin socket
    let _ = fs::remove_dir_all(&tee);

    // 3) PIF 家族模块历史上丢进 GMS/Vending 的注入物
    for pkg in ["com.google.android.gms", "com.android.vending"] {
        for base in [format!("/data/user_de/0/{pkg}"), format!("/data/data/{pkg}")] {
            if !Path::new(&base).is_dir() {
                continue;
            }
            for artifact in ["libinject.so", "classes.dex", "pif.prop"] {
                let f = format!("{base}/{artifact}");
                if Path::new(&f).is_file() {
                    let _ = fs::remove_file(&f);
                }
            }
        }
    }

    // 4) hook ROM 持久化的 spoof-tell props（audit R8-5）：模块要走了，什么都不
    //    再需要它们 —— 与 service 屑的 RESIDUE_PROPS 同一清单，无条件删
    if which("resetprop").is_some() {
        for rp in RESIDUE_PROPS {
            // --delete 清内存副本；-p --delete 清 /data/property 里的持久化记录
            // （否则它会在下次 boot 重新长出来）
            if spawn_rc("resetprop", &[rp]) == 0 || spawn_rc("resetprop", &["-p", rp]) == 0 {
                let _ = spawn_rc("resetprop", &["--delete", rp]);
                let _ = spawn_rc("resetprop", &["-p", "--delete", rp]);
            }
        }
    }

    0
}
