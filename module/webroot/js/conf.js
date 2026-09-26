/* conf.js — WebUI 常量的【唯一定义点】
 *
 * 除本文件外，js/ css/ *.html 在两条发布线中必须逐字节相同 —— 否则又会回到
 * 「同一规则多处定义、各说各话」的老问题（mask_ids 四份副本正是前车之鉴，
 * 见 IntegrityFusion/scripts/test-mask-ids.sh 的字节一致性断言）。
 *
 * 两条线的取值差异只在 MODID / MODPATH：
 *
 *   shell 线（IntegrityFusion）:
 *       MODID   = 'aegisfusion'
 *       MODPATH = '/data/adb/modules/aegisfusion'
 *
 *   rust 线（本仓库，并行变体）:
 *       MODID   = 'aegisfusion_rs'
 *       MODPATH = '/data/adb/modules/aegisfusion_rs'
 *
 * ── 为什么 TEE_DIR 与 PROC 两线相同 ─────────────────────────────────────────
 * 本变体的引擎与 shell 线是同一个上游（JingMatrix/TEESimulator），因此：
 *   · 引擎把数据目录硬编码在源码里 —— `app/.../Const.kt` 的 `DATA_DIR =
 *     "/data/adb/teesim"`，`Control.kt` 的控制 socket、`ConfigStore.kt` 的
 *     `config.json` 监听都挂在它下面。改它要新增一个引擎补丁，得不偿失；
 *   · 进程名由引擎的 `module/daemon`（`--nice-name=teesim`）决定，补丁未改它。
 * 两线共用数据目录是**刻意**的：两者不可能同时生效（都要 hook keystore2），
 * 数据文件格式又完全一致，而 A/B 对比恰恰需要同配置才有可比性。
 * （旧版 ARCHITECTURE.md 的「配置不共享」写于 RS 基座时期 —— 那时 RS 用
 *  /data/adb/tricky_store，共享确实会互相污染。基座换成 TEESimulator 后该前提已消失。）
 *
 * ── 双模式加载（不要改回裸 `window.AEGIS = {...}`）──────────────────────────
 * 浏览器里由 <script src="js/conf.js"> 先加载，写成 window.AEGIS。
 * 但 scripts/test-webui.js / test-apps.js / test-logs.js 会在 **Node 里
 * require() 页面 JS**（那里没有 window），所以本文件同时支持 CommonJS 导出，
 * 页面侧按「先 window、后 require」的顺序取值。改坏这一层会让三个 JS 单测
 * 立刻失败 —— 那是设计好的信号，不要靠删掉检查来绕过。
 *
 * 字段说明：
 *   MODID   模块 id。同时用于 /proc/<pid>/maps 的注入判定（grep 模块目录片段）。
 *   MODPATH 模块目录。脚本入口（keybox-fetch.sh 等）与 pif/指纹文件都挂在这里。
 *   TEE_DIR 数据目录。keybox.xml、config.json、日志、admin socket、全部 marker。
 *   PROC    守护进程名。须与 module/daemon 的 --nice-name 一致，pidof 探测用。
 */
(function (root) {
    var AEGIS = {
        MODID: 'aegisfusion_rs',
        MODPATH: '/data/adb/modules/aegisfusion_rs',
        TEE_DIR: '/data/adb/teesim',
        PROC: 'teesim'
    };
    root.AEGIS = AEGIS;
    if (typeof module !== 'undefined' && module.exports) { module.exports = AEGIS; }
})(typeof window !== 'undefined' ? window : globalThis);
