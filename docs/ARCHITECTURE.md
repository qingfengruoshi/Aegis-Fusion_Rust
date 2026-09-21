# Hide-RS 架构与移植计划（v0.1，2026-09-21）

## 基座盘点（TEESimulator-RS @ 6d241e5）

| 目录 | 内容 | 对我们的意义 |
|---|---|---|
| `native-certgen/` | Rust cdylib：证书生成（ring/x509-cert），JNI 接口 | **核心资产**——Rust 证书生成已就绪 |
| `app/` | Android 组件（Gradle，Kotlin daemon 所在） | verdict/通道逻辑的移植落点 |
| `module/` | 模块文件（customize.sh/service.sh/daemon/action.sh/diag.sh/sepolicy.rule/target.txt） | 与我们 shell 版的对接面 |
| `scripts/package.sh` | 打包 | CI 打包沿用 |
| `docs/UPSTREAM-README.md` | 上游说明（保留） | GPL 归属 |

**基座自带**：AIDL 全接口实现（自称比 TrickyStore/TEESimulator 系更难被行为检测识别）、证书生成 Rust 化、密钥跨重启、RKP 风格链支持（实测一加出现 Droid CA3 短期链）。

## 移植清单（shell 版 → Hide-RS）

| # | 项 | 来源（IntegrityFusion） | 工作量 | 依赖 |
|---|---|---|---|---|
| P1 | WebUI 三页（launcher/apps/logs + css） | `module/webroot/` | 小（前端自包含） | daemon 接口对齐 |
| P2 | verdict 系统（内容哈希锚点 + 套接字兜底 + 收敛） | `module/keybox-fetch.sh` + `engine-verdict.sh` | 中 | RS daemon 的状态接口 |
| P3 | keybox 渠道管理 + 手动获取 + 备份 + 吊销检测 | `module/keybox-fetch.sh` | 中 | 同上 |
| P4 | 安装期本机专属指纹（R7-1） | `module/pif-fetch.sh` + `customize.sh` | 中 | PIF 集成方式对齐 |
| P5 | 诊断导出（全脱敏） | `module/webroot/js/logs.js` | 小 | 日志源对齐 |
| P6 | 受保护应用管理 | `module/apps-sync.sh` + WebUI | 中 | config.json 对齐 |
| P7 | Soter 本地自检（重写独有） | 新增（参照 Sentinel 探测的 op 集合） | 大/待定 | 需先拿到 Soter 失败 op 清单 |
| P8 | 中间 CA 有效期检查 → 强制轮换 | 新增 | 小 | — |

## 待决事项

1. **项目正式名称**（工作区代号 Hide-Rust）；
2. **GitHub 新仓库**（作者创建后本工作区换 remote）；
3. **本机 rustup/NDK** 是否安装（或先依赖 CI）；
4. **daemon 接口对齐**：我们的 verdict/keybox 逻辑放 RS 的 Kotlin daemon 还是下沉 Rust——P2/P3 的关键架构决策；
5. **Soter 失败 op 清单**：需要在一加（AS 或 ours）上抓 Soter checker 的详细失败输出。

## 与 shell 版的边界

shell 版（IntegrityFusion）继续作为稳定发布线；本项目在 v1.1 以**并行变体**发布，v2.0 视 A/B 结果转正。两线的 keybox 渠道/配置不共享（各自目录），避免互相干扰。
