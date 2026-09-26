//! fusionctl — Aegis Fusion RS 管理层（逻辑重实现，见 docs/CONTRACT-*.md）
//!
//! **单一二进制 + 多入口名**：装配时 `module/<abi>/fusionctl` 会被做成
//! `keybox-check`、`engine-verdict` 等名字的链接，本文件按 argv[0] 的 basename
//! 分发。这样模块里只有一个二进制，但对外仍是多个"脚本"。
//!
//! 也支持开发期的显式子命令形式：`fusionctl keybox-check <file>`。

mod apps_sync;
mod engine_check;
mod engine_verdict;
mod fusion_func;
mod keybox_check;
mod keybox_fetch;
mod keybox_swap;
mod pif_fetch;
mod pif_sync;
mod service_env;
mod ui_probe;
mod uninstall;

use std::env;
use std::path::Path;

fn main() {
    let argv: Vec<String> = env::args().collect();
    let invoked = argv
        .first()
        .and_then(|a| Path::new(a).file_stem())
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let args: Vec<String> = argv.iter().skip(1).cloned().collect();

    let rc = match invoked.as_str() {
        "keybox-check" => keybox_check::run(&args),
        "engine-check" => engine_check::run(&args),
        "engine-verdict" => engine_verdict::run(&args),
        "env-hiding" => service_env::run(&args),
        "pif-fetch" => pif_fetch::run(&args),
        "keybox-fetch" => keybox_fetch::run(&args),
        "keybox-swap" => keybox_swap::run(&args),
        "pif-sync" => pif_sync::run(&args),
        "uninstall" => uninstall::run(&args),
        "apps-sync" => apps_sync::run(&args),
        "ui-probe" => ui_probe::run(&args),
        _ => match args.first().map(String::as_str) {
            // 开发期：./fusionctl keybox-check <file>
            Some("keybox-check") => keybox_check::run(&args[1..]),
            Some("engine-check") => engine_check::run(&args[1..]),
            Some("engine-verdict") => engine_verdict::run(&args[1..]),
            Some("env-hiding") => service_env::run(&args[1..]),
            Some("pif-fetch") => pif_fetch::run(&args[1..]),
            Some("keybox-fetch") => keybox_fetch::run(&args[1..]),
            Some("keybox-swap") => keybox_swap::run(&args[1..]),
            Some("pif-sync") => pif_sync::run(&args[1..]),
            Some("uninstall") => uninstall::run(&args[1..]),
            Some("apps-sync") => apps_sync::run(&args[1..]),
            Some("ui-probe") => ui_probe::run(&args[1..]),
            Some("align-patch-level") => {
                let tee = std::env::var("AEGIS_TEE_DIR")
                    .unwrap_or_else(|_| "/data/adb/teesim".to_string());
                fusion_func::align_patch_level(&tee);
                0
            }
            _ => {
                eprintln!("fusionctl: unknown entry name '{invoked}'");
                eprintln!("known entries: keybox-check, engine-verdict, pif-sync, align-patch-level");
                2
            }
        },
    };
    std::process::exit(rc);
}
