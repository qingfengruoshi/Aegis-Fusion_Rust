# Aegis Fusion RS（工作区代号 Hide_Rust，正式名称待定）

Aegis Fusion 的**并行变体**：**引擎与 shell 线完全相同，差异在管理层的实现语言**（shell → Rust）。

## 与 shell 线（IntegrityFusion）的关系

| | shell 线（`IntegrityFusion`） | **本仓库（RS 变体）** |
|---|---|---|
| 模块 id | `aegisfusion` | **`aegisfusion_rs`** |
| 模块目录 | `/data/adb/modules/aegisfusion` | **`/data/adb/modules/aegisfusion_rs`** |
| 数据目录 | `/data/adb/teesim` | 同左（引擎硬编码，见下） |
| 引擎 | JingMatrix/TEESimulator + 7 个补丁 | **完全相同** |
| 管理层 | 13 个 shell 脚本 4,151 行 | **重写**（只取逻辑，不照搬代码） |
| WebUI | 5,146 行（html 350 · css 1,763 · js 3,033） | **重写**（只取功能逻辑，见 `docs/CONTRACT-webui.md`） |

**命名说明**：本仓库名为 Hide_Rust，但**上游 TEESimulator 并不是 Rust 项目**（Kotlin 8,578 / C++ 18,395 / Rust 2,705）。「Rust」指的是**我们自己那 4151 行管理层的重写**，不是引擎。详见 `docs/GAP-AND-ROADMAP.md` §8/§9。

**为什么数据目录与 shell 线共用**：引擎把 `/data/adb/teesim` 硬编码在 `app/.../Const.kt`（`DATA_DIR`），`Control.kt` 的控制 socket 与 `ConfigStore.kt` 的 `config.json` 监听都挂在它下面；改它要新增一个引擎补丁，得不偿失。两线不可能同时生效（都要 hook keystore2），而 A/B 对比恰恰需要同配置才可比。

**A/B 与转正**：两线并行，实测胜出者转正。若 RS 变体胜出，则 shell 线停止维护（作者决定，2026-09-21）。

## 仓库形状（overlay-only）

**本仓库不含引擎源码。** 引擎在构建时按 `versions.env` 钉定的版本拉取并打补丁：

```
scripts/fetch-upstreams.sh   # clone TEESimulator @ TEESIM_REF，应用 patches/teesim/*.patch，
                             # 并按 sha256 校验下载 PlayIntegrityFork 官方 zip
scripts/assemble.sh          # 引擎 zip + PIFork zip + module/ overlay → 一个可刷入模块 zip
.github/workflows/build.yml  # CI：拉取 → 打补丁 → 构建 → 组装 → 发 release
```

| 目录 | 内容 |
|---|---|
| `module/` | Fusion 管理层 overlay：13 个脚本 + `META-INF/` + `webroot/`（引擎侧文件由引擎 zip 提供） |
| `module/webroot/` | WebUI。**`js/conf.js` 是全部路径常量的唯一定义点** |
| `patches/teesim/` | 7 个补丁（与 shell 线相同） |
| `scripts/` | 上游拉取 / 组装 / 11 个单测 / `verify/` |
| `docs/` | `GAP-AND-ROADMAP.md`（缺口与路线）、`CONTRACT-verdict-keybox.md`（管理层 CLI 契约） |
| `versions.env` | 上游钉定版本 + Fusion 版本 |

## 构建

本机**不需要**装 Android SDK/NDK/Rust 工具链也能改代码（静态检查用 `sh -n` 与 `node --check`）；实际构建走 CI。

```bash
scripts/fetch-upstreams.sh      # 拉上游 + 打补丁（需要网络 + git）
# 之后按上游 TEESimulator 的方式构建，再由 assemble.sh 组装
scripts/assemble.sh <teesim-release.zip> <pifork-release.zip> module out/AegisFusionRS-<ver>.zip
```

## 路线图

| 步 | 内容 | 状态 |
|---|---|---|
| 0 | 换基座：改为以 TEESimulator 为基座，沿用 shell 线的补丁与组装链 | ✅ 已完成（构建脚本已与模块 id 解耦） |
| 1 | 抽「功能契约」：把 shell 线的逻辑写成规格（管理层 + UI），作为重写的输入 | 进行中：verdict/keybox 已完成，UI 探针键集已提取 |
| 2 | 用混合语言重写管理层与 UI（只取逻辑，不照搬代码） | 待做 |
| 3 | 可选：把 RS 基座的 `native-certgen`（Rust 证书生成）作为代码并入引擎层 | 待定 |
| 4 | 收尾：`README` / `NOTICE.md` / `CHANGELOG.md` / `versions.env` 换成变体自己的身份 | 待做 |

> **注意**：早先设想的「先把 shell 管理层原样搬进来、跑出等价基线，再逐块换实现」**已取消** —— 因为本变体不照搬 shell 线的代码。等价基线由 **shell 线本身**提供（两条线共用同一个数据目录与引擎，A/B 交替刷入即可对照）。见 `docs/GAP-AND-ROADMAP.md` §12。

## 许可

GPL-3.0。继承 [JingMatrix/TEESimulator](https://github.com/JingMatrix/TEESimulator) 与 [osm0sis/PlayIntegrityFork](https://github.com/osm0sis/PlayIntegrityFork)。归属与来源见 `NOTICE.md`。
