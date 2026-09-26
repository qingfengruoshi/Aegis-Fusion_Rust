# 缺口清单与推进路线（v0.1，2026-09-21）

**对照双方**：`Hide_Rust`（Rust 线，基座 TEESimulator-RS @ `6d241e5`） ↔ `IntegrityFusion`（shell 稳定线，`main`）
**前置文档**：`docs/CONTRACT-verdict-keybox.md`（CLI 兼容层契约）
**本轮性质**：只读盘点 + 决策提请。**未改动任何代码。**

---

## 0. 结论

Rust 版当前是**一块与 Fusion 契约零重叠的独立基座**——不是「缺了几个文件」，而是**四条地基级契约全部对不上**。
其中 admin socket 的缺失不是「少个功能」，而是**会让 verdict 系统在特定设备上彻底失效**（见 §1.2）。

推进顺序因此被倒过来：**不是先搬 WebUI 或先写 Rust，而是先做「基座对齐」**——把路径、进程名、socket 端点三个基石对齐，让 RS 变成一个「能被 Fusion 探针正确识别的壳」，再往里面装逻辑。

### 0.1 先校正一个前提：「上游是 Rust」并不成立

本仓库名虽为 Hide-Rust，但**上游 TEESimulator-RS 并不是 Rust 项目**。实测代码构成：

| 语言 | 位置 | 行数 | 占比 |
|---|---|---|---|
| **Kotlin** | `app/src/main/java/`（35 文件） | **11,337** | **57%** |
| C++ | `app/src/main/cpp/` | 3,694 | 19% |
| **Rust** | `native-certgen/src/` | **2,267** | **11%** |
| Java（stub 桩类） | `stub/` | 1,588 | 8% |

**Rust 只占 11%，且只做一件事**：`native-certgen` —— 一个生成证书的 cdylib（ring / x509-cert / jni），由 Gradle 经 NDK 交叉编译后注入模块。

拦截、配置管理、attestation 构建、日志，**全部是 Kotlin**。所以「Rust 版应该比较快」这个预期需要修正：本项目是「**Kotlin 为主的基座 + Rust 化的工具层**」，Rust 化的部分恰好是我们自己要新增的那部分（CLI 兼容层、`teesim-uds` 客户端、verdict 落盘），而不是既有代码。

### 0.2 两套引擎是**架构级分叉**，不是同一实现的不同语言

| | shell 版（JingMatrix TEESimulator + 7 补丁） | RS 基座（Enginex0） |
|---|---|---|
| 拦截器取配置 | daemon 经**控制 socket** 推送 + 等 ack | 静态 `ConfigurationManager` 对象**直读** |
| 应用范围契约 | `config.json` → `profiles.<active>.apps` | `target.txt`（见 §1.4） |
| keybox 解析 | 独立 **Rust TA**（`teesim-km`）→ `teesim_km_init_ex:` | Kotlin `KeyBoxManager` / `CertificateGenerator` |
| 持久日志 | `LogTail` 把 logcat 镜像成 `log/teesim.log` | `SystemLogger` 仅写 logcat |

⇒ 结论见 §1.2.b：**Fusion verdict 系统依赖的 8 个日志标记，在 RS 源码里命中数全部为 0。** 这不是漏抄，是架构不同。

---

## 1. 硬阻塞（不解决无法开工）

### 1.1 配置目录与模块目录不匹配（7 处硬编码）

| 侧 | 配置目录 | 模块目录 |
|---|---|---|
| RS 基座 | `/data/adb/tricky_store` | `/data/adb/modules/tricky_store` |
| Fusion 层 | `/data/adb/teesim` | `/data/adb/modules/aegisfusion` |

**RS 侧硬编码清单（全部需改或需兼容）**：

| # | 文件:行 | 内容 |
|---|---|---|
| 1 | `app/src/main/java/org/matrix/TEESimulator/App.kt:64` | `NativeCertGen.initialize("/data/adb/modules/tricky_store/libcertgen.so")` |
| 2 | `app/src/main/java/org/matrix/TEESimulator/config/BootStateManager.kt:9` | `private const val CONFIG_PATH = "/data/adb/tricky_store"` |
| 3 | `app/src/main/java/org/matrix/TEESimulator/config/ConfigurationManager.kt:32` | `const val CONFIG_PATH = "/data/adb/tricky_store"` |
| 4 | `app/src/main/java/org/matrix/TEESimulator/pki/NativeCertGen.kt:63` | `private const val LOG_DIR = "/data/adb/tricky_store/logs"` |
| 5 | `app/src/main/java/org/matrix/TEESimulator/util/AndroidDeviceUtils.kt:211` | `private val PERSIST_DIR = File("/data/adb/tricky_store")` |
| 6 | `native-certgen/src/logging/mod.rs:7` | `const VERBOSE_MARKER: &str = "/data/adb/tricky_store/.verbose"` |
| 7 | `module/module.prop` | `id=tricky_store` |

**Fusion 侧硬编码**（若反过来对齐，需改这里）：`launcher.js:19` `MODPATH='/data/adb/modules/aegisfusion'`、`launcher.js:20` / `apps.js:20` `TEE_DIR='/data/adb/teesim'`，以及全部 13 个 shell 脚本的 `TEE_DIR=${AEGIS_TEE_DIR:-/data/adb/teesim}` 默认值。

### 1.2 admin socket 与 verdict 遥测在 RS 中**双双缺失** ⚠️ 最严重

#### 1.2.a admin socket / teesim-uds 不存在

**证据**：
- `grep -rl "LocalSocket|LocalServerSocket|admin.sock|/status|AbstractSocket" app/src/main/java/` → **零命中**
- `app/src/main/cpp/CMakeLists.txt` 只构建 5 个目标：`utils`、`binder`、`libinject.so`、`libsupervisor.so`、`TEESimulator`。**没有 `teesim-uds`**
- shell 版的 `teesim-uds` 是一个**按 ABI 预编译、随模块分发的二进制**：`module/customize.sh:404` → `[ -f "$MODPATH/$abi/teesim-uds" ] && set_perm ...`；运行期由 `module/service.sh:448-450` 拷到 `$TEE_DIR/teesim-uds`

**影响链条**：

```
engine-verdict.sh socket_ack_state()  :107-111
  ├─ [ -x "$TEE_DIR/teesim-uds" ]        → 直接失败
  ├─ [ -e "$TEE_DIR/admin.sock" ]        → 失败
  └─ 需要 /status 返回 "push":{"last":N} 与 "ack":{"last","applied","failed"}
        ↓
engine_verifiable()（keybox-fetch.sh:459）第二判据失效
        ↓
CUR_REJECTED 永远判不出来（:711-713）
deploy_and_verify() 走 fail-open 分支（:530 "no live engine to ask — deployed WITHOUT a verdict"）
        ↓
自动刷新「部署了但从不验证」
```

**为什么这条最严重**：socket 兜底**不是锦上添花**，它专为 **logcat 全死** 的设备而加。脚本注释记录的就是现场报告：

> `engine-verdict.sh:103-106` — "field report 2026-09-20: durable file, in-memory ring and logcat ALL empty while the daemon ran and the interceptor was injected - every log-based signal died at once on that ROM"

⇒ 在那种设备上，**持久轨迹恒空 → 唯一能拿到 verdict 的路径就是 admin socket**。这条不补，P2（verdict 系统）在这类设备上等于没有。

#### 1.2.b 更根本的一条：RS 侧**没有任何 verdict 遥测**（架构原因，非疏漏）

Fusion verdict 系统解析的 **8 个日志标记，在 RS 源码中命中数全部为 0**：

| 标记 | RS 命中 | 语义 | shell 版出处 |
|---|---|---|---|
| `control: ack` | **0** | 拦截器对推送的回执（含 `applied=` / `failed=` 计数） | 上游 `Control.kt` |
| `control: pushed config` | **0** | daemon 已推送配置 | 上游 `Control.kt` |
| `cfg: staged profile` | **0** | 拦截器已暂存 profile | 上游 `ConfigStore` |
| `failed to build` | **0** | profile 构建失败（坏 keybox） | 上游 |
| `never pushed a config` | **0** | daemon 从未推送 | 上游 |
| `target=1` / `target=0` | **0** | 请求被引擎接管 / 穿透到真实 HAL | C++ 拦截层 |
| `teesim_km_init_ex` | **0** | keybox 被拒的**引擎原话** | shell 版的 Rust TA（`rust/teesim-km/src/ffi.rs`） |

**为什么是 0 —— 两套架构根本不同**：

| | shell 版（JingMatrix TEESimulator + 7 补丁） | RS 基座（Enginex0） |
|---|---|---|
| 拦截器取配置的方式 | daemon 经**控制 socket** 推送 + 等 ack | **静态 `ConfigurationManager` 对象**直读（`Keystore2Interceptor.kt:181,261,499` 等） |
| 进程间控制面 | 有（`/data/misc/keystore/.teesim-ctl`） | **无**（`grep LocalSocket\|createSocket` 零命中） |
| keybox 解析在哪 | 独立 Rust TA（`teesim-km`）→ `teesim_km_init_ex:` | Kotlin 侧 `KeyBoxManager` / `CertificateGenerator`，**无同名输出** |
| 日志落地 | `LogTail` 把 logcat 镜像成持久文件 `log/teesim.log` | `SystemLogger` 仅 `Log.i/d/w/e`（**只进 logcat**）+ 一个 per-UID NDJSON 诊断 sink |
| 配置热重载 | daemon 的 `ConfigStore.watch` → `resolveAndPush()` | `ConfigurationManager.ConfigObserver`（`ConfigurationManager.kt:291-312`） |

⇒ **verdict 的数据源在 RS 上一条都不存在**：没有持久轨迹（`log/teesim.log`）、没有控制 socket、没有 ack 计数、没有引擎原话。
`engine-verdict.sh` 搬到 RS 后，`verdict_from()` 必然返回 3 → socket 兜底也失败 → 恒 `write_state unknown` → **exit 2**。
`engine-check.sh` 的第 5 / 第 9 节会全空；WebUI 的 `EAPP`/`EFAULT`/`ESTAGED`/`EBUILD`/`ENEVER`/`ET1`/`ET0` 全为 0；引擎判定灯恒为「未知」。

**因此 D2 的真实规模不是「加一个 socket」**，而是「在 RS 上重建 verdict 的数据源」。见 §4 的 D2 修正。

### 1.3 进程名不匹配

| 侧 | 进程名 | 依据 |
|---|---|---|
| RS 基座 | `TEESimulator` | `module/daemon`: `exec /system/bin/app_process ... --nice-name=TEESimulator org.matrix.TEESimulator.App` |
| Fusion 层 | `teesim` | `engine-check.sh:20` 注释：「app_process rewrites argv[0], so `/proc/<pid>/cmdline` reads "teesim"」；`:77` 用 `pidof teesim` |

**依赖 `pidof teesim` 的探针（3 处）**：`launcher.js:369`（`dp=$(pidof teesim)` → WebUI 的 `DAEMON=running/stopped`）、`engine-check.sh:77`、`keybox-fetch.sh` 的 `engine_verifiable()`。

⇒ 在 RS 上这三处**全部恒判为「守护进程未运行」**，即使它跑得好好的。这与 v3.1.2 修过的那个 `pgrep -f` 伪失败是同一类 bug（`engine-check.sh:16-20` 有完整复盘）。

### 1.4 应用范围契约：`config.json`（shell 版） vs `target.txt`（RS）

| 侧 | 应用范围来源 | 证据 |
|---|---|---|
| shell 版 | **`config.json`** → `profiles.<active>.apps` | `apps.js` 写入；`engine-check.sh:109-114` 读 `config.json` 的 `"mode"` / `"keybox"`；`apps-sync.sh:27` `CONFIG="$TEE_DIR/config.json"` |
| RS 基座 | **`target.txt`** | `ConfigurationManager.kt:33` `TARGET_PACKAGES_FILE = "target.txt"`，`:67` 加载；keybox 作用域用 `[xxx.xml]` 行标记（`:153`） |

**7 个补丁没有一个引入 `config.json`**（已逐个核对 `patches/teesim/*.patch` 的文件清单：0001→App/KeyAdmin/Updater/daemon、0002→webroot、0003→Packages、0004/0006→Harvester、0005→keymint_router、0007→Control/KeyAdmin）。
⇒ 说明 `config.json` 是 **shell 版上游（JingMatrix `org.matrix.teesim`）自带的配置格式**，而 RS（Enginex0，`org.matrix.TEESimulator`）走的是 `target.txt`。两者是**不同的配置契约**。

**后果**：WebUI 的应用管理页（`apps.js`，800 行）写的是 `config.json`，**RS 完全不读**。所以「webui 不变」在这一页需要额外工作量，三条路线：

1. 给 RS 的 `ConfigurationManager` 增加 `config.json` 读取（对齐 shell 版契约）→ WebUI 零改动；
2. 让 `apps-sync.sh` 承担 `config.json` → `target.txt` 的翻译（它已在 service.sh 里每 5 分钟跑）；
3. 让 WebUI 改写 `target.txt` → ❌ 违反「webui 不变」。

（1 与 2 的取舍取决于后续是否要把 app 范围纳入 Rust。）

### 1.5 判定与「WebUI 不变」的耦合

1.1 与 1.3 是一组联立约束：**要让 WebUI 一字不改，RS 侧就必须对齐 Fusion 的路径名与进程名**；反过来若保留 RS 的命名，WebUI 的 2 个常量 + 全部脚本默认值都要改。见 §4 决策 D1。

---

## 2. 功能缺失（代码量问题，非阻塞）

| # | 缺失项 | 规模 | 来源 |
|---|---|---|---|
| 2.1 | **WebUI 整套** | 9 文件 / 3308 行 | `IntegrityFusion/module/webroot/`（`index.html` / `apps.html` / `logs.html` / `css/{home,launcher}.css` / `js/{launcher,apps,logs,prefs}.js`）。RS 侧 `find -iname '*.html'` 零结果 |
| 2.2 | **管理层 13 个 shell 脚本** | 4151 行 | `fusion_func.sh` / `post-fs-data.fusion.sh` / `engine-check.sh` / `engine-verdict.sh` / `keybox-check.sh` / `keybox-swap.sh` / `keybox-fetch.sh` / `pif-fetch.sh` / `pif-sync.sh` / `apps-sync.sh` + 三个 Fusion 版的 `customize.sh` / `service.sh` / `uninstall.sh` |
| 2.3 | **`patches/` 7 个补丁** | — | `0001-fusion-adjustments` / `0002-zh-webui` / `0003-icon-typeface-warmup` / `0004-vbk-compat-override` / `0005-attest-id-retarget` / **`0006-mask-harvest-id-logging`（隐私）** / **`0007-engine-status-socket`（= 1.2）**。RS 是独立 fork，不需要补丁文件，但这些改动必须**落进 RS 源码** |
| 2.4 | **构建与验证链** | 13 个脚本 | `versions.env`（上游钉版）、`assemble.sh`、`scripts/verify/{verify-artifact,verify-n1,compare-batches}.sh`、11 个 `scripts/test-*.sh` 单测。RS 侧只有 `scripts/package.sh` |
| 2.5 | **WebUI 装配步骤** | — | shell 版 `customize.sh` / `service.sh` 里把 `webroot/` 铺到模块目录的步骤，RS 的 `customize.sh` 完全没有（它连 webroot 概念都没有） |

**注**：RS 自带的是 **KSU action 按钮**方案（`module/action.sh` + `action_i18n.sh` 19KB 文案），与 webroot 方案并存不冲突，但两套 UI 的文案需要一致（否则又回到「三处各说各话」的老问题）。

---

## 3. 上游遗留（与移植无关，但迟早要改）

| # | 项 | 位置 |
|---|---|---|
| 3.1 | `id=tricky_store`、`name=TEESimulator-RS`、`author=JingMatrix, Enginex0`、`updateJson` 指向 Enginex0 仓库 | `module/module.prop` |
| 3.2 | `verName = "v6.0.1"`、zip 名 `TEESimulator-RS-*`、`applicationId org.matrix.TEESimulator`、`refreshUpdateJson` 的 zipUrl/changelog 全指 Enginex0 | `app/build.gradle.kts` |
| 3.3 | `LSPlt` 子模块未初始化（`.gitmodules` 指向 `JingMatrix/LSPlt`，目录为空） | `app/src/main/cpp/external/LSPlt` |

---

## 4. 待拍板的决策

### D1 · 路径与模块名怎么定？——**修正：原推荐有误**

**原推荐 D1-a（RS 全盘对齐 Fusion）漏掉了一个冲突**：本项目自己的文档已写明两线要**并行且配置隔离**：

- `README.md:31`：「v1.1：本基座 + 管理层移植 + **并行变体 A/B**（同设备 …）」
- `docs/ARCHITECTURE.md:38`：「本项目在 v1.1 以**并行变体**发布 … **两线的 keybox 渠道/配置不共享（各自目录）**，避免互相干扰」

而 shell 版的模块 id 就是 `aegisfusion`（`module/module.prop:1`），配置目录就是 `/data/adb/teesim`。
Rust 版若沿用这两个值 → 同 id 无法共存，且两线互相覆盖 keybox 与渠道状态 —— 正是文档要避免的。

| 方案 | 动作 | 评价 |
|---|---|---|
| **D1-a′（新推荐）** | Rust 版用**独立**模块 id（如 `aegisfusion_rs`）与独立配置目录（如 `/data/adb/teesim-rs`）；同时把 WebUI 里重复 3 份的 `TEE_DIR` / `MODPATH` 收敛为**单一定义点**，两条线各注入一份 | 满足并行隔离；WebUI 只动这 2 个常量，且顺带消除既有重复 |
| ~~D1-a（原）~~ | RS 全盘对齐 Fusion | ❌ 与并行变体要求冲突，**废弃** |
| D1-b | Fusion 对齐 RS | ❌ 要改稳定发布线，不可接受 |
| D1-c | 符号链接桥 | ❌ 隐式状态，且与「用户导入 keybox 检测」的 mtime 判据互相干扰 |

> **附注（既有隐患）**：`TEE_DIR` / `MODPATH` 目前在 WebUI 里各有 3 份定义——
> `launcher.js:19-20`、`apps.js:20-21`、`logs.js:27-28`。无论选哪个方案，都该收敛成一处。

### D2 · 拆成两件独立的事 ——**修正：不是「加一个 socket」**

#### D2-① admin socket + `teesim-uds`：**硬需求，不是可选项**

原先我把它当作「verdict 的兜底通道」，低估了。实际上它是 **WebUI 两个页面的唯一数据通道**：

| 依赖方 | 位置 | 用途 |
|---|---|---|
| `apps.js:22-24` | `HELPER = TEE_DIR + '/teesim-uds'`、`SOCK = TEE_DIR + '/admin.sock'`、`TOKEN_FILE` | 应用管理页的全部 daemon 交互 |
| `apps.js:242` | `daemonRequest('GET', '/packages')` | 已安装应用列表 |
| `logs.js:28-29` | 同上三件套 | 日志页的 daemon 日志源 |
| `logs.js:153` | `daemonGet('/logs?after=0&max=N')` | admin 内存环日志 |
| `logs.js:166` | `daemonGetRaw('/logs/download?max=N')` | 日志导出 |
| `logs.js:177, 834` | `daemonGet('/status')` | 引擎状态（含 push/ack 字段） |
| `engine-verdict.sh:107-111` | `socket_ack_state()` | verdict 的 socket 兜底 |

⇒ **必须实现**，且端点契约要与上表一致：`GET /packages`、`GET /status`、`GET /logs?after=&max=`、`GET /logs/download?max=`，外加一个 `teesim-uds <sock> <METHOD> <PATH> <token>` 的 CLI 客户端。
（`config.json` 的读写不走 uds，是 `apps.js` 的文件 IO。）

#### D2-② verdict 的数据源：需要选路线

§1.2.b 已证明 RS 侧四个数据源全无。所以问题不是「补一个端点」，而是「重建数据源」：

| 方案 | 动作 | 评价 |
|---|---|---|
| **D2-a′（新推荐）** | **在拦截器内部直接落 verdict**。RS 是单进程内拦截，keybox 解析失败的瞬间就在 `KeyBoxManager` / `CertificateGenerator` 手里，**不需要跨进程 ack**。在那里直接写 `.engine-verdict`（格式与键集完全照 `CONTRACT-verdict-keybox.md` §3.1），数据源 = 拦截器自身，与 logcat 死活无关 | 天然免疫 logcat 全死；不新增进程/socket；写入者从 `engine-verdict.sh` 变为 Kotlin，但**文件格式不变 → WebUI 不变** |
| D2-c | 照搬 shell 版：补 LogTail 持久镜像 + 控制 socket + push/ack 遥测 | 工作量最大，且要在 RS 里凭空造一个它并不需要的跨进程控制面 |
| D2-b | 不做 | `engine_verifiable()` 恒假 → 自动刷新永远 fail-open，**从不验证 keybox** |

#### D2-③ `teesim-uds` 客户端用什么写？

建议 **Rust**——本项目本来就是 Rust 线，且它只是个薄客户端（连 socket、发 `METHOD PATH`、带上 token、把响应打到 stdout）。这与「CLI 兼容层」是同一类产物，可并入同 crate。

### D3 · 进程名保留 `TEESimulator` 还是改成 `teesim`？

若 D1 选 a，建议一并改 `module/daemon` 的 `--nice-name=teesim`——一处改动换来 3 处探针正确，且与 shell 版行为一致。

---

## 5. 建议的推进顺序

**第 1 步 · 决策**：D1 / D2 / D3 拍板（本轮提请）。

**第 2 步 · 基座对齐（"能被认出来的壳"）**
目标：模块能装上、daemon 能跑、**Fusion 探针能正确读出状态**。不碰任何业务逻辑。
- §1.1 的 7 处路径 + `module.prop` id + gradle 命名
- §1.3 进程名
- 验收方式：把 WebUI 的 `PROBE`（`launcher.js:26-161`）单独抠出来在真机上跑一遍，看 `DAEMON=` / `VER=` / `KEYBOX=` 等是否全部合理

**第 3 步 · 补两个关键补丁的语义**
- `0006`（harvest 日志脱敏）落进 RS 源码——**这关系到隐私，不能延后**
- `0007`（admin socket）：按 D2 的结论实施

**第 4 步 · WebUI 整搬**
- 拷 9 个文件 + 路径常量核对（若 D1-a 则常量零改动）
- 在 RS 的 `customize.sh` / `service.sh` 里加装配步骤
- 验收：真机打开 WebUI，三页都能出数据（此处需按项目惯例出 preview mockup + 真机截图对照）

**第 5 步 · verdict / keybox 落 Rust**
严格按 `docs/CONTRACT-verdict-keybox.md`：4 个同名入口 + 25 类数据文件格式逐字复现。

**第 6 步 · 构建与验证链**
`versions.env` / `assemble.sh` / `scripts/verify/` / `test-*.sh` 的移植或改写。

---

## 6. 一句话回答"缺失什么"

- **地基**：路径、进程名、socket 端点三项全不对（§1）——这是「缺失什么」的核心答案；
- **上层**：WebUI 3308 行 + 管理层 4151 行，但那是**照契约搬**的确定性工作，不是风险；
- **真正的风险**是 §1.2——socket 不补，verdict 在 logcat 全死的设备上就是空转，而这恰好是这套系统当初被设计出来要解决的场景。

---

## 7. 变更记录

### 2026-09-21 · Step 2 基座对齐（D1-a′ + D3）

**本轮定下的标识**（三处必须一致，改动时一起改）：

| 项 | 取值 | 引用点 |
|---|---|---|
| 模块 id | `aegisfusion_rs` | `module/module.prop:1`、`module/webroot/js/conf.js` |
| 模块目录 | `/data/adb/modules/aegisfusion_rs` | `App.kt:66`、`conf.js` |
| 配置目录 | `/data/adb/teesim-rs` | 5 处 Kotlin/Rust + 4 处 module 脚本 + `package.sh` 3 处 + `conf.js` |
| 进程名 | `teesim-rs` | `module/daemon`（`--nice-name`）、`conf.js` 的 `PROC` |

**改了什么**：

| # | 范围 | 内容 |
|---|---|---|
| 1 | 配置目录 ×12 | `sed` 统一替换 `/data/adb/tricky_store` → `/data/adb/teesim-rs`（5 Kotlin + 1 Rust + 4 module 脚本 + 3 in `package.sh`），替换后残留 0 |
| 2 | `App.kt:66` | `libcertgen.so` 的模块路径 → `/data/adb/modules/aegisfusion_rs/` |
| 3 | `module/module.prop` | id / name / author / description 全部改；**移除 `updateJson`**（尚无自有仓库，留着会被上游 Enginex0 的 release 覆盖） |
| 4 | `module/daemon` | `--nice-name=teesim-rs`，并注明必须与 `conf.js` 的 `PROC` 一致 |
| 5 | `module/customize.sh` | `CONFIG_DIR`、安装横幅改名；**新增 webroot 解包步骤**（不能用 `unzip -j`，会把目录树拍平），并断言 `conf.js` 存在 |
| 6 | `app/build.gradle.kts` | 新增 `forkRepo` / `artifactName` 单一定义点；`refreshUpdateJson` 改为按 `forkRepo` 生成，留空则删除该文件；zip 名改 `AegisFusion-RS-*`；7 处 task group 改名 |
| 7 | `settings.gradle.kts` / `scripts/package.sh` | 品牌串改名 |
| 8 | `.github/workflows/build.yml` | 产物名与 `out/` 路径随 zip 改名同步修正（否则 CI 上传会失配）。第 133 行 awk 未动 —— 它与 `module/changelog.md`（仍是上游内容）是配套的 |
| 9 | **新增 `module/webroot/`（10 文件）** | 从 shell 版整搬；**并把 `MODPATH`/`TEE_DIR`/`PROC`/`MODID` 收敛到新的 `js/conf.js` 单一定义点**，4 处旧硬编码（launcher.js 2 处、logs.js 2 处）全部改为读 conf.js |
| 10 | 删除 `module/update.json` | 内容为上游 v6.0.1-307 的 release 地址，属误导性陈旧状态 |

**已完成的静态验收**：
- 4 个 JS 文件 `node --check` 全部通过；
- 8 个 module 脚本 `sh -n` 全部通过；
- 全仓库 `tricky_store` 残留 = 0（唯二命中是 WebUI 里**外部模块**的 PIF 源搜索列表 `/data/adb/modules/tricky_store/pif.json`，那是别人的模块，**应当保留**）；
- 旧进程名 / 旧模块 id 残留 = 0。

**尚未做的（有意留待后续）**：
- 真机验收：把 `launcher.js` 的 PROBE 抠出来单跑，核对 `DAEMON=` / `VER=` / `KEYBOX=` 等是否合理（需设备）；
- D2-① admin socket + `teesim-uds`（WebUI 两个页面的唯一数据通道）；
- D2-② verdict 数据源（推荐「拦截器内直落 `.engine-verdict`」）；
- `0006` harvest 脱敏落进 RS 源码（**隐私，优先**）；
- §1.4 的 `config.json` vs `target.txt` 取舍；
- `module/changelog.md` 仍是上游 31KB 内容；
- `LSPlt` 子模块未 init；`native-certgen` 与本机 Android target / NDK 工具链未验证。

---

## 8. 基座选型评估（2026-09-21，回答「要不要抛弃 RS、推倒重来」）

### 8.1 先纠正一个前提：「Rust 版」这个定位是**不成立**的

| | 上游 TEESimulator（JingMatrix，shell 线的上游，`4f42350e`） | RS 基座（Enginex0，本仓库） |
|---|---|---|
| Kotlin | 8,578 | 11,337 |
| **Rust** | **2,705**（`rust/teesim-km`，KeyMint TA） | **2,267**（`native-certgen`，证书生成 + keybox 解析） |
| C++ | **18,395**（`keystore/` 一处就 12,870） | 3,694 |
| 组件划分 | `keymint/` `keystore/` `injector/` `logcat/` `common/` `rust/` `third_party/` | 单体 `app/` |
| 合计 | ~35,000 行 | ~19,000 行 |

**两个上游都是 Rust 混合体，而且 shell 线的上游 Rust 更多、C++ 多 5 倍。**
Enginex0 自己的 README 说的很清楚（`docs/UPSTREAM-README.md:14`）：

> "This is a fork of JingMatrix/TEESimulator. It adds **certificate generation written in Rust**, generated keys that survive reboots, and attestation behavior that matches stock Android."

⇒ RS 的差异**只有三点**，其中只有一点与 Rust 有关（证书生成）。它不是「把引擎 Rust 化了」，而是**把证书生成改成了 Rust，同时把 18k C++ 换成了 ~11k Kotlin**。
**结论：以「想要 Rust 版」为理由选 RS，理由不成立。**

### 8.2 更关键的发现：Fusion 管理层是长在 **TEESimulator** 上的，不是长在 RS 上的

证据一 —— 7 个补丁的文件清单**全部**指向 TEESimulator 的源码，RS 上一个补丁都没有：

| 补丁 | 触及文件（均在 TEESimulator 仓库内） |
|---|---|
| 0001 | `app/.../App.kt`、`KeyAdmin.kt`、`Updater.kt`、`module/daemon` |
| 0002 | `module/webroot/{index.html, js/app.js, js/ui/dom.js, js/ui/logs-view.js}` + 新增 `js/ui/i18n.js` |
| 0003 | `app/.../Packages.kt` |
| 0004 / 0006 | `app/.../Harvester.kt` |
| 0005 | `keymint/keymint_router.cpp` |
| 0007 | `app/.../Control.kt`、`KeyAdmin.kt` |

证据二 —— 本地 `本地 TEESimulator 克隆（shell 线姊妹目录）` 是 `4f42350e` 的 detached HEAD，working tree 里恰好是上面那 12 个文件被改（未提交）＝补丁已就地应用。补丁里已经出现 Fusion 专属代码：
- `App.kt:509` fallback `File("/data/adb/modules/integrityfusion")`
- `Harvester.kt:1270` 注释 `Fusion (Aegis) compat override`，`:1288` 读 `/data/adb/teesim/bootkey.bin`

证据三 —— **TEESimulator 原生就满足 Fusion 的全部契约**：

| Fusion 需要 | TEESimulator 原生提供 | RS |
|---|---|---|
| 数据目录 `/data/adb/teesim` | `Const.kt:8` `DATA_DIR = "/data/adb/teesim"` | ❌ 需改（已做） |
| `config.json` 契约 | `Const.kt:10` `File(DATA_DIR, "config.json")`；`ConfigStore.kt:198-208` FileObserver 监听 `config.json` / `*.xml` | ❌ 用 `target.txt` |
| 进程名 `teesim` | `module/daemon:23` `--nice-name=teesim org.matrix.teesim.App` | ❌ 需改（已做） |
| 控制 socket | `Const.CONTROL_SOCKET_PATH` + `Control.kt`（`LocalSocket` + `peerCredentials.uid` 鉴权，上游 #264/#266） | ❌ 完全没有 |
| keybox 拒绝原因（`teesim_km_init_ex`） | `rust/teesim-km/src/ffi.rs` | ❌ 无同名输出 |

⇒ **改用 TEESimulator 当基座，4 处契约冲突会一次性全部消失**，管理层 4151 行 + WebUI 5,146 行 + 7 个补丁**原样可用**。
> ⚠️ 此结论只对「契约冲突」成立。后来用户决定**管理层与 UI 都重写**（只取逻辑），所以「原样可用」不再是路线选择——见 §12。

### 8.3 三条路

| | A. 继续 RS 桥接 | B. 换 TEESimulator 基座 | C. 从零自写引擎 |
|---|---|---|---|
| 剩余契约冲突 | 2 项（admin socket、`config.json`） | **0 项** | 自己定义 |
| 管理层对接面 | 需逐项重新验证（RS 的日志/状态/配置接口都不同） | **原样可用** | 全部重写 |
| 保留 RS 的三项改进 | ✅ 直接保留 | ❌ 需另行移植 | ❌ |
| 主要成本性质 | **确定性工程量**（约数百行 Kotlin + 一个 Rust 客户端） | **不确定的技术风险**（要移植 `native-certgen`，以及「行为贴近原生」几乎无法移植） | 不现实：拦截层 11k Kotlin + 3.7k C++，安全关键且强设备相关 |
| 长期维护 | 两套架构持续漂移 | 与 shell 线共上游，补丁可共用 | — |

### 8.4 建议

**先回答一个问题：变体存在的理由是什么？** 两条路的取舍完全取决于它：

- **理由 = 「引擎 Rust 化」** → 选 **B**。因为 RS 并不能带来更多 Rust（§8.1），而 B 让契约摩擦归零，并让「Rust 化」变成**可增量、可验证、可回退**的工作（先移植 `native-certgen` 替换 TEESimulator 的证书生成路径，再逐块 Rust 化 keybox 解析 / verdict 落盘 / CLI 兼容层 / `teesim-uds`）。
- **理由 = 「证明行为更贴近原生 Android」** → 只能选 **A**。这是 RS 最难移植的差异，也是它唯一真正的卖点。代价就是老老实实补完 2 项契约并逐项重验。
- **理由 = 「与 AS / shell 线做 A/B 对照」** → 保留两套基座，A 是必然代价。

**如果目标是「Rust 化」——我倾向 B。** 因为 A 的桥接工作（admin socket + `config.json` 读取）本质上是在**给 RS 补上 TEESimulator 早就有的东西**，而补完之后「Rust 占比」并没有提升多少；B 则把这部分省下来的精力直接投到真正的 Rust 化上。

> ⚠️ 顺带一个 shell 线的观察：补丁 0001 给 `App.kt` 加的 fallback 是 `/data/adb/modules/integrityfusion`，而 shell 线的实际模块 id 是 `aegisfusion`（`module/module.prop:1`）。正常路径走 `java.class.path` 推导（`App.kt:502-508`），这个 fallback 几乎不会命中，**但它是个陈旧字符串**，值得在 shell 线里核一下。

---

## 9. 目标定位修正与实施计划（2026-09-21，用户澄清后）

### 9.1 用户澄清的三点

1. **不必全用 Rust** —— 上游本来就是 C++ / Rust / Kotlin 混合，混合代码可以接受；
2. **上一个项目本来就是融合体** —— IntegrityFusion 就是把 TEE（TEESimulator）+ IB（Integrity-Box 的 keybox 渠道）+ PIF（PlayIntegrityFork）融合成一个模块，`scripts/assemble.sh` 干的就是这件事；
3. **保留 Fusion 逻辑的理由** = 那套逻辑已经解决了很多问题，**不重复思考**。

### 9.2 第 3 点这条判据本身就决定了选型 → 选 B（换 TEESimulator 基座）

拿「不重复解决已经解决的问题」去量两条路：

| Fusion 已解决的问题 | 在 RS 上能否原样用 | 在 TEESimulator 上 |
|---|---|---|
| verdict 从 `control: ack` 的 applied/failed 计数判定 | ❌ 无此遥测 | ✅ 原生 |
| 引擎拒绝原因（`teesim_km_init_ex`） | ❌ 无同名输出 | ✅ `rust/teesim-km` |
| `engine_verifiable()` 的 admin socket 兜底 | ❌ 无 socket | ✅ `Control.kt` + `CONTROL_SOCKET_PATH` |
| keybox 热替换免重启（改 keybox.xml 即触发重推） | ⚠️ 机制不同（ConfigObserver 在另一个目录） | ✅ `ConfigStore.watch` |
| WebUI 应用范围（`config.json`） | ❌ RS 读 `target.txt` | ✅ `Const.kt:10` |
| 7 个补丁 | ❌ 全部不适用 | ✅ 全部适用 |

⇒ **在 RS 上，Fusion 的逻辑大部分跑不起来，必须重新推演一遍 —— 而这正是用户明确不想做的事。**
**结论：选 B。** 用户给的这条判据把 §8.4 里那个「取决于变体理由」的问题直接回答了：理由是「保留已解决问题的逻辑」，那就必须站在能让这套逻辑原样运行的基座上。

### 9.3 Rust 化的真实落点 = **管理层**，不是引擎

四层结构（`assemble.sh` 已把前三层合并成一个 zip）：

| 层 | 内容 | 语言 | 本变体怎么处理 |
|---|---|---|---|
| 引擎层 | TEESimulator 源码 + 7 个补丁 | Kotlin 8,578 · C++ 18,395 · Rust 2,705 | **不动**（混合，本来就是） |
| 指纹载荷 | PlayIntegrityFork 官方 zip（校验和钉定） | Zygisk 载荷 | **不动** |
| **管理层** | **Fusion 自有逻辑 13 个脚本 4,151 行** | **shell** | **← Rust 化的落点** |
| WebUI | `html` / `css` / `js` | 5,146 行（html 350 · css 1,763 · js 3,033） | **重写**（§12）——原计划「除 `conf.js` 外逐字节不变」已废弃 |

**为什么 Rust 该用在这一层而不是引擎**：
- 引擎是别人写的、跨语言、安全关键、强设备相关 —— 改它风险高、收益不明（§8.1 已证明「Rust 更多」并不成立）；
- 管理层**是我们自己的代码**，行为已经被现场磨稳（
  脚本注释里记着一堆真实事故的复盘），**契约完全已知**（`docs/CONTRACT-verdict-keybox.md` 已逐条写死），
  但实现是 shell —— 慢、难测、易在边界值上出分歧（`mask_ids` 要复制四份还靠测试断言保持一致，就是 shell 的结构性问题）；
- 把它换成 Rust：**行为契约冻结、实现语言更替**，天然满足「不重复思考」——逻辑照抄，只换壳。

### 9.4 实施顺序（先基线，后替换）

| 步 | 内容 | 验收 |
|---|---|---|
| **0** | 换基座：本仓库改为以 TEESimulator @ `4f42350e` 为基座，沿用 shell 线的 `versions.env` / `fetch-upstreams.sh` / 7 个补丁 / `assemble.sh` | 构建产出的模块，行为与 shell 线 v1.0.1 **逐项一致** |
| **1** | 管理层**原样**搬入（shell 版），得到一个「与 shell 线等价」的基线 | 真机跑通：WebUI 三页有数据、verdict 能判定、keybox 能换 |
| **2** | 按 `CONTRACT-verdict-keybox.md` 逐个把管理层脚本换成 Rust 二进制（入口名不变，`sh <名>` 走 shebang） | 每换一个，跑 shell 线现成的 `scripts/test-*.sh` 套件对拍 |
| **3** | 可选：把 RS 的 `native-certgen` 作为**代码**并入引擎层（混合语言无阻碍） | A/B 对比 attestation 行为 |
| **4** | 收尾：`README` / `module.prop` 的定位描述改成「管理层 Rust 化的融合模块」，不再叫「Rust 版引擎」 | — |

**第 1 步是关键的「不重复思考」保障**：先把等价基线跑起来，再逐块换实现。
这样任何一次替换出问题，都能立刻用基线定位是**替换引入的**还是原本就有的。

> ⚠️ 待确认：本变体与 shell 线会**共享同一个引擎基座与同一套补丁**。这意味着两线在引擎层不再有 A/B 差异 —— 差异只在管理层实现语言。
> 若仍希望保留引擎层的 A/B（RS 的「行为贴近原生 Android」），那引擎层可以做成**可选的第二个变体**，与「管理层 Rust 化」正交，不必二选一。

### 9.5 本机环境约束（实测，2026-09-21）

这一条直接影响「管理层 Rust 化」的工作节奏，必须先解决：

| 项 | 状态 | 影响 |
|---|---|---|
| `rustc` / `cargo` | ✅ **已装**（1.98.1，`~/.cargo/bin`，rustup home `~/.rustup`） | 两条宿主工具链：msvc（默认）+ **gnu** |
| **C 链接器** | ✅ **MinGW-w64 16.2.0**（scoop，`<scoop-mingw-bin>`，已在用户 PATH） | **`cargo test` / `cargo build` 已可用**（实测 1 passed / 0 failed） |
| `cargo-ndk` / Android target | ❌ 未装 / 未加 | 无法交叉编译到 Android |
| Android SDK / NDK | **未安装**（`ANDROID_HOME` / `ANDROID_SDK_ROOT` / `ANDROID_NDK_HOME` 均未设置；无 `local.properties`；`/c/Android` 下**只有 platform-tools**） | 本机**构建不了** Kotlin / C++ / 模块 zip |
| `adb` | ✅ `/c/Android/adb.exe` | 真机运行时验证可用 |
| JDK | ✅ openjdk 21.0.10 | 仅够跑 gradle 的前置检查 |

**本地跑 Rust 的标准调用方式**（默认工具链仍是 msvc，用 `+` 选 gnu）：
```bash
export PATH="$HOME/.cargo/bin:<scoop-mingw-bin>:$PATH"
cargo +stable-x86_64-pc-windows-gnu test
```
> 必须用 **GNU** 工具链 —— MSVC 目标要 `link.exe`（本机没有，且 `rustc` 会**误找 MSYS 的 `/usr/bin/link.exe`**，那是硬链接工具，报 `os error 193 不是有效的 Win32 应用程序`）。

⇒ **本机可做**：读代码、改代码、静态检查（`node --check` / `sh -n`）、**Rust 的 `check` / `test` / `build`**、一致性 grep、adb 真机验证。
**仍不可做**：Android 交叉编译与模块打包。构建产物走 CI。

这同时回答了 `docs/ARCHITECTURE.md` 的待决事项 #3（「本机 rustup/NDK 是否安装」）——**rustup 已装，NDK 与链接器仍无**。

**环境安装的坑（已踩）**：
- 从 Git Bash 给 Windows 程序传 **POSIX 路径的 `CARGO_HOME` / `RUSTUP_HOME` / `SCOOP`** 会被 MSYS 误解析成 `d:/c/Users/...`（当前工作盘是 D: 时，`/c/` 被当作相对路径）。**一律不要设置这三个变量**，让它们用默认值。
- 用 `scoop install rustup` 会因此失败；改用官方 `rustup-init.exe`（minimal profile）。
- `rustup-init` 首次会因 `.cargo/bin/rust-analyzer.exe` 的 0 字节占位报 `os error 183`，删掉后重试即可。

**待决策**（本机能否跑对拍）：
1. 装 **MinGW-w64 gcc** + `rustup toolchain install stable-x86_64-pc-windows-gnu` → 用 gcc 链接，顺带绕开 MSYS `link.exe` 撞名问题（约 100–200MB，最轻）；
2. 装 **Visual Studio Build Tools**（C++ 工作负载）+ 确保其 `link.exe` 在 PATH 中排在 MSYS 之前（数 GB，最重但最标准）；
3. 不装，接受**本机只做 `cargo check`**，所有运行类/对拍测试交给 CI。

---

## 10. 变更记录 · Step 0 换基座（2026-09-21，已完成）

用户决定：**新仓库独立**（接受维护两份副本）；若 RS 变体实测胜出，则 shell 线停止维护只留这一条。
环境走 §9.5 第 3 种：本机只装 `rustup`。

### 10.1 仓库形状改为 overlay-only（与 shell 线一致）

**移除**（引擎源码不再 vendor —— git 历史仍保留在 commit `e7a1078`）：
`app/` `stub/` `native-certgen/` `gradle/` `gradlew` `gradlew.bat` `build.gradle.kts`
`settings.gradle.kts` `gradle.properties` `UPSTREAM` `.gitmodules` `.github/dependabot.yml`
`scripts/package.sh`，以及 RS 遗留的引擎侧 module 文件
（`action.sh` `action_i18n.sh` `changelog.md` `daemon` `diag.sh` `keybox.xml` `sepolicy.rule` `target.txt`）。

**拷入**（自 shell 线）：`patches/teesim/`(7 个补丁) `versions.env` `scripts/`(assemble / fetch-upstreams / harden-pif / 11 个单测 / `verify/`) `module/*.sh` `module/META-INF/` `CHANGELOG.md` `NOTICE.md` `build-fingerprint*` `.gitattributes` `.gitignore` `.github/workflows/build.yml`。

**保留**：`docs/`（我们的）、`module/webroot/`（含 `js/conf.js`）、`LICENSE`。

### 10.2 标识对齐

| 项 | 取值 | 落点 |
|---|---|---|
| 模块 id | `aegisfusion_rs` | `module/module.prop`、`module/webroot/js/conf.js` |
| 模块目录 | `/data/adb/modules/aegisfusion_rs` | overlay 的 9 处 `AEGIS_MODDIR` / 硬编码路径（`sed` 一次改齐，残留 0） |
| 数据目录 | **`/data/adb/teesim`（与 shell 线共享）** | 引擎硬编码（`Const.kt`），见 §10.3 |
| 进程名 | `teesim` | 引擎 `module/daemon` 的 `--nice-name`（补丁 0001 未改它） |
| 版本占位符 | `@FUSION_VERSION@` / `@FUSION_VERSION_CODE@` | 由 `assemble.sh` 替换（原来是 RS 的 `${REPLACEMEVER}`，已改） |

CI 命名同步：artifact `AegisFusionRS_*`、产物 `out/AegisFusionRS-*.zip`、release 标题/附注同步（重复 `RS` 检查通过）。

### 10.3 ⚠️ 我改变了 D1-a′ 的一半，理由是前提变了

原先定的 D1-a′ 是「独立模块 id **+ 独立数据目录**」。换基座后**独立数据目录这一半不再成立**：

- 引擎把 `/data/adb/teesim` **硬编码在源码**（`app/.../Const.kt:8` `DATA_DIR`；`Const.kt:10` 的 `config.json` 与 `Control.kt` 的控制 socket 都挂其下）。要改它必须**新增一个引擎补丁**；
- 而 D1-a′ 当初要求隔离的理由是「RS 用 `/data/adb/tricky_store`、shell 用 `/data/adb/teesim`，共享会互相污染」——**基座换成 TEESimulator 后这个前提消失了**：两条线同引擎、同文件格式；
- 两线**不可能同时生效**（都要 hook keystore2），而 A/B 对比恰恰需要**同配置**才可比。

⇒ 采用「独立模块 id（可区分、可分别刷入）+ **共享数据目录**」。这是 6 行可逆的改动：若要恢复独立数据目录，需改 overlay 约 40 处 `/data/adb/teesim` **并新增一个改 `Const.kt` 的引擎补丁（0008）**。

### 10.4 静态验收（全过）

- `sh -n`：25 个脚本（`module/*.sh` + `update-binary` + `scripts/*.sh`）全部通过；
- `node --check`：5 个 WebUI JS 全部通过；
- 模块目录残留 `modules/aegisfusion`（无 `_rs`）= **0**；
- CI 重复 `RS RS` 检查 = **0**；
- 核实过一处看似缺件：`module/customize.sh:242` 依赖 `$MODPATH/config.default.json`，它由 `scripts/assemble.sh:141` 从**引擎 release zip** 解出 —— overlay 里本来就不该有，**不是缺件**。

### 10.5 仍待处理

1. `CHANGELOG.md` / `NOTICE.md` / `versions.env` 目前仍是 shell 线的内容（身份未换）—— 建议在 Step 4 一并处理；
2. `LICENSE` 取自 RS 快照，需确认与 TEESimulator 的 GPL-3.0 文本一致；
3. RS 基座的 `native-certgen`（Rust 证书生成 + keybox 解析）已从工作区移除，**代码仍在 git 历史 `e7a1078`**；若 Step 3 决定并入，从那里取；
4. `docs/ARCHITECTURE.md` 与 `docs/UPSTREAM-README.md` 是 RS 基座时期的文档，已加「过时」横幅，未删除；
5. 真机验收（Step 1 的出口）：装上新底座模块，确认 WebUI 三页有数据、verdict 可判定、keybox 可换。

### 10.6 本地构建 / 测试循环 —— 实测结论

**关键发现：管理层的验证循环本来就能在本机跑，完全不需要 Android 工具链。** 实测（2026-09-21）：

| 套件 | 结果 |
|---|---|
| `scripts/test-webui.js` | ✅ **109 通过 / 0 失败** |
| `scripts/test-apps.js` | ✅ **89 通过 / 0 失败** |
| `scripts/test-logs.js` | ✅ **92 通过 / 0 失败** |
| `scripts/test-keybox-check.sh` | ✅ PASS |
| `scripts/test-mask-ids.sh` | ✅ PASS |
| `scripts/test-interval-rule.sh` / `test-service-props.sh` / `test-apps-sync.sh` / `test-pif-sync.sh` | ✅ 输出全 PASS，但**跑得慢**（内部有 sleep，>90s 才跑完，不是失败） |

⇒ **改管理层（正是我们要 Rust 化的那一层）时，本机就有完整回归网。** 这比「本地构建整个模块」重要得多 —— 因为 4151 行 shell 的验证几乎都不依赖 Android。

**本机跑「完整模块构建」的代价**（CI 的依赖清单，`.github/workflows/build.yml`）：Android SDK cmdline-tools + **NDK 28.2.13676358**（约 3–4GB）+ `cmake;3.22.1` + `build-tools;36.0.0` + `platforms;android-36`，另加 **BoringSSL 构建所需的 Go、clang、CMake、Ninja**，以及 Rust 的 `aarch64-linux-android` target + `cargo-ndk 4.1.2`。合计约 5–6GB，且**这条链是为 ubuntu runner 写的，Windows 上属于未验证路径**。

**结论**：只有当要改**引擎侧**（补丁、Kotlin/C++）时，本地完整构建才有边际价值；改管理层用本机测试循环即可，产出物交给 CI。

### 10.7 本轮修掉的两个真问题（由本地测试循环抓出）

1. **`scripts/assemble.sh` 会直接让构建失败** —— 它硬编码了模块 id：`:365` 断言 `^id=aegisfusion$`，不匹配即 `exit 1`。更隐蔽的是 `:106` 对 PIF Zygisk 载荷做**定长二进制路径改写**：
   `old = b"/data/adb/modules/playintegrityfix/"`（35 字节）必须与 `new` 等长，末尾用斜杠补位。
   原值 `aegisfusion`（11 字符）需 **6** 个补位斜杠；换成本变体的 `aegisfusion_rs`（14 字符）只能补 **3** 个。
   已改为 `b"/data/adb/modules/aegisfusion_rs///"` 并实测长度 **35 == 35**。注释里写明了「换 id 必须重算补位」。
   （同时把 `:348` 的校验 grep 与 4 个单测文件里 17 处 `modules/aegisfusion` 一并改齐。）
2. **`js/conf.js` 必须双模式** —— 三个 JS 单测会在 **Node 里 `require()` 页面 JS**（那里没有 `window`）。
   我第一版写成裸 `window.AEGIS = {...}` + `if (!C) throw`，**三个 JS 单测立刻全挂**（这正是本地测试循环的价值）。
   现改为：conf.js 同时挂 `root.AEGIS` 与 `module.exports`；页面侧按「先 `window.AEGIS`、后 `require('./conf.js')`」取值。修后 290 条断言全绿。

### 10.8 模块 id：已用「参数化」化解，不再是二选一

原本担心「独立 id 会让 `assemble.sh` 与单测套件变成需长期对账的分叉副本」。**这个成本可以直接消掉 —— 把 id 从写死的字面量改成从单一来源读出来的参数。**

用户的原则是「只取逻辑，不照搬代码，我们自己重构」。按此落地：

| 原先（硬编码） | 现在（参数化） |
|---|---|
| `grep -q '^id=aegisfusion$'` | `grep -q "^id=$MODID$"`，`MODID` 读自 `module/module.prop` |
| `new = b".../aegisfusion_rs///"`（补位靠人算） | 补位**程序化计算**：`pad = 35 − 18 − ${#MODID}`，脚本内断言 `pad ≥ 1` 且 id ≤ 16 字符 |
| 校验 grep 写死补位后的字面量 | 校验 grep 用算出来的 `$PIF_PATH_NEW` |

实测两种 id 都成立：
```
id=aegisfusion     pad=6  /data/adb/modules/aegisfusion//////      len=35  OK
id=aegisfusion_rs  pad=3  /data/adb/modules/aegisfusion_rs///      len=35  OK
```

**⇒ `assemble.sh` 现在与模块 id 完全解耦**（实测残留 0），所以：
- 它**不再需要分叉** —— 两条线可以共用同一份，且这个改动**可以反向贡献给 shell 线**；
- 「独立 id」的长期成本归零，模块 id 取 `aegisfusion_rs` 保持不变（也能在设备上区分两条线）。

同样的思路应施加到 4 个单测文件（从 `module/module.prop` 读 id）—— 待 UI 范围确定后一并处理（其中 3 个 JS 单测与 UI 强耦合，见 §11）。

---

## 11. 待确认：UI 的**范围**（决定 5,146 行 WebUI 的去留）

用户指示：「只有功能部分的逻辑需要拿过来，**ui 部分可以重新重构**」。
这句话有**两种读法，工作量差一个数量级**，必须先确认是哪一种：

### 读法 A（小）：指**引擎自带的上游 WebUI**

- 指 `webroot/teesim/`（TEESimulator 自带的控制台，补丁 0002 给它做中文化）
- `assemble.sh:353` **本来就断言它不得打包** —— audit N2：它的日志导出会把未脱敏的旧日志分片拼进 `/sdcard/Download`。所以我们从一开始就不打算带它。
- Fusion 自己的三页（`launcher` / `apps` / `logs`，5,146 行）**仍然照搬**
- **变更量：0**（现状已经如此）

### 读法 B（大）：指 **Fusion 自己的三页 WebUI 也要重写**

- 作废重来：`module/webroot/` 5,146 行 + 3 个 JS 单测（**290 条断言**的现成回归网）
- 需一并决定：`js/conf.js` 的「单一定义点」约定是否保留？
- ⚠️ 关键提醒：**WebUI 里不只有 UI**。`apps.js` 承担 config.json 的读写与受保护应用管理；`launcher.js` 携带两段内联 shell 探针（约 35 / 45 个 `KEY=VALUE`，是整个仪表盘的数据源）；`logs.js` 含诊断导出与**脱敏**逻辑（H1 审计项）。
  重写这三页 = 重写管理层的另一半，且要重新落实那些审计修复。

### 我的建议

若目的只是「管理层 Rust 化」，**UI 不必重写** —— 它是浏览器侧的呈现层，与 shell→Rust 的迁移正交，而 290 条断言是现成的回归网（§10.6 已实测可本机跑）。
若你确实想要「这个变体有自己的 UI」，那就走读法 B；我会**先把必须保留的功能契约从现有 JS 里抽出来**（探针输出的键集、config.json 的读写方式、`ksu.exec` 命令形态、脱敏规则），写成规格，再按规格重写 —— 这样 UI 换了、功能不变。

---

## 12. 重写范围与策略（2026-09-21，用户明确方向后）

**用户方向**：「只获取它的逻辑，然后我们全部使用混合代码进行重写。」
⇒ 本变体**不照搬 shell 线的产品代码**，只把它的**逻辑（行为契约）**取过来，用混合语言重新实现。

### 12.1 范围

| 对象 | 处置 | 理由 |
|---|---|---|
| 引擎（上游 TEESimulator） | **保留** | 不是 shell 线的代码，是第三方上游；重写它等于重写整个 attestation 引擎 |
| `patches/teesim/*.patch`（7 个） | **保留** | 这些是**我们自己**对上游的改动（作者是项目方），不是待重写的 shell 业务逻辑；且与实现语言无关 |
| 构建 / CI / 安装基础设施（`fetch-upstreams.sh`、`assemble.sh`、`versions.env`、`module/META-INF/`、`.github/`） | **保留** | 工具链，不是产品逻辑。`assemble.sh` 已完成 id 参数化（§10.8） |
| **管理层 13 个脚本（4,151 行 shell）** | **重写** | 产品逻辑的核心 |
| **WebUI（5,146 行 JS/HTML/CSS）** | **重写** | 用户明确：UI 部分重新重构 |
| **针对上述两者的单测** | **部分重写** | 见 §12.3 |

### 12.2 关键连锁变化：「同名 CLI 兼容层」这个约束**消失了**

`docs/CONTRACT-verdict-keybox.md` 当初把「入口名不变、argv/退出码/输出契约照抄」当作硬约束 —— 那个约束的**唯一来源是「WebUI 一字不改」**（WebUI 用 `ksu.exec('sh $MODPATH/xxx.sh …')` 直接调脚本）。

**既然 WebUI 也要重写，这个约束就不存在了。** 于是：

| 契约 | 是否保留 | 为什么 |
|---|---|---|
| **CLI 入口名 / argv / 退出码 / stdout 形态** | ❌ **不再需要** | 新 WebUI 可以直接调用新接口（可以是子命令、也可以走 admin socket） |
| **数据文件格式**（`.engine-verdict` 的键集与锚点、`.kb-fetch.progress` 三行、`.auto-keybox`、`.key-status-n` 的 `-1` 哨兵、`config.json`、`keybox.xml` 的原子 rename…） | ✅ **必须保留** | ① 这些文件是**与引擎的接口**（`ConfigStore.kt` 监听 `config.json`/`*.xml`，`Control.kt` 走控制 socket），改格式就要改引擎；② 两线**共用数据目录**（§10.3），A/B 来回刷入时必须能互相读懂对方的落盘状态 |
| **`mask_ids` 脱敏规则** | ✅ **必须保留语义** | H1 审计项；实现可重写，但四份副本不必再存在（重写后天然单实现，`test-mask-ids.sh` 的字节一致性断言随之退休） |

⇒ **重写时的自由度**：接口怎么设计随我们；文件格式与脱敏语义不能动。

### 12.3 测试去留 —— **已定稿**，见 `docs/TEST-INVENTORY.md`

结论摘要：

| 类别 | 数量 | 处置 |
|---|---|---|
| **黑盒**（用环境变量重定向 + 桩工具，把脚本当 CLI 跑） | **6 个 / 约 1,900 行** | ✅ **可原样复用** |
| **白盒**（`grep`/`sed` 读取或抽取被测算源码文本） | 3 个 | ❌ 必须重写（但语义要迁移） |
| **JS**（`require()` 现有 UI 并驱动 DOM） | 3 个 / 290 条断言 | ❌ 随 UI 重写（断言按语义迁移） |

**最重要的发现**：黑盒套件能复用，靠的是一个隐形契约 —— **21 个 `AEGIS_*` 环境变量**（`AEGIS_TEE_DIR` / `AEGIS_MODDIR` / `AEGIS_ADB` / `AEGIS_PIF_*` / `AEGIS_KB_*` …）。
重写后的实现**必须保留这 21 个注入点**（名称与语义不变），就能把网络、设备、时间全部挡在测试之外，白拿约 1,900 行现成回归网。

白盒那 3 个里「值钱」的语义断言（间隔白名单与单写者、脱敏四形态、ROM-hook 中和）已在 `TEST-INVENTORY.md` §3 逐条列出，重写时按语义转成黑盒式用例。

### 12.4 「抽功能契约」的进度（即用户说的「只获取它的逻辑」）

| # | 内容 | 状态 |
|---|---|---|
| 1 | verdict / keybox 两条线的 CLI 契约 | ✅ `CONTRACT-verdict-keybox.md` |
| 2 | **WebUI 功能契约**：85+10 个探针键的逐键来源、5 条判定规则、exec 面、socket 端点、脱敏规格 | ✅ `CONTRACT-webui.md`（探针键 **95 个唯一键** = 85 字面 + 10 动态 `CFG_*`） |
| 3 | pif-fetch / pif-sync / apps-sync / fusion_func / service / customize 的逻辑契约 | 🟡 进行中：`fusion_func.sh` ✅ 已完整抽取；其余 5 个已列要点与依赖顺序，见 `CONTRACT-management.md` |
| 4 | 测试接缝与去留 | ✅ `TEST-INVENTORY.md`（含 21 个 `AEGIS_*` 注入点） |
| 5 | **④ 重写第一块：`keybox-check` → Rust**（`rust/fusionctl/`，零依赖；差分测试 `test-diff-keybox-check.sh` **20/20 一致**） | ✅ 2026-09-21 |
| 6 | **④ 重写第二块：`engine-verdict` → Rust**（once / show / reason / socket-live + 状态文件 + sha2 内容锚点；差分 `test-diff-engine-verdict.sh` **15/15 一致**。教训：**手写 SHA-256 对 71 个长度全错，改用 `sha2` crate 后一次通过** —— 永不手写密码学原语） | ✅ 2026-09-21 |
| 7 | **④ 重写第三块：`fusion_func` → Rust**（4 助手 + `align_patch_level`；差分 `test-diff-fusion-func.sh` **5/5 一致**，用编译的 C 桩 `resetprop`。**修掉了 shell 版写死数据目录的缺陷**，Rust 版遵守 `AEGIS_TEE_DIR`） | ✅ 2026-09-21 |
| 8 | **④ 重写第四块：`apps-sync` → Rust**（守卫/迁移/GMS 播种/uid pin/清理，定点 JSON 编辑；差分 `test-diff-apps-sync.sh` **5/6 一致 + 1 个已登记的 shell 缺陷** —— **差分挖出 shell 线真 bug**：空 apps 数组 + uid pin 时 shell 产出非法 JSON，见 `KNOWN-FAILURE-MODES.md` §7.1） | ✅ 2026-09-22 |
| 9 | **④ 重写第五块：`pif-sync` → Rust**（9 路源探测 / pget / set_id / ensure_patch_object / assert_flags / 三条回滚；差分 `test-diff-pif-sync.sh` **6/6 一致**。**修掉移植里的真 bug**：改完内存没写回 config.json —— 差分一跑就现形） | ✅ 2026-09-22 |
| 10 | **④ 重写第六块：`pif-fetch` → Rust（最难的一块，§13 标 ★★★★★）**（所有权三规则 / 恢复遍历 / durable master / 种子 / 到期感知轮换 / 三级代理 + 自动探测；差分 `test-diff-pif-fetch.sh` **9/9 一致**。**又修掉两个移植 bug**：忽略 `AEGIS_AUTOPIF` 接缝、没写回 config.json —— 都是差分现形的） | ✅ 2026-09-23 |
| 11 | **④ 重写第七块：`service` 环境隐藏层 → Rust**（BL/VBMeta 7 props + 保修/调试 10 + OEM 3 + 构建信号**遍历** + recovery 隐藏 + **ROM 钩子二分语义**；差分 `test-diff-service-env.sh` **2/2 一致**。含 hook ROM 的中和/清残留二分） | ✅ 2026-09-24 |
| 12 | **④ 重写第八块：`keybox-swap` → Rust**（deploy 的**备份 fail-closed**（audit N15/M11）+ 原子替换（MOVED_TO 触发器 + 替换符号链接本身）+ 剪枝到 10 + .auto-keybox 作废 + validate 委托 + --list/--restore；差分 `test-diff-keybox-swap.sh` **6/6 一致**（restore 单列待查）） | ✅ 2026-09-24 |
| 13 | **④ 重写第九块：`service` 环境隐藏层 → Rust**（BL/VBMeta 7 + 保修/调试 10 + OEM 3 + 构建信号**遍历** + recovery 隐藏 + **hook ROM 二分语义**（中和 9 / 清残留 12）；差分 `test-diff-service-env.sh` **2/2 一致**。桩修 3 个：缺失属性退出码 ×2 分支、list 只输出名字） | ✅ 2026-09-24 |
| 14 | **④ 重写第十块（★5 最难）：`keybox-fetch`(824) → Rust**（渠道生态 + 四档下载阶梯 + 三种解码器 + sha256 pin + 引擎验收循环 + badlist 拉黑 + pre-run 回滚 + 导入护栏 + --force fail-closed 备份 + 吊销缓存 + 并发锁；差分 `test-diff-keybox-fetch.sh` **9/9 一致**。挖出宿主陷阱 6 个：System32 前置的 spawn 解析、PATH 盘符冒号、http_proxy 污染、emoji grep locale、echo 换行 parity、keybox-check 行式解析） | ✅ 2026-09-25 |
| 16 | **④ 重写第十二块：`uninstall`(66) → Rust**（杀 daemon → 抹数据目录（新增 `AEGIS_TEE_DIR` 接缝）→ 清注入物 → 残留 props（12 个 RESIDUE_PROPS，--delete + -p --delete）；差分 `test-diff-uninstall.sh` **2/2 一致**（resetprop 调用序列逐条比；shell 删除目标硬编码不可宿主重定向）。`post-fs-data.fusion.sh`(17) 已由 fusion_func 的 align-patch-level 入口覆盖） | ✅ 2026-09-25 |
| 17 | **④ 重写第十三块：`watch` 子命令 → Rust**（engine-verdict 的轮询等待：字节偏移 + 轮转整读 + 计数判定 + admin socket 兜底 + SILENT 尾部 mask_ids；**report() 的 rc=1 引擎原话块按 shell 原文归位**——once 与 watch 共用。keybox-swap 补 `--watch`/`--auto`/单候选验收流，顺带修 validate 从未真正跑过 keybox-check 的潜伏 bug（Windows 直接 exec 脚本必败）。新差分 `test-diff-keybox-swap-watch.sh` **11/11** + engine-verdict 扩到 **23/23**。顺带结案 restore "mtime/ls 差异" = harness 参数映射漏行） | ✅ 2026-09-26 |
| 18 | **④ 重写最后一块：WebUI 探针层 → Rust**（新增 `fusionctl ui-probe launcher\|logs`：95 键逐键按契约 §1.4 实现并**与 JS 内联 shell 探针逐行差分对拍**（`test-diff-ui-probe.sh` **2/2**，launcher 37 键 + logs 77 键含 CFG_* 动态键与输出顺序）。JS 的解析/渲染/脱敏逻辑零改动（290 条 Node 断言全绿：webui 109 + logs 92 + apps 89）；C 类 exec 调用点换 fusionctl（手动抓取 nohup、指纹导入链 pif-fetch+pif-sync）；MNT_* 加 `AEGIS_MOUNTS_FILE` 接缝。**顺带把 socket 路径从"两边都失败"的假覆盖变成真覆盖**（桩 shebang `#!/system/bin/sh` 在 MSYS 不可执行 → 改 `#!/bin/sh`，补 rust socket_ack_state 的 sh 兜底） | ✅ 2026-09-26 |
| 15 | **④ 重写第十一块：`engine-check`(258) → Rust**（9 节只读诊断报告 + **mask_ids 四条 sed 规则的纯 Rust 复刻**（字节级，无 regex crate）；差分 `test-diff-engine-check.sh` **3/3 一致**（完整 stdout 逐字节比，pid/logcat/etime 全桩化零归一）。修：rule1 漏等号、ps 尾换行） | ✅ 2026-09-25 |

**差分测试累计：12 套 89 case —— 88 一致 + 1 个已登记的 shell 缺陷，0 处重写失败**（keybox-check 20 + engine-verdict 23 + fusion_func 5 + apps-sync 5+1 + pif-sync 6 + pif-fetch 9 + keybox-swap 6 + keybox-swap-watch 11 + service-env 2 + keybox-fetch 9 + engine-check 3 + uninstall 2）+ Rust 单元测试 8 项。
④ 管理层重写进度：**13/13 完成**。UI 采取「保留形态、换数据源」策略：HTML/CSS/JS 渲染层零改动（290 断言守护），两段内联 shell 探针与 C 类 exec 触发点全部换到 `fusionctl` 子命令，95 键经差分对拍。customize 保留 shell 是架构决策。
**遗留（装配期/真机阶段）**：① `module/<abi>/` 里把 keybox-check.sh / engine-verdict.sh 等做成 fusionctl 链接时，JS 与脚本里的 `sh <script>` 调用形式要核对（Rust spawn 已双形态兼容）；② 真机全场景点验（95 键在真机 getprop/uds 实环境下逐键核对）；③ CI 的 Android 交叉编译（cargo-ndk）。
**过程中挖出的 shell 线缺陷与桩缺陷**：shell 线 1 个（空 apps 数组 + uid pin ⇒ 非法 JSON，§7.1）；桩 5 个（缺失属性退出码 ×2 分支、list 只输出名字、list 分支未声明变量、同文件读写截断）。
另发现并记录了 4 条宿主测试夹具的 MSYS/Windows 陷阱（cygpath、.exe 扩展名、CRLF、同文件读写截断），见 `KNOWN-FAILURE-MODES.md` §6。

**抽契约过程中发现的现存缺陷**（新实现应一并修掉，不要原样继承）：
1. `DAEMON` 键在两个页面语义不同 —— `launcher.js` 用 admin socket `GET /status`，`logs.js` 用 `pidof`。同一个键两种含义。
2. `mask_ids` 的四份副本里，shell 那三份**把长度丢了**（替换成 `<redacted>`），而注释自己写着「Presence + length is all the diagnosis needs」；只有 JS 侧保留了 `<redacted:len=N>`。规格已定为采纳保留长度的形式。
3. shell 与 JS 的排除字符集不完全一致（JS 多排除 `]`）。

这份契约是**重写的输入**，也是**新 UI 与旧 UI 行为等价的验收依据**。

### 12.5 「全部重写」的边界，与「混合代码」的实际分配

用户重申：「对于全部的代码我们都可以重写，我们只取逻辑，然后重构所有，使用混合代码」。

**边界**（我的理解，需确认）：

| 对象 | 能否重写 | 说明 |
|---|---|---|
| 我们的管理层（4,151 行 shell） | ✅ 重写 | — |
| 我们的 UI（5,146 行） | ✅ 重写 | — |
| 我们的测试（~2,700 行） | ✅ 重写 | 但黑盒那 6 个可**复用**（见 §12.3），不必重写 |
| **7 个补丁** | ⚠️ 形式可选 | 它们是**"我们的引擎改动"这个逻辑的载体**，与实现语言无关。保留补丁文件 = 保留逻辑；改成自维护 fork（改动变成 commit）= 同一个逻辑换一种打包。**建议保留补丁** —— 改 fork 意味着要维护 35k 行引擎树 |
| **上游引擎（TeleSimulator，Kotlin 8,578 / C++ 18,395 / Rust 2,705）** | ❌ **不能** | 第三方代码，不是"我们的代码"；重写它等于重写整个 attestation 引擎，与「快速拿到可用的 Rust 化产物」相悖 |

**「混合代码」的实际落点**（避免为了混合而混合）：

| 层 | 语言 | 理由 |
|---|---|---|
| 管理层逻辑（判定 / 抓取 / 解析 / 落盘） | **Rust** | 纯逻辑、可本机 `cargo check`、有黑盒测试可复用 |
| UI | **JS / HTML / CSS** | WebView 里没有别的选择；「重写」指的是重新实现，不是换语言 |
| 引擎 | 保持上游的 **Kotlin / C++ / Rust** | 不碰 |
| 需要 native hook 时 | **C++**（仅当确实需要） | 目前看不到必要 |

⇒ 真正的「混合」是**跨语言协作**（Rust 二进制 ⇄ 引擎的 Kotlin daemon ⇄ JS 前端），而不是把管理层的每个部分刻意换成不同语言。

---

## 13. 难度评估：把 Fusion 重写成混合代码，难不难？

**一句话**：**不是研究型难题，是「工程量大 + 验证成本高」的活。** 没有任何需要发明算法的地方 —— 全都是「把已知行为用另一种语言精确地重新表达」。

### 13.1 按组件拆（难度**很不均匀**）

| 组件 | 行数 | 难度 | 说明 |
|---|---|---|---|
| `keybox-check.sh` | 264 | ★☆☆☆☆ | **纯函数**（文件进 → 退出码 + 文本出）。Rust 里**比 shell 里简单**：现在这版是用 awk 手写复刻 base64 crate 的 `InvalidByte(index, byte)` 语义，是全项目最脆弱的一处；Rust 里直接用 `base64` crate 就是本职 |
| `apps-sync.sh` / `pif-sync.sh` | 301 / 282 | ★★☆☆☆ | 文件搬运 + 少量 JSON/文本解析。Rust 的 serde 比 sed 强得多 |
| `engine-verdict.sh` | 389 | ★★☆☆☆ | 解析日志 + 落盘 `key=value` 状态文件，直接受益于 Rust 的正则与错误处理 |
| `fusion_func.sh` | 96 | ★★☆☆☆ | 已完整抽清（`CONTRACT-management.md` §1） |
| `customize.sh` | 427 | ★★★☆☆ | 安装期逻辑：20s 预算内的本机指纹抓取、keybox 校验、多版本清理 |
| `service.sh` | 492 | ★★★★☆ | **架构变化，不是翻译**：崩溃重生循环 + 每小时 tick + 启动时序，在 Rust 里是常驻进程 + 定时器 + 信号处理 |
| `keybox-fetch.sh` | **824** | ★★★★★ | **最难的一块**：四档下载阶梯（`curl`→`wget`→`busybox wget`→`curl --resolve` 直连 CDN IP）+ 代理三级来源 + 端口自动探测 + 引擎验收循环。难在**行为等价的复刻**（超时/重试/降级顺序/错误分类），不在实现 |
| UI（html + css + js） | 350 + 1,763 + 3,033 | ★★★☆☆ | 难在**量和静默失败**，不在算法（见 §13.3） |

### 13.2 让它**比看起来简单**的因素

1. **契约已抽清** —— 最大的降险项。4,151 行 shell 里真正难的不是「写 Rust」，而是「搞清 shell 到底在干什么」（隐式全局、`set -e` 语义、`case` 模式、字符串拼接的边界）。这部分已经变成三份 `CONTRACT-*.md`。
2. **6 个黑盒测试套件可复用**（~1,900 行）—— 现成回归网，且把网络/设备/时间全挡在外面。
3. **21 个 `AEGIS_*` 注入点** 让实现天然可测（保留它们即得该收益）。
4. **不用碰引擎** —— 35,000 行 Kotlin/C++/Rust 完全不动。
5. **有活的参照物** —— shell 线还在，随时可对照行为。

### 13.3 让它**比看起来难**的因素

1. ~~**本机不能链接**（最大摩擦）~~ → ✅ **已于 2026-09-21 解决**：装了 MinGW-w64 16.2.0 + Rust 的 GNU 宿主工具链，**`cargo test` / `cargo build` 本机可用**。
   本地调用：`export PATH="$HOME/.cargo/bin:<scoop-mingw-bin>:$PATH"` 然后 `cargo +stable-x86_64-pc-windows-gnu test`。
   ⇒ **本机可以「写完就跑测试」，不必每次走 CI。** 仍需 CI 的只有 Android 交叉编译与模块打包（缺 NDK + cargo-ndk）。
2. **UI 的静默失败面**：95 个探针键**少接一个不会报错**，只会让某个状态灯显示「未知」。所以**必须有等价性验收**（`CONTRACT-webui.md` §6）。
3. **网络阶梯的等价复刻**：`keybox-fetch.sh` 的降级顺序与代理探测是踩了实际事故才形成的（2026-09-13 受限网络下静默失效）。少一档降级 = 那类设备上自动刷新永久失效。
4. **`service.sh` 是架构差异**：shell 的 `while true; sleep 3600` 在 Rust 里是常驻进程 + 定时器，要认真设计而不是直译。
5. **`resetprop` 这类外部二进制**：建议**继续 shell out**，别为了「纯 Rust」去重新实现系统属性写入（要 root + 特定 syscall）。

### 13.4 据此得出的一个实施判断

**`keybox-fetch.sh` 单独占 824 行，且是全项目最难的一块。** 压缩风险的做法是：

> **它不是「最后一个被重写」的，而应该是「第一批被重写、但最后被切换」的** —— 先让 Rust 版与 shell 版**并存对拍**（同一份输入、同一台设备），确认行为一致再摘掉 shell 版。

其余脚本（`keybox-check` / `engine-verdict` / `fusion_func` / `apps-sync` / `pif-sync`）契约清晰、测试现成，可以放心一次切换。
