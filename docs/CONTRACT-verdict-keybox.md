# verdict + keybox 迁移契约（v0.1，2026-09-21）

**来源**：`shell 线仓库 IntegrityFusion（本机姊妹目录）`（shell 稳定线，`main` @ 领先 origin 7 commit）
**落点**：本仓库 Hide_Rust（Rust 引擎线，基座 TEESimulator-RS @ `6d241e5`）
**目的**：在不动 WebUI 一个字节的前提下，把 verdict / keybox 两条逻辑线从 shell 迁到 Rust。本文只定义**对外契约**，不涉及实现。

---

## 0. 一句话结论

WebUI 对 Fusion 脚本的**真实** exec 面只有 **3 个调用点**，且全部是「无参 / 单参数 / 只看退出码」的低带宽形态。
所以 Rust CLI 兼容层**不需要**复刻任何 `KEY=VALUE` 协议——它只需要 **4 个同名可执行文件** + **一套 byte 级不变的落盘文件格式**。

真正的工作量不在命令行接口上，而在**下面第 4 节那 40 多个数据文件的格式**上。

---

## 1. WebUI 的 exec 面全量清单（已核验）

### A 类：内联 shell 探针（不依赖任何 Fusion 脚本）

| 位置 | 用途 | 输出 |
|---|---|---|
| `launcher.js:26-161` | 仪表盘单次探针 | 约 35 行 `KEY=VALUE` |
| `logs.js:325-445+` | 诊断导出探针 | 约 45 行 `KEY=VALUE` |

这两个探针内部只做：读文件 / `getprop` / `stat -c %Y` / `sha256sum` / `pidof teesim` / `readlink` / `magisk --sqlite`。
**它们不 exec 任何 Fusion 脚本**（唯一例外见 D 类第 3 条）。

### B 类：文件 IO

`cat <file>` / `echo <v> > <file>` / `tail -n N <file>` / `test -f <file>`。
调用点：`apps.js:78,92,169` · `launcher.js:224,240,1021` · `logs.js:98,110,147,229`。
目标全部是 `$TEE_DIR` 与 `$MODPATH` 下的数据文件。→ Rust 侧只要保证文件格式不变，这一层零改动。

### C 类：daemon 传输（引擎自带，与 Fusion 层无关）

```
$TEE_DIR/teesim-uds $TEE_DIR/admin.sock <METHOD> <PATH> $(cat $TEE_DIR/admin.token)
```
调用点：`apps.js:105` · `logs.js:119`。

> **注意**：这是 admin socket 接口。shell 版靠 `patches/teesim/0007-engine-status-socket.patch` 提供，
> `engine-verdict.sh` 的 `socket_ack_state()` 读的是 `"push":{"last":N}` 与 `"ack":{"last","applied","failed"}`。
> Rust 基座的 app/ 是 Kotlin daemon，**是否已有该端点、字段名是否一致，必须先确认**（见 §6 阻塞项 1）。

### D 类：Fusion 脚本调用 —— CLI 兼容层的最小必需集

| # | 调用点 | 命令行 | 依赖的契约 |
|---|---|---|---|
| 1 | `launcher.js:916` | `nohup sh $MODPATH/keybox-fetch.sh --force </dev/null >/dev/null 2>&1 & echo spawned` | **退出码被丢弃**。WebUI 只轮询 `.kb-fetching.lock` 与 `.kb-fetch.progress` |
| 2 | `launcher.js:967-968` | `sh $MODPATH/pif-fetch.sh >/dev/null 2>&1 && sh $MODPATH/pif-sync.sh >/dev/null 2>&1; echo applied` | 只看 `&&` 链是否走到 `echo applied`；两个脚本的退出码都必须是 0 才会打出 `applied` |
| 3 | `logs.js:339` | `[ -f "$kbc" ] && { if sh "$kbc" $TEE_DIR/keybox.xml --quiet >/dev/null 2>&1; then kbchk=ok; else kbchk=bad; fi; }` | **退出码即结论**：0 → `KBCHK=ok`，非 0 → `KBCHK=bad`。stdout 被 `/dev/null` 丢弃 |

**只有这 3 个调用点。** 以下是常见误判，明确排除：

| 出现的脚本 | 位置 | 性质 |
|---|---|---|
| `keybox-swap.sh` | `logs.js:555`、`logs.js:584` | **仅提示文案**，从未被 exec |
| `engine-verdict.sh once` | `logs.js:558` | **仅提示文案**，从未被 exec |
| `apps-sync.sh` | `apps.js:11,391,472` | **仅注释** |
| `engine-check.sh` | 无 | WebUI 完全不触碰 |
| `keybox-fetch.sh` / `pif-fetch.sh` / `pif-sync.sh` | `service.sh` 定时调用 | 系统侧，非 WebUI |

---

## 2. 被复制多份的逻辑：陈旧锚点（冻结项）

`.engine-verdict` 的**陈旧判定规则存在三份独立实现**：

| # | 实现 | 位置 |
|---|---|---|
| 1 | 权威 | `engine-verdict.sh` 的 `show` 分支（`kbhash` 优先，`kbtm` 仅兜底 2026-09-19 前的记录） |
| 2 | 逐字复制 | `launcher.js:86-96` 内联探针 |
| 3 | 第三份读取 | `logs.js:416-424`（推导 `EIREASON` / `EISTATE`） |

同类「三处共享」还有：

| 规则 | 三处位置 |
|---|---|
| 用户导入判定（hash ≠ marker，或 `kbtm > kbmm`） | `keybox-fetch.sh:610-638` · `launcher.js:65-67` |
| keybox-refresh 间隔白名单 `0/12/24/72/168` | `service.sh` · `customize.sh` 安装总结 · `launcher.js:626` · `logs.js:618` |

> ⇒ **锚点语义是冻结契约。** Rust 侧不得改 `.engine-verdict` 的键集、不得改 `kbhash` 优先 / `kbtm` 兜底的判定顺序。
> 改了必须同步改两份 JS——这正是项目一直强调的「UI display 与逻辑共享同一 source of truth」。

---

## 3. 五个脚本的 CLI 契约

### 3.1 `engine-verdict.sh` — verdict 的唯一权威

> `engine-check.sh:212` 注释原文：**"One authority: engine-verdict.sh reads the ack COUNTS"**。
> Rust 侧重写后，`.engine-verdict` 必须仍由**唯一写入者**写。

| 子命令 | argv | stdout | 退出码 |
|---|---|---|---|
| `once` | — | `VERDICT: ACCEPTED/REJECTED/PARTIAL/NO-ACK` + 引擎原话 | `0` accepted（`applied>0` 且 `failed=0`）· `1` rejected（`applied=0`）或 partial（`applied>0` 且 `failed>0`）· `2` 无 ack |
| `watch` | `[secs] [byte-from]` | 先打印 `-- engine log since the deploy --` 段，再同上 | 同上；超时后打印 `VERDICT: SILENT` 并 `2` |
| `show` | — | `cat .engine-verdict`，陈旧时打印 `state=stale` | `0` ok · `1` rejected/partial · `2` stale 或 unknown |
| `reason` | — | 仅引擎原话（无则空行） | 恒 `0` |
| `socket-live` | — | `state=<rc> ack=<line>` 或 `state=none` | `0` 有 ack · `2` 无 |
| `-h` / `--help` / 空 | — | 帮助文本 | `0` |
| 其它 | — | stderr `unknown mode: $1 (try --help)` | `2` |

**副作用**：原子写 `$TEE_DIR/.engine-verdict`（`.tmp` + `mv -f`，`chmod 0644`）：

```
state=ok|rejected|partial|silent|unknown
reason=<引擎原话；仅 rejected/partial 时非空>
ack_applied=N
ack_failed=N
ack=<原始 ack 行>
kbtm=<记录时的 keybox.xml mtime>
kbhash=<记录时的 keybox.xml sha256；无 sha256sum 时省略该行>
ts=<记录时刻 epoch>
```

数值参数白名单：`watch` 的 `$2`（秒）与 `$3`（字节偏移）必须**纯数字**，否则回落默认值（`15` / 当前日志大小）。见 `:309`、`:315`。

### 3.2 `keybox-check.sh` — 结构校验器

| argv | 退出码 | 语义 |
|---|---|---|
| `<file> [--quiet]` | `0` | 可用 |
| | `1` | 不可用（引擎无法用它构建 TA） |
| | `2` | 文件不存在 / 不可读 / 非普通文件 / 未传参 |

stdout 为人类可读多行，前缀固定：`ok  :` · `warn:` · `FAIL:` · `note:` · `PASS:`。
`--quiet` 下**健康 keybox 完全静默**，但坏 keybox 仍以非 0 退出（`say()` 只吞 stdout，不吞退出码）。

校验规则 1–5 与 `rust/teesim-km/src/attest.rs`（`CertSignInfo::new` → `parse_algo` → `decode_pem`）**同序、同措辞**。Rule 5 精确复刻 base64 crate 的 STANDARD engine 语义。

### 3.3 `keybox-swap.sh` — 热替换 + 读回引擎判决

| argv | 退出码 |
|---|---|
| `<candidate.xml>` | `0` 引擎接受 · `1` 校验失败（或引擎拒绝）· `2` silent / 非文件 |
| `<candidate.xml> -f`（同 `--force`） | 同上（跳过结构校验） |
| `--auto <c1> [c2...]` | `0` 有一个被接受 · `1` 全部失败（并回滚 prerun）· `2` 用法错误 |
| `--watch [secs]` | 转发 `engine-verdict.sh watch` 的退出码 |
| `--restore` | `0` / `2`（无备份） |
| `--list` | 恒 `0` |

**副作用**：
- 写 `$BKDIR/keybox.<YYYYmmdd-HHMMSS>.xml`，保留最新 10 份（`:81`）
- 写 `$TEE_DIR/.keybox.prerun.xml`（`--auto` 期间），成功时删除
- 部署成功后 `rm -f $TEE_DIR/.auto-keybox`（`:103`）
- 部署方式：`cp -f <cand> keybox.xml.new` + `mv -f`，**必须**是同目录原子 rename（否则 `cp` 会写穿 symlink）

### 3.4 `keybox-fetch.sh` — 多渠道抓取 + 引擎验收

| argv | 退出码 | 触发点 |
|---|---|---|
| 无参 | `0` 成功 / 无需动作 | 正常路径结尾 `:824`；session recycle 路径 `:593,636,741,748` |
| | `1` | `--force` 时当前 keybox 备份失败 → 中止，不替换（`:655`） |
| | `7` | 所有候选源都没通过引擎验收（`:773`） |
| | `8` | `sha256sum` 不可用（`:810`） |
| | `75` | 已有并发锁且持有者存活（`:109`、`:113`） |
| `--force` | 同上 | 手动获取，绕过用户导入守卫 |
| `--revcheck` | `0` | 只刷新 Google 吊销缓存后即退出（`:593`） |

**关键内部契约**：
- 四档下载阶梯：`curl` → `wget` → `busybox wget` → `curl --resolve <fastly-ip>`（`:300-330` 附近）
- 代理三级来源：`AEGIS_KB_PROXY` 环境变量 → `$TEE_DIR/pif-proxy.conf` 首行 → `$TEE_DIR/pif-proxy.auto` 首行
- 代理值字符白名单：`[A-Za-z0-9:._@/-]`，越界即丢弃并告警
- 引擎验收：`deploy_and_verify()` → `engine-verifiable()`（要求 daemon 存活 **且** 日志已有 `control: ack`，或 `socket-live` 通过）→ `engine-verdict.sh watch 10`。**silent 视为通过（fail-open）**，rejected 才返回 1
- 已知坏 payload 以 sha256 记入 `.keybox-bad-payloads`（上限 20 行），下次直接跳过

### 3.5 `engine-check.sh` — 一次性体检报告

| argv | 退出码 |
|---|---|
| 无参 | 隐式 `0`（末尾是 `echo "== done =="`，**脚本内没有任何 `exit` 语句**） |

stdout 为 9 个 section 的文本报告（`== N. 标题 ==` 分隔）：
1. module / daemon 进程 · 2. keystore2 注入 · 3. 控制 socket · 4. 将要推送的 config（含逐个 keybox 跑 `keybox-check.sh`）· 5. 引擎持久轨迹 · 6. daemon admin 端点 · 7. daemon stderr · 8. logcat 兜底 · 9. verdict 判定

> **Rust 重写注意**：该脚本无显式退出码，且第 9 节内部调用 `engine-verdict.sh once`。
> 迁移时应**显式化退出码**（建议沿用 0/1/2），但需同步 `service.sh:295-329` 的读取方式。

---

## 4. 数据文件契约（byte 级冻结）

这是**真正的迁移工作量**。以下文件由 shell 侧写、由 WebUI / service.sh 读，Rust 侧必须逐字复现。

| 文件（相对 `$TEE_DIR`） | 写入者 | 读取者 | 格式 |
|---|---|---|---|
| `.engine-verdict` | engine-verdict.sh | launcher.js / logs.js / service.sh | `key=value` 9 键，见 §3.1 |
| `.kb-fetch.progress` | keybox-fetch.sh `progress()` | launcher.js:102 / logs.js:426 | 3 行：`epoch` / `stage` / `detail` |
| `.kb-fetching.lock` | keybox-fetch.sh（**目录**，内含 `holder` 文件存 pid） | launcher.js:873,907 / logs.js:346 | `mkdir` 原子锁；stale 判据：持有者已死，或存活但超 900s |
| `.kb-last-fetch` | keybox-fetch.sh `touch_fetch_ts()` | launcher.js:111 | 单行 epoch |
| `.auto-keybox` | keybox-fetch.sh / customize.sh | launcher.js:66 / logs.js:333 | 单行 sha256（**0600**） |
| `.keybox-source` | keybox-fetch.sh | launcher.js:68 | 单行渠道名 |
| `.keybox-source-pref` | WebUI（渠道 chip） | keybox-fetch.sh:667 / launcher.js:69 | 首行渠道名 |
| `.key-status-n` | keybox-fetch.sh | launcher.js:71 / logs.js:343 | 单整数；`-1` = 未知（**不是"坏"**） |
| `key-status.txt` | keybox-fetch.sh | launcher.js:72 | 原始上游有效性串（单行读） |
| `.keybox-bad-payloads` | keybox-fetch.sh | 自身 | 每行一个 sha256，上限 20（**0600**） |
| `.keybox-bad` | `service.sh:303`（启动校验；通过则 `:296` 删除） | engine-check.sh:142 / logs.js:340 | 单行 epoch |
| `.imported-bounced` | keybox-fetch.sh:628 | 自身 | 单行 sha256 |
| `.revocation-status.json` | keybox-fetch.sh `rev_cache_refresh()` | launcher.js:842 / logs.js:349 | Google 官方吊销列表原始 JSON；TTL 3600s |
| `keybox-refresh` | WebUI / customize.sh | launcher.js:70 / logs.js:342 | 单整数小时；默认 **24**（注意：与 12h 约定的关系见 §6） |
| `.pif-source` | pif-fetch.sh / customize.sh | launcher.js:159 | 单行：`seed` \| `runtime-fetch` \| `install-fetch` |
| `.pif-auto` | pif-fetch.sh | launcher.js:139 | 第 1 行基线 epoch，第 2 行到期 epoch（缺则 `+1209600`） |
| `.pif-off` / `.pif-sync-off` | WebUI | launcher.js | 存在即关 |
| `.debug` | WebUI | keybox-fetch.sh `dbg()` / launcher.js:440 | 存在即开 |
| `keybox.xml` | keybox-fetch / keybox-swap / 用户导入 | 全体 | **0600**，原子 rename 部署 |
| `config.json` | WebUI（经 uds） | daemon | 见 apps.js |
| `keybox-fetch.log` | keybox-fetch.sh（超 400 行裁到 200） | launcher.js:73 | `[YYYY-MM-DD HH:MM:SS] 文本` |
| `debug.log` | 各脚本 `dbg()` | logs.js | `[时间] [来源] 文本` |
| `log/teesim.log` | 引擎 LogTail | 全体 | 引擎原始轨迹（**只读**） |
| `admin.sock` / `admin.token` | daemon | teesim-uds | Unix socket + token 文件 |
| `pif-proxy.conf` / `pif-proxy.auto` | 用户 / 自动探测 | keybox-fetch + pif-fetch **共享** | 首行代理 URL |

---

## 5. Rust 侧落点建议

**单一二进制 + 多入口名**：
```
crates/fusionctl/            # bin crate，argv[0] 分发自命令
  src/main.rs                # 按 argv[0] basename 路由
  src/cmd/keybox_fetch.rs
  src/cmd/keybox_check.rs
  src/cmd/pif_fetch.rs
  src/cmd/pif_sync.rs
  src/cmd/engine_verdict.rs  # 可选：若下沉
  src/cmd/engine_check.rs
  src/cmd/keybox_swap.rs
  src/store.rs               # 全部数据文件的读写，唯一 source of truth
```

`customize.sh` 里注入 4 个（或 7 个）符号链接：
```
ln -sf fusionctl "$MODPATH/keybox-fetch.sh"
ln -sf fusionctl "$MODPATH/keybox-check.sh"
...
```
——WebUI 零改动，因为 `sh <symlink>` 走的是 shebang。

**理由**：
1. 数据文件格式集中在 `store.rs` 一处，避免 shell 版「同一规则复制三份」的老问题；
2. 单二进制省模块 zip 体积（当前已有 `libcertgen.so` 等 4 个 .so）；
3. 入口名保持不变 = WebUI 契约自动满足。

---

## 6. 实现前必须确认（阻塞项）

1. **Rust 基座是否提供 admin socket 的 `/status`？**
   `engine-verdict.sh` 的 `socket_ack_state()` 依赖 `"push":{"last":N}` / `"ack":{"last","applied","failed"}` 四个字段。
   shell 版由 `0007-engine-status-socket.patch` 提供。需先核对 RS 的 `app/src/main/java/.../KeyAdmin.kt` 是否暴露等价端点、字段名是否一致。
   → **若没有，P2 的 socket 兜底路径无法迁移**，需先在 Kotlin 侧补。

2. **`keybox-refresh` 默认值**：`launcher.js:70` 与 `logs.js:342` 回落到 `ref=24`，而项目近年已锁定 **12h**。
   迁移时要确认「默认 24」是刻意保留的兜底，还是漏改。**建议在动 Rust 之前先统一**。

3. **下载阶梯的网络可达性**：脚本注释记录了 2026-09-13 的实际事故（受限网络下所有 `raw.githubusercontent.com` 不可达，自动刷新静默失效）。
   Rust 侧必须复刻四档降级 + 代理三级来源，否则会重演。

4. **`mask_ids` 的四份副本**：`scripts/test-mask-ids.sh` 断言四份实现字节一致。
   Rust 侧改为单实现后，该测试的断言目标要改（或删除）。

---

## 7. 「逻辑不变」的边界

| | 项 |
|---|---|
| **可改** | 内部实现语言、并发模型、错误处理结构、日志措辞（非契约部分） |
| **不可改** | ① 脚本文件名与入口名 ② 退出码语义 ③ `.engine-verdict` 键集与锚点判定顺序 ④ `.kb-fetch.progress` 三行格式 ⑤ `.auto-keybox` 语义 ⑥ `.key-status-n` 的 `-1` 哨兵 ⑦ `keybox.xml` 原子 rename 部署方式 |
| **建议新增** | `--version`（不破坏现有契约） |
