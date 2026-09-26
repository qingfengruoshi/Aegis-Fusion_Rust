# v1.0.0

首个融合版本。Initial fusion release.

- 融合 [KOWX712/PlayIntegrityFix](https://github.com/KOWX712/PlayIntegrityFix)（`inject_s` 分支）与 [JingMatrix/TEESimulator](https://github.com/JingMatrix/TEESimulator)（`dev` 分支）为一个模块：`integrityfusion`。
- 合并安装脚本（customize.sh / service.sh）：PIF 的属性伪装与 DenyList 处理 + TEESim 的控制守护进程，一次安装同时生效。
- TEESim 守护进程 dex 更名为 `teesim-service.dex`，避免与 PIF 的 Zygisk 载荷 `classes.dex` 冲突。
- WebUI 启动器：打开后可选进入 PIF（`webroot/pif/`）或 TEESimulator（`webroot/teesim/`）管理界面。
- 安装时自动禁用同机的独立版 `playintegrityfix` / `teesim` / `tricky_store`，防止重复挂钩；卸载融合模块后可自行重新启用。
- 迁移逻辑：自动继承独立 PIF 的自定义 `pif.prop`、TrickyStore 的 `keybox.xml`。
- 禁用了 TEESimulator 的内置 canary 自更新（避免把独立 `teesim` 模块刷回来造成双重挂钩）；更新请刷新的融合包。

# v1.1.0

- TEESim WebUI 简体中文汉化：新增 `patches/teesim/0002-zh-webui.patch`。
- 修复 CI 构建失败（`KeyAdmin.kt:380 Unresolved reference 'install'`）：0001 补丁删除了 `Updater.install()` 但 HTTP 路由仍在调用它。现 `POST /canary/install` 路由保留，改为返回 `{ok:false, error:"Self-update is disabled in the Integrity Fusion build..."}`，WebUI 里以中文 toast 提示"融合版已禁用自更新；请刷入新版融合包升级"。
- 汉化采用**外挂 i18n 层**而非改动散落在约 4600 行视图/控制器代码里的英文文案：新增 `js/ui/i18n.js` 字典（约 400 词条 + 30 余条动态正则规则），仅在 `dom.js` 的统一文本出口 `el()` 与 `toast()` 处挂钩翻译函数 `t()`。
- 上游更新时视图文件零冲突；字典未收录的词条自动回落英文，不会出现空白界面。
- 技术标识（包名 `com.example.app`、属性名 `verifiedBootState`、日志行、密钥算法名等）刻意保留原文，避免歧义。
- 启动器页脚文案同步汉化；版本升至 v1.1.0 (20260904)。
  - 实现方式：独立的 i18n 字典 `js/ui/i18n.js`（约 250 词条 + 40 条动态规则），在 `dom.js` 的全部文本出口（text 属性 / 字符串子节点 / title / placeholder / aria-label / toast）挂钩翻译，**不修改任何视图文件**。
  - 上游更新时视图文件零冲突；文案改名只会让该处回落英文，不会破坏渲染。
  - 刻意不翻译的内容：配置令牌（`patch`/`generation`/`system_property`）、keymaster 标签名、安全级别名（`Software`/`TrustedEnvironment`/`StrongBox`）、包名/别名/日志内容——翻译这些会破坏筛选匹配或造成误导。
- 静态部分（底部导航、健康胶囊）直接在 `index.html` 中翻译，`lang` 改为 `zh-CN`。
- 已验证：108 项翻译冒烟测试全过；补丁在固定 commit 上可依次与 0001 同时应用。

# v1.2.0

- 零配置：首次开机约 40 秒后自动运行 `autopif.sh` 获取 Pixel Canary 指纹并写入 `/data/adb/pif.prop`，失败下次开机重试。
- 启动器新增运行状态面板（指纹 / 守护进程 / keybox 三灯）+ 一键拉指纹 + keybox 引导。

# v1.3.0

- 融合 [MeowDump/Integrity-Box](https://github.com/MeowDump/Integrity-Box) 的 keybox 自动化：新增 `module/keybox-fetch.sh`（Megatron 混淆解码 + 有效性校验 + 滚动备份 + 写入 TEESim 路径 + 重启 keystore2 重注入），社区 keybox 默认 24h 自动续期，间隔可在 WebUI 调整（关 / 12h / 24h / 3 天 / 每周），用户自导入的 keybox 永不覆盖。

# v1.3.1 / v1.3.2

- 修复 WebUI 状态永不渲染（probe 大小写、KSU exec 桥同步/回调形态、Android 无 curl 导致 keybox 拉取失败、CSS 覆盖 hidden）、守护进程误报；新增 keybox 错误可视化与 Zygisk 检测；Keybox 刷新间隔改为胶囊按钮组。

# v2.0.0

架构重构：**移除 PlayIntegrityFix，融合 Integrity-Box 的环境隐藏层**。新的三合一组合——

- **TEE 证明伪装**（[JingMatrix/TEESimulator](https://github.com/JingMatrix/TEESimulator)，软件 KeyMint / keybox attestation）
- **BL / 环境隐藏**（来自 [MeowDump/Integrity-Box](https://github.com/MeowDump/Integrity-Box) 的 shell 层）：开机 `resetprop` 伪装 `ro.boot.vbmeta.device_state`、`verifiedbootstate`、`flash.locked`、`veritymode`、warranty、`release-keys`、`build.type=user`、OEM 锁定状态，隐藏 recovery bootmode 等。
- **Keybox 自动管理**：沿用 v1.3.x 的社区 keybox 自动获取与定时续期。

主要变化：

- 不再内置 PIF / Zygisk 载荷：**无需 Zygisk**（Magisk / KernelSU / APatch 均可裸跑），构建链去掉 PIF 的 NDK 29 / pnpm / Node 步骤。
- WebUI 完全重做：不再有"PIF / TEESim 两个入口卡片"，打开即是完成态——三灯状态（TEE 引擎 / Keybox / BL 隐藏）+ Keybox 刷新控制 + **受保护的应用**。
- **受保护的应用**：统一的单页应用选择器（应用名 + 图标 + 搜索 + 多用户支持，图标与列表来自 TEE 守护进程的 root-only socket）。勾选的应用写入 `config.json` 的 per-profile `apps`，由守护进程自动应用 TEE 证明伪装；BL / 属性隐藏对整机全局生效。
- 自带 `common_func.sh`、`META-INF`（标准 Magisk 安装器）与 `uninstall.sh`，不再依赖 PIF 产物提供这些文件。
- 安装时自动禁用同机独立的 `playintegrityfix`（含 Integrity-Box）/ `teesim` / `tricky_store`，并清理历史注入残留；继续收养 TrickyStore 的 keybox。
- 高级功能（证书检查、密钥管理、日志）保留在 WebUI 底部的"高级控制台"（TEESim 原版界面，已汉化）。

升级注意：从 v1.x 升级会自动清理旧 PIF 注入物；`/data/adb/pif.prop` 不再被读取，可自行删除。指纹伪装随 PIF 一并移除——若你的 ROM 需要 fingerprint 级伪装，请保留使用上游 PIF / Integrity-Box 而非本模块。

# v2.0.1

- 修复 CI：`scripts/test-webui.js` 内嵌了开发机的 Windows 绝对路径加载 `launcher.js`，Linux runner 上报 `MODULE_NOT_FOUND`。改为 `path.join(__dirname, ...)` 相对解析。
- keybox 刷新成功后回收 DroidGuard（`com.google.android.gms.unstable`）并 force-stop Play Store，新密钥材料免重启即被 Play Integrity 采信（借鉴社区参考项目，见 NOTICE）。
- service.sh 新增类原生 ROM 痕迹清理（借鉴社区参考项目）：`ro.product.vendor.name` 的 `lineage_` 前缀剥除、相机辅助包列表中 `org.lineageos.aperture` 移除——属性名携带 "lineage" 是 DroidGuard 可读的 ROM 指纹。
- 版本升至 v2.0.1 (20260906)。

# v2.1.0

## 修复：TEE 引擎误报"未运行"

- 守护进程存活检测不再依赖 `pgrep`（对 app_process nice-name 的匹配在不同 Android 版本上不可靠，会永久误报"未运行"）。改为与上游 TEESimulator 自己的 WebUI 相同的判定方式：通过 root-only admin socket 执行 `teesim-uds … GET /status`，通即是活。
- 状态灯新增**注入已生效**（读取 daemon 上报的 hook 库）与 daemon 构建版本显示；未运行时给出区分诊断：`进程存在但控制通道不通` / `引擎文件缺失` / `未运行`，便于定位是崩溃循环还是模块文件问题。

## 重做：受保护的应用独立页面

- 新增 `apps.html` 独立页面（主页卡片"管理应用"点入）：全部应用 + 勾选框，勾选即保存（原子写 `config.json`，其余字段原样保留，TEE 守护进程实时应用），支持搜索与应用图标。
- 右上角 **⋮ 设置菜单**（自动保存于 `/data/adb/teesim/`）：
  - **显示系统应用**：默认隐藏系统应用；
  - **自动添加新安装的应用**：开启后由模块后台每 5 分钟合并（`apps-sync.sh`，busybox awk 单配置安全合并——多 profile 配置自动跳过、写入前做完整性校验）。
- 主页简化为只读芯片展示 + 入口链接；选择器逻辑整体迁往 apps 页。

## 其他

- CI：新增 `apps.js` 语法检查与 `test-apps.js`（26 例）冒烟测试；launcher 测试更新为 19 例（覆盖 TEE 灯的四种状态）。
- assemble.sh 完整性检查加入 apps 页与 apps-sync.sh。
- 版本升至 v2.1.0 (20260906)。

# v2.2.1

## 严重修复：config.json 被污染导致 TEE 隐藏失效（c5a68dd 回归）

- **根因**：`apps-sync.sh`（自动添加新装应用）用 `pm list packages -3` 取列表。当 `pm` 在 stdout 打出错误横幅（如 `cmd: Failure calling service package: Broken pipe (32)`）时，脚本按**空白**拆分该行，把 `cmd:`、`Failure`、`calling`、`service`、`package:`、`Broken`、`pipe`、`(32)` 每个词都当成了包名合并进 config.json —— 高级控制台里的"无效的应用条目"正是这些词。守护进程的 profile 解析被垃圾条目干扰，TEE 证明伪装失效，Play Integrity 连带失败（看起来像 BL 也失效；BL 属性层本身未被 c5a68dd 改动）。
- **修复（三道闸）**：
  1. `apps-sync.sh`：pm 输出强制过正则校验（必须是点分字母数字包名），错误文本无法再进入合并；合并重建数组时同时**清除已有垃圾条目**（自愈）。
  2. apps 页读取 config.json 时忽略无效条目并提示"配置中有 N 个无效条目已被忽略，保存任意更改时自动清除"。
  3. pm 回退列表（daemon 不可达时）同样过正则，错误文本不可能再变成可勾选的行。

## 受保护应用保存策略改版（用户要求）

- 不再"打勾即保存"。勾选只修改**草稿**；右下角出现**悬浮保存按钮**（仅在草稿与已保存配置不一致时显示）；不点保存则配置不变。保存成功后按钮消失，计数行显示"有未保存的更改"提示。
- 附带收益：误触不再直接写配置文件。

## 图标

- 排查结论：调用格式与上游 TEESimulator 自身 WebUI 完全一致（`/icon?pkg=&user=` + `--b64`），端点无问题。改进：传输失败不再记负缓存（下次滚动/搜索自动重试，只负缓存 daemon 明确回答"无图标"的情况），并发 2→3，新增失败计数提示（页脚"N 个图标未能加载"）。c5a68dd 时期图标大面积失败的最可能原因是 config 污染期间 daemon 状态异常，清理配置后应恢复。

## 测试

- apps 页 42 例（新增：草稿/FAB 保存流、无效条目清理、pm 回退校验）；launcher 17 例。apps-sync 的 awk 净化+合并本机端到端验证通过。
- 版本升至 v2.2.1 (20260906)。

# v2.2.2

## 严重修复：daemon 图标渲染崩溃循环（v2.2.1 真机日志定位）

- **现象**：打开受保护应用管理页滚动时，TEESim daemon 反复崩溃重启（日志中 pid 4053→16659→18370→19237→20036→21396），TEE 隐藏间歇性失效；整个日志没有任何一条 `/icon` 请求成功返回。
- **根因**：daemon 是**裸 app_process**（不从 zygote fork、不走 ActivityThread 的 BIND_APPLICATION），libhwui 的原生默认字体 `gDefaultTypeface` 从未被初始化。绝大多数应用图标绘制不涉及文字，但个别应用（日志中稳定复现：抖音 yyds 变体 `com.ss.android.ugc.aweme.yyds`）的图标 Drawable 在 `draw()` 里调用了 `Canvas.drawText`，走到 AOSP `Typeface::resolveDefault` 的 `LOG_ALWAYS_FATAL_IF(src == nullptr && gDefaultTypeface == nullptr)` —— SIGABRT 直接杀掉整个 daemon。WebUI 重试图标 → daemon 重启后再请求 → 再崩，形成崩溃循环。
- **修复（daemon 侧，新增补丁 `0003-icon-typeface-warmup.patch`）**：`Packages.iconPng` 首次渲染前调用 `Typeface.loadPreinstalledSystemFontMap()`（AOSP 为非 zygote 进程预留的 hidden 初始化入口）预热系统字体表，一次性设置默认字体。调用失败（旧平台缺失/被拦）只记日志，行为与之前一致。
- **加固（WebUI 侧）**：图标传输失败按包名熔断——同一图标连续 2 次传输失败即本会话负缓存（保留字母头像），不再重试可能"一渲染就杀死 daemon"的图标；传输抖动仍允许一次重试。
- **其他（日志中顺带发现，暂不处理）**：`teesim_km` 一次 `CannotAttestIds "attestation ID mismatch for brand"`（cert.rs:566），来自上游 TA 对 brand 不匹配的证明请求的拒绝，与本次崩溃无关；RevocationList 拉取超时为离线所致。
- **测试**：apps 页 45 例（新增 3 例：断路器首次请求、一次重试、熔断后不再请求）；launcher 17 例全绿。
- 版本升至 v2.2.2 (20260907)。

# v2.2.3

## CI 修复：daemon 补丁的 hidden API 编译失败

- v2.2.2 的 0003 补丁直接调用 `Typeface.loadPreinstalledSystemFontMap()`，但该方法是 hidden API，不在编译 SDK 的 android.jar 里，CI 的 `compileReleaseKotlin` 报 `Unresolved reference`。改为反射调用（`Typeface::class.java.getMethod(...)`），旧平台缺失该方法时落入原有 try/catch 只记日志。补丁已对上游 5e59714 的真实源文件验证 dry-run + 应用成功。

## 新功能：受保护应用页"全选/取消全选"（用户要求）

- 页脚计数行新增文字按钮。作用域 = **当前正在显示的应用集合**：与列表使用同一条过滤链（搜索词 + "显示系统应用"开关，上限同渲染上限 500 行）。系统应用未显示时绝不会被全选扫入；搜索收窄后全选只作用于匹配行。
- 列表内所有可见应用均已选中时按钮自动变为"取消全选"，点击只从草稿中移除可见应用（不在显示范围内的已保存应用不受影响）。
- 遵循 v2.2.1 草稿模型：全选只改草稿，不写文件；悬浮保存按钮出现后才落盘，daemon 自动热更新。
- 测试：apps 页 55 例（新增 8 例：草稿-only 写入零次、系统应用隔离、搜索收窄作用域、按钮文案翻转、FAB 联动）；launcher 17 例全绿。
- 版本升至 v2.2.3 (20260908)。

# v2.2.4

## 新功能：apps-sync 自动清理已卸载应用的残留条目（用户报告驱动）

- 现象：TEES 作用域编辑器里出现 `com.google.android.apps.messaging 未安装` 等条目——作用域只存包名，应用卸载后条目永久残留（惰性、无实际效果，仅界面提示）。
- apps-sync.sh 新增反向清理：每轮同步同时拉取**全量**包列表（含系统应用，与 `-3` 列表分开校验），把 config 里存在但系统已无此包的条目移除。安全闸：①全量列表必须通过同样的包名正则校验，pm 失败横幅（如 `cmd: Failure ... (32)`）驱动不了任何删除；②带 `@user` 后缀的定向条目跳过（pm 报告的是 user 0，其他用户的包不在列表里是正常的）；③系统应用对照全量列表，不会被误判为已卸载；④仅单 profile 配置可编辑（沿用原约束）；⑤写盘前 JSON 完整性校验不变。
- 沙箱仿真验证：增/删/垃圾自愈三通道正确、幂等（无变化不写盘）、pm 全量列表失败时零删除。
- 回归：apps 55 + launcher 17 全绿。版本升至 v2.2.4 (20260909)。

# v2.2.5

## 重构：自动添加改用 TEES 原生 autoIncludeNewApps（用户提议）

- 上游本就有 per-profile 的 `autoIncludeNewApps` 字段（ConfigStore/Scope/Resolver 全链路支持）：daemon 在作用域解析时把**基线（known_packages.json，首次运行时种子）之后新安装**的应用 uid 折叠进作用域——跨所有 Android 用户生效、跳过特权 uid、绝不写脏 apps 数组、基线为空时故障安全（什么都不加）。
- 我们 apps-sync 的"添加已安装应用"通道与之功能重复且更差：只覆盖 user 0 的 -3 包、首次开启会把设备上全部第三方应用扫进列表、还往 apps 数组写条目（正是"未安装"残留的来源）。**退役**。
- WebUI 开关"自动添加新安装的应用"改名"自动纳入新安装的应用"，直接写 config.json 的 `autoIncludeNewApps`（沿用单 profile 约束；若其他 profile 已开启则拒绝并提示——上游不允许两个 profile 同时开启，否则拒绝加载配置）。守护进程 watch 配置，切换立即生效。
- apps-sync.sh 转型为"作用域清洁工"：①一次性迁移旧 flag 文件（apps-auto-add=1 → 写入 autoIncludeNewApps=true 后删除）；②清理通道常态化（每 5 分钟）：清除无效条目（v2.2.0 污染自愈）+ 已卸载应用条目，全量包列表硬校验、pm 失败零删除、@user 条目仅在格式非法时清理、多 profile 跳过。
- 沙箱仿真 5 场景全过：迁移、幂等、pm 失败零删除、多 profile 跳过、flag=0 不误写。测试 apps 61（+6：开关写原生字段/翻转/守卫拒绝）+ launcher 17 全绿。
- 版本升至 v2.2.5 (20260910)。

# v2.2.6

## 严重修复：Keybox"立即刷新"冻结整个 WebUI（真机报告）

- **现象**：点击 keybox 卡片的"立即刷新"后整个 WebUI 卡死无法点击；退出重进白屏，只有把管理器划卡重启才恢复。
- **根因**：30 秒以上的 keybox-fetch.sh（网络下载 + keystore2 重启 + DroidGuard 重杀）此前**跑在 exec 桥上**——桥 5 秒即放弃且 1.5 秒兜底重发同一命令，长脚本堆叠出重复 root shell；在单参数 exec 为同步实现的机制上（如 KSU）直接冻死 WebUI 主线程。
- **修复（双保险）**：①launcher.js 改为"发射后不管"——`nohup … </dev/null >/dev/null 2>&1 &` 把脚本脱管进后台 shell（exec 瞬间返回），按钮只做 3 秒一轮的锁文件快速轮询，3 分钟后停止轮询显示"后台仍在刷新"；②keybox-fetch.sh 自带 `mkdir` 原子锁（陈旧锁 15 分钟自动回收），WebUI 按钮/cron/开机三条触发路径天然互斥，重叠获取在锁外直接跳过。
- **测试**：webui 新增 9 例（后台发射、锁轮询、跟随已有刷新、不二次发射、KBRUN 渲染），26+61 全绿。

## 更名：Integrity Fusion → **Aegis Fusion**

- 新名称寓意"神盾融合"——模块 ID 保持 `integrityfusion` 不变，直接刷入新版即可无缝升级（KSU/Magisk 按 ID 识别）。
- module.prop：显示名改为 `Aegis Fusion (TEE + BL)`，作者署名 qingfengruoshi；WebUI 两页标题与主页大标题同步更新；README 全面重写。
- README 新增"上游更新指南"（versions.env 换锁 + GitHub 网页操作 + 补丁冲突处理）与"Fork 即自维护"章节：本仓库是配方而非成品，Fork 后跑同一套 CI，可自由锁定上游 commit、增删补丁、上游跑路也不影响构建。

- 版本升至 v2.2.6 (20260911)。

# v2.2.7

## apps 页对齐 TEESimulator 作用域页交互

- 筛选芯片（全部/系统/已选）取代 ⋮ 菜单里的"显示系统应用"开关；旧 show-system flag 文件继续作为"系统"芯片的持久化（同一文件同一含义，不新增状态源），"已选"为会话级不落盘。
- 孤儿芯片：已保存但已卸载的条目在列表上方单独呈现、一键移除；pm 降级列表只认识 user 0 裸包名，**不标记无法核验的 @user 条目**（避免把正常的工作配置条目误报成已卸载）。
- 已勾选的行置顶，组内按名称 A→Z 排序（对齐 TEES 作用域页的 inScope-first 行为）。
- 批量行：全选/反选/清除，作用于当前可见集合（取代 v2.2.3 页脚"全选"按钮）；依旧只改草稿，悬浮保存按钮落盘。
- 搜索 140ms 防抖、回车立即渲染（与 TEES 作用域页一致）。
- 测试：apps 页 61 → 75 例，launcher 26 例全绿。版本升至 v2.2.7 (20260912)。

# v2.2.8

## 修复：设备 ID 证明缺失导致 PIAC 仅 BASIC（真机对照实验驱动，根因修正）

- **对照实验**：同一把 keybox（逐字节同链：叶/中间/根序列号完全一致——Megatron、Yurikey、Integrity-Box action 分发的是同一把社区 key），在 Integrity-Box + TEESimulator-RS 组合下 PIAC 三绿/两绿，在本模块下仅一绿——**排除 keybox 吊销因素，锁定引擎配置差异**。
- **根因**：上游 TA 在应用请求带设备 ID 字段（ATTESTATION_ID_BRAND/MODEL/IMEI…）的证明密钥时，用 profile 预置的 brand/device/model/serial/imei 等与请求比对；默认配置这些字段全空 → `CANNOT_ATTEST_IDS: attestation ID mismatch for brand`（诊断日志可证）→ GMS 拿不到 ID 证明 → Play Integrity 仅 BASIC。RS 引擎自动采集设备 ID 回填，故"简单配置即可三绿"。
- **修复**：customize.sh 安装/升级时用本机真实属性回填全部 ID 字段（ro.product.* 与 serial；IMEI 尽力而为：厂商属性 → iphonesubinfo，取不到留空），只回填空字段（不覆盖用户自定义），幂等，sed 特殊字符转义；沙箱验证字段正确、二次运行无破坏、JSON 始终有效。
- **勘误**：此前"社区三绿为失真数据 / keybox 已被 Google 吊销"的判断**有误**——社区状态与该 keybox 实际相符；"部分应用 TEE 隐藏失效"的报错（CANNOT_ATTEST_IDS）同样是本根因的表现，非上游引擎缺陷。
- **渠道现状说明**：Megatron / Yurikey / Integrity-Box action 当前分发同一把社区 keybox——源头同 key 时"换渠道"无差别；渠道轮换的价值在于各家**轮换新 key 的时间点不同**。

## 复审修复批次（代码复查驱动）

- **批量操作与渲染的 500 条截断口径统一**：渲染是"先排序后截断"（`renderList`），批量全选/反选/清除此前却是"先截断（未排序）"（`visibleEntries`）——可见行数超过 500 时（"系统"芯片下的大 ROM 很容易）两者集合不一致，扫过的行和看到的行对不上。现抽出 `sortedVisible()` 供两处共用，都走同一"排序 → 截 500"序列，"可见集合即作用域"在超长列表上依然成立。
- **孤儿芯片省略号修复**：`.ap-orphan` 此前没有 max-width，inline-flex 芯片按 max-content 撑开，内部 `text-overflow: ellipsis` 永远不触发，长包名会横向溢出卡片；现 `max-width: calc(100% - 6px)` 约束芯片宽度，省略号生效。
- **apps-sync 旧标志迁移不再覆盖显式值**：迁移条件从"config 里没有 `autoIncludeNewApps: true`"改为"没有该字段"（任意显式值都视为权威）。此前 WebUI 把开关拨到关会显式写入 `false`，而迁移只 grep `true`，会在标志文件仍存在时把 `true` 重新插回去——产生重复 JSON 键并静默还原用户的"关"。
- **小优化**：重复点击已激活的筛选芯片不再全量重渲染/重写标志文件；加载期间不再闪现"无法读取应用列表"假错误（首次渲染推迟到初始化完成，loadSettings 只高亮芯片）；"已选"芯片的空态文案区分"还没有勾选"与"搜索无匹配"；清理死代码（`renderList` 的未用参数、从未消费的 `launchable` 字段）。
- 测试：apps 页 75 → 82 例（新增：超 500 条渲染/扫选一致性、重复点击芯片零写入、"已选"+搜索空态文案），launcher 26 例全绿。版本升至 v2.2.8 (20260913)。

## 新功能：统一日志与诊断页（logs.html）

- **三处既有日志一个窗口**：Keybox 获取（`keybox-fetch.log`）、作用域同步（`apps-sync.log`）、守护进程内存日志（admin socket `GET /logs`，按 level 分级着色）；芯片切换 + 手动刷新，沿用 apps 页的芯片/卡片设计语言，无新依赖、离线不变。
- **一键诊断导出**：模块/引擎版本、设备与管理器、daemon `/status`（注入是否上报）、keybox 元数据（仅 sha256 前缀 + 社区/自导入来源）、受保护应用**数量**、BL 属性当前值、三处日志尾部 → `/sdcard/Download/aegis-diagnostics-<时间>.txt`，直接发给开发者即可。
- **硬性脱敏（测试断言兜底）**：keybox 内容、`admin.token`、config 中的包名永不入包；日志尾部原样包含（可能含包名），生成文件与页面均注明"分享前请自查"。
- 主页页脚新增"日志与诊断"入口；高级控制台标签去掉"日志"字样（统一页已覆盖日常查看）。
- **作者署名明确化**：module.prop author 改为 `qingfengruoshi (Aegis Fusion) · JingMatrix (TEESimulator) · MeowDump (Integrity-Box & keybox channel)`。
- 测试：新增 `test-logs.js` 40 例（三源渲染/切换/刷新 + 导出内容 + 四条脱敏断言 + 失败路径 + 守护进程缓冲超长回退），82 + 40 + 26 全绿；`assemble.sh` 增加日志页产物校验。

## 修复：Keybox 状态灯语义 + 多渠道自动轮换（真机报告驱动）

- **现象**：WebUI 显示"Google 源有效 🟢🟢🟢"，但 Play Integrity API Checker 仅 BASIC 通过——状态灯言过其实。
- **根因**：状态灯读的是 MeowDump 社区的 key-status 文件，它描述的是**渠道最新 keybox** 的社区报告，而非 Google 对本机已部署 keybox 的实时判定（Google 不提供查询接口）；且本机可能是刷新失败的旧 keybox，也可能是用户自导入的 keybox——社区状态与其完全无关。
- **语义修复**：文案改为"社区源报告有效 / 社区源已吊销 / 社区源状态未知"；用户导入的 keybox 显示"用户导入 · 社区源状态仅供参考"；状态文件只与实际供给本 keybox 的渠道**配对**（不再拿 A 渠道的状态描述 B 渠道的 keybox）；提示语写明实际判定以 SPIC / PI Checker 为准、检测应用需在受保护列表。
- **多渠道自动轮换**（渠道表来自 [Tricky Addon Enhanced](https://github.com/Enginex0/tricky-addon-enhanced) / [TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS) 生态，逐渠道验证）：Megatron（MeowDump，主，唯一带社区状态文件）→ Yurikey（base64 一次）→ KOWX712 镜像（hex→base64；上游在两轮轮换之间清空该文件，自动跳过）。支持 `/data/adb/teesim/keybox-sources.conf` 自定义渠道（`name|url|format|status_url`，format = b64 / hexb64 / megatron / raw），用户渠道优先于内置。
- **渠道选择 UI**：Keybox 卡片新增"获取渠道"芯片行（自动 / Megatron / Yurikey / KOWX712），点选写入 `keybox-source-pref`，抓取时把该渠道排到最前；失败仍自动回退其余渠道（过期的偏好永远不会断供）。选择在下次刷新生效，"自动"清除偏好。
- **来源可溯**：实际生效的渠道记入 `.keybox-source` 并显示在状态灯与诊断导出中；用户导入检测提前到任何网络请求之前。
- **排障指引**（本机"全绿但不通过"的三种常见原因）：检测应用不在受保护列表、DroidGuard 缓存旧证书链（刷新 keybox 后脚本已自动回收，必要时重启）、社区状态文件滞后于 Google 的吊销。统一日志页的 keybox-fetch.log 可直接核对上次刷新的渠道与哈希。
- 测试：webui 更新断言 + 新增用户导入 / 无状态渠道 / 渠道芯片读写用例。

## 修复：受保护应用误报「已卸载」（小米换机案例，真机报告）

- **现象**：v2.2.8-a57f4d0 上已安装的小米换机（com.miui.huanji）在受保护应用页被标记"已卸载"；而 apps-sync 的清理日志证明全量包列表认得它（并未被清理）。
- **根因**：两处判定用了不同视野——清理以全量 `pm list packages` 为准，而 WebUI 的孤儿判定只信守护进程 `/packages` 的枚举，其视野更窄（会漏掉非启动/被隐藏的应用），单源缺失即误报。
- **修复**：WebUI 孤儿判定改为**双源交叉**——守护进程列表缺失的条目再对照全量 pm 列表，还认账就不判"已卸载"（裸条目与 @user 条目同样保护，宁可漏报不误报）；只有两个来源都缺失才标记。清理脚本本就以全量列表为准，无需改动。
- 测试：apps 82 → 85 例（守护进程缺失但 pm 已装 → 不标记；真缺失 → 照旧标记）。

## 修复：真机反馈批次（v2.2.8-4dcd02f 报告）

- **证书有效期显示"—"**：探测脚本用 sed 行区间提取证书，对部分 PEM 布局会漏内容导致解析失败；改为整行展平后按 `<Certificate>` 标签对提取（已用真实渠道 keybox 数据比对验证）。
- **用户导入 keybox 时"立即刷新"不再假装可用**：按钮禁用并显示"已让路"，提示文案同步说明恢复方法（删除 keybox.xml 即恢复自动管理）；"社区状态"行对用户导入不再显示绿格——那是渠道最新 keybox 的报告，与本机导入的无关，避免误导。
- **获取渠道改为同款胶囊 + 下拉气泡**：与刷新时间选择器一致的交互（此前误留平铺芯片）。

## 安全加固（安全审计驱动）

- **admin token 不再进入 WebView / exec 桥命令行**：apps / logs 页对守护进程的全部调用改为 shell 侧 `$(cat admin.token)` 运行时读取——token 只出现在短命 root helper 进程的 argv 里（上游 helper CLI 的固有限制，socket 目录 0700 使其对外不可利用），不再出现在 WebView 内存、桥命令行或任何桥日志中。
- **自定义渠道支持 sha256 锚定**：`keybox-sources.conf` 第 5 字段可填期望的 sha256，载荷哈希不符时在部署前整渠道拒绝（大小写与空白自动归一；沙箱验证正确/错误/归一化/无锚定四场景）。
- **本地证书有效期判定（对齐 Integrity-Box 的红绿灯思路）**：从部署的 keybox.xml 提取 X.509 证书有效期（DER 内 ASCII 日期字段，无需 openssl），折叠面板显示剩余天数并按剩余 ≤30 天/≤14 天/已过期分级着色；**证书过期时无视社区报告强制红灯**——这是不依赖任何第三方状态文件的本地判定。
- **红绿灯固定三格**：🟢 数量 + 🔴 补满——2 绿显示 🟢🟢🔴、1 绿显示 🟢🔴🔴，等级一眼可读；新增 1 绿 = "严重受限 · 仅 BASIC 级"档位。
- **第二轮安全审计**：对多渠道抓取/折叠栏/token 改造后的全部新增代码复扫——无危险 DOM/执行模式、无新增网络出口（仍为文档化的 5 个）、注入面核查通过（偏好文件经清洗后仅用于 awk 字面量匹配、渠道 URL 全程引号传递、sha256 锚定为字面比较、token 的 `"$(cat …)"` 包裹使引号/空格无法拆分参数）。
- **Keybox 卡片重构（界面评审定稿）**：状态灯只保留"绿格数 + 判定"短文案，且为**三格制**（🟢 数量 + 🔴 补满，2 绿显示 🟢🟢🔴 一眼可读；1 绿新增"严重受限 · 仅 BASIC 级"档位）；"Keybox 自动刷新"并入"Keybox"单折叠面板——收起时右侧常显"现用渠道 · 间隔"，展开 = 详情行（当前渠道/上次刷新/证书有效期/上次错误）+ 获取渠道（胶囊下拉）+ 刷新间隔（左标注右时间下拉气泡，off / 12h / 24h / 3d / 1w）+ 手动获取（通栏主按钮）。社区状态不设详情行（与状态灯三格重复）。窄屏（320px）与系统字体放大下均无截断。
- **"手动获取"（keybox-fetch.sh --force）**：按当前渠道强制抓取一次——首次安装的人手动拉一次，之后按刷新间隔自动续期；也是"用户导入 keybox 已被吊销"的恢复路径（绕过让路保护强制接管，原文件保留在滚动备份，接管后写入标记转为自动管理；渠道内容与已部署一致时仅补标记）。
- **证书有效期显示"—"修复**：探测脚本用 sed 行区间提取证书，对部分 PEM 布局会漏内容导致解析失败；改为整行展平后按 `<Certificate>` 标签对提取（已用真实渠道 keybox 数据比对验证）。
- **社区状态不再误导用户导入**：渠道绿格只描述渠道最新 keybox，与本机导入的无关——用户导入时状态灯仅显示"用户导入"，不渲染绿格；"立即刷新"更名"手动获取"并始终可用（配合 --force 即恢复路径）。
- 测试：82 + 40 + 58 全绿（webui 新增折叠栏/气泡/三格/有效期/用户导入/渠道选择器断言；apps/logs 的 token mock 顺序随 shell 侧读取调整）。

# v2.2.9

- **本机吊销实测（本版核心）**：WebUI 之前只转发社区渠道的绿格报告——那描述的是"渠道最新 keybox"，滞后于 Google 实际吊销（实测案例：界面 🟢🟢🟢、PIAC 只过 BASIC），且对用户导入的 keybox 完全无判断。现在 keybox-fetch.sh 每小时缓存 Google 官方证书吊销状态列表（`android.googleapis.com/attestation/status`，1 小时 TTL，随 `--revcheck` 新参数与 service.sh 滴答运行，即使自动刷新已关闭也保持更新）；WebUI 打开时本地提取**本机部署 keybox 链上全部证书**的 serial（纯 JS 极简 DER 解析，Android 无 openssl 也能跑）并在缓存列表中比对：
  - 命中 REVOKED → 状态灯红灯"**本机实测：已被 Google 吊销 · 请手动获取或换渠道**"（优先级最高，覆盖社区绿格，用户导入的 keybox 同样生效）；
  - 命中 SUSPENDED → 黄灯"本机实测：已被 Google 暂停"；
  - 未命中 → 状态灯追加"**本机实测未吊销**"（自动管理与用户导入都显示）；
  - 缓存缺失/解析失败 → 静默降级为原有社区状态显示，绝不显示假结论。
  - WebUI 本体保持零联网：唯一网络请求是 fetch 脚本的缓存刷新，离线契约不破坏。
- 顺带澄清社区绿格语义（不变）：绿格 = 渠道方对渠道最新 keybox 的报告；"本机实测" = Google 官方列表对本机这份 keybox 的判定。两者同时展示。
- 测试：webui 57→66（吊销命中/未命中/用户导入/自动管理/无缓存降级/长格式 DER 编码 fixture），apps 85、logs 40 不变，全绿。
- **换箱立即生效（本版第二个关键修复）**：上游 TA 把 keybox 字节嵌在 daemon 的 config 推送帧里、keystore2 侧的 TA 每次推送构建一次后常驻复用——**没有文件监听、没有 reload 命令**，只换 keybox.xml 磁盘文件时 TA 仍用旧箱作答；若 profile 构建失败则请求被静默转发真硬件（解锁 BL 的真硬件证明 = PIAC 只剩 BASIC 一绿）。实测抓到此路径：自动刷新换箱后只重启 keystore2、daemon 从未重读；`--force` 遇相同 hash 甚至连 keystore2 都不重启。现在抽出 `bounce_tees()`（kill teesim → service.sh 2 秒内拉起并重读 config+keybox 重新注入推送 → keystore2 → DroidGuard → Play Store），真正换箱与 `--force` 相同 hash 两条路径都会触发；WebUI 提示同步更新（手动导入后需重启设备或点一次"手动获取"才生效）。

# v2.2.10

- **指纹伪装层协同（pif-sync，本版核心）**：参照一个社区参考项目（见 NOTICE）的架构结论补齐另一半。Play Integrity 的 DEVICE/STRONG 判定由两个独立层决定——①硬件证明链（TEES 用 keybox 重签，本模块的核心）；②DroidGuard 看到的设备指纹（只有 PIF 类模块能作答，该参考项目即 TEESimulator-RS + PlayIntegrityFork 的合体，其无指纹伪装的 Lite 版与本模块单独使用时表现一致）。两层身份不一致时（PIF 声称 Pixel、证明链携带本机真实 brand/model），谷歌交叉校验失败、verdict 被压到 BASIC——这正是"keybox 干净、引擎正常、却始终一绿"的最终解释。新增 `pif-sync.sh`：
  - 开机（daemon 读配置前）与每小时滴答运行，定位活跃的 PIF 类配置（`/data/adb/pif.json` 标准路径 + playintegrityfix / playintegrityfork / Integrity-Box / tricky_store 等模块本地路径），把 BRAND/DEVICE/PRODUCT/MANUFACTURER/MODEL/SECURITY_PATCH 镜像进 TEE profile 的显式 ID 字段与 patchLevel.system（TEES 原生支持，机制同参考项目的 security-patch sync）；
  - 身份变化才动作：变更后重启 teesim daemon 重推配置（v2.2.9 语义），值相同则完全静默；
  - 指纹层移除后自动回滚为本机真实属性（避免证明链声称无人背书的 Pixel 身份），非 PIF 字段（imei/serial 等）与 apps 列表永不触碰；
  - 完整幂等：日志、marker、回滚均可在宿主机测试（新增 `scripts/test-pif-sync.sh`，19 例，含模块本地路径发现/回滚/幂等）。
- **WebUI 新增"指纹伪装层"状态行**：检测 PIF 类配置的存在并显示来源；未检测到时黄灯明示"DEVICE/STRONG 还需 PIF / Integrity-Box 指纹层"——把"为什么三绿变一绿"直接画进界面，不再让用户对着干净的社区绿格困惑。keybox 提示文案同步解释两半架构。
- **DroidGuard 自动回收（安装即用收口）**：DroidGuard（`gms.unstable`）的作答会话会跨变更残留——换 keybox、指纹重同步、刷模块后，旧会话继续用旧的设备画像作答，直到进程被回收。此前最后一步"杀 GMS"需要手动，违背安装即用宗旨，现在模块全自动：①开机约 3 分钟后（daemon 与首轮 keybox 通道稳定后）回收一次；②每 12 小时例行回收（社区参考项目同款语义），防止长命会话漂移；③keybox 部署与 pif-sync 身份变更时随 bounce 顺带回收（回收动作对用户不可见，进程按需自愈重启）。时间戳记于 `.gms-recycle` 备查。用户流程收敛为：装上 → 重启 → 直接测。
- **状态显示简化（用户反馈驱动）**：状态列表改为"安静除非有错"——①Keybox 行：自动获取/手动获取只显示绿格（🟢🟢🟢 / 🟢🟢🔴…），用户导入只显示"用户导入"，不再挂"社区源报告有效/本机实测未吊销"等尾巴（此前"三绿"被误解为设备成绩——它实为渠道方对其渠道箱子的报告）；本机吊销检测仍在后台运行，仅在被 Google 吊销/暂停时插红黄警告；②BL 隐藏行：只显示"已生效 / 部分生效 / 暂无数据"，去掉属性细节；③删除"证书有效期"行——shell 侧提取在真机上从未成功过（无 openssl、DER grep 太脆），永远显示"—"，属死功能，连坐删除 PROBE 的 KBEXP 采集；④Keybox 长提示压缩一半。
- **修复状态行长文本被截断**：真机反馈"指纹伪装层"行显示成"…还需 PI…"——flex 子项缺 `min-width: 0` 导致溢出发生在行容器上，setState 的 scrollWidth 换行检测永远不触发。补上收缩约束并在检测中同时检查行容器；现在放不下的长提示（如"未检测到 · DEVICE/STRONG 还需 PIF / Integrity-Box 指纹层"）会换行完整显示。
- 测试：webui 66→68、apps 85、logs 40、pif-sync 19（新增），全绿。

# v3.0.0

- **指纹伪装层并入模块（真·单模块，本版核心）**：v2.2.10 的结论是 DEVICE/STRONG 需要两个半层——硬件证明链（TEES）+ GMS 进程内指纹（只有 Zygisk 能做到，物理边界无法绕过），彼时需另刷一个指纹模块。本版把指纹半直接吸收进来，"一个模块做多个事"的宗旨真正落地：捆绑开源指纹伪装组件 Play Integrity Fork（osm0sis & chiteroman，GPL-3.0 与本模块同许可，以官方 release zip + SHA256 校验和 pin 定供应链，详见 NOTICE）：
  - CI 在拉取 TEESimulator 的同时下载 pin 定的指纹组件 release zip（校验和不符即失败），`assemble.sh` 把 `zygisk/`、`classes.dex`、autopif4/killpi/migrate 脚本并包——TEES daemon dex 早已更名 `teesim-service.dex`，与指纹组件的 `classes.dex` 天然无冲突；我们的 `common_func.sh` 更名 `fusion_func.sh`，根名让给指纹组件的原样引用；其 `service.sh` 转为 `pif-service.sh` 由融合 service.sh source，`post-fs-data.sh` 整体收编；
  - **指纹全自动（pif-fetch.sh）**：开机 + 每小时滴答运行，首次无指纹时自动调用组件自带的 autopif4 `--strong` 预设生成随机最新 Pixel Canary 指纹（strong 预设 = 关闭 keystore provider 伪装、正好匹配硬件证明栈），生成后立即触发 pif-sync 同步身份；约 6 周过期、14 天自动轮换；用户自放的 `custom.pif.prop/.json`（模块目录内）永远优先、绝不触碰；失败静默重试；
  - **pif-sync 升级**：指纹源优先探测本模块目录的 custom.pif.prop/json，并新增 prop 方言解析（v18 默认产出 prop 格式，含 `*.security_patch` 通配键），独立 PIF 类模块路径继续兼容；
  - **安装脚本**：检测 Zygisk 环境（Magisk 开关或 Zygisk Next/ReZygisk/NeoZygisk），无 Zygisk 只黄字警告不阻断（TEE 半仍工作，verdict 上限 BASIC）；从独立 PIF 迁移时先采纳用户的 custom.pif 配置再禁用旧模块；安装提示更新；
  - autopif4 生态本就识别 `/data/adb/teesim`（TEESimulator v4.x 提示手动对齐 patch level）——我们的 pif-sync 正是那个"手动"的自动化。
- **WebUI 状态行跟进**："指纹伪装层"从"未检测到 · 还需另装"改为内置语义——裸绿格"内置 · 自动指纹 / 内置 · 用户指纹 / 外部指纹模块"（安静除非有错），缺失时黄灯"指纹未生成 · 重启后自动获取（需网络）"，Zygisk 缺失时黄灯明示后果；PROBE 新增内置指纹路径族与 Zygisk 环境探测。
- **升级为四合一**：TEE 证明伪装 + 设备指纹伪装 + BL/环境隐藏 + keybox 自动管理，模块名改为 Aegis Fusion (TEE + 指纹 + BL)。v2.x"不带 PIF 载荷"的组装断言反转为"必须带"。
- 测试：webui 68（新增内置指纹四态断言）、apps 85、logs 40、pif-sync 19、pif-fetch 22（新增：生成/幂等/轮换/用户指纹保护/失败重试/缺生成器），全绿；本地以真实 release zip 端到端验证 assemble 合并产物。

# v3.0.1

- **GMS 自动入域（本版核心修复，一绿元凶）**：Play Integrity 的 DEVICE verdict 由 DroidGuard 在 GMS 进程内产出——它向 keystore2 请求硬件 attestation 并上报 Google。若 GMS 不在 TEE 作用域内，DroidGuard 拿到的是**真机的证明**（BL 解锁、无认证链），verdict 永远卡在 BASIC——keybox 再干净也没用。这正是"Integrity-Box + TEES 三绿、融合模块一绿"的差异根源：IB 自动把 GMS 纳入目标作用域，而融合模块一直依赖用户自己去 apps 页勾选。现 `apps-sync.sh` 在每次开机后的一次性流程里自动把 `com.google.android.gms` 写入作用域（`.gms-scope-seeded` 标记防重复，用户手动移除后不会被加回；删标记可重新播种）。仅单 profile 配置可被自动编辑，多 profile 照旧跳过。
- `apps-sync.sh` 单/多 profile 判定从**按行计数**改为**按出现次数**——紧凑单行 JSON 的双 profile 配置不再被误判为单 profile 而遭误编辑。
- 测试：新增 `scripts/test-apps-sync.sh`（18 例：播种/幂等/一次性/未安装/多 profile 守卫/无配置静默/清理通路共存），全量 258 例绿。

# v3.0.2

- **Debug 模式（默认开启，WebUI 可关）**：排障不再靠猜。新增统一详细日志 `/data/adb/teesim/debug.log`——`.debug` 标记文件存在时（刷入即默认开启），所有脚本把每一步决策写进去，每行带来源标签：`[kbfetch]`（下载尝试次数/字节数/退出码、哈希对比、锁获取、吊销缓存刷新、bounce 各进程 pid）、`[piffetch]`（用户指纹跳过、保鲜判断、autopif4 调用与退出码）、`[pifsync]`（指纹源定位、身份变更/无需变更判定、daemon/DroidGuard 回收）、`[appssync]`（profile 判定、GMS 播种决策、清理决策）、`[service]`（开机启动、每小时滴答参数、12h DroidGuard 回收）。标记文件每次调用时检查，开关即点即生效，无需重启。
- **日志页新增 Debug 标签与开关**：`debug.log` 作为第四个日志来源；Debug 卡片一键开/关（写入 `touch`/`rm -f` 即完成），开关动作本身也记入 debug.log，日志断档可自解释。
- **诊断导出跟进**：新增 Debug 模式状态行与 `debug.log` 尾部（最后 150 行）——远程排障一份诊断文件即可看全决策链。
- 测试：apps-sync 21（+3 debug 行为）、logs 55（+9 debug 标签/开关/诊断断言），全量 270 例绿。

# v3.0.3

- **导入即生效（修复"导入后没变成用户导入/点手动获取反被覆盖"）**：诊断日志还原了事故链——用户把另一台机器的 keybox.xml 放进 `/data/adb/teesim/` 后，界面仍显示"社区自动管理"（判定只看 `.auto-keybox` 标记，手动替换文件不会清标记）；按旧提示"点一次手动获取生效"操作后，`--force` 反而从渠道重新抓取并接管，导入被覆盖（13:18 导入 → 13:20 被渠道箱顶掉，日志全程可见）。三处修复：①导入检测新增 **mtime 启发式**——keybox.xml 比标记文件新 = 被用户在抓取器之外替换过，即使与渠道箱 hash 相同也判为用户导入（同一套社区密钥的文件 hash 完全一致，纯 hash 比对对此失明）；②导入确认后**自动 bounce 一次 daemon**（`.imported-bounced` 按 hash 去重，每小时滴答不会反复重启），导入即生效、无需重启、更不需要"手动获取"；③导入态点"手动获取"先弹确认对话框明示接管后果；提示文案删掉误导性的"点一次手动获取"。
- **"上次刷新"不再停在旧时间**：之前该值取 keybox.xml 的 mtime，hash 未变的刷新（大多数手动获取都是同箱）不重写文件 → 界面永远显示旧年龄。抓取器现在每次成功通过（updated/unchanged/adopted）都写 `.kb-last-fetch` 时间戳，WebUI 优先读它（无此文件时回退文件 mtime，导入箱不受影响）。
- **诊断导出补 `pif-fetch.last`**：指纹生成失败时 autopif4 的原始报错此前不在诊断文件里（00:08 那次 generation failed 无法远程归因），现在随诊断导出。
- **debug 增强**：指纹自动标记写入失败可见化（部分 KSU 挂载下模块目录只读会导致指纹永不轮换，之前静默）；导入守卫的 mtime/hash 双通道判定全程留痕。
- 测试：webui 71（+3：导入态手动获取警告/拒绝不动手/确认后正常抓取），全量 273 例绿。

# v3.0.4

- **修复"轮换失败 = 指纹清零"（2026-09-08 实机事故回归）**：旧轮换逻辑在生成新指纹**之前**就删掉旧指纹和 `.pif-auto` 标记——2026-09-08 00:07 轮换触发后 wget 被墙（`Connection reset by peer`），设备从"有一个能用的指纹"直接变成"一个指纹都没有"，之后无论换什么 keybox PIAC 都只有 BASIC（真机诊断逐行还原）。现改为**生成成功才替换**：autopif4 只在全部网络请求成功后才落盘 `custom.pif.prop`，失败时旧指纹与标记原样保留，设备始终带着可用身份等下一次滴答重试；轮换只在新指纹落盘后才清理不同名的旧文件（如 `pif.json` → `custom.pif.prop`）。生成成功判定收紧为 `rc==0 且文件非空`——文件存在不再等于生成成功（旧幸存者会伪装成新产出）。
- 测试：pif-fetch 30（+8：轮换失败保留旧指纹/标记存活/失败日志可见、轮换成功替换异名旧文件并重启时钟），全量 281 例绿。

# v3.0.5

- **WebUI 指纹导入（参考 AlwaysStrong 的 WebUI Advanced 思路，补齐网络受限环境的救命通道）**：主页新增"指纹伪装层"折叠详情栏——显示指纹来源路径 + "导入指纹文件"按钮。联网拉取失败（国内直连 developer.android.com 被重置）时，从任何一台三绿机器导出 `pif.json` / `custom.pif.prop`，在界面里选文件即可：JS 侧读取并 base64 过 exec 桥写盘（无引号转义问题），按扩展名分方言落盘（.json → custom.pif.json，否则 custom.pif.prop），清除 `.pif-auto` 标记（自动轮换永久让路），随后立即跑 pif-sync 同步身份并回收 DroidGuard——导入即生效、无需重启。内容含身份字段校验（BRAND/FINGERPRINT 等，兼容 prop 与 JSON 方言），选错文件不会写盘。
- **冲突禁用补全**：`customize.sh` 的双挂钩禁用列表补上独立 `Integrity-Box` id（v28 之前的手动安装形态）——该形态 hook 所有应用进程，是"微信掉登录"类报告的元凶。
- 测试：webui 80（+9：详情栏 root 解锁/来源回显/JSON 与 prop 双方言落盘/标记清理/立即同步/错误文件拒写），FileReader mock 就位，全量 290 例绿。

# v3.0.6

- **指纹正本持久化（修复"刷入/更新模块后指纹消失 → TEE 身份回滚真机"）**：2026-09-08 实机诊断还原——14:32 指纹还确认在位（fresh, nothing to do），14:34 重启（刚刷入过模块包）后 pif-sync 报"no fingerprint source found"，把 TEE profile 回滚成真机身份。根因：模块更新会**整体替换模块目录**，运行期生成的 `custom.pif.prop` 与 `.pif-auto` 不在包内即被清掉（同机 keybox 在 `/data/adb/teesim/` 两次重启间纹丝不动，形成对照）。现指纹的**正本**移入 `/data/adb/teesim/pif-master/`（与 keybox 同域，模块更新不可达）：pif-fetch 在每次启动/滴答开头先做找回（模块目录被重置 → 从正本恢复工作副本与所有权标记，PIFork 读的工作副本仍在模块目录不动）；生成成功/用户导入/保鲜确认三个节点都镜像到正本（用户指纹镜像时清除正本自动标记，所有权语义原样保留）。service.sh 开机顺序改为 pif-fetch 先于 pif-sync（找回必须发生在身份同步之前，否则同步会把真机身份写回 profile）。WebUI 指纹导入命令同步接上镜像步。
- 测试：pif-fetch 38（+8：生成镜像到正本/用户指纹镜像且清自动标记/重刷后从正本找回含标记、找回时零生成），全量 298 例绿。

# v3.0.7

- **`.pif-off` 总开关（对照实验开关，"一键回到原版等价态"）**：对照实验确立——同一设备、同一 keybox，独立版 TEESimulator 可过 DEVICE，融合版仅 BASIC。据此把融合栈与独立版的差异面收敛为两处：PIFork 对 GMS 的 Build 伪装（canary 指纹）+ pif-sync 写入 TEE profile 的身份与 `patchLevel.system`（源码推导：Play Integrity 密钥请求不带 ID attestation，两版最终 attestation 的唯一实质差异就是 os_patchlevel；VBK/VBH 由 daemon 内 Harvester 同源产出，两版相同）。新增 `/data/adb/teesim/.pif-off` 标记文件：pif-fetch 挂起生成/轮换/找回；pif-sync 抑制同步并把已同步的身份**连同** `patchLevel.system` 一起还原为真机值（与 PIF 移除的回滚不同，后者保留 system 补丁级不动）——即完整复现独立版通过 DEVICE 的状态。配合把模块目录 `zygisk/` 改名停用 PIFork 载荷，即得到与独立版完全等价的运行态，PIAC 结果可一锤定音定位毒源。实验后删除 `.pif-off` 并把 `zygisk.bak` 改回即恢复融合态。
- 测试：pif-fetch 42（+4：开关下零生成/零找回/零同步/挂起有日志），pif-sync 24（+3：已同步时全量还原含 system 补丁级、vendor 不动、未同步时配置零扰动），全量 307 例绿。

# v3.0.8

- **`.pif-sync-off` 拆分开关（嫌疑 A/B 区分实验）**：`.pif-off` 只能把 PIF 半层整体关掉，过了也无法区分"canary 指纹被 DroidGuard 识别（嫌疑 A）"还是"os_patchlevel canary 日期被服务端拒（嫌疑 B）"。新增 `/data/adb/teesim/.pif-sync-off`：仅抑制 pif-sync 的 TEE 半层同步（profile 保持不动，pif-fetch 与 PIFork 照常运行）。三态实验矩阵：①基线（全开）=已知 BASIC；②`.pif-off`+zygisk 改名=纯 TEES 等价态；③`.pif-sync-off`（先跑过②让 profile 已还原真机值）=GMS 被 canary 伪装而 attestation 携带真机补丁级。②过③过→嫌疑 B（补丁级同步是毒），②过③不过→嫌疑 A（canary 伪装本身被识别），②不过→融合栈另有未发现差异。
- 测试：pif-sync 27（+3：开关下 profile 零扰动、无标记创建、抑制有日志），全量 310 例绿。

# v3.0.9

- **诊断盲区补全（②③实验全一绿后的分析刚需）**：2026-09-08 19:43 诊断显示②③实验开关均正确生效（真机还原/同步抑制都有日志），但②"纯 TEES 等价态"仍一绿——与"原版通过 DEVICE"的对照结论矛盾。现有诊断缺四块关键信息，本次补上：①`config.json` 摘要（mode/osVersion/patchLevel 三级/五项身份字段）；②真机补丁级（ro.build/ro.vendor security_patch，与 profile 对照即判同步差异——attestation 补丁级只取年月，canary 2026-08-05 与真机 2026-08-xx 编码后相同，嫌疑 B 可能从未成立）；③实验开关状态（.pif-off/.pif-sync-off）；④daemon 日志尾部 100→400 行（覆盖开机 Harvest complete 的 bootKey=VBK 行）。测试模拟器同步扩展（探针含 config.json 路径后需先于 cat 规则匹配）。
- 测试：logs 58（+3：开关状态/profile 摘要/真机补丁级），全量 313 例绿。

# v3.0.10

- **`bootkey.bin` 强制 VBK 通道（引擎补丁 0004，"Tricky 兼容对照实验"杠杆）**：决定性对照实验反转了结论——同一台设备、同一份 keybox，Integrity-Box（TrickyStore 系）三绿、本融合栈一绿，**毒源不在 keybox 而在两个引擎的 attestation 产出差异**。TrickyStore 1.0.2 开源版（2024-07，该家族最后公开代码）给出已验证可过的模板：`verifiedBootKey = 32 随机字节`（源码注释原文 "TODO: get verified boot keys"，即随机值照样过 DEVICE）、RootOfTrust={随机 VBK, locked=true, Verified, 原 leaf VBH}、叶子公钥替换为 keybox 公钥、其余 KeyDescription 全部保留真 TEE 字节、补丁级不改。本栈与之仅存的实质差异：VBK 取 Harvester 收割值（K70 真机值或 `sha256("TEESimulator/verified_boot_key")` 共享常量——后者若被大量用户共用即成可黑名单指纹）。新增引擎补丁：`/data/adb/teesim/bootkey.bin`（恰好 32 非零字节）存在时**优先于一切**（含 TEE 成功捕获）作为 verifiedBootKey，日志行 `boot key: forced from bootkey.bin` 可验证生效；文件不存在时行为与上游完全一致（零风险默认）。写入一次后保持稳定（VBK 兼作 KEK 派生输入，跨重启不变）。实验：MT 管理器/终端 `head -c 32 /dev/urandom > /data/adb/teesim/bootkey.bin` → 重启 → 测 PIAC。
- 对照实验记录（2026-09-08 晚）：TEES 渠道池 keybox 一绿；Integrity-Box 零配置三绿；Integrity-Box + K70 同款 keybox 三绿；独立 PIFork 无改观。据此排除 keybox 池降级与指纹层，收敛至引擎 attestation 差异。

# v3.0.11

- **`/proc/cmdline` 伪装杠杆（实验开关 `.cmdline-spoof`）**：BL 隐藏差分实验指出信号通道缺口——resetprop 改写属性区，但 `/proc/cmdline` 是内核启动时组装的 procfs 文件，`androidboot.verifiedbootstate=orange`、`androidboot.vbmeta.device_state=unlocked` 等真值始终原样暴露，属性层修复碰不到它；PIFork 只伪装指纹字段也不覆盖；独立版 TEES 一绿与独立版 TEES+IB 三绿的差异（IB 的 Zygisk 进程级 hook）最可能就补在这类通道上。新增 opt-in 开关：`/data/adb/teesim/.cmdline-spoof` 存在时，service.sh 用 sed 仅改写 BL 态条目（verifiedbootstate→green、vbmeta.device_state→locked、flash.locked→1、veritymode→enforcing、warranty_bit→0，其余启动参数保持真值）生成 `cmdline.spoofed` 并 `mount -o bind` 盖到 `/proc/cmdline`；幂等（mountinfo 查重），失败可见（debug.log 记录）。默认不开启，无标记时行为与上游完全一致。验证：debug.log 出现 `cmdline: /proc/cmdline masked via bind mount` 即生效。

# v3.0.12

- **vendor 补丁级同步（Box-Brain 实锤的"融合不完整"真 bug）**：Integrity-Box 的 Box-Brain 日志包（2026-09-08 23:03 采集）给出两条决定性信息：①`keybox.log` 显示其 GitHub keybox 拉取**失败**、`remove.log` 显示 `/data/adb/tricky_store/keybox.xml` 不存在——"TEES+IB=三绿"时 attestation 100% 来自 TEES（引擎彻底洗清）；②`prop_patch.log` 显示 IB 把**系统与 vendor 补丁级都**改写为 2026-09-05——而 K70 真机 vendor 补丁为 **2026-02-01**，比系统（2026-08-01）旧半年。据此锁定被所有前轮实验漏掉的矛盾：自称 Pixel 的身份报出小米的 vendor 补丁日期——DroidGuard 可据此拒绝 DEVICE。本栈 pif-sync 此前**只同步 `patchLevel.system`**（os_patchlevel），attestation 的 vendor_patchlevel 保持真机值；PIFork 的 `*.security_patch` glob 会把 GMS 侧 vendor 报告伪装成指纹日期——结果 attestation(202602) 与 DroidGuard 报告(202608) 互相矛盾。修复：pif-sync 将 `patchLevel.vendor`/`patchLevel.boot` 与 system 一并同步为指纹的 SECURITY_PATCH（同一日期，全链一致）；`.pif-off` 还原路径对称恢复 vendor/boot 真机值。该修复统一解释全部实验矩阵：独立 TEES 一绿（真机身份非认证指纹）／TEES+PIFork 一绿（vendor 补丁矛盾）／TEES+IB 三绿（IB 双补丁齐改+内置指纹）／IB 单独一绿（无有效 attestation）。ps -A 问题：无终端不影响——调试探针已内置，诊断导出即可。
- 测试：pif-sync 29（+2：vendor/boot 与指纹日期同步断言），全量 315 例绿。

# v3.0.13

- **身份同步撤回（CannotAttestIds 实锤：身份同步是毒，且从来不可能生效）**：2026-09-09 00:00 诊断（v3.0.12 刷入后仍一绿）的 daemon 日志暴露全新硬错误——测试窗口（23:56–23:58）内 GMS（uid 10250）的 `DeviceGenerateKey` 连续十余次失败：`Hal(CannotAttestIds, "attestation ID mismatch for brand")`，TA error -66。keystore2 请求参数解码：ATTESTATION_ID_BRAND=Redmi、DEVICE/PRODUCT=vermeer、MANUFACTURER=Xiaomi、MODEL=23113RKC6C、SERIAL/IMEI 为真机值——keystore2 是原生守护进程，Zygisk（PIFork/IB 的进程级 hook）对它不可见，它收集的永远是真机身份。读 AOSP system/keymint（pinned cfeefc94）`ta/src/cert.rs`：①ID 请求先经 `check_match` 与 profile 配置的身份比对，不一致即 CannotAttestIds 拒绝——我们同步的 Pixel 身份（google/rango）对上 keystore2 收集的真机 Redmi 身份，门禁必挂；②门禁通过后证书编码的是 `requested_ids`（**keystore2 请求来的真机 ID**），profile 配置值从不出现在证书里——**同步 Pixel 身份从来不可能让 attestation 变 Pixel，唯一效果就是弄挂整个硬件证明请求**。GMS 拿不到 attestation 密钥，DEVICE 无从谈起。这同时闭环全部实验矩阵：原版 TEES 收割真机身份做 profile → 门禁通过 → 证书带真机 ID → 配 IB 三绿；本栈一同步身份反而劣于原版。修复：pif-sync 撤回五项身份字段同步（brand/device/product/manufacturer/model），**只保留补丁级同步**（v3.0.12 的 vendor/boot 对齐仍然成立且必要）；sync 路径幂等执行 `restore_real` 自动把旧版本写入的 Pixel 身份还原回真机值（下轮 tick 即迁移，无需手动干预）；PIF 移除与 `.pif-off` 的回滚路径不变。诊断导出同步更新：Profile 身份行标注"应为真机值"，出现 Pixel 值即提示为旧版残留待自动还原。
- 测试：pif-sync 33（case2 改为身份不被同步断言 +case9 旧版 Pixel 身份自动迁移），logs 58（身份行文案），全量 319 例绿。

# v3.0.14

- **persist.sys 伪装残留清理（本地检测器 5 hits 的修复）**：本地取证检测器（`__system_property_get` 原生探针）报出 5 个 `persist.sys.spoof/pixelprops.*` 红项——源头是 PIFork 上游 service 脚本的 ROM 钩子中和逻辑：检测到 PropImitationHooks/PixelPropsUtils 类 ROM 时写入 `persist.sys.pixelprops.*=false` 等开关，**且以 `-p` 持久化**。一旦写入：①开关永久驻留 `/data/property/persistent_properties`，重刷/卸载都清不掉；②开关的存在让自己的触发条件永远为真（自锁循环，每次开机重写）；③`persist.sys.spoof.gms` 这类命名是任何原生 App 可读的伪装标记。修复：把"真钩子 ROM"（AOSPA/PixelOS/Afterlife 构建标记、LeafOS `gms_certified_props.json`、或 ROM 写入的非空 `pihooks` 值）与纯残留区分开——真钩子 ROM 走原上游中和逻辑一字不动；非钩子 ROM（MIUI/A HyperOS 等）则把整族 12 个属性连同持久化记录一起删除（`--delete` 清内存副本 + `-p --delete` 清持久化文件），首次运行后重启归零、此后零开销。路径加 `AEGIS_GMS_JSON` 测试覆盖口。注：检测器自己说得很清楚——"没有残留不等于原生状态"；这项清理消灭的是**可消除**的暴露，内核版本、注入痕迹等共性项任何伪装栈都在所难免。
- 测试：新增 scripts/test-service-props.sh 冒烟测试 8 例（残留清理/幂等无扰动/LeafOS json 钩子 ROM 中和/ROM 非空 pihooks 值判定）并接入 CI；全量 327 例绿。

# v3.0.15

- **product 还原修复（v3.0.13 迁移的第二处残留，CannotAttestIds 从 brand 转移到 product 的根因）**：诊断 20260909-131632（v3.0.14 刷入后仍一绿）显示 ID 门禁错误已从 `attestation ID mismatch for brand` 变为 `mismatch for product`——v3.0.13 的真机身份还原对 brand/device/manufacturer/model 全部生效，唯独 product 残留 Pixel 值（rango_beta）。根因：`restore_real` 用的属性名 `ro.product.product` 在 Android 上**不存在**（keystore2 的 ATTESTATION_ID_PRODUCT 读的是 `ro.product.name`），getprop 返回空 → set_id 空值跳过 → 旧版同步的 Pixel product 原样留在门禁上。修复：product 改读 `ro.product.name`，异常情况下回退 `ro.build.product`；cert.rs `check_match` 语义核对过（配置缺席=跳过、配了且不等=报错），填真机值即与 keystore2 请求恒等。这是 v3.0.13 实锤"身份只能用真机值"后的最后一处迁移残留，修复后 TEE profile 身份 = 原版 TEES 收割态（已验证能过门禁的形态）。
- 测试：pif-sync 35（case9 补 product 迁移断言、props mock 改用真实存在的 ro.product.name + 新增 case10 ro.build.product 兜底）。

# v3.0.16

- **补丁级同步撤回（pif-sync 停止改写 profile 的任何补丁级；profile 归还给采集值/用户配置）**：IB 大脑日志（2026-09-09 Box-Brain）证伪了 v3.0.12 的"跨层补丁级矛盾"理论——IB 开机把全局属性 resetprop 成 2026-09-05，而原版 TEES profile 保持采集值（os=2026-08、vendor/boot=2026-02-01），TEES+IB 照样三绿：**Google 不做跨层补丁级日期校验**。已验证能过的 profile 状态 = 采集态（真机身份 + 采集补丁级），任何同步偏差都是零收益风险；且同步会在每次开机/小时 tick 覆盖用户在管理器 App 里手动配置的值（诊断 20260909-201705 实证：17:49/20:10 两次开机的 "identity changed" churn）。修复：pif-sync 的 PIF 在场路径只保留真机身份门禁（restore_real 幂等迁移旧版残留），不再写 patchLevel 的任何字段；`.pif-off` 回滚路径保留（旧版同步过的补丁级仍还原为真机属性值）。用户在 TEES 管理器里的配置（mode/patchLevel/osVersion，含 system_property 选项）从此开机不再被改。推荐配置 = 三项补丁级选 system_property（恒等于真机/采集值）或直接填采集值。
- 测试：pif-sync 35（case2/case4 翻转为"补丁级不被改写"断言、case9 更名），全量 329 绿。

# v3.0.17

- **IB v42 源码级启动链分析收尾（teesim.sh 补齐）+ 安装器 product 同族 bug 修复**：从 GitHub Releases 拿到 v42 发布 zip（git 仓库不含 teesim.sh），确认：①teesim.sh 只在 Action 按钮/WebUI/远程 emergency 时执行（开机不执行），且前置要求 custom.pif.prop + tricky_store/security_patch.txt + target.txt 全部存在；②其写入：身份五项 ← PIF 指纹值、mode → "generation"、patchLevel.system → "system_property"、vendor/boot ← security_patch.txt 的 all= 值（2026-09-05）、osVersion → "17"、apps ← target.txt 全量包名；③在用户"安装→重启→零操作"的三绿实验里 teesim.sh 从未运行，config.json 保持 TEESim 收割态——与融合版 v3.0.15/16 的状态一致，**config.json 层面两栈已等价，嫌疑二排除**；④融合版剩余差异收敛为：IB 开机全局 resetprop 补丁级（TEESim daemon 若晚于其启动，收割值即为统一新日期）、service.d/hash.sh 的 vbmeta digest 清理、IB PIF 引擎细节（Shadow Hook/strong/advanced 标志/指纹源）。⑤顺手修复安装器 customize.sh 的 fill_id product 同族 bug（ro.product.product 不存在 → 改读 ro.product.name，与 bed83f5 同根因；此前被 pif-sync 的 restore_real 开机回填掩盖）。完整分析：build/IB-v42-callchain-analysis.md。

# v3.1.0

- **Round 12：同步方向反转 + AS 实证配方移植（对位实验三绿后的集成层大修）**。AlwaysStrong-TEESIM（同款 JingMatrix TEES 引擎 + PIFork 单模块）在调试机 K70 实测三绿，本栈一绿的根因收敛为集成层缺陷。本期六项修复全部来自对其运行时 config.json（57 apps + uid 钉子 + patchLevel 对象）与桥接脚本（attest/teesim.sh、lite_pif_sync.sh、sync_patch.sh）的逐行对照：
  1. **pif-sync 方向反转**：PIF 在场时 profile **跟随 PIF 伪装身份**（brand/device/product/manufacturer/model 镜像进 config.json，字段缺失时从 FINGERPRINT 分量回退），废除 v3.0.13–v3.0.17 的 restore_real 主路径（降级为 PIF 移除/.pif-off 的回滚路径）。依据：AS 三绿配置的 profile 即 Pixel 身份；单一真机 profile 与 DroidGuard 的伪装 Build 视图错位，DEVICE 判定必挂。
  2. **patchLevel 对象形态修复**：TEES ConfigStore 以 optJSONObject 读取 patchLevel，字符串形态会静默解析为空。pif-sync 现保证 patchLevel 恒为对象，system 跟随 PIF 的 SECURITY_PATCH（非日期值退化为 today）；vendor/boot 保持 "YYYY-MM-05" 模板（与 AS 桥接一致，TEES 自行解析）。
  3. **PIF 开关断言**：Round 7 实证 custom.pif.prop 全部开关为 0（哑化实验残留，DroidGuard 运行时检测必挂）。pif-sync 每次运行对自有载荷断言 spoofBuild=1 / spoofProps=1 / spoofVendingFinger=1 / spoofProvider=0；$TEE_DIR/spoof.conf 可逐键覆盖（AS spoof.conf 语义）。
  4. **uid:N 钉子**：apps-sync 新增 PI 核心三件套钉扎——GMS/Vending/GSF 除包名外，以 packages.list 解析的原始 uid（uid:10250/10138/10217）写入 apps 数组，防多用户/开机时序下包名匹配落空导致 generateKey 回落真 HAL；清理阶段永不剪除 uid: 条目；.uid-pins-off 可停用。
  5. **检测器应用默认排除**：ID 认证类应用（KeyAttestation/IntegrityCheck/NativeTest 等 6 个）默认移出 scope——不进 scope 即走真 TEE 出真机身份，天然规避 profile（伪装身份）与请求（真机身份）错位导致的 -66，KeyAttestation 恢复出证。.keep-detectors 可保留。这是比 AS（其 scope 内 KeyAttestation 实测 -66）更进一步的两全设计。
  6. **补丁级对齐前移**：align_patch_level 移入 fusion_func.sh，新增 post-fs-data.sh 在开机最早期对齐（AS sync_patch.sh boot 同位），service 阶段与每小时 tick 的调用保留。
- 测试：pif-sync 48（方向反转断言重写 + case11 字符串 patchLevel 重写 + case12/13 开关断言与幂等），apps-sync 35（+14：uid 钉扎/幂等/停用/检测器排除与退出），service-props 8，全量 91 例绿。
- 遗留观察点：AS 环境下 GMS 请求未被 -66 拒绝而 KeyAttestation 被拒的内部分流机制（uid 钉子触发请求改写为头号嫌疑）待源码级确认；Round 12 刷机验证为本期最终裁决。

# v3.1.1

- **修复“指纹半边从未生效”的集成缺陷（PIF 路径未重定向）**。PlayIntegrityFork v18 的 Zygisk 载荷把配置路径**硬编码**为 `/data/adb/modules/playintegrityfix/`（custom.pif.prop / custom.pif.json / pif.prop / pif.json / classes.dex 五处）。融合版模块 id 是 `integrityfusion`，该目录从不存在，于是载荷永远读不到指纹配置：pif-fetch 写下的 custom.pif.prop 无人读取，DroidGuard 始终面对真实设备 → PI 恒定停在 BASIC（一绿），与 TEE 半边状态无关。AlwaysStrong 的“PIF 路径二进制补丁”即为此事。
  - assemble.sh 新增 `patch_pif_paths()`：等长替换 34 字节前缀 `.../playintegrityfix/` → `.../integrityfusion//`（双斜杠在 Linux 下等价解析），二进制布局不变；并在 sanity check 中断言“不再含 playintegrityfix 且含 integrityfusion//”，缺失即打包失败。
- **修复陈旧开关静默解除武装（.pif-sync-off 语义变更）**。旧语义为整脚本退出，配合上一版 Round 12 的改动，导致数据目录里遗留的 `.pif-sync-off`（Round 6 实验产物，刷模块不会清除）把整套新逻辑全部架空——日志实证：`[pifsync] TEE sync suppressed via .pif-sync-off — profile left untouched`，于是 PIF 开关健康检查一次也没跑过。现语义：该开关**只抑制 profile 镜像**，载荷开关健康检查（spoofBuild/spoofProps/spoofVendingFinger=1、spoofProvider=0）无条件执行，并记录明确日志。
- 测试：pif-sync 52 例（case8 重写为「镜像被抑制但开关仍被纠正」）。

# v3.1.2

- **修复两处“错误信号”自检缺陷（它们把两天的排查带进了沟里）**。此前所有诊断导出的引擎结论都建立在两个错误探针上，导致现场数据自相矛盾：
  1. **守护进程存活探针永远为假**：`pgrep -f org.matrix.teesim` 从不匹配——app_process 会把自己的 argv[0] 改写成短名，`/proc/<pid>/cmdline` 里只有 `teesim`，Java 类名根本不存在。**v3.1.0/v3.1.1 导出的诊断一直写着 `DAEMON=stopped`**，而守护进程其实活得好好的。改用 `pidof teesim`（logs.js 探针 + engine-check.sh）。
  2. **`PIFMAP=0` 是假警报**：PlayIntegrityFork 通过 `memfd_create` 装载 dex，模块路径**永远不会**出现在 GMS 的 maps 里，指纹半层正常工作时该值同样是 0。此前把它当作“指纹载荷未注入”的证据，属于误判。现标注为“仅供参考”，并改为在判定段明确说明。
- **引擎判定改读持久日志（关键能力补齐）**。此前判定依赖 logcat，而 logcat 在开机后几分钟内就会把开机决策轨迹轮转掉——恰好是“配置到底有没有送达拦截器”唯一可回答的时间窗。引擎其实自带持久轨迹：LogTail（进程内 native logd 读取器）把**所有** `TEESimulator` 标签行（daemon + TA + 两个 native 拦截器）写入 `/data/adb/teesim/log/teesim.log` 及轮转分片，崩溃/重启后仍在。engine-check.sh 与 WebUI 诊断导出现在优先读它，logcat 仅作回退。
- **engine-check.sh 重写**（9 段式）：守护进程（pidof）/ 注入 / 控制 socket / config 与 **config 实际引用的每个 keybox**（存在性 + 是否为 Keybox XML）/ 持久引擎轨迹计数（pushes / acks / staged / build-failed / never-pushed / target=0|1）/ **守护进程 admin `/status` 与 `/logs` 实时查询**（经 `teesim-uds`，免依赖 logcat）/ daemon.log 崩溃栈 / logcat 回退 / 单行裁决。裁决把 `never pushed a config` 细分为三种归因：**推送成功但 lib 拒绝全部 profile → keybox 不可用**、**推送成功但从未 ack → 控制通道断裂**、**从未推送且无报错 → daemon 启动后期静默崩溃**。
- WebUI 诊断导出同步升级：新增“持久引擎日志”段落（最后 300 行），判定段改为基于推送/ack/staged/构建失败四项计数的归因式输出，并附最后几条 ack 行（`applied=` / `failed=`）。
- 关键提示（写给下一个排查者）：`cfg: staged profile` 出现 = 配置真的进了拦截器；`failed to build` 出现 = keybox 被引擎判为不可用，**引擎会整条丢掉该 profile**，其外部表现与“daemon 从未推送”完全一致——这是最容易误判的一对。

## v3.1.2 追加：keybox 结构校验（现场实锤后的对症修复）

**现场实锤（2026-09-11 持久日志）**——一绿的根因不是"daemon 没推送"，而是 **keybox 被引擎判定不可用**：

```
09-11 12:40:21 I TEESimulator: control: pushed config (epoch=15)
09-11 12:40:21 E TEESimulator: keymint: profile default failed to build (bad keybox?)
09-11 12:40:21 I TEESimulator: control: ack epoch=... ok=true applied=0 failed=1
09-11 12:44:41 E TEESimulator: still no profile after waiting; the daemon never pushed a config
```

`applied=0 failed=1` → `g_profiles` 恒空 → 之后每一次请求都是 `target=0` → 全部转发真机 HAL → 恒定一绿。而 09-10 12:39/12:54/12:56 的三次推送都是 `applied=1 failed=0`（**能用的 keybox**）；分界点正是 09-10 23:45 —— `keybox.xml` 被替换成指向 `/data/adb/tricky_store/keybox.xml` 的**符号链接**。

**两个结构性缺陷**：

1. **模块的 keybox 校验太弱**。`keybox-fetch.sh` 的 `valid_keybox()` 只有 `grep -q "<Keybox" && grep -q "PrivateKey"`。而 TA 侧（`rust/teesim-km/src/attest.rs` 的 `CertSignInfo::new` → `parse_algo`）实际要求：①至少一个 `<Key algorithm="rsa">` 或 `"ecdsa">`；②该 Key 的链**至少 2 张证书**（`expected at least 2 certificates`）；③`<PrivateKey>` / `<Certificate>` 体非空且能 base64 解码。**一个只有单证书链、或 `<Key>` 缺 `algorithm` 属性、或被截断/仍是混淆态的 keybox，能通过那两个 grep，却让引擎丢掉全部 profile。**
2. **符号链接 keybox.xml 永远无法被自愈**。`customize.sh` 用 `[ ! -f /data/adb/teesim/keybox.xml ]` 判断"是否已存在 keybox"——`-f` **跟随符号链接**，所以只要目标文件在，收养逻辑就永远跳过，重刷也修不好；而且链接目标可以在引擎背后被换掉。

**修复**：

- 新增 `module/keybox-check.sh`：结构校验器，规则与 `attest.rs` 逐条对应（同一个评估顺序），失败原因文案对齐 Rust 原文便于检索；`rc=0` 可用 / `1` 不可用 / `2` 缺失。**四个合成样本（正常 / 单证书链 / 无 algorithm / HTML 页面）已验证判定正确**。
- `keybox-fetch.sh`：`valid_keybox()` 改为调用共享校验器（校验不过即换下一个源，宁缺毋滥）。
- `customize.sh`：**符号链接先落地成真实文件**（目标不存在则删除死链）；收养后**强制校验**，不合格则 ui_print 明确原因、移出到 `keybox.rejected.<ts>.xml`（保留字节）并清掉 `.auto-keybox`，让定时抓取补一个能用的。
- `service.sh`：开机在 daemon 读配置**之前**校验。符号链接就地落地为真实文件（引擎绝不透过链接读）；不合格则写 `keybox-bad.log` + `.keybox-bad` 标记并在 debug.log 告警——**刻意不动用户文件**（安装器可以移走，因为那时模块确实没法工作；开机不该动用户数据）。
- `engine-check.sh`：第 4 段用同一校验器逐个校验 config 实际引用的 keybox，并显示符号链接指向与 `.keybox-bad` 标记。
- WebUI 诊断导出新增两行最高信号字段：`KBCHK`（ok / bad / 未检测）与 `KBLINK`（keybox.xml 是否为符号链接及指向），并在 `运行状态` 段直接给出结论文案。

### v3.1.2 追加：`keybox-swap.sh` —— 把"换 keybox 看引擎怎么说"做成一条命令

判定一个 keybox 能否被引擎使用，**唯一的权威是 keystore2 里的 TA**，而它只用两行日志回答。所以正确做法是把候选交给引擎、读它的回答——这个来回约一秒，**不需要重启、不需要刷机**。原理：daemon 对 `/data/adb/teesim` 注册了 FileObserver（`CLOSE_WRITE|MOVED_TO|DELETE`，路径为 `config.json` 或以 `.xml` 结尾即触发），替换 `keybox.xml` 本身就是触发信号。注意必须"同目录 `cp` 到临时名 + `mv` 覆盖"：这样是一次原子 rename（MOVED_TO），且**替换掉符号链接本身**；直接 `cp` 到符号链接上会写穿链接、改掉它指向的文件（例如 TrickyStore 自己的 keybox）。

```
keybox-swap.sh <candidate.xml>     校验 → 备份 → 原子部署 → 等引擎回答
keybox-swap.sh <candidate.xml> -f  校验不通过也部署（直接听引擎怎么说）
keybox-swap.sh --watch [secs]      什么都不改，只看下一次 push/ack
keybox-swap.sh --restore           把最新备份放回去
keybox-swap.sh --list              列出备份
```

- 退出码即结论：`0` 引擎接受 / `1` 拒绝或部分拒绝 / `2` 静默（超时未见 push-ack）。
- 判定**解析 ack 计数**而不是匹配单行：`applied=0` 全拒、`applied>0 failed>0` 部分、`applied>0 failed=0` 通过——多 profile 场景下"部分生效"也能被正确报出（单行匹配会把"部分"误报成通过）。
- 候选先过 `keybox-check.sh`；部署前**跟随符号链接**备份当前 keybox 的字节（`cp -L`）到 `keybox-backups/`（保留最新 10 份，可 `--restore` 回滚）；部署成功后清除 `.auto-keybox` 标记。
- 日志读取容忍轮转：记录偏移前先比大小，变小即按"整个新文件都是新内容"处理。
- 本地已用合成日志验证两种判定：`applied=1 failed=0` → ACCEPTED rc=0；`failed to build` + `applied=0 failed=1` → REJECTED rc=1（后者复刻的正是现场那三行）。

# v3.1.3

现场结论（调试机实测）：**一绿不是"daemon 没推配置"，而是"引擎拒绝了这份 keybox"**。用户把自动获取来的 keybox 换成自己手里的两份，同一个设备、同一个 daemon、同一个 TEESimulator 构建，立刻变成"两绿"——变量只有 keybox 的字节。而引擎其实早就把原因写进日志了，只是这个原因被埋在一个没人读的标签里。

## 1. `engine-verdict.sh`（新）——让"引擎怎么说"只有一个出口

C++ 侧只会说 `keymint: profile <id> failed to build (bad keybox?)`；真正的诊断由 Rust TA 的 keybox 解析器给出，并且**逐字打进了同一个 tag**（`rust/teesim-km/src/ffi.rs:172` 的 `log::error!("teesim_km_init_ex: {e}")`，android_logger 的 tag 就是 `TEESimulator`，所以 LogTail 会把它写进持久轨迹）：

```
E TEESimulator: teesim_km_init_ex: RSA: expected at least 2 certificates, found 1
E TEESimulator: teesim_km_init_ex: keybox parse: expected `>` not `<`
E TEESimulator: teesim_km_init_ex: EC: missing PrivateKey
E TEESimulator: teesim_km_init_ex: keybox: no <Key algorithm="rsa"> or <Key algorithm="ecdsa">
```

`engine-verdict.sh` 把 ack 计数（判定用）和这行原因（解释用）合成一个结论，并写进 `/data/adb/teesim/.engine-verdict` 供 WebUI / engine-check.sh / 定时抓取共同读取：

```
engine-verdict.sh once            现在立刻判一次并记录
engine-verdict.sh watch [秒] [偏移] 等下一次 push/ack（换 keybox 后使用）
engine-verdict.sh show            读记录（含陈旧判定）
engine-verdict.sh reason          只输出引擎的原话
```

- **陈旧锚点**：记录里存了当时的 `keybox.xml` mtime（`kbtm`）；文件一变，旧结论立即判为 `stale`，不会把上一次的"通过"显示成当前状态。
- 只在拒绝/部分拒绝时记录 `reason`——否则一个健康的 keybox 旁边会挂着一句历史报错。

## 2. 自动获取改为"引擎验收制"（`keybox-fetch.sh`）

老逻辑：谁第一个通过**结构校验**就部署谁，从不问引擎。这正是"模块显示三绿、设备实际一绿"的来源——结构合法 ≠ 引擎能用。现在：

- **逐个候选部署 → 等引擎 ack → 只有 `applied>0 failed=0` 才算赢**；被拒的载荷按 sha256 记入 `.keybox-bad-payloads`（有界保留 20 条），小时级任务不再重复试一个已知死掉的 box。
- 当前已部署的 keybox 若被引擎拒绝，**哈希相同也不再算"无需处理"**（老代码会永远停在这个状态）；改为继续找下一个源。
- 全部候选都没通过时，恢复本次运行前的那份 keybox（`--auto` 同样处理：用运行前快照，而不是"最新备份"——那是上一个候选的状态）。
- **删掉 `bounce_tees()`**：它 kill daemon + keystore2 + DroidGuard 并 force-stop Play Store。依据上游源码，`App.kt:182` 的 `ConfigStore.watch { resolveAndPush() }` 本身就是热重载触发点（`CLOSE_WRITE|MOVED_TO|DELETE`，路径 `config.json` 或 `*.xml`），ack 之后 daemon 还会自己重签目标应用的既有密钥（`Control.kt:209-227` → `ReAttest.run`，必要时才自己重启 keystore2）。**外部 kill 不但多余，还打断了 daemon 自己那趟重签**，并把一次换 keybox 从约 1 秒拉到 30 秒以上。现在只保留客户端侧的 `client_recycle()`（回收 DroidGuard + force-stop Play Store），因为 DroidGuard 的缓存会话会继续用旧链作答。
- 引擎不可问时（daemon 未起 / 本 boot 尚无 ack）**fail-open**：照旧部署、不判死刑。

## 3. `keybox-swap.sh --auto` —— 一批候选，引擎挑一个

```
keybox-swap.sh --auto <候选1.xml> <候选2.xml> ...
```
逐个走"校验 → 备份 → 原子部署 → 等引擎回答"，第一个被接受即收工；全军覆没则把运行前那份放回去。拒绝时会打印**引擎的原话**（不再只是"bad keybox?"）。

## 4. WebUI：引擎实测覆盖渠道自述

用户原话："他显示是三绿，但是实际是他是一绿。" 那三个绿点来自渠道自己的 `key-status` 文件（渠道对渠道 box 的自述），不是设备结论。现在：

- 绿格标注 `· 渠道自述`；引擎接受时追加 `· 引擎已加载`；**引擎拒绝时整行变红并直接显示引擎给出的原因**，同时带上"渠道自述"的绿格做对照。
- 诊断导出新增 `EIREASON` / `EISTATE`，并在"Keybox 引擎可用性"下方直接打印引擎原话。
- 探针 `PG` 从 `pgrep -f org.matrix.teesim.App` 改为 `pidof teesim`：app_process 会把 argv[0] 改写成 `teesim`，老探针**永远匹配不到**，会把正在运行的 daemon 报成"未运行"。

## 5. 其它

- `engine-check.sh` 第 5 段新增 `teesim_km_init_ex` 原话；第 9 段改为先调用 `engine-verdict.sh once`，并给出 `keybox-swap.sh --auto` 的下一步。
- `service.sh` 开机后等首个 ack（最多约 60 秒）记录一次引擎结论；拒绝则写入 `keybox-bad.log`（带引擎原因）。
- 修复 `keybox-fetch.sh` 的 `dbg: command not found`：`dbg()`/`log()` 原先定义在并发锁之后，而锁块已经在用了，每次抓取都会往 stderr 吐一行报错。
- `keybox-fetch.sh` 导出 `AEGIS_TEE_DIR`，使被调用的 `engine-verdict.sh` / `keybox-check.sh` 与其路径保持一致。
- `customize.sh` 为 `engine-verdict.sh` 补 `chmod +x`。

# v3.1.4

现场取回了引擎的原话，一绿的最后一环闭合：

```
E TEESimulator: teesim_km::ffi: teesim_km_init_ex: base64: InvalidByte(1887, 61)
```

`61` 是 ASCII 的 `=`，`1887` 是 0-based 偏移——**某个 `<Certificate>` 的 base64 体内，在一个 `=` 之后还跟着数据**（典型是两段 blob 被追加进同一个 element，而不是替换）。引擎在**解码阶段**就失败了，于是 `profile default failed to build (bad keybox?)` → `ack applied=0 failed=1` → 全部 profile 被丢弃 → 设备恒定一绿，而渠道侧照旧显示三绿（渠道自述来自服务端，与本地解析无关，见 v3.1.3）。

## 1. `keybox-check.sh`：新增 Rule 5，逐 element 复刻 `decode_pem()`

v3.1.3 的校验只查"字符集 + 长度 %4"，所以上面这种坏体能通过校验并被部署——这正是"模块说没问题、设备一绿"的缺口。Rule 5 现在**按引擎的真实实现**做同一件事（`attest.rs:128-138`）：

- 切出每个 `<PrivateKey>` / `<Certificate>` 的 body，按行 trim、丢弃空行与**整行**装甲（`-----BEGIN/END ...-----`）、去掉行内空白，拼成累计串；
- 依 `base64` crate 的 STANDARD 规则预测 `InvalidLength` / `InvalidByte(index, byte)`：长度为 4 的倍数、`=` 仅在最后 4 字符组、`=` 之后不得再有数据；`index` 为 0-based、`byte` 为真实字节值，措辞与 Rust 的 `Debug` 输出一致；
- **指出是第几个 element**（如 `rsa / Certificate #1`）并打印出错偏移前后的上下文，而不是笼统地说"keybox 有问题"；
- 修复 `--quiet` 泄漏：Rule 5 的成功摘要此前绕过 `say()` 直接打印，导致 `--quiet` 在好 box 上不静默。现在统一走 `say()`（静默时仅由退出码承载结论）。

顺带记录一个上游行为，值得写进校验规则：`decode_pem()` 是**逐行**剥离装甲的（`line.starts_with("-----")`），所以装甲"贴着"最后一行数据（`QUJD...-----END CERTIFICATE-----`）时，破折号会被当数据送进解码器而失败——这种 keybox 在编辑器里看着完全正常。回归套件已把它作为一条独立用例。

## 2. 回归套件 `scripts/test-keybox-check.sh`（重写）

从"文档式断言"改成**与引擎对齐的契约**：引擎会拒的夹具必须被拒、引擎会收的夹具必须被收。21 项，全部使用合成夹具（无真实密钥材料），覆盖干净 rsa / ec-only / 3 证书、单证书链、缺算法、长度非 4 倍、非 base64 字符、HTML 错误页、缺文件 / 空文件 / 无参数、装甲两种摆位、`--quiet` 静默，以及**现场复刻用例**（1887 个 `A` + `=` + 第二段 blob → 断言输出含 `InvalidByte(1887, 61)` 与 `Certificate #1`）。

## 3. 结论：无需刷写原版 TEES+IB

对照实验已经闭环——同一设备、同一 daemon、同一 TEESimulator 构建，**只换 keybox 的字节**，结果在一绿与两绿之间切换。根因是这份自动获取的 keybox 引擎用不了，不是 TEES 或 Integrity Box 被写坏。

# v3.1.5

一份现场诊断（`aegis-diagnostics-20260911-164428.txt`）说明：**这次流程本身是对的，是报告和界面在说矛盾的话。**

时间线（设备时钟）：16:41:58 开机 → 开机校验判 `REFUSED (base64: InvalidByte(1887, 61))` → 16:43:02 手动刷新 → 16:44:20 Yurikey 候选 → **16:44:22 `ack applied=1 failed=0`，`keybox parsed (rsa=true, ec=true)`，2 个既有密钥被重签为 4 证书链** → 一两分钟后完整性检查变两绿。整条链路（热重载、重签、引擎验收）都按设计工作。修的是下面这些"说谎"的地方。

## 1. 一个"通过"，配着一个已经作废的失败原因

报告里相邻四行出现：

```
Keybox 引擎可用性: 通过 — 引擎能据此建出 TA
  ★ 引擎给出的原因（teesim_km_init_ex）: base64: InvalidByte(1887, 61)
```

两行都是真的，但说的是**两个不同的 keybox**：原因来自刚刚被换掉的那一份。根因是诊断导出**绕过了 `.engine-verdict`**（v3.1.3 专门为此建立的"引擎结论唯一出口"），自己去持久日志里 `grep | tail -1` —— 那份日志会保留**它历史上打印过的每一次拒绝**。

- 原因现在只从 `.engine-verdict` 读，而 `engine-verdict.sh` 在引擎接受时会**主动清空** reason；
- 只有在"引擎仍在拒绝"（state=rejected/partial，或最新 ack 的 `failed>0`）时才把原因当作现状显示；
- 被取代的原因不丢，但**标注为历史**：`历史（已被当前 keybox 取代，不是本机现状）`。

## 2. 拿"上辈子"的请求计数当现状

同一份报告里，同一个指标出现了两个数字：`引擎已接管请求=76 · 仍转发真机=11`（探针，全量持久日志）与 `引擎接管请求(target=1) = 0 · 转发真机(target=0) = 12`（健康判定段，日志窗口）。更要命的是后者的结论句：

```
注意: 全部 12 次 generateKey 都是 target=0 —— 引擎没有生效 profile, 或调用者未被匹配。
```

那 12 次调用**全部发生在 16:44:22 那次 ack 之前**——也就是引擎接受新 keybox 之前。这条"警告"描述的是一种已经不存在的状态。

- `ET1`/`ET0` 改为**自最后一次 ack 起**统计（即"当前这份 keybox 的时代"），并保留 `ET1ALL`/`ET0ALL` 作为累计值，两个数各自带标签，不再混淆；
- 健康判定段同样按最后一次 ack 切窗口；
- 新增第三种情况：自 ack 起**没有任何** generateKey 时，说明"还没有应用发起认证请求（正常，跑一次完整性检查即可看到）"，而不是报成故障。

## 3. `Google 源状态: -1 个有效`

`-1` 不是"未知"，是 `keybox-fetch.sh` 的**故意哨兵值**：说明这个渠道根本不发布状态文件（Yurikey 就是）。渲染层把它当普通数字直接印了出来。现在显示 `渠道未提供自述（该渠道不发布状态文件）`。

同理，状态灯上的 `已配置 · 状态未知 · 引擎已加载` 改为 `已配置 · 渠道无自述 · 引擎已加载`——"状态未知"紧挨着"引擎已加载"读起来像出了问题，而事实只是这个渠道没有自述源。

## 4. "后台刷新中"一直不更新

用户原话："刚开始显示后台刷新中一直不更新"。这不是错觉：一次抓取在离线环境下实测 **66 秒**（真实网络下 81 秒），这段时间界面只有一个不动的转圈。

- `keybox-fetch.sh` 现在把当前阶段写进 `$TEE_DIR/.kb-fetch.progress`（epoch / 阶段 / 详情），每次尝试都重写：`下载候选 · Yurikey · 第 2/3 次尝试`、`等引擎应答 · Yurikey · 最多 10 秒`、`已接受 · …`；退出时随锁一起清掉；
- 状态灯显示 `刷新中 42s`，折叠面板显示 `刷新中：下载候选 · Yurikey · 第 2/3 次尝试（本阶段已 42 秒）`；
- **界面在刷新期间会自己轮询**（5 秒一次，约 10 分钟预算）——之前只在页面加载时读一次，所以永远停在你打开页面时的那一帧。

## 5. 顺带修掉的日志噪音

- `download failed: attempt N rc=0` → 区分 `download empty: … (downloader rc=0, server sent 0 bytes)`。下载器成功但服务器给空 body 是常事，`rc=0` 配上"failed"读起来像自相矛盾，上一个排查回合就为此多花了一轮。
- `download start: … timeout=timeout 45` → `timeout=45`（把命令前缀当数值印了出来）。
- `debug.log` 里 `[1970-02-14 10:56:45] [patch] …`：这行在 post-fs-data 阶段写，此时 RTC 还没就绪，`date` 给出的不是时间。现在打印 `boot-early (RTC 未就绪)`，不再伪造一个 1970 年的日期让整份日志看起来乱序。

## 6. 回归

- `scripts/test-logs.js`：新增 8 项，把这次现场的两个矛盾场景钉死——引擎已接受时**不得**出现现行失败原因（被取代的原因只能以"历史"出现）；拒绝时原因**必须**打印；请求计数按 ack 切窗口，ack 之前的 `target=0` 不得被报成现状；`KBG=-1` 不得渲染成负数。→ **69 passed**。
- `scripts/test-webui.js`：更新两条被有意改掉的文案，并新增两条（刷新中必须带秒数、折叠面板必须给出阶段与渠道）。→ **86 passed**。
- `scripts/test-keybox-check.sh`：21 passed（未改动）。

# v3.1.6

一份现场诊断（`aegis-diagnostics-20260911-165938.txt`）把另一个长期存在的行为摆上了台面：**"受保护的应用"里的密钥认证（KeyAttestation）和 PIAC 会莫名其妙地被取消勾选。** 这不是 bug 的 bug——是 `apps-sync.sh` 第 3b 节（Round 12）的**检测类应用排除**在每次运行时静默删除这 6 个包，而界面、日志、文档里对这件事**一个字都没有提**。用户看到的现象就是"模块自己在乱动我的勾选"。

## 1. 审计结论：到底会不会动别的应用

把两条删除路径分开看（`apps-sync.log` 全量核对）：

- **检测类排除（3b 节，硬编码 6 个包）**：`io.github.vvb2060.keyattestation`（密钥认证）、`io.github.vvb2060.mahoshojo`、`gr.nikolasspyr.integritycheck`（PIAC）、`icu.nullptr.nativetest`、`com.reveny.nativecheck`、`io.github.qwq233.keyattestation`。全部是检测/attestation 类，**没有任何正常业务应用在这份列表里**。日志里它反复命中 keyattestation 与 integritycheck（16:49:40、16:58:07…），与用户观察完全一致。
- **卸载清理（第 3 节）**：只删 `pm list packages` 里不存在的条目。日志中仅 2026-09-08 22:41:15 出现过一次：`com.google.android.apps.messaging`、`com.google.android.apps.walletnfcrel`——不在检测列表里，走的是"已卸载"路径。可用 `pm list packages | grep -E 'messaging|walletnfcrel'` 自行核实（小米系 ROM 通常确实没装这两个）。
- `uid:N` 条目**永不**被清理；`pkg@user` 条目只在格式非法时清理。

结论：**没有"莫名其妙取消其他软件"的第三条路径**。问题只在于检测类排除是静默的。

## 2. 为什么当初要排除（-66 的由来）

TEES 的 attestation-ID 门会把**请求里的真机 ID** 与 profile（现跟随 PIF 伪装身份）比对：任何在保护范围内的应用若请求 ID 证明，且 ID 与伪装身份不一致，就得到 `CannotAttestIds(-66)`。检测类应用恰恰全会请求 ID 证明，所以"留在保护范围内 = 必然 -66"；"被移出范围 = 走真机 TEE，显示真机值（未知根证书 / 引导加载程序已解锁）"。两个状态都出不了干净结果，这是 TEES 的设计边界，不是配置问题——但**替用户做决定且不留痕迹**是错的。

## 3. 修复：从"静默删除"到"明示 + 一个开关"

- `apps-sync.sh` 3b 节：
  - 排除动作落在 `$TEE_DIR/.detector-excluded`（`pkg<TAB>epoch`，**只在改写真正落地后**才写，失败不写假记录）；
  - 日志拆成独立两行：`auto-excluded detector apps (in scope they fail with CannotAttestIds/-66): …` + `-> keep them anyway: touch $TEE_DIR/.keep-detectors`，不再混进 `cleaned, removed`；
  - 卸载清理行补上原因：`cleaned, removed:… (absent from pm list packages — uninstalled or uninstalled for this user)`；
  - `.keep-detectors` 存在时同时清掉记录文件，避免界面残留陈旧排除列表。
- WebUI 受保护应用页（`apps.html`/`apps.js`/CSS）：
  - 新增**检测类应用通知卡**：显示"检测类应用已自动移出保护列表 · N"、被移出的包名与时间、-66 与真机值两种状态的解释，以及 **"保留它们（不再自动排除）"** 一键开关（写 `.keep-detectors`；已开启时显示"恢复自动排除"）；
  - 对应应用行内加 `检测类 · 已自动排除（避免 -66）` 标注——被排除的应用不再看起来像"用户忘了勾"；
  - 等价命令直接印在卡片上，终端党不需要翻文档。
- 诊断导出（`logs.js`）：新增 `检测类应用自动排除:` 一行，报告当前是开启/关闭、本轮移出了哪些包、以及恢复保留的命令——之前导出只说"受保护应用数量: 55"，两个应用悄悄消失时报告毫无线索。

## 4. 回归

- `scripts/test-apps-sync.sh`：case13/14 重写 + 新增 3 组，钉死——排除**必须**走独立日志行且不得伪装成 prune；记录文件必须存在、逐包两列、二次运行后仍然恰好两行；`.keep-detectors` 生效时保留应用且清除陈旧记录；普通 prune **不得**产生排除记录。→ **50 passed**。
- `scripts/test-apps.js`：新增 11 项——通知卡出现/计数/包名/-66 解释/按钮；行内标注；点击保留写出 `.keep-detectors` 且文案翻转；纯 opt-out（无记录）时状态仍可见但无行标注。→ **97 passed**。
- `scripts/test-logs.js`：新增 3 项（导出含排除明细与 opt-out 命令、opt-out 状态导出解释 -66 权衡），并修复 noPif 变体的写入捕获竞态（全局"第二次写入"匹配会被新增的导出截胡，改为按点击点截断）。→ **72 passed**。

# v3.1.7

用户拍板（现场：`aegis-diagnostics-20260911-175042.txt` + 两张截图）："这些应用没必要自动取消啊，添加就添加了，但是你需要**解决这些问题**"——即：密钥认证/PIAC 保持勾选要**真能用**，而不是靠"移出去避开 -66"。这一版把 v3.1.6 的"明示 + 开关"再往前走了一步：**排除整个退役，-66 在引擎层修掉。**

## 1. 先回答"点了不排除为什么还排除"

时间线核对：17:47:36 apps-sync 移出两个检测类应用 → 17:48:59 密钥认证截图（走真机 TEE，未知根证书 + BL 已解锁）→ 之后点了"保留它们" → **17:50:42 导出确认 `.keep-detectors` 已存在，且 17:47 之后 apps-sync 再没有删过任何东西**。开关本身是生效的；错觉来自两点：应用已被移出（需要重新勾选一次），通知卡要等下次同步/刷新页面才翻转。但这个体验确实绕，根源是"先移出、再求保留"这个流程本身不该存在——于是直接砍掉。

## 2. -66 的确切机制（读上游源码定案）

- keystore2 在应用请求**设备属性证明**（ID 证明）时，用**真机身份**（Build 字段 + 电话标识）填好 `ATTESTATION_ID_*` 标签再发给 KeyMint；
- 引擎 TA 里存的是 profile 的身份——v3.1.0 起 profile 跟随 PIF 伪装（google/tokay/Pixel 9）；
- AOSP 参考 TA（kmr）对请求标签与自身存量做**逐一比对**，不一致即 `CANNOT_ATTEST_IDS`（keystore2 层表现为 -66，社区报错栈：`security_level.rs:636 → Error::Km(r#CANNOT_ATTEST_IDS)`）。

所以：**只要 profile 伪装身份 ≠ 真机身份，勾选密钥认证就必然 -66**。这与 keybox 好坏、勾没勾保护都无关，是那道"ID 门"的几何关系。不勾选走真机 TEE，显示的是真机值（未知根证书 / 引导加载程序已解锁）——同一枚硬币的两面。

## 3. 引擎修复：补丁 0005（`patches/teesim/0005-attest-id-retarget.patch`）

TrickyStore 一类项目的做法是"证书整体自己签，ID 想写什么写什么"；TEES 的 resign 路径其实已经会把 profile 身份写进叶子证书，缺的只是**请求在进 TA 前过不了那道门**。补丁在 `keymint_router.cpp` 里补上这最后一环：

- `Profile`/`RequestTarget` 携带 profile 的 `deviceIds`（守护进程本来就会下发：显式值 + 收割基线，见 `Resolver.kt`）；
- `generateKey` 在**由我们的 TA 服务**时（generation 模式、attest-key 两分支），把请求里的 `ATTESTATION_ID_*` 值改写为 profile 值——门就过了，叶子证明的是伪装身份（与 resign 写入的一致）；
- profile 没有的 ID（如 MEID）**丢弃该标签**而非失败，语义等同 `destroyAttestationIds()`；
- 走真机 HAL 的路径（patch 模式、外来 attest key）**不改写**——真机 TA 存的就是真机值，改了反而 -66。

⚠️ 引擎补丁要**重构 TEESim payload 才生效**（CI `./gradlew zipRelease`）。本仓库的本地 zip 用的是既有 `build/teesim-payload.zip` 二进制，所以在 CI 产物出来之前，勾选密钥认证仍可能看到 -66——那是旧二进制，不是 v3.1.7 脚本没生效。

## 4. 排除机制退役（脚本层，本版即生效）

- `apps-sync.sh`：第 3b 节整个删除——**受保护列表从此只有用户自己会变**；一次性清理 v3.1.6 残留的 `.detector-excluded` / `.keep-detectors`（带日志）；
- WebUI 受保护应用页：v3.1.6 的检测类通知卡与行内标注移除（无排除即无需解释）；
- 卸载清理日志保留原因后缀（`absent from pm list packages …`），审计能力不回退；
- 诊断导出改为固定说明行，写明排除已退役与 -66 的修复载体。

## 5. 回归

- `scripts/test-apps-sync.sh`：3b 相关 3 组用例重写——检测类应用**必须**留在 scope；残留标记文件必须被清理且留日志；卸载清理照常工作并说明原因。→ **42 passed**。
- `scripts/test-apps.js`：移除通知卡 11 项（随 UI 退役）。→ **85 passed**。
- `scripts/test-logs.js`：导出断言改为固定说明行，顺带把 v3.1.6 引入的 noPif 写入捕获按点击点截断（修一个测试自身竞态）。→ **70 passed**。
- `scripts/test-webui.js`：**86 passed**（未动）。
- 补丁验证：`git apply --check` 在 pinned commit `4f42350` 的原始树上干净通过。

# v3.1.8

现场（DuckDetector 两张截图）："检测 root 软件发现有暴露行为，并且密钥认证出现 -66 错误"。两件事两回事：

## 1. -66：预期中的旧引擎二进制

v3.1.7 的修复载体是引擎补丁 0005，它要**重构 TEESim payload**（CI `./gradlew zipRelease`）才生效。本地 zip 始终内嵌既有 `build/teesim-payload.zip` 二进制——勾选密钥认证出现的 -66 就是旧二进制的 ID 门。**修复已就绪，等一次 CI 构建。**

## 2. "跨进程挂载表分裂"：先给排查数据，再谈修复

DuckDetector 的 Mount 卡片：扫 933 个 pid，4 张可读挂载表出现 **2 种视图**（期望 1），判为"选择性挂载隐藏"。这是管理器侧按应用"卸载模块挂载"的固有形态：被处理的应用进程看不到模块挂载，而它派生的 isolated 辅助进程看不到同样的处理——**应用自己内部就有两种视图**，任何只藏一部分进程的方案都会被这类"跨进程对比"检测命中。启动预载/路径探测/shell tmp 视图三项全 Clean，说明静态痕迹没有暴露，暴露的只有这个视图分裂。

本版把排查数据加进诊断导出：新增 `== 挂载视图 (本进程) ==` 段——本进程挂载总数、含 `/data/adb` 的挂载数与路径，并指出管理器（KSU）"卸载模块挂载"开关是视图分裂的来源：**全局统一开或关**（而非按应用）可消除分裂——先试全关，因为路径探测本来就是 Clean，统一可见不会新增静态暴露。

## 回归

- `scripts/test-logs.js`：+3 项（挂载基线行、管理器开关提示、探针 MNT_* 字段）。→ **72 passed**。
- 其余套件未动（apps-sync 42 / apps.js 85 / webui 86）。

# v3.2.0

改名与加固版本。模块 ID 由 `integrityfusion` 变更为 **`aegisfusion`**（与品牌名对齐；无正式版发布、无存量用户，零迁移成本），同期完成一轮完整安全审查与多项体验收尾。

## 模块 ID 改名（integrityfusion → aegisfusion）

- `module.prop` id 与全部硬编码引用同步：customize（迁移）、engine-check / keybox-swap / pif-fetch（MODDIR）、pif-sync（候选路径与 case 模式）、WebUI 三页（MODPATH 常量 + GMS maps 注入检测 grep）、测试夹具（test-pif-sync / test-webui / test-logs）。
- **assemble.sh 的 PIF 路径等长二进制补丁适配**：`/data/adb/modules/playintegrityfix/`（35 字节）→ `/data/adb/modules/aegisfusion//////`（6 个补位斜杠凑等长，35=35，脚本自带 `assert len` 防错）；打包后验证 grep 与 module.prop id 检查同步更新。**新包必须由本次改动之后的 CI 构建产出**。
- 升级语义：测试机直接删旧目录（`kill $(pidof teesim)` → 删 `/data/adb/modules/integrityfusion` 与 `/data/adb/teesim` → 重启）后刷新包；历史记录（CHANGELOG / 复盘报告）保留旧 ID 不篡改。

## 安装器双语化（跟随系统语言）

- `customize.sh` 新增 i18n 层：`getprop persist.sys.locale`（回退 `ro.product.locale`），`zh*` 显示中文、其他一律英文；`msg <en> <zh>` 辅助函数封装全部 26 处安装文案；两处 `abort`（Android < 8、非 64 位）改为"双语提示 + exit 1"，拦截语义不变。中英混排的 Debug 提示顺带统一。

## 安全加固（详见 `docs/security-review-20260911.md`，2 中危 + 4 低危全修）

- **keybox 下载恢复 TLS 校验**：删除系统 wget 分支的 `--no-check-certificate`（curl 与 busybox 分支本就校验；中间人无法再替换 keybox/吊销列表）。
- **临时目录迁出全局可写路径**：`TMPD` 由 `/data/local/tmp/fusion-kb.$$` 移至 `$TEE_DIR/.tmp.$$`（父目录 root-only 0700，消除符号链接攻击面）。
- **sed 替换转义补全**：customize `fill_id` 与 pif-sync `set_id` / `ensure_patch_object` / `assert_flags` 四处，值先剥换行再转义 `& / \`（此前反斜杠会产出损坏的 sed 表达式 → config/prop 静默腐坏）。
- **config.json 权限收紧**：0644 → 0600（纵深防御，与 keybox/marker 一致；WebUI 走 root 桥读取不受影响）。
- **Debug 默认关闭**：debug.log 记录完整决策链属隐私面，出厂不再默认开启；日志页开关保留，诊断导出会引导报障者按需开启。
- **CI**：Cargo 缓存 key 改为 `hashFiles('versions.env')`（原 `hashFiles('upstream/…')` 在 checkout 时永远 miss）。
- 以上全部不触碰 keybox 校验 / 引擎验收 / attestation 请求链，对 PI verdict 零影响。

## 卸载 = 彻底删除（行为变更）

- `uninstall.sh` 重写：先 `kill $(pidof teesim)`，再整目录删除 `/data/adb/teesim`（config、keybox、备份、日志、标记、socket 全清），GMS/Vending 注入残留清理保留。**想转投上游 TEESimulator 的用户请先自行备份 keybox.xml。**

## 诊断导出补全

- 新增 `== pif-sync.log (最后 100 行 · 双端身份同步) ==` 段——身份同步是 verdict 路径的关键环节，此前导出唯独漏了它。
- 新增**报障指引**：Debug 关闭时自动提示"开 Debug → 复现 → 重新导出"；开启时提示"本文件已含完整决策链"；并注明导出不含 keybox、令牌与应用清单。

## 文档

- 新增 `docs/one-green-postmortem.md`：一绿问题四天攻坚复盘（v2.2.8 → v3.1.8 的七个叠加根因、对照实验方法论、完整因果链）。
- 新增 `docs/security-review-20260911.md` 与 `docs/security-review-20260911-malware-audit.md`：漏洞审查（含处置记录）+ 恶意行为专项审计（后门/蠕虫/病毒全阴性，供应链信任边界说明）。

## 回归

- webui 86 / apps 85 / logs 72 / pif-sync 52 / pif-fetch 42 / apps-sync 42 / service-props 8 / keybox-check 21 —— 全部通过；全部 `.sh` 过 `bash -n` + `sh -n`（dash 兼容），三个 JS 过 `node --check`。

# v3.2.2 ⚠️ 安全敏感版本（网络获取层变更）

> **给开发者**：本版动了 keybox 的网络下载路径，属于安全敏感变更。再次触碰该区域前，先读
> [`docs/RELEASE-NOTES-v3.2.2.md`](docs/RELEASE-NOTES-v3.2.2.md)（改了什么/为什么/根因）与
> [`docs/security-report-keybox-fetch-v3.2.2.md`](docs/security-report-keybox-fetch-v3.2.2.md)（威胁模型/攻击面/残余风险）。
> 版本号自 v3.2.0 直接跳到 v3.2.2：v3.2.1 编号被开发期代理块草案占用，未发布。

## 背景（为什么是大事）

2026-09-13 真机事故：污染网络下 keybox 自动刷新**静默冻结**（"上次刷新 —"），根因是唯一下载通道 raw.githubusercontent.com 不可达且无任何兜底。本版为系统性修复，同时补上开发期发现的真实缺陷。

## 下载阶梯（module/keybox-fetch.sh，⚠️ 重点）

每条 URL 依次尝试，任一成功即止：

1. **直连重试 ×3**（旧行为，不变）；
2. **代理穿透**（新增）：环境变量 > `pif-proxy.conf` > 记忆文件 `pif-proxy.auto`——与 pif-fetch.sh 完全同款契约；字符白名单拒绝 shell 元字符，仅作环境变量传递，无 eval，`unset` 覆盖成功/失败全部退出路径；
3. **本地端口自动探测**（新增）：7890/7897/10808/10809/2334/2080，仅当②全空且①失败时每轮至多一次；只向 `127.0.0.1` 出站，不监听任何端口；
4. **直连 CDN IP**（新增，最后手段）：`curl --resolve` 把 raw.githubusercontent.com 钉到官方 Fastly IP（185.199.108~111.133）绕过 DNS 污染——**TLS 证书验证全程保留**（明确拒绝 Integrity-Box 的 `--insecure` 路线）；IP 写死不走 DNS；仅该域名生效。

配套修复：

- `pif-proxy.auto` **只写不读**缺陷（外来草案缺陷）：`kb_proxy_resolve` 补齐记忆读取，否则每次失败都从零探测 6 端口、陈旧清理分支永不触发；
- `TEE_DIR` 支持 `AEGIS_TEE_DIR` 覆盖（此前硬编码，测试 harness 会误操作真实 `/data/adb/teesim`）；
- **明确否决** setprop DNS 覆写（Android 8+ 基本无效 + 动系统属性）——本版零系统状态修改；内容处理路径（校验/部署/权限）一行未动。

## 测试

- 新增 `scripts/test-keybox-fetch.sh`：**17 项断言全绿**（语法门禁 ×2、代理穿透 kbf1、共享 conf kbf2、敌意 conf 拒收 kbf3、陈旧记忆清理 kbf4、直连 IP 兜底 kbf5）；网络由假 curl 全拦截，零真实外联；
- CI（build.yml）加入该测试；本地调试期三类环境异常（开发机环境代理泄漏 / WorkBuddy rm shim 拦截 / 旧运行锁残留）全部根因定案于测试 harness 并修复，与模块运行时无关。

## 同周期入库（同属本版）

- `ad7f994` feat(pif)：到期感知轮换钟 + 两级过期警示；
- `804c6c3` fix(pif)：`expiry_epoch` dash 兼容；
- `72508e3` ui(home)：删 verdict 卡、状态点对齐、下拉胶囊化。

## 版本

- versions.env：v3.2.0 → **v3.2.2**（versionCode 基线 20260913，CI 仍按构建日期覆盖）。

# v3.2.3 ⚠️ 安全修复版本（外部全量审查处置）

> 审查报告：[docs/security-audit-20260915.md](docs/security-audit-20260915.md) ·
> 逐条处置：[docs/security-audit-20260915-response.md](docs/security-audit-20260915-response.md)。
> 本版是"审计响应版"：C1（严重）、H1（高）、M2/M11（中）当场修复，其余逐条排期或知情留档。

## C1【严重】随包指纹脚本 TLS 降级 + eval ⇒ MITM→root RCE —— ✅修复

- `scripts/harden-pif.sh` 正式接线 `assemble.sh`：打包期对暂存副本执行——8 处 `--no-check-certificate` 改为运行时 TLS 能力探测（默认验证；wget 不支持时回退并日志告警）；明文 `nc:80` 头探测降为 HTTPS-first 最后手段；`migrate.sh` 三处文件派生值 `eval` 去 eval 化（数据只进变量赋值，不再被重解析）。
- 每处补丁带计数断言：上游漂移 ⇒ 构建失败而非静默带洞发布。已对真实 PIF v18 字节验证 + `sh -n` 双脚本通过。
- `scripts/harden-pif.sh` 与 `patches/teesim/0006` 一并入库（此前未提交，CI 全新 checkout 看不到）。

## H1【高】诊断导出含明文 IMEI/IMEI2/MEID/serial 且文案称"可放心分享" —— ✅修复

- 源头：`patches/teesim/0006-mask-harvest-id-logging.patch`——Harvester 日志改为 `len=N`/`blank`（诊断价值保留：取没取到、格式长度对不对），真实值只在 root-only 的 harvested.json/config.json；
- 导出层：`logs.js` 写盘咽喉点 `maskDeviceIds()`（全文掩码、保留长度，对老日志同样生效）；
- `engine-check.sh`：/logs 环形缓冲、daemon.log、logcat 三处输出统一 `mask_ids`；头注释更正；
- 文案：`logs.js` / `logs.html` / `engine-check.sh` 三处"可放心分享/safe to paste"更正为"设备标识已自动脱敏"；
- 回归：`test-logs.js` fixture 注入真格式假值 Harvest 行，新增 5 条硬断言（80/0 全绿）。

## M11【中】"手动获取"覆盖用户导入 keybox 且无备份，承诺为假 —— ✅修复

- `keybox-fetch.sh` --force 路径：替换前先把当前 keybox 备份到 `keybox-backups/keybox_pre-force_<ts>.xml`（0600，保留最近 5 份）；**备份失败即中止**，绝不无备份覆盖；
- `customize.sh` / `README.md` 假承诺文案更正（"自动刷新永不覆盖；手动获取会替换，替换前自动备份"）；
- 导入判定边界补设计注释（hash==marker 且 mtime 更旧 ⇒ 字节等同上次渠道部署，判定非导入，无用户数据损失）。

## 其余当场修复（P1 速赢）

- L2：两处代理探测由 `www.baidu.com` 改为 `https://github.com/robots.txt`（目标基础设施自身，免第三方域名，请求不含设备数据；`timeout` 3s→8s）；
- L15：`test-keybox-check.sh` 接入 CI 测试清单；
- L8：诊断文件写入权限 0644 → 0600；
- M2：`keybox-check.sh` 不再回显私钥 base64 上下文（只报偏移量与 ord 值）；
- 文档：`security-report-v3.2.2` 加 2026-09-15 勘误（探测出网表述 / TLS 范围限定）；`RELEASE-NOTES-v3.2.2` TLS 声明加范围限定。

## 复核响应（N 系列，报告：[docs/security-audit-20260915-v3.2.3-verification.md](docs/security-audit-20260915-v3.2.3-verification.md)）

- **N1【高】**：`engine-check.sh` 第 6 节不再打印 `/status` 原始 JSON（其内嵌 harvest 明文记录）——只过滤输出 `version`/`hook` 字段；`mask_ids` 与 `maskDeviceIds` 均补第三条 JSON 形态规则（`"key":"value"`，原规则只认 `key='v'`/`key=v`）；`test-logs.js` 新增 5 条 JSON 掩码断言（85/0）；`assemble.sh` 加后置断言（`head -c 1200` 原样打印不得回归）。
- **N2【中】**：**上游控制台 `webroot/teesim/` 不再随包**（其日志导出把含明文 harvest 的全部轮转分片写进 `/sdcard/Download`，无任何脱敏），`index.html` 入口链接同步移除，`assemble.sh` 加"不得随包"断言；`customize.sh` 升级时就地脱敏设备上旧日志（teesim.log + 轮转分片，掩码不删除）；README 标注该处置（兑现上次承诺）。
- **N4【低】**：TLS 能力探测由 `--spider`（busybox wget 不支持 ⇒ 降级成常态）改为完整 GET `-O /dev/null`（toybox/busybox 通用），降级只在真实 TLS/网络故障时发生且显式告警；对官方 v18 字节重跑硬化验证 + 注入测试通过、幂等。
- **N5【低】**：M11 备份补 2 条回归测试（kbf6：备份成功且字节一致；kbf7：备份位置不可用 ⇒ 中止且 keybox.xml 原样），`test-keybox-fetch.sh` 25/0。
- **N6【低】**：README 测试计数更正并补全 9 套件清单（test-keybox-fetch/check、apps-sync、service-props）。
- **N7【信息】**：升级时的旧日志就地脱敏（N2 同一机制）使 WebUI 屏幕视图也不再显示旧明文 harvest 行。

## 第三轮复核响应（N9–N12，报告：[docs/security-audit-20260915-v3.2.3-r3-review.md](docs/security-audit-20260915-v3.2.3-r3-review.md)）

- **N9**：`pif-fetch.sh` / `keybox-fetch.sh` 的 `probe_port` 弃用 `--spider`（busybox wget 不支持 ⇒ 自动代理探测在那些设备上永不成功），改完整 GET `-O /dev/null`，与 N4 同理；
- **N10**：`pif-fetch.sh` 的 `unset http_proxy https_proxy` 改为**无条件**先执行再显式导出配置代理——宿主注入的代理不再把"直连轮"悄悄变成代理轮（日志 `proxy=none|none` 恢复可信）；
- **N11**：`test-pif-fetch.sh` / `test-apps-sync.sh` 夹具改为每次运行唯一目录（零 `rm -rf`），并旁路宿主 safe-delete 钩子对模块自身 `rm` 的否决——消除"同一代码 69/5 ↔ 61/13 波动"的伪失败；
- **N12**：响应文档基线哈希笔误更正；N1 复现脚本入库 `scripts/verify/verify-n1.sh`；
- N4 收尾（仅证书错误时降级 + 显式开关）维持 P2，与 L14 同批处理。

## 第四轮复核响应（N13–N17，报告：[docs/security-audit-20260915-v3.2.3-r4-review.md](docs/security-audit-20260915-v3.2.3-r4-review.md)）

- **N13**：`engine-verdict.sh` SILENT 分支的日志尾部补 `mask_ids`（三条规则与 engine-check.sh 逐字节相同）——H1 掩码咽喉点的**最后一条已知绕过路径**封死；
- **N15**：`keybox-swap.sh` 备份失败由"告警后继续"改为 **fail-closed 中止**（对齐 M11：备份不成功，绝不替换）；
- **N16**：`resetprop_if_diff` 属性缺失即跳过确认为**有意设计**（与上游 common_func.sh 逐字节同语义：绝不凭空创建 OEM 没写的属性），意图已写入注释；
- **N17**：`engine-verdict.sh` 的 `$3` 补数字白名单（与 `$2` 一致）；
- **N14**：`bootkey.bin` 全设备覆盖 KEK 基准且优先于真实采集的兼容行为已在 README 显式告知；"覆盖是否应排在可用性检查之后"知情维持现状（该补丁即为此场景而写），理由见响应文档。

## 第五轮复核响应（R5-1/R5-2，报告：[docs/security-audit-20260915-v3.2.3-r5-review.md](docs/security-audit-20260915-v3.2.3-r5-review.md)）

- **R5-1**：设备标识脱敏与上游日志拼写**强耦合**的健壮性缺口——键名表补 `serialno`（引擎实际读 `ro.serialno`），裸值类从 `[A-Za-z0-9]{4,}` 放宽为"直到下一个分隔符"，新增"键+空白+值"规则；**4 份副本同步**（logs.js 导出 / engine-check / engine-verdict / customize 安装期就地脱敏）。带连字符值、首段 <4 值、空格分隔、值换行 4 类原样穿过的形态现全部脱敏（今日上游拼写不产生这些形态，属纵深防御而非当日泄漏）；负向对照钉住 `serialVersionUID` 等无害词不误伤；
- **R5-2**：新增 `scripts/test-mask-ids.sh`（22 断言：从 3 份 shell 副本抽取**真实 sed 表达式**断言逐字节一致 + 7 形态对抗 + 负向对照），`test-logs.js` +5 端到端断言（90/0），`verify-artifact.sh` +8 产物级断言（4 副本在解包产物上逐一核对），CI 回归清单接入；
- 附带：KSU/APatch root 执行桥（`ksu.exec`）专项复核通过——无命令注入构造，admin token 不进 JS 内存；
- CI：弃用 `android-actions/setup-android@v3`（在新 runner 上请求已移除的 `tools` 包导致构建失败），改用 runner 自带 sdkmanager 直接接受许可证。

## 第八轮复核响应（R8-1/R8-2/R8-4/R8-5 等，报告：[docs/security-audit-20260916-v3.2.3-r8-review.md](docs/security-audit-20260916-v3.2.3-r8-review.md)，2026-09-16）

- **R8-4（破坏性，原 M10 上调为中）**：`assemble.sh` 剥掉上游 `common_setup.sh` 的 `elif [ "$MODPATH/uninstall.sh" ]; then sh $MODPATH/uninstall.sh` 分支（负向断言把关）——此前若模块目录存在 `skippersistprop` 标记（独立 PIF 用户迁移习惯），**每次开机**都会执行卸载脚本清空 `/data/adb/teesim`（keybox 不可再生）。标记的本义"不写入 persist 伪装属性"保留；`customize.sh` 检测到该标记时显式提示语义与安全性；
- **R8-5**：`uninstall.sh` 补 `RESIDUE_PROPS` 持久属性清理（与 service.sh:211-235 同清单）——此前卸载后 `persist.sys.pihooks.*/pixelprops.*/pp.*/spoof.gms` 在 hook ROM 上永久残留，与头部"Nothing survives"声明矛盾（上游追加给自家 uninstall.sh 的还原行在融合版是死代码）；
- **R8-1**：`pif-fetch.sh` shebang `#!/system/sh` → `#!/system/bin/sh`（1 字符；调用方均显式走 `sh`，属潜伏不一致）；
- **R8-2（知情告知收尾）**：README 注意事项补"设备身份的读取与保存"条目——模块以 root 读取并保存 IMEI/IMEI2/序列号进 `config.json`（设计必需、root-only、诊断导出不含、卸载即删），r6 三条告知建议全部落地；
- **L10（选项 a：注释诚实化）**：`service.sh` / `fusion_func.sh` / `post-fs-data.fusion.sh` 三处声称"service 阶段 + 每小时 tick 调用 `align_patch_level`"的失实注释改为如实陈述（唯一调用点 `post-fs-data.fusion.sh:14`，轮换后重启才对齐）；补真实调用列为待真机验证的开放决策；
- **R7-3**：`.gitattributes` 补 `update-binary text eol=lf`（无扩展名文件此前不受任何规则保护，Windows 侧提交会 CRLF 毁安装器）；
- **R7-4/M4 部分**：CI 新增 `Generate SHA256 checksum` 步骤——artifact 与 release 均附带 `.zip.sha256`（actions SHA-pin 维持冻结至发布后）。

### 同日追加（作者裁定后的小修批）

- **M6**：`set_id` / `ensure_patch_object` / `fill_id` 三处 JSON 写入补齐引号与反斜杠的三层转义——值含 `"` 或 `\` 不再写坏 `config.json`（经 sed replacement 中转需预翻倍反斜杠，已在含引号+反斜杠+`&`+`/` 的对抗值上往返实测无损；旧代码连反斜杠都会写坏 JSON，本次一并修正）。`assert_flags` 写入目标是 prop 文件（引号合法、无 JSON 语义），维持原转义并注释说明；
- **M5 余项**：`pif-fetch.sh` 对"包内无内置种子指纹"改为 fail-loud——日志明确写出原因（构建期抓取失败），不再静默跳过让"BASIC 无指纹"无从排查；
- **L7**：WebUI 受保护应用页的守护进程分支与 pm 分支同过 `VALID_PKG_RE` 严格包名正则，畸形条目在进 UI 与作用域前丢弃（一致性卫生，r8 已核验 WebUI 零注入面，本项非安全修复）。

## 发布前收尾（2026-09-17，作者裁定"肯定要修"）

- **R7-7**：release notes 收窄为本版 CHANGELOG 段落（awk 按 tag 截取 + 空段落回退全文件），发布页不再展示 v1.0.0 起全部历史；
- **R7-5**：assemble 期剥离 `zygisk/armeabi-v7a.so`（~170 KB，模块不为 v7a 构建解释器、该载荷永不加载）+ 负向断言，包体更小、面更小。

### L14 关闭：操作按钮不再泄露机型（2026-09-18，作者裁定）

- assemble 期把 action 按钮的 `autopif4.sh -m`（用**本机机型名**作为查询参数请求 Google flashstation——全模块唯一设备派生出站值）改为 `autopif4.sh --strong`（随机 Pixel beta 机型），带负向断言；Round 13 的"写标记 + 立即同步"保留。自此**任何路径都没有设备派生数据出网**，且操作按钮 / 安装时抓取 / 自动轮换三者语义统一为随机机型。

### 种子烤入失败修复（2026-09-17，CI 64dd168 实测发现）

- **根因**：Google 移除了 flashstation builds JSON 中的 `"canary": true` 锚点字段（RC 周期），autopif4 的提取锚点失效 → `Failed to extract build info from JSON` → 包内无种子（CI 日志实证，64dd168 无 pif_seed.prop）。上游 main 分支仅加"换设备重试"、锚点未修；
- **修复（harden-pif.sh 新增 S1 seed-compat 三补丁，全部带独立守卫与断言）**：S1a 锚点失败时回退取 JSON 中**最新构建对象**（tac 反转后 releaseCandidateName/buildId 最先出现）；S1b 工厂镜像 URL 从最新对象直接提取（供 Last-Modified 日期估算）；S1c 从 RC 名派生 canary-id（`CP41.260828.004.A8` → `2026-08`，供公告页月度查找，实测命中 `2026-08-05`）；
- **端到端实证**：对真实 yogi_beta JSON 提取出 ID=`CP41.260828.004.A8`、INCREMENTAL=`16319058`、FINGERPRINT=`google/yogi_beta/yogi:CANARY/CP41.260828.004.A8/16319058:user/release-keys`、SECURITY_PATCH=`2026-08-05`。

## 排期（未在本版修复，逐条记录于回应文档）

- P1：L9 卸载前备份用户 keybox、L10 align_patch_level 调用点、L7 apps.js 包名正则、M6 JSON 双引号转义、L11 debug 升级路径、种子缺失 fail-loud（M5 余项）；
- P2：M3 sepolicy 收窄、M4 CI pin SHA + 产物 sha256、M10、L12 NOTICE 更正、L14 -m 路径知情说明。（M15/上游控制台已在复核响应中移除随包，见上）

## 版本

- versions.env：v3.2.2 → **v3.2.3**（基线 20260915）。

# v1.0.0 —— 首个公开发布

> 本项目在此前的内部开发序列中使用 v1.0.0–v3.2.3 版本号（完整历史见上方各节），
> 对外公开发布自 v1.0.0 起。

- Aegis Fusion 首个公开发布的完整包：TEE 证明伪装（软件 keybox）+ 指纹伪装（PIFork）
  + Keybox 自动管理 + BL/环境隐藏，一次刷入四合一；
- 内含截至本版的全部安全审计处置（r1–r8 九轮 + 产物级核验）：
  C1（MITM→root RCE）、H1/N1（设备标识脱敏）、R8-4（开机清 keybox）、
  R8-5（卸载残留属性）、L14（设备派生数据出网）、S1（种子烤入）等全部修复；
- 质量保障：九轮审查 + 产物级核验（30/0）+ 真机验证 + 恶意软件指标专项扫描
  （域名/外发行为/提权/载荷全负）；
- 已知知情项：M3 sepolicy 范围、L10 轮换后重启对齐、R7-1 内置种子共享
  （下一版改为安装时随机抓取）、L9 卸载提示——详见 docs/security-audit-OPEN-ITEMS.md。

# v1.0.1

- **引擎状态在禁用日志的设备上不再永远"未知"**（真机发现，新增补丁 0007）：部分 ROM（含作者测试机）整机关闭 logcat，而引擎判定的全部信号原本都经 logcat 落盘——导致 WebUI 的 keybox 灯永远无法显示"引擎已加载"。现在控制守护进程在内存记录最近一次推送/应答并经管理套件 `/status` 暴露，判定在持久日志为空时自动改走该套接字通道（持久日志仍是主源）；`keybox-fetch` 的部署校验同样接受该通道，不再"无判定直接放行"。
- **keybox 刷新节拍改为继承**（行为变更）：原先每次开机重置计数并强制刷新一次；现在以"上次成功刷新时间"为锚点——重启/升级不再强制刷新，WebUI 手动刷新会重新起算节拍，深度睡眠导致的计时偏差一并消除。新装设备仍在开机后首次抓取；离线失败不盖时间戳，每小时重试。
- **判定失效锚点改用内容哈希**：同一 keybox 被同字节重写（实体化符号链接、恢复备份、重部署同载荷、更新重拷）不再被误判为"待引擎确认"；开机顺序修正（keybox 实体化先于判定记录）+ 每小时自动收敛——卡住的状态无需重启即可自愈。
- **指纹来源对"升级继承"的身份给出诚实话术**：旧版本安装、来源未记录的身份显示"已有身份（升级前继承，来源未记录）"与操作提示，不再显示裸文件路径。
- **安装界面文案与真实设置一致**：自动获取周期读取 WebUI 的实际设置（不再硬编码 24 小时）；选择"关闭"时明示"自动获取已关闭"；检测到已有安装时明示"保留你的 keybox 与 WebUI 设置，本次未覆盖"。
- **受保护应用管理打开不再白屏**：先绘制界面与"正在读取应用列表…"占位，让出一帧后再枚举应用（此前在枚举完成前整页空白，体感像卡死）。
- **安装期 `TEE_DIR` 未定义修复**（上一版引入）：该变量缺失曾使"已有身份守卫"恒真、来源标记被写到根目录；现已定义，并新增通用闸门断言（任何引用该变量的出货脚本必须自行定义）。
- **引擎调用可移植性修复**：一处调用直接执行模块脚本，而脚本 shebang 是 Android 专用路径——在非 Android 环境（CI / Linux）会以 rc=126 失败并使引擎校验静默降级；现统一经 `sh` 调用，并全仓扫描同类调用点。
- **构建载荷提示**：补丁 0007 重编译了控制守护进程 dex，本版编译载荷不再与 v1.0.0 逐位一致（原生库 / 注入器 / Zygisk 载荷 / sepolicy 等 10 项中 9 项仍逐位一致）；同时清除残留旧项目名（含 dex 字符串池）。
- **安装时抓取本机专属指纹**（审计 R7-1 实施，作者定稿设计）：手动刷入模块时尝试一次（约 20 秒上限）随机抓取一份本机专属身份，成功即写入包内、首启生效（首启零网络依赖）；离线 / 失败 / 超时零中断回退包内种子，安装界面给出明示与安抚文案；用户自带的 `custom.pif.prop` 始终最高优先、完全跳过该步骤。
- **包内种子不再长期共享**（R7-1 续）：种子是"同批安装共享同一身份"，现在其轮换期限被置为即刻——首个联网成功的 tick（开机或每小时）即自动随机替换为设备专属身份，无感、仅 debug.log 留痕；离线时种子继续工作，不产生空窗。
- **WebUI 指纹来源细分**（R7-1 续）：详情区显示 本机专属（安装时 / 运行时随机抓取）或 包内种子（保底中）+ 型号，并给出对应操作提示；不新增按钮，手动入口仍是管理器 ⚡ 操作按钮（单一已审计路径）。
- **补丁日期同启动对齐**（审计 L10 功能部分）：轮换后不再等下次重启——开机 `pif-sync` 后与每小时 tick 的 `pif-sync` 后各补一次 `align_patch_level`（`resetprop_if_diff` 仅在真变化时写入）。
- **CI 供应链钉定**（审计 M4 剩余部分）：所有第三方 action 由可变 tag 改为完整 commit SHA 钉定（checkout / cache / upload-artifact 的 v4；setup-java 因上游弃用 v4 而迁至 v5 并钉定），仓库内记录更新流程。
- 质量保障：产物闸门 **49/0**（新增内容哈希锚点 / 开机顺序 / 套接字兜底 / 间隔继承 / 安装文案等断言）、`test-keybox-fetch` 新增端到端「部署 → 套接字验证」用例，九套回归全绿（webui 109 / logs 92 / apps 89 / engine-verdict 31 / interval-rule 19 / pif-fetch 87 / pif-sync 52 / keybox-check 21 / mask-ids 22）+ 可复现构建管线（引擎 pin / NDK / BoringSSL / Cargo.lock / Rust 工具链五重钉定）。
