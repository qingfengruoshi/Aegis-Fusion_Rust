# WebUI 功能契约（重写输入）

**用途**：本变体的 UI 将**重新重构**（用户决定，见 `GAP-AND-ROADMAP.md` §12）。这份文档把现有 UI 的**功能面**（不是外观）抽出来，作为新 UI 的输入与等价性验收依据。
原则：**UI 换了，功能不变。**

**来源**：`module/webroot/`（合计 **5,146 行** = html 350 · css 1,763 · js 3,033）。其中功能契约来自 `js/launcher.js`（1,081）、`js/apps.js`（806）、`js/logs.js`（967）；`js/prefs.js`（129）按自身设计是**纯呈现层**（只读 DOM class 聚合判定语 + 持久化布局偏好，不做任何模块判断），不参与功能契约。
**状态**：§1 的键集与逐键来源、§2 的判定规则、§3 的 exec 面、§4 的 socket 端点、§5 的脱敏规格**均已完成**。
仍未覆盖：`prefs.js` 的呈现偏好（布局/主题，`localStorage` 键 `af-layout` / `af-theme`）—— 它按自身设计不参与功能契约，新 UI 可自行决定是否保留。

---

## 1. 探针键集（实测：**95 个唯一键**）

两个页面各自跑**一段内联 shell 探针**，输出 `KEY=VALUE` 行；这是整个 WebUI 的数据来源（不依赖任何 HTTP 后端）。

| | 键数 |
|---|---|
| `launcher.js` 探针输出 | 37 |
| `logs.js` 探针输出 | **77**（67 个字面键 + `config.json` 驱动的 **10 个动态 `CFG_*` 键**） |
| 其中**共用** | 19 |
| **去重合计** | **95** |
| launcher 独有 | 18 |
| logs 独有 | 58 |

> ⚠️ 提取陷阱：`logs.js` 里有 `echo "CFG_$(echo "$ck" | tr a-z A-Z)=$cv"` 这种**动态生成的键**（`ck` 循环 `config.json` 的 10 个字段），
> 用 `grep 'echo "[A-Z0-9_]+='` 抓不到。新 UI 的验收脚本必须把这一类也纳入。

### 1.1 共用键（19）

```
DAEMON  KBAGE  KBG  KBMARK  KBPROG  KBPROGT  KBRUN  KEYBOX  PIFAUTO
PIFD  PIFEXP  PIFSRC  PIFST  REF  REVA  REVJ  UID  VER  ZYG
```

### 1.2 仪表盘（`launcher.js`）独有（18）

```
BL1 BL2 BL3 BL4 DEX DVER HOOK KBCERTS KBERR KBEV KBPREF KBRS
KBS KBSRC PG PIFMODEL PIFPROV SOCK
```

### 1.3 日志页（`logs.js`）独有（48）

```
ABI API AREL BL_BTYPE BL_DEBUGGABLE BL_FLASH BL_LOCKSTATE BL_OEMUNLOCK BL_TAGS
BL_VBMETA BL_VBOOT BL_VBVENDOR BL_VERITY CTL_SOCK DBG EACK EAPP EBUILD EFAIL
EIHIST EIREASON EISTATE ELOGSZ ENEVER EPUSH ERESOLVE ESTAGED ET0 ET0ALL ET1
ET1ALL INJECTED KBBAD KBCHK KBLINK KBRUNM KBSHA MGR MNT_ADB MNT_ADB_PATHS
MNT_TOTAL MODEL PF_OFF PF_SYNCOFF PIFFAIL PIFMAP SW_PATCH VEN_PATCH
```

### 1.4 逐键取值来源（**已逐个核到源码**）

> 这是新 UI 的**实现输入**：每个键的取值方式必须与下表一致，否则界面会显示错误的状态。

#### 共用键（19）

| 键 | 取值来源 | 备注 |
|---|---|---|
| `UID` | `id -u`（失败回退 `1`） | root 与否 |
| `VER` | `grep -m1 '^version=' $MODPATH/module.prop \| cut -d= -f2` | 仅显示 |
| `KEYBOX` | `[ -s $TEE_DIR/keybox.xml ]` | `yes`/`no` |
| `KBMARK` | `.auto-keybox` 存在 **且** marker mtime ≥ keybox.xml mtime | **两个条件缺一不可**（见 §2） |
| `REF` | `cat $TEE_DIR/keybox-refresh`，空 → **`24`** | 见 §2 的间隔白名单 |
| `KBG` | `cat $TEE_DIR/.key-status-n`，缺省 **`-1`** | `-1`≠`0`，见 §2 |
| `KBAGE` | (`.kb-last-fetch` mtime，回退 `keybox.xml` mtime) 距 now | 单位**小时** |
| `KBRUN` | `.kb-fetching.lock` 是**目录**（`[ -d ]`） | 抓取进行中 |
| `KBPROG` | `.kb-fetch.progress` 第 2 行 +（有第 3 行时 ` · ` + 第 3 行） | 人可读进度 |
| `KBPROGT` | 同文件第 1 行（非数字 → `0`） | epoch |
| `REVJ` | `.revocation-status.json` 非空 | Google 吊销缓存 |
| `REVA` | 该文件 mtime 距 now；无文件 → `-1` | 单位**小时** |
| `PIFSRC` | 候选路径依序取第一个非空（清单见下） | **含第三方模块路径** |
| `ZYG` | `zygisknext` / `zygisksu` / `rezygisk` / `neozygisk` 模块目录存在；或 `magisk --sqlite ... key='zygisk'` 命中 `*zygisk\|1*` | 指纹半的前提 |
| `PIFST` | `.pif-auto` 到期判定 → `ok` / `soon`（≤7 天）/ `expired` | |
| `PIFD` | 距到期天数：未到期=剩几天，已过期=过了几天，不适用=`-1` | |
| `PIFAUTO` | `.pif-auto` 存在 **且** `PIFSRC` 等于 `$MODPATH/custom.pif.{prop,json}` | 只有自动管理的才评phase |
| `PIFEXP` | `$PIFSRC` 里 `# Estimated Expiry: ` 行 | |
| `DAEMON` | ⚠️ **两个页面不同**，见 §1.5 | |

#### `launcher.js` 独有（18）

| 键 | 取值来源 |
|---|---|
| `DAEMON` | `teesim-uds … GET /status` **返回成功** → `yes`（**不是 pidof**） |
| `HOOK` | /status JSON 的 `hook` 字段（`tr "{,}" "\n\n"` 后 `grep hook \| cut -d\" -f4`） |
| `DVER` | /status JSON 的 `version` 字段 |
| `PG` | `pidof <PROC>`，仅作 not-running 时的**旁证** |
| `DEX` | `$MODPATH/teesim-service.dex` 或 `$MODPATH/service.apk` 存在 |
| `SOCK` | admin socket 存在（`[ -S ]`） |
| `KBSRC` | `cat $TEE_DIR/.keybox-source` |
| `KBPREF` | `head -n 1 $TEE_DIR/keybox-source-pref` |
| `KBS` | `key-status.txt` 去掉换行 |
| `KBERR` | `keybox-fetch.log` 里**最后一行含 `ERROR`**，截前 140 字符 |
| `KBEV` | `.engine-verdict` 的 `state=`，**并做陈旧判定**（`kbhash` 优先 / `kbtm` 兜底）；陈旧 → `stale`；无记录 → `unknown` |
| `KBRS` | `.engine-verdict` 的 `reason=` |
| `KBCERTS` | keybox.xml 里各 `<Certificate>` 体（去 PEM 壳、去空白）以 `;` 连接 |
| `BL1`–`BL4` | `getprop`：`ro.boot.vbmeta.device_state` / `ro.boot.verifiedbootstate` / `ro.build.tags` / `ro.boot.flash.locked` |
| `PIFPROV` | `.pif-source` 第 1 行（`seed` / `runtime-fetch` / `install-fetch`） |
| `PIFMODEL` | `$MODPATH/custom.pif.prop` 的 `MODEL=` |

#### `logs.js` 独有（58）

**引擎轨迹类**
| 键 | 取值来源 |
|---|---|
| `ELOGSZ` | `log/teesim.log` 字节数（无文件 → `0`） |
| `EPUSH` / `EACK` / `ESTAGED` / `EBUILD` / `ENEVER` | 分别 `grep -c`：`control: pushed config` / `control: ack` / `cfg: staged profile` / `failed to build` / `never pushed a config` |
| `ERESOLVE` | `grep -cE "Failed to resolve/push config\|No valid config to push"` |
| `ET1ALL` / `ET0ALL` | `grep -c 'target=1'` / `'target=0'` —— **全量（终生）**计数 |
| `ET1` / `ET0` | **从最后一次 `control: ack` 的那一行起**计数（"era split"：上一次 keybox 的计数不混进来） |
| `EAPP` / `EFAIL` | 最近一条 `control: ack` 里的 `applied=` / `failed=` |
| `EISTATE` | `.engine-verdict` 的 `state=` |
| `EIREASON` | 按 state 分流：`rejected`/`partial` → 用 `.engine-verdict` 的 `reason`；否则若 `EFAIL>0` → 用 `EIHIST` |
| `EIHIST` | 引擎日志里**最近一条** `teesim_km_init_ex:` 的原话 |

**设备与运行环境类**
| 键 | 取值来源 |
|---|---|
| `DAEMON` | `pidof <PROC>` → `running` / `stopped`（⚠️ 与 launcher 的判定方式**不同**） |
| `CTL_SOCK` | `/data/misc/keystore/.teesim-ctl` 存在 → `present` / `missing` |
| `INJECTED` | keystore2 进程 `/proc/<pid>/maps` 里 `libteesim` 的计数（无 keystore2 → `-1`） |
| `PIFMAP` | GMS 进程 maps 里 `<MODID>` 的计数 —— **仅参考**：PIF 走 `memfd_create` 加载 dex，路径不会出现在 maps 里，`0` **不代表**指纹半坏了 |
| `KBRUNM` | 抓取运行中时，把锁目录 mtime 换算成**分钟** |
| `KBSHA` | `keybox.xml` 的 sha256 **前 12 位** |
| `DBG` | `.debug` 存在 |
| `PIFFAIL` | `pif-fetch.log` 里**最后一行**含 `generation failed` |
| `PF_OFF` / `PF_SYNCOFF` | `.pif-off` / `.pif-sync-off` 存在 |
| `KBCHK` / `KBBAD` / `KBLINK` | 结构校验结果（跑 `keybox-check.sh --quiet` 只看退出码）/ `.keybox-bad` 存在 / keybox.xml 是符号链接时的目标 |
| `AREL` / `API` / `MODEL` / `ABI` | `getprop`：`ro.build.version.release` / `ro.build.version.sdk` / `ro.product.model` / `ro.product.cpu.abi` |
| `MGR` | 按目录判定：`/data/adb/ksu` → KernelSU、`/data/adb/ap` → APatch、`/data/adb/magisk` → Magisk |
| `SW_PATCH` / `VEN_PATCH` | `getprop ro.build.version.security_patch` / `ro.vendor.build.version.security_patch` |
| `BL_VBMETA`/`BL_VBVENDOR`/`BL_VBOOT`/`BL_FLASH`/`BL_VERITY`/`BL_LOCKSTATE`/`BL_TAGS`/`BL_BTYPE`/`BL_DEBUGGABLE`/`BL_OEMUNLOCK` | 一批 `getprop`（见 `logs.js:477-481`） |
| `MNT_TOTAL` | `/proc/self/mounts` 行数 |
| `MNT_ADB` | 其中含 `/data/adb` 的行数 |
| `MNT_ADB_PATHS` | 去重后的前 5 个 `/data/adb` 挂载点，`\|` 连接 |
| `CFG_MODE` `CFG_OSVERSION` `CFG_SYSTEM` `CFG_VENDOR` `CFG_BOOT` `CFG_BRAND` `CFG_DEVICE` `CFG_PRODUCT` `CFG_MANUFACTURER` `CFG_MODEL` | **动态键**：循环这 10 个字段名，从 `config.json` 取 `"<字段":"<值>"` 的**第一个匹配** |

#### 1.5 ⚠️ 同一个 `DAEMON` 键，两页语义不同

| 页面 | 判定方式 | 取值 |
|---|---|---|
| `launcher.js` | admin socket `GET /status` **成功** | `yes` / `no` |
| `logs.js` | `pidof <PROC>` | `running` / `stopped` |

**这是现存的不一致，不是设计。** 新 UI 应当统一 —— 建议统一走 `/status`（它是引擎自报，比 `pidof` 更强），但**必须同时保留 `pidof` 作为旁证**（`PG` 键）：daemon 进程在但 socket 不通，是一个必须能显示出来的状态。

**`PIFSRC` 的候选清单（顺序敏感，且包含第三方模块路径）**：
`$MODPATH/custom.pif.prop` → `$MODPATH/custom.pif.json` → `/data/adb/pif.json` → `/data/adb/modules/playintegrityfix/{custom.pif.prop,custom.pif.json,pif.json}` → `/data/adb/modules/playintegrityfork/pif.json` → `/data/adb/modules/Integrity-Box/pif.json` → `/data/adb/modules/tricky_store/pif.json`
（最后那个 `tricky_store` 是**别人的模块**，不要当成自己的路径删掉。）

---

## 2. 必须保留的判定规则（**不是 UI 细节，是功能**）

| 规则 | 为什么不能改 |
|---|---|
| `.engine-verdict` 的**陈旧判定**：`kbhash` 优先、`kbtm` 仅兜底 2026-09-19 前的记录 | 该规则目前**存在三份实现**：`engine-verdict.sh` 的 `show` 分支（权威）、`launcher.js`、`logs.js`。三处必须一致，否则界面与脚本各说各话 |
| `.key-status-n` 的 `-1` 与 `0` **语义不同** | `-1` = 渠道没提供状态文件（未知）；`0` = 提供了但零绿圈。混同会误导用户 |
| 「用户导入 keybox」判定：hash ≠ marker **或** `kbtm > kbmm` | 只用 hash 会漏掉「用户覆盖成与渠道完全相同的字节」这一情形 |
| 诊断导出必须**全脱敏** | H1 审计项，导出文件落在 world-readable 的 `/sdcard/Download` |
| 受保护应用列表以 **`config.json` 为准**（引擎侧契约） | 引擎的 `ConfigStore.kt` 监听 `config.json` / `*.xml`；改格式要改引擎 |

---

## 3. `ksu.exec` 面（新 UI 可自由改形态，但须覆盖同样的能力）

**特权操作全部经 KernelSU 的 exec 桥走 root shell**，没有 HTTP 后端。现状分三类：

**A. 只读探针**（§1 的两段，各一次 exec，返回多行 `KEY=VALUE`）

**B. 单文件读写**
`cat <file>` / `echo <v> > <file>` / `tail -n N <file>` / `test -f <file>`，目标集中在 `$TEE_DIR` 与 `$MODPATH`。

**C. 调用模块脚本与 admin socket**
| 用途 | 现状命令 |
|---|---|
| 手动获取 keybox | `nohup sh $MODPATH/keybox-fetch.sh --force`（退出码被丢弃，改为轮询 `.kb-fetching.lock` / `.kb-fetch.progress`） |
| 重取指纹 | `sh $MODPATH/pif-fetch.sh && sh $MODPATH/pif-sync.sh`（只看 `&&` 链是否走到 `echo applied`） |
| keybox 结构校验 | `sh $MODPATH/keybox-check.sh $TEE_DIR/keybox.xml --quiet`（**只看退出码**） |
| daemon 交互 | `$TEE_DIR/teesim-uds $TEE_DIR/admin.sock <METHOD> <PATH> "$(cat $TEE_DIR/admin.token)"` |

> **重写后的自由度**：C 类的入口名/形态**可以改**（原约束「WebUI 一字不改」已随 UI 重写而消失，见 `GAP-AND-ROADMAP.md` §12.2）。
> 但 **B 类涉及的数据文件格式不能改** —— 那是与引擎的接口，且两线共用数据目录、要能互相读懂对方的落盘状态。

---

## 4. admin socket 端点（现状，改形态前先确认引擎侧）

| 端点 | 用途 |
|---|---|
| `GET /status` | daemon 状态；`engine-verdict.sh` 另从它读 `"push":{"last":N}` 与 `"ack":{"last","applied","failed"}` 作为 logcat 全死时的兜底 |
| `GET /packages` | 已安装应用列表（受保护应用管理页） |
| `GET /logs?after=<n>&max=<n>` | daemon 内存环日志 |
| `GET /logs/download?max=<n>` | 日志导出（取真正的尾） |

⚠️ `/status` 与 `/logs` 的响应体**内嵌完整 harvest 记录（明文 IMEI/MEID/serial）**，所以：
- 界面**绝不能原样打印**；现状只取白名单字段（如 `version` / `hook`）；
- 这是 shell 线 audit N1 的修复点，重写时必须保留同等约束。

---

## 5. 设备标识脱敏规格（**已合并为单一实现规格**）

**背景**：现状有四份副本 —— `module/customize.sh`、`module/engine-check.sh`、`module/engine-verdict.sh`（三份 shell `mask_ids`），
加 `module/webroot/js/logs.js` 的 `maskDeviceIds()`（第四份，JS）。`scripts/test-mask-ids.sh` 断言三份 shell 一致。
重写后只需**一份实现**，那份字节一致性断言随之退休；本规格取代它。

### 5.1 键名集合（大小写不敏感）

```
secondImei  imei2  imei  meid  serialno  serial
```
（`serialno` 是引擎真正读的属性，audit r5 补入；`imei2`/`secondImei` 是两种上游拼写。）

### 5.2 四种形态与精确模式

按此顺序应用（顺序敏感，见 §5.4）：

| # | 形态 | 样例 | 模式（JS 正则语法） | 替换为 |
|---|---|---|---|---|
| 1 | 单引号 | `imei='35…'` | `(KEYS)='([^']*)'` | `k='<redacted:len=N>'` |
| 2 | JSON | `"imei":"35…"` | `"(KEYS)"\s*:\s*"([^"]*)"` | `"k":"<redacted:len=N>"` |
| 3 | 裸键值 | `imei=35…` | `(KEYS)\s*=\s*([^\s'",;)\]}]+)` | `k=<redacted:len=N>` |
| 4 | 空格分隔 | `imei 35…` | `\b(KEYS)[ \t]+([^\s'",;)\]}]{4,})` | `k <redacted:len=N>` |

### 5.3 ⚠️ 现状两份实现不一致，规格取「更好」的那一份

| 差异 | shell `mask_ids` | JS `maskDeviceIds` | **规格采纳** |
|---|---|---|---|
| 替换文本 | `<redacted>`（**丢掉长度**） | `<redacted:len=N>` | **保留长度** |
| 规则 3 的排除字符集 | 空格 `'` `"` `,` `;` `)` `}` | 多排除一个 `]` | **取并集**（多排除 `]`） |

第一行是个自相矛盾：shell 侧注释自己写着「**Presence + length** is all the diagnosis needs」，
但它的替换把长度丢掉了 —— 只有 JS 侧真正保留了长度。**新实现一律采用 `<redacted:len=N>`。**

### 5.4 顺序与跨行

- **顺序敏感**：1 → 2 → 3 → 4。必须先处理带引号的形态，否则规则 3 会抢先吃掉引号内的值。
- **跨行**：shell 逐行处理（每行是一条完整记录，所以行尾不会出现裸 `imei=`）；JS 处理的是**拼接后的文本**，
  因此规则 3 的分隔符要容忍 `\n`（把换行后继续的值也覆盖）。新实现按 JS 行为。
- 规则 4 的值下限是 **4 字符**，且**仅限同一行**（行尾的裸词不得吞掉下一行的首个 token）。

### 5.5 重写后的验收方式

按 §5.2 的形态表做对抗性用例，重点是审计踩过的坑：
- 行尾裸 `imei=`（值换行）
- 值含连字符（如 `imei=35-0000-0000-0001`）
- 首段字母数字短于 4 的值
- 空格分隔值（`imei 350000000000001`）
- 内嵌引号的畸形值
- `]/}` 终止的值（验证排除集）
- 大小写混写（`IMEI=`、`Serial=`）

---

## 6. 新 UI 的验收方式（待定）

- **探针等价**：新探针输出的键集 ⊇ §1 的 85 个键（少一个都可能让某个状态灯失去数据源）；
- **判定等价**：§2 的五条规则逐个用 fixture 对比新旧实现；
- **脱敏等价**：拿 §5 的形态清单做对抗性用例（含畸形输入）；
- 现有 290 条 JS 断言的**语义**（不是代码）应尽可能迁移到新 UI 的测试里 —— 它们记录了行为，不只是实现。
