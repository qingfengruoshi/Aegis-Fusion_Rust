# 测试去留清单（重写输入）

**用途**：本变体将**重写全部自有代码**（只取逻辑，见 `GAP-AND-ROADMAP.md` §12）。这份清单判定现有 14 个测试各自的去留，并抽出**让黑盒测试能继续复用**所需的接缝契约。
**判定方式**：逐文件读其调用被测对象的方式（黑盒跑 CLI vs 读源码文本）。
**状态**：分类已定稿；§3 的语义断言清单待逐个补齐。

---

## 1. 分类

### 1.1 黑盒 —— **可复用**（6 个，共 1,899 行）

共同模式：**用环境变量把路径重定向到临时目录 + 在 PATH 前面塞桩工具，然后把脚本当 CLI 跑**，检查退出码 / 输出 / 落盘文件。不读源码文本。

| 测试 | 行数 | 被测对象 | 桩与接缝 |
|---|---|---|---|
| `test-keybox-check.sh` | 220 | `module/keybox-check.sh` | 校验器是**引擎的复刻**（镜像 `rust/teesim-km/src/attest.rs` 的 `decode_pem()` + base64 crate 的 STANDARD 规则），契约是「同序、同措辞」——重写时这条必须照搬 |
| `test-engine-verdict.sh` | 274 | `module/engine-verdict.sh` | `AEGIS_TEE_DIR`；自带假 `teesim-uds` / 假 `pidof` |
| `test-keybox-fetch.sh` | 264 | `module/keybox-fetch.sh` | 假 `curl`（记录 proxy env 与 `--resolve`）、`AEGIS_KB_*` 一批 |
| `test-pif-fetch.sh` | 598 | `module/pif-fetch.sh` | 假 `autopif4` 生成器、`AEGIS_PIF_*` 一批 |
| `test-pif-sync.sh` | 337 | `module/pif-sync.sh` | `AEGIS_ADB` / `AEGIS_PROP_FILE` / `AEGIS_TEE_DIR` |
| `test-apps-sync.sh` | 206 | `module/apps-sync.sh` | 桩 `pm` / `busybox`、`AEGIS_PKG_LIST` |

### 1.2 白盒 —— **必须重写**（3 个）

| 测试 | 行数 | 为什么不能留 |
|---|---|---|
| `test-interval-rule.sh` | 179 | **14 处** `grep -n` / `sed -n` 直接定位并**提取** `customize.sh` / `service.sh` 的源码行，再对提取出的片段求值。断言的对象是 shell 的**代码结构**（如「`_kbiv=` 到 `case` 之间的块」），重写后无对象可读 |
| `test-mask-ids.sh` | 130 | 断言 `customize.sh` / `engine-check.sh` / `engine-verdict.sh` 里**三份 `mask_ids` 副本字节一致**（第四份在 `logs.js`）。重写后天然只有一份实现，该断言**失去对象 → 退休**；但要改成对实现的脱敏用例测试 |
| `test-service-props.sh` | 102 | 从 `service.sh` **抽取**「ROM-hook / 残留属性」代码块，配桩 `resetprop` 跑。同样依赖代码结构 |

### 1.3 JS —— **必须重写**（3 个，共 290 条断言）

`test-webui.js`（109）· `test-apps.js`（89）· `test-logs.js`（92）：`require()` 现有 UI 的 JS 文件并驱动 DOM。UI 重写后不再适用。**但它们的断言记录了「行为」，不只是实现**——应逐条迁移到新 UI 的测试里。

---

## 2. 测试接缝：**21 个 `AEGIS_*` 环境变量**（重写必须保留）

这是让 6 个黑盒测试能 100% 复用的**唯一前提**。现状脚本支持 21 个覆盖变量，测试实际用掉 14 个：

```
AEGIS_TEE_DIR          数据目录（用得最多）
AEGIS_MODDIR           模块目录
AEGIS_ADB              「/data/adb」根（pif-sync）
AEGIS_PROP_FILE        属性文件路径（pif-sync）
AEGIS_PKG_LIST         包列表文件（apps-sync）
AEGIS_GMS_JSON         GMS 配置（apps-sync）
AEGIS_AUTOPIF          指纹生成器路径（pif-fetch）
AEGIS_PIF_SYNC         pif-sync 入口（pif-fetch）
AEGIS_PIF_PROXY        / AEGIS_PIF_AUTOPROXY / AEGIS_PIF_PROBE / AEGIS_PIF_PROBE_PORTS
AEGIS_PIF_RETRY_WAIT   / AEGIS_PIF_ATTEMPTS / AEGIS_PIF_MAX_AGE_DAYS
AEGIS_KB_PROXY         / AEGIS_KB_AUTOPROXY / AEGIS_KB_PROBE / AEGIS_KB_PROBE_PORTS
AEGIS_KB_DIRECTIP      / AEGIS_KB_IPS
```

> **结论**：重写后的实现**必须保留这 21 个环境变量作为注入点**（名称与语义都不变）。
> 这样做的收益是把「网络、设备、时间」全部挡在测试之外 —— 6 个黑盒套件（约 1,900 行）可以直接复用，
> 而这恰好是重写过程中最需要的回归网。

⚠️ 注意：`AEGIS_*` 是**为了测试而存在的接缝**，不是产品接口。它们不该出现在面向用户的文档里，但必须在实现里保留。

---

## 3. 必须迁移的语义断言（白盒测试里「值钱」的部分）

代码结构会变，这些**语义**不能丢：

### 3.1 `keybox-refresh` 间隔（原 `test-interval-rule.sh`）
- `0 / 12 / 24 / 72 / 168` 是白名单值，`0` 表示**已关闭**（不是「立即」）；
- 同一条间隔在**三处描述、一处执行**，必须一致：`customize.sh` 的安装总结、WebUI 仪表盘、诊断导出、`service.sh` 的每小时循环；
- **单写者**：只有 WebUI 药丸写 `keybox-refresh`（原断言 `scripts/test-interval-rule.sh` 的 `single writer` 用例）；
- 12 渲染为「每 12 小时」；0 渲染为「已关闭」，**不渲染成任何周期**。

### 3.2 设备标识脱敏（原 `test-mask-ids.sh`）
- 四种形态都要覆盖：`k='v'` / `"k":"v"` / `k=v`（值到下一个分隔符） / `k v`（空格分隔且值 ≥ 4）；
- 键名集合：`secondImei` `imei2` `imei` `meid` `serialno` `serial`；
- **不得与单一上游拼写耦合**（audit r5）：连字符值、首段字母数字短于 4 的值、空格分隔值都必须被遮蔽；
- JS 侧独有的一条：**跨行拼接后的文本再脱敏**（shell 侧每行是完整记录，不会出现行尾裸 `imei=`）。
- 完整规则见 `CONTRACT-webui.md` §5。

### 3.3 ROM-hook 属性中和（原 `test-service-props.sh`）
- 非 hook ROM：该属性家族在**两个存储（persistent / ram）中都缺席**；
- hook ROM：以**上游的中和值**出现（`pixelprops.gms=false`、`spoof.gms=false`）。

### 3.4 UI 行为（290 条断言）
待逐条迁移。优先级最高的是这几类（在 `CONTRACT-webui.md` §2 已单列）：
`.engine-verdict` 陈旧锚点的三处一致、`.key-status-n` 的 `-1 ≠ 0`、用户导入 keybox 的双判据、`/status` 与 `/logs` 不得原样打印（audit N1）、诊断导出全脱敏。

---

## 4. 重写后的测试策略

| 层 | 做法 |
|---|---|
| 黑盒那 6 个 | **原样保留**，只把「被测对象」从 `sh module/xxx.sh` 换成新实现的可执行入口。保留 `AEGIS_*` 接缝是关键 |
| 白盒那 3 个 | 按 §3 的语义重写为**黑盒式**测试（喂 fixture → 看输出/落盘），不再依赖代码结构 |
| UI 那 3 个 | 随新 UI 重写；断言按 §3.4 迁移 |
| 新增 | ① `mask_ids` 单实现的对抗性用例；② 模块 id 与 `js/conf.js` 的一致性断言（若保留 conf.js 思路） |
