# 管理层逻辑契约（重写输入）

**用途**：本变体「只取逻辑，全部重写」（`GAP-AND-ROADMAP.md` §12）。本文把管理层的**逻辑**逐脚本抽出来，作为 Rust 重写的输入。
**配套**：`CONTRACT-verdict-keybox.md`（verdict / keybox 两条线）、`CONTRACT-webui.md`（UI 功能面）、`TEST-INVENTORY.md`（测试接缝与去留）。

**状态**：**6 个脚本全部完成**（`fusion_func` §1 · `pif-fetch` §2 · `pif-sync` §3 · `apps-sync` §4 · `service` §5 · `customize` + `post-fs-data.fusion` §6）。
**原则**：只记**行为与契约**，不抄 shell 实现；同时把抽的过程里发现的**缺陷与不一致**标出来（新实现应当修掉，不要原样继承）。

---

## 1. `fusion_func.sh` —— 公共库（96 行，**已完整抽取**）

被 `post-fs-data.fusion.sh` 与 `service.sh` 以 `. "$MODPATH"/fusion_func.sh` 引用。
⚠️ 注意命名：**根级 `common_func.sh` 属于 PIF 载荷**（它的脚本会不加修改地 source），所以 Fusion 自己的助手必须叫 `fusion_func.sh`。
`assemble.sh` 有断言强制这一点（`$OVERLAY/common_func.sh` 若存在即构建失败）。

### 1.1 副作用：PATH 前置

把 `/data/adb/ksu/bin`、`/data/adb/ap/bin` 加到 `PATH` 最前（若存在且尚未在内）。
理由：KernelSU / APatch 各自带 `resetprop`，后面的助手依赖它。

### 1.2 四个助手

| 函数 | 签名 | 行为 |
|---|---|---|
| `resetprop_if_diff` | `<prop> <expected>` | 当前值**为空**或**已等于** expected → **直接返回**；否则 `resetprop -n <prop> <expected>` |
| `resetprop_if_match` | `<prop> <substring> <new_value>` | 仅当当前值**包含** `<substring>` 时 `resetprop -n` 改写 |
| `delprop_if_exist` | `<prop>` | 属性存在（`resetprop` 取值非空）则 `resetprop --delete` |
| `align_patch_level` | — | 见 §1.3 |

**`resetprop_if_diff` 的关键语义（audit N16，刻意为之）**：
**属性缺失时跳过，不创建。** 理由：调用方要处理的属性（BL/verified-boot 状态、补丁日期）在所有有意义的设备上都存在；
**凭空造一个 OEM 从未写入的属性本身就是异常信号**（例如 bootloader 从未写过的 `verifiedbootstate`）。
缺失时诚实的语义是「无需对齐」，而不是「编一个值」。

### 1.3 `align_patch_level` —— 把全局补丁日期对齐到 TEE 档案里**被证明的**值

**为什么存在**：R4 语义（Round 12 形式化）。AlwaysStrong v1.0.4 修的是同一个问题 ——「让系统安全补丁日期等于被证明的那个」。

**读值（`config.json` 的 `patchLevel.system`）**，两级：
1. 对象形态：`"patchLevel":{"system":"<值>"}` → 取 `system`；
2. **遗留形态**：`"patchLevel":"YYYY-MM-DD"` 纯字符串 → 也接受（防手改配置被静默跳过；`pif-sync` 会把这种形态改写成对象）。

**取值判定**：
- 形状是 `YYYY-MM-DD` → 采用；
- 字面量 `today` → 用**当天日期**；
- 其它一律 → **直接返回，不做任何写入**。

**写入**：`resetprop_if_diff` 依次写 `ro.build.version.security_patch` 与 `ro.vendor.build.security_patch`。
（注意：第二个属性名是 `ro.vendor.**build.security_patch**`，与 WebUI 探针里读的 `ro.vendor.build.version.security_patch` **不是同一个**，不要"顺手统一"。）

**调用点：三处**（audit L10，2026-09-19 闭环）
1. `post-fs-data.fusion.sh` —— 最早，对齐 AS 的 `sync_patch.sh` 开机行为；
2. `service.sh` —— 启动阶段 `pif-sync` 之后；
3. `service.sh` —— 每小时 tick 循环里的 `pif-sync` 之后。
> 三处的意义：**档案轮换后能在同一次开机内重新对齐**这些属性，不必等下次重启。

**时间戳兜底（值得重写时保留的细节）**：
它会从 post-fs-data 被调用，此时 RTC 可能还没设置，裸 `date` 会打出 `1970-…` 这种读起来像乱序的时间戳。
所以代码显式判断：**年号不在 `19xx` / `2000-2019` 区间时，把时间戳替换成 `boot-early (RTC 未就绪)`** —— 命名条件，而不是打印一个不是时间的时间。

**调试输出**：仅当 `$_TEE/.debug` 存在时，追写 `$_TEE/debug.log`。

### 1.4 ⚠️ 缺陷：本文件**不遵守 `TEE_DIR` 覆盖约定**

`align_patch_level` 里写死了 `_TEE=/data/adb/teesim`，而不是其它脚本统一的 `TEE_DIR="${AEGIS_TEE_DIR:-/data/adb/teesim}"`。
后果：测试无法把这个文件的数据目录重定向（`TEST-INVENTORY.md` §2 的 21 个注入点在它身上失效）。
重写时应改为遵守同一套注入点 —— 顺带让 `align_patch_level` 变成可测的。

---

## 2. `pif-fetch.sh`（509 行，**已完整抽取**）

**一句话**：为捆绑的 PIF 载荷**自动生成 / 轮换指纹**。PIFork 故意不带指纹（公开的几天内就被封），没有这个脚本用户就得自己去找。

### 2.1 所有权三条规则（marker 文件是全部要害）

| 状态 | 行为 |
|---|---|
| 有 `custom.pif.prop`/`.json`，**无**我们的 marker | **用户提供 → 永不触碰。用户的私有指纹永远胜出** |
| 有指纹，**有** marker | 自动生成 → 临近到期就重新生成（Canary 实测约 6 周寿命，我们按 **14 天**轮换留足余量） |
| 完全没有 | 立即生成 |

### 2.2 关键路径与数据文件

| 路径 | 用途 |
|---|---|
| `$MODDIR/custom.pif.{prop,json}` | **工作副本**（PIFork 读这个） |
| **`$TEE_DIR/pif-master/`** | **durable master** —— 模块更新/重刷会清空整个模块目录，`/data/adb/teesim` 能存活 |
| `$MODDIR/.pif-auto` | 所有权 marker，**两行**：`第1行=出生 epoch`、`第2行=到期感知轮换截止` |
| `$TEE_DIR/.pif-source` | 来源：`user` / `seed` / `runtime-fetch` / `install-fetch` / `legacy` |
| `$MODDIR/pif_seed.prop` + `pif_seed.auto` | CI 烘进来的种子指纹 + 其构建 epoch |
| `$TEE_DIR/pif-proxy.conf` / `pif-proxy.auto` | 手配代理 / 自动探测记忆的代理（与 `keybox-fetch` **共享**） |
| `$TEE_DIR/pif-fetch.last` | 生成器的输出（诊断用） |

### 2.3 日期运算：**纯 shell 整数，刻意不用外部 `date`**

`expiry_epoch` 用 Fliegel–Van Flandern JDN 自己算 epoch。理由（源码原话）：设备上的 `date` applet（toybox / busybox / GNU）解析格式各不相同，**这绝不能成为轮换时钟坏掉的原因**。
拒绝一切非 `YYYY-MM-DD` 的输入（含 autopif4 的 `"Unknown"` 占位）→ 调用方回退固定 14 天。

**⚠️ 一个必须原样保留的坑**：去前导零是**手写循环**做的，因为
- `$((10#09))`（bash/ksh 的 base# 语法）在 **dash 下是语法错误**；
- `$(( 09 ))` 是**非法八进制**。
> CI 的 `/bin/sh` 是 **dash**，而 Git Bash 的 `sh` 是 bash —— 所以这个 bug「本地过、CI 挂」（源码注明：exact 现象是到期感知的 deadline 在 CI 上静默回退成 14 天）。

`rotation_deadline` = **`min(估算到期 − 3 天, 出生 + 14 天)`**，其中到期来自生成器自己写在 prop 里的 `# Estimated Expiry: YYYY-MM-DD` 注释行 —— **从我们自己的文件读，从不联网**（每 tick 零额外开销）。

### 2.4 恢复遍历（restore pass）—— 起因是一次实机事故

模块目录丢了指纹（更新/重刷重置）但 durable master 还在时，**先还原**：工作副本 + `.pif-auto` marker + **`.pif-source` provenance**，然后再往下走检测。

> 事故（2026-09-08，源码原文）：重刷在开机时抹掉了 `custom.pif.prop` + `.pif-auto`，`pif-sync` 于是把 TEE 身份回滚成真机，**设备又变一绿**。

`mirror_master <file>` 在**每个决策点**都跑（够便宜）：同步文件、marker、provenance 三样到 master。

### 2.5 种子指纹（v3.2.1）—— 一个刻意设计的「立即过期」

`assemble.sh` 在 CI runner 上烘一个新鲜指纹进 zip，`pif_seed.auto`（构建时写的 epoch）启动 14 天时钟。
目的：全新安装**第一天就有可用身份**，没有"首次成功抓取之前的空窗"（3.2.0 用户曾有几小时没指纹）。

两条容易做错的规则：
1. **`pif_seed.prop` 刻意不在指纹检测列表里** —— 未部署的 seed **绝不能冒充用户指纹**。
2. **R7-1：seed 不能坐满 14 天。** 它是**共享身份**（装这个包的每个人都带同一个 model），所以轮换截止直接设成**现在** —— 第一个网络可用的 tick 就用设备专属的随机抓取把它换掉。在那之前 seed 保持设备可用，而**替换是静默的**（只写 debug.log）。

**Audit M5（fail-loud）**：包可能**没有** seed（构建期抓取失败时 `assemble.sh` 只警告不失败）。以前这与"任何空状态"无法区分——用户看到"没指纹 / PI 只有 BASIC"，日志里零原因。现在**显式命名原因**。

### 2.6 Provenance 与用户指纹

- 用户指纹 → `mirror_master` + `.pif-source` 写 `user` + **退出**（永久放手）。
- **F-11 回填**：身份创建于 `.pif-source` 存在之前（从「安装期抓取把路径写到文件系统根」的构建升级上来）→ 标为 `legacy`，WebUI 显示「已有身份（升级前继承，来源未记录）」而不是裸路径。**只会触发一次**。

### 2.7 轮换判定与「绝不预先删除」

- marker **第 2 行**（有则）是到期感知的 deadline；**单行 marker**（旧格式或写入时解析失败）保持固定 14 天 —— **永不死路，只是余量更宽**。
- **刻意不在生成前删除旧指纹。** 生成器只在**每次网络抓取都成功之后**才写 `custom.pif.prop`，所以失败的一轮会让旧指纹（及其 marker）原封不动 —— 设备保持一个可用身份，下个 tick 直接重试。
  > 先删后生成 = 一次坏网络的轮换让设备**完全没有指纹**（2026-09-08 实机：轮换 → wget reset → 一绿）。

### 2.8 生成器调用与**成功判定**

- 命令：`autopif4.sh --strong`（在 `$MODDIR` 里跑，往自己目录写 `custom.pif.prop`），需 root + 网络。
- 每次尝试硬上限 **`timeout 300`**；最坏 `ATTEMPTS × 300s`（默认 3×300 = **15 分钟**），仍远低于每小时循环周期 ⇒ **不会堆积**。
- `ATTEMPTS=3` / `WAIT=20`（v3.2.1：一次/tick 意味着一次不稳定路由就烧掉整整一小时）。
- **成功 = `rc == 0` 且存在非空的指纹文件。**
  > **文件本身不是证据**（源码原话）：既然不再预先删旧指纹，失败后磁盘上的文件只是**旧幸存者**；把它当新输出会**错误地重启轮换时钟**，让一个陈旧身份续命。

### 2.9 代理：三级来源 + 一次「无条件 unset」的教训

**来源优先级**：`AEGIS_PIF_PROXY`（测试）→ `pif-proxy.conf` 首行 → （Round 2）`pif-proxy.auto`。

- 代理**只在生成器循环周围** export，之后立刻 unset —— `pif-sync` 及其后的一切都无代理运行。
- 用 **`export` 而不是 `env VAR=...` 前缀** —— env 前缀在 Git Bash/MSYS 上见过**静默 no-op**。
- 代理值是**敌意输入**（它进入 root shell 的环境）：只接受保守的 URL/host:port charset，含 shell 元字符即拒绝并告警。
- **⚠️ Audit N10：无条件 `unset http_proxy https_proxy`**，然后才显式重新 export 配置的代理。
  旧写法是条件式（`[ -n "$PX" ] && unset …`），只在配置了代理时才清理 —— 于是**从调用环境继承来的代理会静默把"直接"这一轮变成走代理**，破坏整条阶梯的判别力（也让生成器日志里 `proxy=none|none` 的自述变成谎话）。

### 2.10 Round 2：自动代理回退（默认开）

Round 1 直接失败且**未配置**代理时：
1. 若 `pif-proxy.auto` 有记忆值 → 先用它；
2. 否则探测常见本地代理端口 **`7890 7897 10808 10809 2334 2080`**，把赢家写进 `pif-proxy.auto`（抗重刷）；
3. 通过它**重跑整轮**；
4. 若记忆的代理已失效（VPN 关了 / 端口变了）→ **删掉 `pif-proxy.auto`**，让下个 tick 重新探测，而不是重试一具尸体。

**为什么默认开是安全的**：健康的直连网络根本走不到这里（Round 1 就成功），探测对其他人**零成本** —— 而硬编码一个默认端口就不安全。**手动创建的 `pif-proxy.conf` 永远胜过自动探测的。**

**`probe_port` 用真实请求验证**（不是只做 TCP 连接），并且：
- **Audit L2**：探测 **GitHub 本身**（`https://github.com/robots.txt`，200 且无需认证），**不是第三方搜索域** —— 请求要经候选代理发出，就该瞄准生成器端点所在的基础设施。**请求不含任何设备数据。**
- **Audit N9**：**完整 GET，不用 `--spider`** —— busybox wget 不支持 `--spider`，会让这个探测在那些设备上**永远失败**、自动代理救援路径**不可达**。

### 2.11 失败时的「可发现性」提示（v3.2.1）

生成失败且未配代理时，往 **`pif-fetch.log`**（WebUI 日志页与诊断导出都看这个文件 —— 用户会看的地方）写一条 hint：把本地代理地址写进 `pif-proxy.conf`。
这条正是分隧道 VPN / 受限网络的用户会命中、但完全不知道有解法的故障签名。

### 2.12 成功后的落盘顺序（有一步失败必须**显式告警**）

1. 轮换时删掉**不同名的** legacy 文件（**仅在新文件已存在之后**）
2. `date +%s > $MARKER`（出生时间）
3. 计算并写入第 2 行 deadline（到期感知）
4. `.pif-source` 写 `runtime-fetch`
5. **marker 写失败 → 显式告警**：「指纹将被当作用户提供」（无 marker 就永不轮换；某些 KSU 挂载器下模块目录只读会命中这条）
6. `chmod 0600`
7. `mirror_master`
8. **调用 `pif-sync.sh`**（`$AEGIS_PIF_SYNC` 可覆盖）—— 它自己检测真实变化并 bounce daemon + DroidGuard

### 2.13 总开关

`$TEE_DIR/.pif-off` 存在 → 记录日志、**直接退出**（不抓取不轮换）。`pif-sync` 会把档案恢复为**真机真实身份** —— 即独立 TEESimulator 的状态。
用途（2026-09-08）：受控实验的杠杆 —— 同一台设备同一个 keybox，独立模块过 DEVICE 而融合模块只到 BASIC；把 PIF 半边停掉，就能把剩余差异从等式里剔除。**与 `.pif-sync-off` 是两个不同粒度**（见 §3.3）。

## 3. `pif-sync.sh`（282 行，**已完整抽取**）

**一句话**：把**活跃的 PIF 指纹镜像进 TEE 档案**，使引擎的证明与 DroidGuard 看到的设备一致。

### 3.1 方向被刻意反转过（v3.1.0 / Round 12）—— 不要"修正"回去

- **v3.0.13–v3.0.17 的方向是「保持档案为真实身份」**；
- **v3.1.0 反转为「档案跟随 PIF」**。依据是同一台 K70 上的对照：AlwaysStrong 的 config.json 档案带 **PIF 伪装后的 Pixel 身份**（generation 模式、`patchLevel.system` = pif 的 SECURITY_PATCH），三绿；而本栈用真实身份档案只有一绿。
- v3.0.12 时代的 GMS `-66` 被解释为**缺少 uid pins + 开关全关的残留**，而不是"同步身份"本身导致的。

> 这是**证据驱动的方向反转**，不是遗漏。重写时必须保留这个方向。

**⚠️ 但这个方向有一个前提，必须显式化（原文档里是隐式的）**：

倒查 `docs/one-green-postmortem.md` §3.6 会发现，同一个问题历史上**反向走过三次**：
v3.0.12 同步身份 → **v3.0.13 撤回**（依据读 AOSP `system/keymint` 源码得出的结论：
TA 的 ID 门禁把 keystore2 请求来的**真机 ID** 与 profile 比对，且门禁通过后**证书编码的是请求里的真机 ID、profile 值从不出现在证书里** ⇒ 「同步 Pixel 身份从来不可能让 attestation 变 Pixel，唯一效果就是弄挂整个硬件证明请求」）
→ v3.1.0 又反转为同步（Round 12 的 AS 对照）。

两次结论都对，因为**中间多了一个引擎补丁 0005**（`0005-attest-id-retarget.patch`）：
它把请求里的 `ATTESTATION_ID_*` **改写为 profile 值**（profile 没有的 ID 丢弃标签而非失败；走真机 HAL 的路径不改写），门禁因此可过。

⇒ **「档案跟随 PIF」的有效前提是补丁 0005 已生效**，顺序不能颠倒：

```
0005 落在引擎里  →  档案跟随 PIF  →  三绿
```

**重写时的具体风险**：若按本例实现了同步，而引擎侧没有 0005，检测类应用与 GMS 会立刻回到 `-66`。
所以重写实现里应当**显式检查/依赖这一点**（或至少在发布物验收里把「0005 是否在 payload 里」列成前置断言）。

### 3.2 三项职责

| # | 职责 | 关键约束 |
|---|---|---|
| 1 | 镜像 PIF 身份（`brand` / `device` / `product` / `manufacturer` / `model`）进 profile | 被证明的设备必须与 DroidGuard 看到的一致 |
| 2 | `patchLevel.system` 跟随 PIF 的 `SECURITY_PATCH`，且 `patchLevel` 必须是**对象形态** | **纯字符串会被 TEES 的 ConfigStore 静默丢弃** —— 它用 `optJSONObject()` 读，字符串形式解析成空对象 |
| 3 | 在我们**自己的** `custom.pif.prop` 里重新断言 STRONG spoof 标志 | autopif 类抓取器每次抓取都会把标志重置为弱默认值；Round 7 诊断里它们**全是 0**，那个状态下 DroidGuard 的运行时检查无论 TEE 半边做什么都过不了 |

**职责 3 的边界**：只改**我们自己的**载荷文件（`$ADB/modules/<本模块>/`）。standalone 的 PIF 模块保持对它自己 prop 的自主权。

### 3.3 三条回滚路径（互不相同，别合并）

| 触发 | 行为 |
|---|---|
| PIF 源消失（且 `.pif-synced` 存在） | **恢复真实身份**（`restore_real`），清 `.pif-synced` |
| `.pif-off`（且 `.pif-synced` 存在） | **恢复真实身份 + 真实补丁日期**（`system`/`vendor`/`boot` 三个子键），清 `.pif-synced` |
| `.pif-sync-off` | **只抑制 profile 镜像**；**载荷标志断言仍然跑** |

**第三条是事后复盘修的（v3.1.1）**：它原来会 abort 整个脚本，结果一个残留的 `.pif-sync-off` 让 Round 12 的健康检查**从未运行过**。
「断言自己载荷里的标志」是对**我们自己发布物**的健康检查，不是 profile 改动 —— 所以必须无条件跑，否则 DroidGuard 会一直看到一个"已禁用构建"的设备。

### 3.4 PIF 源探测顺序（9 个候选，第一个**非空**者胜）

```
$ADB/modules/<本模块>/custom.pif.prop
$ADB/modules/<本模块>/custom.pif.json
$ADB/pif.json                                     ← 遗留标准路径
$ADB/modules/playintegrityfix/custom.pif.prop
$ADB/modules/playintegrityfix/custom.pif.json
$ADB/modules/playintegrityfix/pif.json
$ADB/modules/playintegrityfork/pif.json
$ADB/modules/Integrity-Box/pif.json
$ADB/modules/tricky_store/pif.json
```
后 4 个是**其它模块**的布局，为「用户偏爱独立指纹模块」的场景保留 —— 同步要保证两半一致。

### 3.5 字段读取与回退

`pget` 同时读两种格式：`key=value` 行（`custom.pif.prop`）与 legacy JSON（`pif.json` / `custom.pif.json`）。

身份字段缺失时**从 `FINGERPRINT` 的 `/` 分量回退**（与 AS 的 `teesim.sh` 同法）：
```
google/caiman_beta/caiman:13/...  →  brand=google, device=caiman, product=caiman_beta
```
`SECURITY_PATCH` 若不是 `YYYY-MM-DD` 形状 → 退化为字面量 **`today`**（TEES 解析为**启动日期**）。

### 3.6 `restore_real` 的属性映射（有个踩过的坑）

| 字段 | 属性 |
|---|---|
| `brand` | `ro.product.brand` |
| `device` | `ro.product.device` |
| `product` | **`ro.product.name`**（回退 `ro.build.product`） |
| `manufacturer` | `ro.product.manufacturer` |
| `model` | `ro.product.model` |

> ⚠️ `product` 取 `ro.product.name` —— Android **没有** `ro.product.product` 这个属性（v3.0.15 修的）。
> 这组属性重要是因为 **keystore2（native daemon）从这几个属性填充 `ATTESTATION_ID_*` 请求参数**。

### 3.7 写入：值转义规则（三层，顺序不可换）

`set_id` 写 JSON 字符串值时，值里的 `"` 必须落盘为 `\"`、`\` 必须落盘为 `\\`；
而 **sed 的 replacement 模式还会吃掉一层反斜杠**（`\"` 会被还原成裸引号），所以每个反斜杠都要在转义步骤里**预先翻倍**：

```
`\` → 4 个反斜杠        `"` → 2 个反斜杠 + 引号        `&` `/` → 前置反斜杠（分隔符）
```
**顺序不可换**：引号新增的反斜杠不能再被第一遍翻倍。日志里记的是**原始值**，不是转义后的。

`ensure_patch_object` 用同一套转义把 legacy 字符串改写成对象形态（`system` = 目标值，`vendor`/`boot` = `YYYY-MM-05` 占位）。
`assert_flags` 写的是 **prop 文件而非 JSON** —— **不加** JSON 式引号转义（加了反而会往值里塞反斜杠），只处理 `&` / `/` / `\`。

### 3.8 标志断言

| 键 | 默认值 |
|---|---|
| `spoofBuild` | `1` |
| `spoofProps` | `1` |
| `spoofVendingFinger` | `1` |
| `spoofProvider` | `0` |

每键可被 `$TEE_DIR/spoof.conf` 的 `key=value` 行覆盖（AS 同款）。
键已在载荷里 → 原地改写；不存在 → 追加。

### 3.9 改动的后果（只有真变了才发生）

`changed` 标记为 1 时（**值相等不算改动**，幂等）：
1. `kill teesim`（`service.sh` 的重生循环 ~2s 内拉起，重读配置并重新推送）
2. `kill com.google.android.gms.unstable` —— **回收 DroidGuard 的缓存会话**，强制它重读（PIF 伪装后的）属性，而不是从旧快照回答
3. 写 `$TEE_DIR/.gms-recycle` 时间戳

**`changed` 也包含「标志被重新断言」**（DroidGuard 必须重启才能看到变化后的 Build 视图）。

### 3.10 入口守卫与日志

- **`[ -f "$CFG" ] || exit 0`** —— 没有 `config.json` 就**静默退出**（`test-apps-sync.sh` 有对应用例）
- `pif-sync.log` 超 400 行裁到 200（与 `keybox-fetch.log` 同策略）
- `AEGIS_PROP_FILE` 存在时 `get_prop` 改为从该 JSON 读（测试接缝）

### 3.11 ⚠️ 重写时必须显式决定的一件事：**改用真正的 JSON 解析会改变落盘字节**

现状**所有 JSON 编辑都是 `sed`/`grep` 正则**（`set_id`、`ensure_patch_object`、`pget`），并且**依赖一些脆弱假设** —— 例如注释里明说：`patchLevel` 的 `system`/`vendor`/`boot` 子键名必须**只出现在 `patchLevel` 对象内部**，否则替换会打错地方。

Rust 里用 `serde_json` 会天然修掉这整类脆弱性，但**输出字节会变**（空白、键序、转义形式、数字格式）。这**不是**纯内部变化：

- ✅ 可以接受的依据：ConfigStore 只要求**合法 JSON**；我们的 shell 实现本来就会重排空白。
- ❗ 必须验证的：改完之后**引擎仍能读、仍能推送**（真机 `engine-verdict.sh once`）。
- ❗ 必须显式决定的：是否保持"只动目标字段、其它字节原样"的现状语义（那需要保住顺序的 JSON 库，或做定点编辑而非整体重序列化）。

**建议**：采用「**保留顺序的定点编辑**」而非整体重序列化 —— 既拿到 JSON 的正确性，又不动其它字节。这样 `config.json` 的其余部分（用户手写的字段、注释态内容）不会被我们"顺手格式化"。

## 4. `apps-sync.sh`（301 行，**已完整抽取**）

**一句话**：保持受保护作用域整洁，并**一次性播种 GMS 进作用域**。

> **自 v2.2.5，「自动添加新安装」这一半已退役** —— TEES 有原生的 per-profile `autoIncludeNewApps` 字段（只管未来安装、跨所有 Android 用户生效、**永不污染 apps 数组**），WebUI 的开关现在直接驱动那个字段。
> 本脚本只留两个 **TEES 自己不做**的 janitor 职责。

### 4.1 两条刻意的约束（不要"优化"掉）

| 约束 | 理由（源码原文） |
|---|---|
| **只编辑单 profile 的 `config.json`**；若存在多于一个 `apps` 数组（用户在高级控制台建了自定义 profile）→ **跳过而不猜** | 「猜错会把 keybox 错配」 |
| 修剪**比对完整包列表（含系统应用）**，且**只有通过与其它 pm 读取同等的硬校验**才进行 | 「**一个失败的 `pm` banner 绝不能驱动删除**」 |

### 4.2 环境前提

- **busybox awk 是 Android 上唯一可靠的 JSON 切片工具**（toybox 在很多构建上**没有 awk**）。用与 `keybox-fetch.sh` 相同的 manager busybox 链（ksu → ap → magisk → PATH）；**找不到就 `exit 0`**。
- `[ -f "$CONFIG" ] || exit 0` —— 没有 config 静默退出。
- `AEGIS_TEE_DIR` / `AEGIS_PKG_LIST` 为测试接缝。

### 4.3 单 profile 判定：**数出现次数，不是数行数**

```sh
N=$(tr -d "\n\r" < "$CONFIG" | grep -o '"apps"' | wc -l)   # 必须 == 1
```
> 如果按行 grep，一个**紧凑（单行）** 的 JSON 里含两个 profile 会被读成"单 profile"，然后被错改。

### 4.4 迁移：`autoIncludeNewApps` 的「权威字段」检查

legacy `$TEE_DIR/apps-auto-add` 标志文件 → 折进 profile 的 `autoIncludeNewApps=true`，然后删掉标志文件。

**关键细节**：判定「配置里已有该字段」时，**任何显式的 `autoIncludeNewApps` 值都算，不只是 `true`**。因为 WebUI 在用户**关掉**自动添加时写的是 `false`；
> 只 grep `true` 会把该字段**重新插回去** → **重复的 JSON 键 + 用户的「off」被静默回滚**（窗口期：开机到这次迁移运行之间）。

只有**完全缺该字段**的配置才会折进 legacy 标志。插入方式：先压平文件，再用 sed 插到 `"apps"` 之前，然后过 sanity check。

### 4.5 GMS 作用域播种（v3.0.1）—— **这就是「一绿元凶」**

**机制**：PI 的 DEVICE 判定由 GMS 里的 **DroidGuard** 产生 —— 它在硬件 keystore 里生成密钥并读回证明。
**GMS 不在 TEE 作用域 ⇒ 那个证明是「真机」的**（解锁 bootloader、无认证链）⇒ verdict **永远卡 BASIC，无论 keybox 多干净**。

**对照证据**：独立的 IB + TEES 拿 DEVICE，而融合版只有 BASIC —— 因为 **IB 自动 target GMS，而我们依赖用户自己去 apps 页找到它**。

**播种规则**：
- **每次安装只种一次**（marker `$TEE_DIR/.gms-scope-seeded`）⇒ 用户事后把它移除，**我们不会反复抢回来**。
- **marker 即使 gms 缺席、或已在作用域内，也会写** —— 因为每次运行都重检会与用户的刻意移除对抗。用户删掉 marker 即可重新播种。
- 插入用 busybox awk，处理两种形态：**空数组不插尾逗号**、非空数组前置并补逗号。

### 4.6 PI 核心三件套的 uid pin（Round 12）

**依据**：AS-TEESIM 的运行时配置在 K70 上三绿，它**在包名之外还把 PI 核心 pin 到它们的真实 uid**。

**为什么光靠包名不够**（源码原话）：**只靠包名 target 可能漏掉 GMS / Vending / GSF** —— 多用户、共享 uid、**启动期的解析时机** —— 于是 `generateKey` 落到真实 HAL。

| 项 | 行为 |
|---|---|
| 目标 | `com.google.android.gms`、`com.android.vending`、`com.google.android.gsf` |
| 只 pin 实际安装的 | 按 `packages.list` 判定 |
| uid 来源 | **`/data/system/packages.list`**（root 可读，**不需要 system_server**；`AEGIS_PKG_LIST` 可覆盖） |
| 每个应用产出 | **两条**：包名条目 + `"uid:N"` 条目 |
| 幂等 | 已存在的保留；用户仍可在 WebUI 删掉，但**下一个 tick 会回来** |
| 关闭方式 | 删 marker `$TEE_DIR/.uid-pins-off` |
| `packages.list` 读不到 | **干净跳过** —— 那 pass 既无法解析 uid、也无法做安装检查，而裸名字还会与下面的清理 pass 打架 |

### 4.7 清理 pass：硬校验是**必须**的

**历史事故（v2.2.0 现场报告）**：`pm list packages` **可能在 stdout 打文字 banner**
（例如 `cmd: Failure calling service package: Broken pipe (32)`）。
按空白切分会把 `cmd:`、`Failure`、`(32)` 这类 token 当作包名**灌进 `config.json` 的 apps 数组**，破坏 TEE daemon 的作用域解析。

⇒ **每一个驱动编辑的列表都必须通过严格包名过滤**：
```
^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$      # 点分、仅字母数字 + ._
```

**修剪规则**（三条，优先级不同）：

| 条目形态 | 处理 |
|---|---|
| `uid:N` | **永不修剪**（它们 pin PI 核心三件套） |
| `*@*`（带 user 后缀） | **只在无效时**修剪 —— 这里的 `pm list packages` **只报用户 0**，所以 `pkg@10` 很可能确实存在却不出现在列表里 |
| 其它 | 不在完整包列表里 → 移除（TEES 会永远保留死名字并只标记「未安装」） |

### 4.8 v3.1.7 的一次性清理：检测类应用排除机制**整个退役**

v3.1.6 曾每次运行把六个检测类应用（KeyAttestation / PIAC …）拉出作用域，记录到 `.detector-excluded`，以 `.keep-detectors` 为 opt-out。
**两者都已退役** —— 现在作用域**恰好等于用户勾选的内容**，而它们当初在规避的 `-66`，真正的修复在引擎侧：

> **上游补丁 0005** 在 TA 的 `CANNOT_ATTEST_IDS` 门禁看到之前，把请求里的 `ATTESTATION_ID_*` 标签**改写为 profile 的身份** —— 于是作用域内做 ID 证明的检测类应用是**被服务**而不是被拒绝。

遗留的 marker 文件会让 WebUI 上一个陈旧提示继续活着 ⇒ **响亮点地删掉一次**。

### 4.9 重写的落盘方式与安全网

- **重写用 awk 重建 apps 数组，其余字节保持不变**（先压平）；**找不到 apps 数组就原样打印，绝不截断**。
- 每次编辑**之后**都过 sanity check：临时文件非空 + 含 `"apps"` + 含 `"profiles"`；失败则删临时文件、记 ERROR，**原文件不动**。
- 日志要**说清为什么**而不只是做了什么 —— 裸的 `cleaned, removed:xxx` 读起来像随机抖动。（前缀保留是为了 grep/向后兼容。）

### 4.10 ⚠️ 与 §3.11 相同的重写决策

本脚本的全部 JSON 编辑同样是 **awk / sed 正则**（插入、重建数组、压平），因此 `CONTRACT-management.md` §3.11 的结论同样适用：
**改用 serde 会修掉整类脆弱性，但落盘字节会变** ⇒ 建议「**保留顺序的定点编辑**」，并注意本脚本特有的两条约束：
1. **多 profile 时宁可不动**（§4.1）—— 用 serde 也很容易先解析再写回，那会**破坏用户的紧凑布局**；定点编辑天然符合这条；
2. **`uid:N` 与 `@user` 后缀不是包名**，不能被"规范化"掉。

## 5. `service.sh`（492 行，**已完整抽取**）

**一句话**：开机服务 —— 环境隐藏 + 定时任务编排 + daemon 启动与重生。

### 5.1 v3.x 的五层组合

| # | 层 | 实现 |
|---|---|---|
| 1 | **环境 / BL 隐藏**（"box" 层） | 基于 `resetprop` 的 bootloader / verified-boot / 保修 / 构建信号伪装（合并自 Integrity-Box 与 PIF 的早期启动属性修复） |
| 2 | 指纹半的**晚启动属性重置** | source 捆绑的 PIF 服务脚本 `pif-service.sh` |
| 3 | 定时社区 keybox 刷新 | `keybox-fetch.sh`（每小时 tick） |
| 4 | 定时指纹生成 / 身份镜像 | `pif-fetch.sh` + `pif-sync.sh` |
| 5 | **TEESimulator 控制 daemon** | 启动 + 重生循环 |

顶部 source `$MODPATH/fusion_func.sh`。

### 5.2 ⚠️ 文件内的注释自相矛盾（重写时以代码为准）

`service.sh:25-33` 的注释写：
> 「`align_patch_level()` … **There is deliberately NO service-stage or hourly-tick call** (audit L10, 2026-09-16 — earlier comments here claimed both existed; **they never did**).」

但代码里 `align_patch_level` **有两处 service 阶段调用**：
- `service.sh:405` —— 每小时 tick 内、`pif-sync` 之后
- `service.sh:470` —— daemon 启动前

原因：**这段顶部注释是 2026-09-16 写的，而 L10 在 2026-09-19 被闭合了**（两处调用是后加的，代码注释里写着 `audit L10 closed (2026-09-19)`）。
`fusion_func.sh` 的注释是对的：「Called from **three places** … post-fs-data.fusion.sh (early), and service.sh **twice**」。

⇒ **重写时以「代码 + `fusion_func.sh` 的注释」为准，`service.sh` 顶部那段是陈旧的。** 这也提示：这个仓库的注释里混着不同时间的状态，**不能只看一处**。

### 5.3 早期启动：BL / verified-boot / 构建信号隐藏

用 `resetprop_if_diff`（**只在真正不同的时候写** —— 避免开机时唤醒 property_service 监听者上百次）。

| 组 | 内容 |
|---|---|
| **BL / VBMeta 核心** | `ro.boot.vbmeta.device_state=locked`、`vendor.boot.vbmeta.device_state=locked`、`ro.boot.verifiedbootstate=green`、`vendor.boot.verifiedbootstate=green`、`ro.boot.flash.locked=1`、`ro.boot.veritymode=enforcing`、`ro.secureboot.lockstate=locked`（MIUI） |
| 保修 / 调试 | `ro.boot.warranty_bit` / `ro.vendor.boot.warranty_bit` / `ro.vendor.warranty_bit` / `ro.warranty_bit` = 0；`ro.debuggable=0`、`ro.force.debuggable=0`、`ro.secure=1`、`ro.adb.secure=1`、`sys.oem_unlock_allowed=0`、`ro.oem_unlock_supported=0` |
| OEM 专属 | Realme ×2、OnePlus `ro.is_ever_orange=0` |
| **构建信号（遍历，非硬编码）** | `resetprop \| grep -oE 'ro.*.build.tags'` → `release-keys`；`'ro.*.build.type'` → `user` |
| 自定义 recovery 隐藏 | `ro.bootmode` / `ro.boot.bootmode` / `vendor.boot.bootmode` 含 `recovery` → `unknown`（用 `resetprop_if_match`） |

**Root-hiding 卫生**：Magisk DenyList 处于 enforce → 把 `com.google.android.gms` **移出** denylist；非 enforce 且装了 Shamiko 且未开 whitelist → 把 GMS（含 `.unstable`）与 Vending **加进去**。

### 5.4 `/proc/cmdline` 掩蔽（实验杠杆，默认关闭）

**原理（值得理解）**：`resetprop` 只改**属性区**，而 `/proc/cmdline` 是内核启动时组装的 **procfs 文件** —— 里面的 `androidboot.*` 项仍带**真实**的解锁/orange 状态，**任何属性修复都碰不到**。
> 源码称这是「**一绿缺口剩下的最强嫌疑**」：IB 的钩子层在**进程内**处理它，我们**用 bind mount 全局覆盖**。

- **opt-in**（marker `$TEE_DIR/.cmdline-spoof`），默认与纯上游**逐字节一致**。
- 做法：sed 把 5 个 `androidboot.*` 项改写为 locked/green（**其它启动参数保持真实**）→ 写 `cmdline.spoofed` → `mount -o bind` 到 `/proc/cmdline`。
- 已挂载则跳过（检查 `/proc/self/mountinfo` 是否含 `cmdline.spoofed`）。
- 失败（内核/命名空间限制）→ 记 debug，**真实 cmdline 保持可见**。

### 5.5 衍生 ROM 清理：隐藏 lineage 标记

`ro.product.vendor.name` 的 `lineage_*` 前缀剥掉；`vendor.camera.aux.packagelist` 与 `persist.vendor.camera.privapp.list` 里的 `org.lineageos.aperture` 去掉。

**理由（源码原文）**：Health HAL 的破绽是**属性名本身**（名字里带 "lineage"），不是运行的服务 —— 所以丢掉属性就能隐藏 ROM 标记，**而不破坏充电限流**。

### 5.6 ROM pixel-imitation 钩子：中和 **或** 清残留（v3.0.14）

**背景**：上游 PIFork 通过写 `persist.sys.*` 开关（**持久化 `-p`**）来中和自定义 ROM 的 `PropImitationHooks` / `PixelPropsUtils`。
**问题**：一旦写入，这些开关**让自身的触发条件永远为真**（自锁循环）、**在重刷/卸载后存活**，并且作为 `persist.sys.spoof` / `persist.sys.pixelprops` 的破绽留在 **world-readable 属性区**（2026-09-09：K70 上 5 次命中）。

**现在的语义（二分）**：

| 判定 | 行为 |
|---|---|
| **真 hook ROM**（build-prop 标记 / LeafOS 的 `gms_certified_props.json` / ROM 自己写的非空 `pihooks` 值） | 上游中和，**不变**（写 9 个 `pihooks`/`pixelprops`/`pp` 家族属性 + LeafOS 的 `persist.sys.spoof.gms=false`） |
| **其它一切** | 整个家族都算**残留** → **同时删除持久记录与内存副本**（`--delete` 清内存 + `-p --delete` 清 `persistent_properties` 记录，**让它下次开机不再复活**） |

`HOOK_ROM` 判定三项：`ro.aospa.version` / `net.pixelos.version` / `ro.afterlife.version`，或 `gms_certified_props.json` 存在，或 `pihooks` 值非空。
**重跑在干净后是 no-op。**

### 5.7 GMS 卫生：回收 DroidGuard（三条触发路径）

**为什么**：DroidGuard（`com.google.android.gms.unstable`）产生的正是 PI 读的设备判定，而**它的会话比我们的改变活得更久** —— 换 keybox / 指纹重同步 / 刷模块之后，缓存会话会继续用**旧**设备画面作答，直到进程被回收。
**对用户不可见**（进程按需重生）—— 这正是让模块「装上就能用」而不是「刷完还要手动杀 GMS 再测」的原因。

| # | 触发 | 位置 |
|---|---|---|
| 1 | 开机后约 **3 分钟**（等 daemon 与首次 keybox pass 稳定） | `service.sh:257-264` |
| 2 | **每次 keybox 部署** | 由 `keybox-fetch.sh` 的 `client_recycle` 做（daemon 自己会重推重证，**只有客户端需要推一下**） |
| 3 | **每 12 小时** | 每小时 tick 里的 `gcount >= 12` 计数 |

### 5.8 ⚠️ keybox 校验块与引擎 verdict 的**顺序契约**

**契约**：keybox 校验块必须留在**启动期引擎 verdict 之上**。`assemble.sh` 里的 `verify-artifact.sh` **断言这个顺序**。

**理由（源码原文）**：下面的 **symlink 实体化会重写 `keybox.xml`**，所以在此之前取的 verdict **一写下就过期**，而下次部署前没人会重取 —— WebUI 于是**永远停在「待引擎确认（keybox 刚变更）」**（现场报告：v3.2.3 → v1.0.1 升级后）。

| 块 | 行为 |
|---|---|
| **symlink 实体化** | **永不读穿符号链接** —— 目标能在我们脚下被换掉，而 TrickyStore 的工具**已知会写这种链接**。`cp -fL` 目标 → `mv` 覆盖 |
| **`keybox-check.sh` 通过** | 删 `.keybox-bad` |
| **失败** | 写 `keybox-bad.log`（含校验器的逐条理由）+ 记 epoch 到 `.keybox-bad` |
| **刻意非破坏性** | 与安装器不同（安装器会把被拒 keybox 移到一边，因为模块**可证明**无法与它工作），**启动绝不能碰用户数据** —— 只记录 verdict，让 WebUI / `engine-check.sh` / 定时抓取去行动 |

**启动期引擎 verdict**（在 keybox 块之后）：
- 先等日志里出现 `control: ack`（最多 `60 × 2s = 120s`）；
- `engine-verdict.sh once` 成功 → 记 debug；失败 → 取 `reason` **追加**到 `keybox-bad.log`。
- 为什么结构检查不够：它在 daemon 启动**之前**跑，无法知道唯一重要的事 —— **TA 能否真的从这个 keybox 构建 profile**。

### 5.9 每小时 tick 循环（先 `sleep 90` 等网络稳定）

```sh
iv=$(cat $TEE_DIR/keybox-refresh); 非数字 → 24
锚点 = .kb-last-fetch 的 mtime      # 最后一次【成功】的抓取
iv > 0 且 (now - lfts) >= iv*3600  → keybox-fetch.sh
keybox-fetch.sh --revcheck          # 每 tick 必跑（即使 iv=0）
verdict 收敛检查
pif-fetch.sh → pif-sync.sh → align_patch_level
gcount+1；到 12 → 回收 DroidGuard
sleep 3600
```

**四条设计要点**：

1. **继承锚点是 `.kb-last-fetch`**（updated / unchanged / adopted 都会盖章它）⇒ 计划**跨重启与升级存活**，WebUI 的一次手动抓取从那一刻**重新武装**，旧的"内存计数器深度睡眠漂移"问题消失。**无时间戳（全新安装）→ 立即到期**，保留了「开机后不久抓一次」的安全网。**失败永不盖章** ⇒ 离线设备每个 tick 都重试直到成功。
2. **`--revcheck` 每 tick 必跑**，**即使 `iv=0`（完整抓取已关闭）** —— WebUI 的「已被 Google 吊销?」本机判定读这个缓存，**不能因为完整抓取关闭就变陈旧**；`--revcheck` 只刷新缓存列表（脚本内 1h TTL）**从不碰 `keybox.xml`**。
3. **verdict 收敛（2026-09-19）**：记录下来的 verdict 锚定 keybox **内容**（sha256），之后任何重写 `keybox.xml` 的操作都会让它失效。这里做一次**廉价的读**（`engine-verdict.sh show`）—— state 不在 `ok|rejected|partial` 内就重取 `once`。
   ⇒ **每 tick 一次读让状态自愈**：`show` 在 verdict 与磁盘 keybox 匹配时是**静默**的，所以只有陈旧/缺失的 verdict 才付出重取成本。
4. **12h DroidGuard 回收**用 `gcount` 计数（AlwaysStrong 语义）。

### 5.10 scope janitor

`sleep 150` 后每 **300 秒**跑一次 `apps-sync.sh`（无条件跑是安全的 —— 它校验每次 pm 读取，且没事可清时 no-op）。

### 5.11 daemon 启动（顺序很重要）

1. **权限**：`chmod 0700 $TEE_DIR`、`chmod 0600 admin.token` ⇒ **admin socket 因此对其他应用不可达**。
2. **staging `teesim-uds`**：从 `$MODPATH/*/teesim-uds` 拷到固定 root-only 路径 `$TEE_DIR/teesim-uds`（`chmod 0700`）。
   > 为什么：让 WebUI 调用它时**无需知道模块的运行路径或设备 ABI**。安装后只有设备自己的 ABI 目录存活，所以那个 glob **只匹配一个文件**。**每次开机刷新** ⇒ 模块更新后总是 stage 当前版本。
3. **daemon 读 config 之前**必须完成 `pif-fetch.sh` → `pif-sync.sh` → `align_patch_level`：
   - 理由：DEVICE/STRONG 需要 **attestation 身份与 DroidGuard 的伪装指纹一致**；
   - **`pif-fetch` 必须先跑**（源码原文）：有指纹时它毫秒级 no-op，而**模块更新/重刷（重置模块目录）之后，它从 durable master 恢复工作副本** —— **没有它，`pif-sync` 会看到「没有指纹源」，并在开机时把 TEE 身份回滚成真机**。
4. **daemon 重生循环**：`: > daemon.log` 先清空 → `while true` 跑 daemon（追加）→ 记 `rc` → **超 200 KB 裁到 100 KB** → `sleep 2`。
   > **v3.1.2 的理由**：daemon 的 stdout/stderr 追加到**持久文件**。`SystemLogger` 走 logcat（**几分钟内轮转**），导致**崩溃循环的 daemon 完全不可见** —— 这正是项目花一天追的失败模式：「daemon 从未推送配置」而其它指标全健康。现在 stderr 上的 stack trace 被保留下来。

### 5.12 其它

- 若存在 zygisk payload（`zygisk/{arm64-v8a,x86_64,armeabi-v7a}.so`）→ source `pif-service.sh`（它自己 source 根级 `common_func.sh`，那是 PIF 载荷的助手，是 `fusion_func.sh` 的超集）。
- `resetprop -c` 在 hook 处理之后调一次（清属性缓存）。

## 6. `customize.sh`（427 行）+ `post-fs-data.fusion.sh`（17 行），**已完整抽取**

**一句话**：安装器 —— 安装期检查、禁用会双重挂钩的模块、迁移与收养用户资产、播种 TEE 配置、安装期一次有界指纹抓取。

### 6.1 i18n 与一个**曾经不存在**的变量

- **语言**：`persist.sys.locale` → 回退 `ro.product.locale`；**非 `zh*` 一律英文**。`msg <english> <chinese>` 双语法。
- **⚠️ `TEE_DIR` 的定义曾缺失**（review finding 2026-09-19，**由一次真实的 v3.2.3 → v1.0.1 升级安装抓到**）：
  寥寥几处 `"$TEE_DIR/..."` 会**静默指向 `/`** —— 因为 `mkdir -p ""` 是 no-op，而每个写都带 `2>/dev/null`。
  后果：**破坏了 R7-1 的 durable-master 守卫与 provenance marker**。现在与其它脚本统一：`TEE_DIR="${AEGIS_TEE_DIR:-/data/adb/teesim}"`。

### 6.2 安装期检查

| 检查 | 行为 |
|---|---|
| `! $BOOTMODE` | **abort**（不支持 recovery 安装） |
| `API < 26` | `exit 1`（Android 8 以下） |
| `ARCH` 不是 `arm64` / `x64` | `exit 1` —— **只接受 64 位**。理由：TEE 拦截器是注入 keystore daemon 的 64 位库，而该 daemon 在所有支持的设备上都是 64 位 ⇒ **拒绝纯 32 位设备，而不是静默失败** |
| Zygisk | **仅警告，不中止**。检测 `zygisknext`/`zygisksu`/`rezygisk`/`neozygisk` 模块目录存在**且无 `remove` 文件**，或 `magisk --sqlite` 的 zygisk 设置匹配 `zygisk\|1$`。**无 Zygisk 时 TEE 半仍工作，但 verdict 上限是 BASIC** |

### 6.3 禁用会双重挂钩的模块（附「先收养指纹」）

| 目标 | 行为 | 理由 |
|---|---|---|
| `playintegrityfix` / `teesim` / `Integrity-Box`（standalone） | `touch disable` | TEE 组件已内置，残留独立安装会**第二次 hook keystore**。注释特别指出：**Integrity-Box 自 v28 起以 `playintegrityfix` id 发布**；而独立的 `Integrity-Box` id（较旧/手动安装）**hook 每个应用进程**并破坏应用级设备身份（**微信强制登出类报告**），所以看到也禁用 |
| **先收养 standalone PIF 的指纹** | 若本模块还没有 `custom.pif.prop`/`.json`/`pif.json`，且 standalone PIF 目录里有 → `cp -af` 过来 | **用户精心维护的私有指纹在迁移中存活**；捆绑载荷从本模块目录读**同名**文件 |
| `tricky_store` | `touch disable` | 拦截**同一个 keystore 路径** |
| `safetynet-fix` | `touch remove` | 过时且不兼容；hook 的正是我们环境层要清理的那个 GMS 表面 |
| `MagiskHidePropsConf` | **仅警告** | 属性伪装助手会与环境隐藏层打架 |

### 6.4 迁移

1. **保留旧 `system.prop`**（来自 `$MODPATH/system.prop` 的上一版）——注意这一处的路径是**模块 id 相关**的。
2. **audit N2/N7：原地脱敏历史日志（绝不删除）**
   - ≤ v3.2.2 写的日志含**明文** IMEI/IMEI2/MEID/serial（上游 harvest 行）。补丁 0006 在**源头**遮蔽新行，但**升级设备上已轮转的分片仍持有旧明文**。
   - 对 `$TEE_DIR/log/teesim.log` 与 `teesim.*.log` **原地遮蔽** —— 源码原话：「**never delete: the diagnosis value is kept, the identifiers are not**」。
   - 这是 `mask_ids` **四份副本的第三份**（另三份：`engine-check.sh`、`engine-verdict.sh`、`logs.js`），`test-mask-ids.sh` 断言四份一致。

### 6.5 播种 TEE 配置

- **`_kbiv` 只读一次**（在任何东西触碰 keybox **之前**）：下面的「检测到已有安装」行与安装结束总结**必须引用运行时循环（`service.sh`）实际会用的同一个数字**。安装器里**没有第二处**解释这个文件的地方。`test-interval-rule.sh` **提取这几行**并把它们的行为钉在执行器的相同规则上。
- **`_kbpre`**：本次安装**之前**是否已有 keybox（含 symlink）？**只有那时**安装器才可以声称「你的设置已保留」——首次安装收养 TrickyStore 的 keybox 时用户没有任何东西可保留，说保留就是撒谎。
- **symlink 实体化（与 `service.sh` 同一坑在本文件的第二次出现）**：
  `/data/adb/teesim/keybox.xml → /data/adb/tricky_store/keybox.xml` 是**实战观察到的真实状态**（TrickyStore 自己的工具会写它），而它**击败下面所有存在性测试** —— `[ -f link ]` 跟随链接，所以一旦目标存在，收养就**永远被跳过**，**重刷也永远修不好**。
  更糟：symlink 会**静默把引擎重定向**到 TrickyStore 当时的任何东西，**包括引擎无法解析的 keybox**。
  → 目标存在则 `cp -fL` + `mv` 实体化并写 `.auto-keybox` 哈希；目标不存在则**移除死链接**。
- 从 TrickyStore 收养 keybox（若无自己的）+ 写 `.auto-keybox` 哈希 —— 标记为**自动管理**，让定时刷新接管它（而不是永远跳过）。
- **⚠️ 校验失败时「移开」—— 与 `service.sh` 刻意相反**：
  `keybox-check.sh` 失败 → 打印逐条理由 + 说明症状（PI 卡 BASIC 一绿而其它一切看似正常）+ **移开**为 `keybox.rejected.<ts>.xml` + 删 `.auto-keybox`。
  > **安装器可以移开**（模块**可证明**无法与它工作）；**启动不能**（`service.sh` §5.8 只记录 verdict）。**两种行为都是刻意的，都要保留。**
- `config.json` 不存在 → 从 `$MODPATH/config.default.json` 复制。

### 6.6 设备证明 ID 回填（对应故障模式 §1.1）

**机制（源码中文注释原文）**：上游 TA 在 App 请求带设备 ID 字段的证明密钥时，用 profile 预置的 `brand/device/...` 与请求比对，**不一致（或为空）即拒绝（`CANNOT_ATTEST_IDS`）**。**默认配置这些字段全空** → GMS 的证明请求失败 → **PI 只剩 BASIC**。
（注释还留着一句对照：「RS 引擎因自动采集设备 ID 而无此问题」。）

**`fill_id <field> <value>`**：**只回填空字段**（兼容有无空格的 JSON 格式），sed 特殊字符先转义 —— **三层转义、顺序不可换**，与 `pif-sync.sh` 的 `set_id`（§3.7）是**同一套规则**。

| 字段 | 来源 |
|---|---|
| `brand` / `device` / `manufacturer` / `model` | 对应 `ro.product.*` |
| **`product`** | **`ro.product.name`** —— 注释**再次**强调 `ro.product.product` 在 Android 上**不存在**（getprop 返回空会让 product 留空） |
| `serial` | `ro.serialno` |
| **`imei`（尽力而为）** | ① 四个厂商属性取第一个**纯数字**的：`ro.ril.oem.imei` / `persist.vendor.radio.imei` / `vendor.ril.imei` / `ro.vendor.ril.imei`；② 否则 `service call iphonesubinfo 1 s16 com.android.shell`，从输出抓 `'[0-9]+'`，**要求长度 ≥ 14**，否则**留空** |
| `imei2` | `ro.ril.oem.imei2` / `persist.vendor.radio.imei2` / `vendor.ril.imei2` |

### 6.7 安装期一次有界指纹抓取（R7-1，2026-09-19）

**作者锁定的设计**（基线 `docs/design/pif-source-preview-20260916.html`）：
**只试一次、~20 秒预算、在首次开机之前** —— 让设备开机时就带着自己的指纹，**首次开机完全不需要网络**。
离线/失败/超时 → 通过零中断的 `|| true` 回退到包内烘的**种子**；`pif-fetch` 随后在第一个网络可用的 tick 把那个**共享**种子换掉。
**用户放置的 `custom.pif.prop` 压过一切并完全跳过这个块。**
> 源码明确写着：**60–90 秒的安装等待被作者拒绝；20 秒是约定的上限。**

**两个守卫（都会导致"静默遮蔽"，务必保留）**：

1. **Guard 1（review finding 2026-09-19）**：模块更新/重刷会抹掉模块目录，但 **durable master 存活**，而 `pif-fetch` 的恢复遍历会在开机时把那个身份拷回来（**包括用户精心维护的那种**）。
   在这里抓取会先把一个新鲜随机文件放进模块目录 → **恢复遍历被跳过**（它只在模块目录没有指纹时运行）→ **存活的身份被遮蔽**。
   ⇒ **只有「模块目录与 master 都没有身份」时才抓取。**
2. **Guard 2**：只接受**规范输出**（`custom.pif.prop` / `.json` —— autopif4 与捆绑的 `migrate.sh` 会产出的），匹配 `pif-fetch.sh` 自己的成功判据。
   裸的 `pif.prop` / `pif.json` 是 **pre-migrate 残留**，**不能被标记为本次抓取的结果**。

**显示加固**：模型名来自**下载来的文件** ⇒ 限制为可打印白名单（`tr -cd 'A-Za-z0-9 ._+-'`）并**截断到 40 字符**，让安装日志与 WebUI **不能被灌入终端转义或垃圾**。

成功 → 写 `.pif-auto`（epoch）+ `chmod 0600` + `.pif-source` 写 **`install-fetch`**；超时（`rc=124`）与失败有不同文案。
（`.pif-source` 的四种取值：`install-fetch` / `seed` / `runtime-fetch` / `user` / `legacy` —— 见 §2.6。）

### 6.8 `skippersistprop` 标记（audit R8-4）

上游 PIF 把这个标记文件当作「跳过 persist-prop 写入」；而 **R8-4 修复之前，它的 stock 分支还会每次开机跑 `uninstall.sh`** —— 在融合构建里就是 **keybox 被抹掉**。该分支在 **assemble 时被剥离**；若用户从 standalone PIF 带过来这个标记，这里会告知它现在（不再）意味着什么。

### 6.9 Debug 默认关闭（安全审查 2026-09-11 + audit L11）

- **默认关闭**：`debug.log` 叙述**完整决策链**（渠道、URL、身份同步、引擎原因），而诊断导出**能把它带出设备** ⇒ **verbose logging 是隐私面，不是默认值**。日志页可开，标志文件**每次调用都检查**（所以开关是实时的）。
- **audit L11**：v3.0.2–v3.1.x **曾默认开启**（"since flash"），所以**升级会让详细日志永远开着**，而这条消息声称关闭 ⇒ **升级时清掉陈旧标志一次**，用户可再从日志页打开。

### 6.10 清理注入痕迹

对 `com.google.android.gms` 与 `com.android.vending`，在两个数据目录（`/data/user_de/0/$pkg` 与 `/data/data/$pkg`）里删除 `libinject.so` / `classes.dex` / `pif.prop` —— 这是 **PIF 家族模块（含 fusion v1.x）留下的注入痕迹**。

### 6.11 ABI 剪裁与权限

只留本机 ABI：`arm64 → rm -rf x86_64`、`x64 → rm -rf arm64-v8a`（另一个 ABI 的原生库在这里是死重）。
`set_perm_recursive "$MODPATH" 0 0 0755 0644`；`daemon` / `<abi>/inject` / `<abi>/teesim-uds` → `0755`。

### 6.12 安装总结

明确告知：两半都内置、指纹来源（联网则本机专属 / 离线用种子 / 无 Zygisk 则最高 BASIC）、**用户放置的 `custom.pif.prop` 永远优先**。
**间隔数字用 `$_kbiv`**（§6.5 只读一次的那个）—— 源码注释解释了为什么：
> WebUI 的量程是 `0/12/24/72/168`（0 = 关），而**硬编码 "24h" 曾在作者的 12h 设置上自相矛盾**；在用户已经关闭时声称 24h 节奏，是**同一个谎说两次**。

### 6.13 `post-fs-data.fusion.sh`（17 行）

极小的早期钩子：source `$MODPATH/fusion_func.sh`，然后调用 **`align_patch_level`**（三处调用点中最早的一处，对标 AS 的 `sync_patch.sh` 开机行为）。
它在 assemble 时被**追加进** `post-fs-data.sh`（PIF 载荷的同名脚本）。

---

## 7. 待补清单（按重写依赖顺序）

| 优先级 | 脚本 | 行数 | 状态 | 为什么排这个顺序 |
|---|---|---|---|---|
| 0 | `fusion_func.sh` | 96 | ✅ 完成 | 公共库，被 service / post-fs-data 引用 |
| 1 | `pif-sync.sh` | 282 | ✅ 完成 | 它改 `config.json`，是引擎侧契约的写入者；被 `pif-fetch` 与 `service` 依赖 |
| 2 | `pif-fetch.sh` | 509 | ✅ 完成 | 最大的一块，网络与重试逻辑最多 |
| 3 | `apps-sync.sh` | 301 | ✅ 完成 | 与 UI 的 `config.json` 交互面重叠 |
| 4 | `service.sh` | 492 | ✅ 完成 | 编排者，依赖前三个的行为 |
| 5 | `customize.sh` | 427 | ✅ 完成 | 安装期，与运行期相对独立 |

**6 个脚本全部完成。** 至此重写所需的输入齐备：
`CONTRACT-management.md`（本文，管理层 6 个脚本）+ `CONTRACT-verdict-keybox.md`（verdict / keybox 两条线）+ `CONTRACT-webui.md`（UI 功能面，95 个探针键）+ `TEST-INVENTORY.md`（测试接缝与去留）+ `KNOWN-FAILURE-MODES.md`（8 条根因 + 8 条环境陷阱）。
