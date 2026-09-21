# Hide-RS（工作区代号，正式名称待定）

Aegis Fusion 的 **Rust 引擎重写**项目（v1.1/v2.0 路线，IntegrityFusion 账本 §I.2/§I.3）。

**基座**：[TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS)（Enginex0 对 JingMatrix/TEESimulator 的 Rust 重写 fork，GPL-3.0）——主打「证明行为匹配原生 Android」。钉定快照见 `UPSTREAM`；上游原 README 保留在 `docs/UPSTREAM-README.md`。

**与 shell 版（IntegrityFusion）的关系**：shell 版保留为稳定发布线，不受本项目影响；本项目产出 **自有 Rust 引擎分支**，A/B 实测胜出后转正为后续版本的默认引擎。

## 与 AS（AlwaysStrong）的差异化

AS = PlayIntegrityFork + 原版 TEESimulator-RS（引擎之上几乎无管理层）。我们在这个基座上叠加 shell 版已验证的**全套管理层**：

| 层 | 内容（自 shell 版移植/重实现） |
|---|---|
| **WebUI 管理套件** | 状态灯（keybox 渠道+来源+引擎判定+本机吊销检测）、指纹来源细分、受保护应用管理、诊断导出（全脱敏）、日志多标签 |
| **verdict 系统** | 内容哈希锚点 + 管理套件套接字兜底 + 每小时收敛（R9-1 边界下保证「引擎已加载」可判定） |
| **keybox 渠道管理** | 多渠道 + 手动获取接管 + 备份 + 本机吊销检测 + 哈希拉黑 |
| **安装期本机专属指纹** | R7-1：安装时一次随机抓取（~20s 预算），失败回退种子 |
| **新增能力（重写独有）** | Soter 本地自检支持（尽力而为）、中间 CA 有效期检查 → 强制轮换 |

**明确不做**：Widevine L1 供给伪造（DRM HAL 层级，任何 keystore 引擎都不可达；国行设备出厂状态）。

## 构建与工具链

- `native-certgen/`：Rust cdylib（ring / x509-cert / jni），Gradle 经 NDK 交叉编译注入模块；
- 需要本机安装 **rustup + Android target（aarch64-linux-android 等）+ Android NDK**（或依赖 CI 构建）；
- `scripts/package.sh` 打包模块 zip。

## 路线图（详见 IntegrityFusion 账本 §I）

- **v1.1**：本基座 + 管理层移植 + 并行变体 A/B（同设备 Sentinel + Soter checker + SPIC 对照 AS/ours）；
- **v2.0**：A/B 胜出后 RS 转正，JingMatrix 引擎退役或降级为兼容变体。

## 许可

GPL-3.0（继承 TEESimulator-RS / JingMatrix/TEESimulator）。
