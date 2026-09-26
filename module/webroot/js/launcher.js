/* Aegis Fusion WebUI — single-page, "already configured" dashboard.
 *
 * Composition (v3.x, fingerprint payload bundled):
 *   1. Status lights: TEE engine daemon / keybox validity / BL-hiding props /
 *      built-in fingerprint (pif-fetch generated or user-provided).
 *   2. Keybox auto-refresh controls (interval chips + refresh now).
 *   3. Protected-apps entry card: count of protected apps + link to the
 *      dedicated apps page (apps.html owns selection). A checked app is written
 *      to /data/adb/teesim/config.json -> profiles.<active>.apps, which the TEE
 *      daemon resolves on its next push (same contract TEESimulator's own WebUI
 *      uses). The BL/prop hiding layer is global and needs no per-app config.
 *
 * All privileged work goes through the KernelSU WebUI exec bridge. Nothing loads
 * from the network; app icons come from the TEE daemon over its root-only unix socket.
 */
(function () {
    'use strict';

    // 常量唯一来源：js/conf.js。浏览器走 window.AEGIS；Node（scripts/test-webui.js
    // 会 require 本文件）没有 window，退回 require('./conf.js')。
    // 缺失即抛错，不静默回落 —— 路径分歧曾让两条发布线互相覆盖配置。
    var C = (typeof window !== 'undefined' && window.AEGIS) || null;
    if (!C && typeof require === 'function') { try { C = require('./conf.js'); } catch (e) { C = null; } }
    if (!C) throw new Error('aegis: js/conf.js 未加载（缺常量来源）');
    var MODID = C.MODID;
    var MODPATH = C.MODPATH;
    var TEE_DIR = C.TEE_DIR;
    var PROC = C.PROC;
    var CONFIG = TEE_DIR + '/config.json';
    var HELPER = TEE_DIR + '/teesim-uds';
    var SOCK = TEE_DIR + '/admin.sock';
    var TOKEN_FILE = TEE_DIR + '/admin.token';

    // One root shell probe that always exits 0 and prints parseable lines.
    // DAEMON: liveness is decided the same way TEESimulator's own WebUI does it —
    //         a GET /status round-trip over the daemon's root-only admin socket
    //         (pgrep against app_process nice-names is unreliable across Android
    //         versions, and produced permanent "not running" false alarms).
    // HOOK  : the interceptor lib the daemon's /status reports (empty = not attached).
    // DVER  : daemon build version from /status.
    // PG/DEX/SOCK: raw diagnostics for the not-running case (process visible via
    //         pgrep as a fallback signal, daemon dex present, socket file present).
    // VER   : fusion module.prop version (display only).
    // KEYBOX/KBG/KBS/KBAGE/KBERR/REF: keybox state, identical to v1.x semantics.
    // KBMARK/KBSRC: auto-managed vs user-imported, and which channel supplied
    //         the deployed keybox (v2.2.8 multi-source fetcher).
    // BL*   : live bootloader/verified-boot/build-tag props as the box layer left them.
    var PROBE =
        // RS 线：探针数据源已整体移植为 fusionctl 的 ui-probe 子命令（95 键
        // 逐键差分对拍见 scripts/test-diff-ui-probe.sh）。JS 侧的解析与渲染
        // 逻辑不变 —— 本字符串只是 ROOT shell 要执行的一条命令。
        MODPATH + '/fusionctl ui-probe launcher';

// ---------- TEE daemon transport lives in apps.js (the only page that talks
    // to the daemon); the dashboard renders state from the shell probe + config. ----------

    // ---------- config.json (the per-app scope contract) ----------

    // ---------- KernelSU WebUI exec bridge ----------
    // Callback form FIRST (the path the official kernelsu npm library uses and the one
    // proven to work on-device), synchronous string-returning overload as fallback, with
    // backstop + give-up timers. Proven in fusion v1.3.x.
    function exec(cmd) {
        var ksu = window.ksu;
        if (!ksu || typeof ksu.exec !== 'function') {
            return Promise.reject(new Error('no-ksu-api'));
        }
        return new Promise(function (resolve, reject) {
            var settled = false;
            var name = '__fusion_cb_' + Date.now() + '_' + Math.floor(Math.random() * 1e5);
            function finish(ok, v) {
                if (settled) return;
                settled = true;
                try { delete window[name]; } catch (_) { window[name] = undefined; }
                clearTimeout(backstop);
                clearTimeout(giveUp);
                (ok ? resolve : reject)(v);
            }
            window[name] = function (code, stdout, stderr) {
                if (code === 0) finish(true, stdout == null ? '' : String(stdout));
                else finish(false, new Error(stderr || ('exit ' + code)));
            };
            var callbackLaunched = false;
            try {
                ksu.exec(cmd, '{}', name);
                callbackLaunched = true;
            } catch (e) { /* no 3-arg overload on this build */ }

            var backstop = setTimeout(function () {
                if (settled) return;
                try {
                    var direct = ksu.exec(cmd); // runs the command again
                    if (typeof direct === 'string' && direct.length > 0) {
                        finish(true, direct);
                        return;
                    }
                } catch (e2) { /* no 1-arg overload either */ }
                if (!callbackLaunched) finish(false, new Error('exec unavailable'));
                // else keep waiting for the callback
            }, 1500);

            var giveUp = setTimeout(function () {
                finish(false, new Error('exec timeout (callback never fired)'));
            }, 5000);
        });
    }

    // ---------- shell helpers (the only place command strings are built) ----------
    // POSIX single-quote one token; everything between the quotes is inert data.
    function q(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }
    function readFile(path) {
        // cat prints nothing for an absent file — absent and empty are the same here.
        return exec('cat ' + q(path)).then(function (out) { return String(out || ''); },
            function () { return ''; });
    }
    // Injection-safe atomic write: base64 in JS, heredoc with an impossible EOF marker,
    // decode into a temp file in the target's directory, atomic mv.
    function writeFileAtomic(path, text) {
        var b64 = btoa(unescape(encodeURIComponent(text))); // UTF-8 safe
        var marker = 'FUSION_EOF_' + Math.random().toString(36).slice(2);
        var tmp = TEE_DIR + '/.write.tmp.' + Math.random().toString(36).slice(2);
        // chmod 0600 (audit DP-1): these targets live in the root-only TEE_DIR
        // and carry identity data (config.json: IMEI/serial); the shell side
        // already enforces 0600, so the WebUI write path matches it.
        var script =
            'base64 -d > ' + q(tmp) + " <<'" + marker + "' && " +
            'mv -f ' + q(tmp) + ' ' + q(path) + ' && chmod 0600 ' + q(path) + '\n' +
            b64 + '\n' + marker + '\n';
        return exec(script).then(function () { return { ok: true }; }, function (e) {
            return { ok: false, error: (e && e.message) || 'write failed' };
        });
    }

    // ---------- TEE daemon transport lives in apps.js (the only page that talks
    // to the daemon); the dashboard renders state from the shell probe + config. ----------

    // ---------- config.json (the per-app scope contract) ----------
    function loadConfig() {
        return readFile(CONFIG).then(function (raw) {
            if (!raw || !raw.trim()) return { ok: false, error: 'missing' };
            var cfg;
            try { cfg = JSON.parse(raw); } catch (e) { return { ok: false, error: 'invalid JSON' }; }
            if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg) ||
                !cfg.profiles || typeof cfg.profiles !== 'object' || Array.isArray(cfg.profiles)) {
                return { ok: false, error: 'unexpected shape' };
            }
            return { ok: true, config: cfg };
        });
    }
    // The profile the fusion edits: "default" when present, else the first one.
    function pickProfile(cfg) {
        if (cfg.profiles.default) return 'default';
        return Object.keys(cfg.profiles)[0] || null;
    }
    // A real package entry: dotted name, optional "@<userId>". Garbage from the
    // v2.2.0 apps-sync pollution (shell error tokens) must not be counted.
    var VALID_ENTRY_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+(?:@\d+)?$/;

    // ---------- tiny DOM helpers ----------
    function $(id) { return document.getElementById(id); }
    function setState(row, cls, text) {
        var dot = row.querySelector('.dot');
        var val = row.querySelector('.value');
        row.classList.remove('ok', 'warn', 'err', 'unknown');
        if (cls) row.classList.add(cls);
        if (dot) dot.className = 'dot' + (cls ? ' ' + cls : '');
        if (val) {
            val.textContent = text;
            // The value column is nowrap+ellipsis to keep the list compact;
            // when the text does not fit, wrap to a second line instead of
            // clipping the message mid-word (scrollWidth sees the full text
            // even while the CSS hides the overflow). Belt and braces: also
            // check the row itself, in case some future style change moves
            // the clipping box up a level again.
            if (val.scrollWidth > val.clientWidth + 1 ||
                row.scrollWidth > row.clientWidth + 1) row.classList.add('wrap');
            else row.classList.remove('wrap');
        }
    }
    function shorten(s) {
        s = String(s || '').trim();
        if (s.length <= 34) return s;
        return s.slice(0, 22) + '…' + s.slice(-10);
    }

    // ---------- session state ----------
    var state = {
        probe: {},            // parsed shell probe
        config: null,         // parsed config.json (when readable)
        profileName: null,    // the profile the fusion edits
        selected: {}          // entry -> true (draft = saved config's apps)
    };

    // ---------- status rendering ----------
    function renderStatus() {
        var st = state.probe;
        var teeRow = $('st-tee'), kbRow = $('st-keybox'), blRow = $('st-bl');
        if (!teeRow || !kbRow || !blRow) return;

        if (String(st.uid).trim() !== '0') {
            setState(teeRow, 'unknown', '读取失败 · 点右上角重试');
            setState(kbRow, 'unknown', '读取失败 · 点右上角重试');
            setState(blRow, 'unknown', '读取失败 · 点右上角重试');
            var noApi = $('noapi');
            if (noApi) { noApi.hidden = false; }
            var kbCtrl = $('kb-ctrl');
            if (kbCtrl) kbCtrl.hidden = true;
            var pifCtrl = $('pif-detail');
            if (pifCtrl) pifCtrl.hidden = true;
            return;
        }
        var noApi2 = $('noapi');
        if (noApi2) noApi2.hidden = true;
        var kbCtrl2 = $('kb-ctrl');
        if (kbCtrl2) kbCtrl2.hidden = false;
        var pifCtrl2 = $('pif-detail');
        if (pifCtrl2) pifCtrl2.hidden = false;

        // TEE engine — daemon liveness comes from the admin socket (upstream
        // semantics); PG/DEX/SOCK distinguish *why* it is down when it is.
        if (st.daemon === 'yes') {
            var hookTxt = (st.dver ? ' · ' + st.dver : '');
            if (st.hook && st.hook !== 'unknown' && st.hook !== '') {
                setState(teeRow, 'ok', '运行中' + hookTxt + ' · 注入已生效');
            } else {
                setState(teeRow, 'warn', '运行中' + hookTxt + ' · 注入未上报（稍后重试或重启手机）');
            }
        } else if (st.pg === 'yes') {
            setState(teeRow, 'err', '进程存在但控制通道不通 — 重启手机');
        } else if (st.dex !== 'yes') {
            setState(teeRow, 'err', '引擎文件缺失 — 请重装模块');
        } else if (st.sock !== 'yes') {
            setState(teeRow, 'err', '未运行 — 重启一次手机；若仍如此请重装模块');
        } else {
            setState(teeRow, 'err', '未运行 — 尝试重启一次手机');
        }

        // Keybox. Honest semantics (v2.2.8): the community status file describes
        // the CHANNEL's latest keybox — it is NOT Google's live verdict on the
        // keybox deployed here (Google publishes no per-keybox status endpoint),
        // it pairs only with the channel that actually supplied this keybox,
        // and it says nothing about a user-imported one. The light stays SHORT
        // (greens + verdict only); refresh age, channel, status detail and the
        // channel picker live in the collapsible 渠道与详情 panel below.
        var age = parseInt(st.kbage, 10) || 0;
        var kbRunning = String(st.kbrun) === 'yes';
        // A long fetch must say WHAT it is doing and for how long (v3.1.5). The row
        // itself stays short; the stage/detail goes in the collapsible panel.
        var kbProg = String(st.kbprog || '').trim();
        var kbProgT = parseInt(st.kbprogt, 10) || 0;
        var kbElapsed = kbProgT > 0 ? Math.max(0, Math.floor(Date.now() / 1000) - kbProgT) : -1;
        var runTxt = kbRunning ? ' · 刷新中' + (kbElapsed >= 0 ? ' ' + kbElapsed + 's' : '…') : '';
        var ageTxt = age > 0 ? (age >= 24 ? Math.floor(age / 24) + ' 天' : age + ' 小时') + '前' : '—';
        var srcName = String(st.kbsrc || '').trim();
        var pref = String(st.kbpref || '').trim();
        var kbg = parseInt(st.kbg, 10);
        var imported = String(st.kbmark) !== 'yes';
        var hasBox = st.keybox === 'yes';
        kbImported = hasBox && imported;

        // Local certificate-expiry clock: REMOVED (v2.2.10 field report) — the
        // shell-side extraction never produced a date on real devices (no
        // openssl, DER-grep too fragile), so the row always showed "—". The
        // honest local judgement is the revocation check below, which works.

        var rev = String(state.kbrev || 'unknown'); // ok|revoked|suspended|unknown
        var reva = parseInt(st.reva, 10);
        if (isNaN(reva)) reva = -1;

        // Three-cell status: greens for the community count, reds filling the
        // rest — 2 green reads as 🟢🟢🔴 at a glance instead of a bare "🟢🟢".
        function keyStatusCells(n) {
            if (isNaN(n) || n < 0) return '';
            var g = Math.max(0, Math.min(3, n));
            return new Array(g + 1).join('🟢') + new Array(3 - g + 1).join('🔴');
        }
        var cells = keyStatusCells(kbg);

        // Quiet-unless-wrong (v2.2.10 user feedback): the greens are the
        // CHANNEL's report about the CHANNEL's box, not a device verdict. The old
        // build left them completely bare on the theory that any suffix read like a
        // device verdict — but bare is exactly how "🟢🟢🟢" got read as "the phone is
        // fine" while the engine was refusing the keybox (v3.1.3 field report:
        // "it shows three greens, but actually it is one"). So the greens now carry
        // their provenance, and the ENGINE's verdict (below) outranks them.
        var cls = 'ok';
        var lightVal;
        if (!hasBox) {
            cls = 'warn';
            lightVal = (cells ? '未获取 · ' + cells : '未配置 · 开机后自动获取') + runTxt;
        } else if (imported) {
            lightVal = '用户导入' + runTxt;
        } else if (kbg === 3) {
            lightVal = cells + ' · 渠道自述' + runTxt;
        } else if (kbg === 2) {
            cls = 'warn';
            lightVal = cells + ' · 渠道自述 · 受限' + runTxt;
        } else if (kbg === 1) {
            cls = 'err';
            lightVal = cells + ' · 渠道自述 · 严重受限' + runTxt;
        } else if (kbg === 0) {
            cls = 'err';
            lightVal = cells + ' · 渠道自述 · 已吊销 · 等待刷新' + runTxt;
        } else {
            // kbg < 0 is NOT "unknown". keybox-fetch.sh writes -1 deliberately when
            // the winning channel publishes no status file at all (Yurikey does not).
            // Printing "状态未知" next to "引擎已加载" reads as a problem when the only
            // real fact is that this channel has no self-report feed — a field report
            // read it exactly that way. Say what is actually true.
            lightVal = '已配置 · 渠道无自述' + runTxt;
        }
        // Local truth, in order of authority.
        //
        // 1. THE ENGINE'S OWN VERDICT (v3.1.3). This is the device's actual answer
        //    about the keybox deployed right now: the TA could not build a profile
        //    from it, so every request is forwarded to the real HAL. It outranks
        //    every channel feed, and it prints the engine's own reason.
        var kbev = String(st.kbev || 'unknown');
        var kbrs = String(st.kbrs || '').trim();
        if (hasBox && kbev === 'rejected') {
            cls = 'err';
            lightVal = (imported ? '用户导入 · ' : '')
                + '引擎拒绝：' + (kbrs || '无法用它构建 TA')
                + (cells ? ' · 渠道自述 ' + cells : '')
                + ' · 请换渠道或手动获取' + runTxt;
        } else if (hasBox && kbev === 'ok') {
            // The engine is serving this keybox — the one thing the chips cannot say.
            lightVal = lightVal + ' · 引擎已加载' + runTxt;
        } else if (hasBox && kbev === 'stale') {
            lightVal = lightVal + ' · 待引擎确认（keybox 刚变更）' + runTxt;
        }
        // 2. Google revocation, checked locally against the deployed chain.
        // Community chips lag behind real revocations, and a user-imported box
        // has no chips at all. Quiet when fine; loud when the box is dead.
        if (hasBox && rev === 'revoked') {
            cls = 'err';
            lightVal = (imported ? '用户导入 · ' : '') + '本机实测：已被 Google 吊销 · 请手动获取或换渠道' + runTxt;
        } else if (hasBox && rev === 'suspended') {
            if (cls === 'ok') cls = 'warn';
            lightVal = (imported ? '用户导入 · ' : '') + '本机实测：已被 Google 暂停' + runTxt;
        }
        setState(kbRow, cls, lightVal);

        // Collapsible panel — everything that would bloat the light row.
        function setD(id, text, cls2) {
            var n = $(id);
            if (n) n.textContent = text;
            if (n) {
                n.classList.toggle('err', cls2 === 'err');
                n.classList.toggle('warn', cls2 === 'warn');
            }
        }
        setD('kb-d-src', !hasBox ? '—' : imported ? '用户导入'
            : (srcName || '自动轮换') + (pref && pref !== srcName ? '（优先 ' + pref + '）' : ''));
        setD('kb-d-refresh', hasBox
            ? ageTxt + ' · 间隔 ' + intervalText(st.ref) +
                (kbRunning
                    ? ' · 刷新中' + (kbProg ? '：' + kbProg : '') +
                      (kbElapsed >= 0 ? '（本阶段已 ' + kbElapsed + ' 秒）' : '')
                    : '')
            : '—');
        // kb-d-validity row removed (v2.2.10): the shell could never extract
        // the expiry on real devices, so it permanently showed "—".
        // 在线状态行:仅用户导入时出现。本地能真实测的是结构/序列号与吊销名单,
        // "几绿"取决于 Google 服务端的吊销名单,无法离线判断——如实说明,
        // 指向 PIAC 实测。自动管理的 keybox 其绿格已在状态灯上,不重复。
        var statusRow = $('kb-d-status-row');
        if (statusRow) statusRow.hidden = !(hasBox && imported);
        if (hasBox && imported) {
            // v2.2.9: the revocation check makes this row a real verdict for
            // imported boxes too — no more "无法在线判断" when the cache is warm.
            var revD;
            if (rev === 'ok') {
                revD = '本机实测：未在 Google 吊销列表' + (reva > 0 ? '（' + reva + ' 小时前更新）' : '') + ' · 仍以 PIAC 实测为准';
            } else if (rev === 'revoked') {
                revD = '本机实测：已被 Google 吊销 · "手动获取"可接管';
            } else if (rev === 'suspended') {
                revD = '本机实测：已被 Google 暂停';
            } else {
                revD = '本机实测数据暂缺 · 联网后每小时自动与 Google 官方列表比对';
            }
            setD('kb-d-status', revD, rev === 'revoked' ? 'err' : rev === 'suspended' ? 'warn' : undefined);
        }
        var kbe = String(st.kberr || '');
        // The engine's refusal outranks a fetch-log error: it names the reason the
        // TA could not build a profile from the deployed keybox.
        if (kbev === 'rejected') {
            setD('kb-d-err', '引擎拒绝：' + (kbrs || '无法用它构建 TA（无原因输出）'), 'err');
        } else {
            setD('kb-d-err', kbe || '无');
        }
        var refV = parseInt(st.ref, 10);
        if (isNaN(refV)) refV = 24; // 0(关闭)是合法值,不能走 || 默认
        var ivD = intervalParts(refV);
        var sum = $('kb-detail-sum');
        if (sum) {
            sum.textContent = !hasBox ? ('未配置 · ' + ivD[0] + ivD[1])
                : imported ? ('用户导入 · ' + ivD[0] + ivD[1])
                    : ((pref && pref !== srcName ? '优先 ' + pref + ' · ' : '') + '现用 ' + (srcName || '自动轮换') + ' · ' + ivD[0] + ivD[1]);
        }
        // While a fetch runs in the background, the button is a no-op — say so
        // instead of letting a second click stack another fetch. 手动获取 always
        // works: it force-fetches from the preferred channel and takes over.
        var kbBtn = $('kb-now');
        if (kbBtn && !refreshingKb) {
            kbBtn.disabled = kbRunning;
            kbBtn.textContent = kbRunning ? '后台刷新中…' : '手动获取';
        }

        // BL hiding — one word per state (v2.2.10 user feedback): the props
        // behind the verdict live in the module's own logs, nobody needs
        // vbmeta=reminder noise on the status list.
        var vb = String(st.bl1 || ''), vbst = String(st.bl2 || '');
        var good = (vb === 'locked' && vbst === 'green');
        if (good) {
            setState(blRow, 'ok', '已生效');
        } else if (vb || vbst) {
            setState(blRow, 'warn', '部分生效');
        } else {
            setState(blRow, 'unknown', '暂无数据 · 重启后生效');
        }

        // Fingerprint layer — the other half of the Play Integrity story. The
        // payload is BUNDLED since v3.0 (no separate module needed): the
        // fingerprint lives in this module's own dir (auto-generated by
        // pif-fetch.sh or user-provided custom.pif.prop), and pif-sync.sh
        // mirrors its identity into the TEE profile so both halves agree.
        // quiet-unless-wrong: a working setup is one green cell; only a
        // missing fingerprint or a missing Zygisk environment gets words.
        var pifRow = $('st-pif');
        if (pifRow) {
            var psrc = String(st.pifsrc || '').trim();
            var zyg = String(st.zyg || '').trim();
            var plabel = '';
            // Rotation phase (v3.2.2): only our own auto-managed fingerprints
            // ever warn. A user-imported file is the user's decision — never
            // graded, never nagged. Two escalation levels, both pointing at
            // the manager action button / import; no network specifics here.
            var pifst = String(st.pifst || 'ok');
            var pifauto = String(st.pifauto || 'no');
            if (!psrc) {
                setState(pifRow, 'warn', '指纹未生成 · 重启后自动获取（需网络）');
            } else if (zyg === 'no') {
                setState(pifRow, 'warn', 'Zygisk 未启用 · 需启用后重启（无 Zygisk 只能 BASIC）');
            } else if (pifauto === 'yes' && pifst === 'expired') {
                setState(pifRow, 'err', '指纹已过期 · 请重新获取');
            } else if (pifauto === 'yes' && pifst === 'soon') {
                setState(pifRow, 'warn', '指纹即将到期 · 建议重新获取');
            } else {
                var builtin = psrc.indexOf('/' + MODID + '/') !== -1;
                plabel = builtin
                    ? (psrc.indexOf('.json') !== -1 ? '内置 · 用户指纹' : '内置 · 自动指纹')
                    : '外部指纹模块';
                setState(pifRow, 'ok', plabel + ' · 身份已同步');
            }
            // Collapsible detail panel mirrors the Keybox one: source path and
            // the import path for network-dead environments (v3.0.5). R7-1
            // (2026-09-19) adds the provenance breakdown per the author-approved
            // preview (docs/design/pif-source-preview-20260916.html): 安装时抓取 /
            // 运行时抓取 (both device-specific) vs 包内种子 (shared fallback,
            // swapped automatically once the network works).
            var prov = String(st.pifprov || '').trim();
            var pmodel = String(st.pifmodel || '').trim();
            var provLabel = '';
            if (prov === 'install-fetch') provLabel = '本机专属（安装时随机抓取）';
            else if (prov === 'runtime-fetch') provLabel = '本机专属（运行时随机抓取）';
            else if (prov === 'seed') provLabel = '包内种子（保底中）';
            else if (prov === 'user') provLabel = '用户导入（自有文件）';
            else if (prov === 'legacy') provLabel = '已有身份（升级前继承，来源未记录）';
            var pSum = $('pif-detail-sum'), pSrcV = $('pif-d-src');
            if (pSum) pSum.textContent = psrc ? (provLabel || plabel || '已就位') : '未生成 · 可导入';
            if (pSrcV) {
                if (provLabel) {
                    pSrcV.textContent = provLabel + (pmodel ? ' · ' + pmodel : '');
                } else {
                    pSrcV.textContent = psrc || '未生成 · 自动获取需网络，或导入文件';
                }
            }
            var pWarn = $('pif-d-warn');
            if (pWarn) {
                if (psrc && pifauto === 'yes' && (pifst === 'soon' || pifst === 'expired')) {
                    pWarn.textContent = '自动轮换暂未成功：可在管理器的模块操作列表 → 本模块 → ⚡ 操作按钮中重新获取一次，或导入自己的指纹文件。';
                    pWarn.hidden = false;
                } else if (psrc && prov === 'seed') {
                    pWarn.textContent = '正在使用共享保底身份（与同批安装的用户相同），联网后会自动随机更换，无需操作；也可以现在点按管理器模块列表 → 本模块 → ⚡ 操作按钮手动抓取（需网络）。保底身份不影响任何功能，建议联网后尽早更换。';
                    pWarn.hidden = false;
                } else if (psrc && prov === 'user') {
                    pWarn.textContent = '当前使用你导入的指纹文件（最高优先，自动轮换不会覆盖它）。如需更换：重新导入，或点按管理器模块列表 → 本模块 → ⚡ 操作按钮随机抓取一份新的（会接管为自动管理，原文件保留在 /data/adb/teesim/pif-master）。';
                    pWarn.hidden = false;
                } else if (psrc && prov === 'legacy') {
                    pWarn.textContent = '当前使用的是升级前继承的身份（旧版本未记录来源）。自动轮换会在到期时随机更换；也可以点按管理器模块列表 → 本模块 → ⚡ 操作按钮立即随机抓取一份新的。';
                    pWarn.hidden = false;
                } else if (psrc && (prov === 'install-fetch' || prov === 'runtime-fetch')) {
                    pWarn.textContent = '本机专属身份，与包内种子不同。如需立即更换：管理器模块列表 → 本模块 → ⚡ 操作按钮（随机抓取并立即同步，会重新拉起引擎）。包内种子仅作保底，正常情况下不会用到。';
                    pWarn.hidden = false;
                } else {
                    pWarn.hidden = true;
                }
            }
        }

        // keybox hint with the last fetch error, as in v1.x
        var kbHint = $('kb-hint');
        if (kbHint) {
            var kbe = String(st.kberr || '');
            kbHint.textContent = (kbe ? '上次刷新错误：' + kbe + '。' : '') +
                '绿格是渠道方对“渠道最新 keybox”的报告，不是本机判定；本机 keybox 每小时与 Google 官方吊销列表比对，仅异常时在此提示。最终以 PIAC 实测为准（检测应用需加入受保护列表）。指纹伪装已内置：开机自动生成并同步身份（需网络，需 Zygisk）；拉取失败时在下方“指纹伪装层”详情里导入 pif.json / custom.pif.prop 即可，无需重启。“手动获取”按当前渠道强制抓取一次；导入自己的 keybox.xml 后自动刷新会让路、不会覆盖。';
            kbHint.hidden = false;
        }
        renderSourceTrigger(st.kbpref || '');
        renderInterval(refV);
    }

    // 刷新时间折叠栏:数值 <-> 显示映射。数值与 keybox-refresh 文件、
    // keybox-fetch.sh 的间隔约定一致(0/12/24/72/168 小时)。
    var INTERVAL_DISPLAY = {
        0: ['off', ''], 12: ['12', 'h'], 24: ['24', 'h'], 72: ['3', 'd'], 168: ['1', 'w']
    };
    // 间隔数值的**唯一解释规则**(2026-09-19)。同一个设置会被三处描述:执行者
    // (service.sh 每小时循环,它对数值没有白名单,写多少就按多少跑)、安装总结
    // (customize.sh)与本页。三者不能各说各话 —— 否则用户看到的就是"安装界面
    // 一种、WebUI 一种",而作者点出的正是这一点:显示不一致 = 两个显示都没有意义。
    // 因此不在胶囊档位里的值(手改过 keybox-refresh、或由别的版本写入)**按原值
    // 显示**,不再静默回落成 24h;0 表示关闭,读作"已关闭"而不是"0 小时"。
    function intervalNum(v) {
        var n = parseInt(v, 10);
        if (!isFinite(n) || n < 0) n = 24;   // 缺失/垃圾值 -> 与执行者同款的默认
        return n;
    }
    function intervalText(v) {
        var n = intervalNum(v);
        return n === 0 ? '已关闭' : n + ' 小时';
    }
    function intervalParts(v) {
        var n = intervalNum(v);
        if (n === 0) return ['off', ''];
        return INTERVAL_DISPLAY[n] || [String(n), 'h'];
    }
    function renderInterval(v) {
        var d = intervalParts(v);
        var num = $('kb-interval-num'), unit = $('kb-interval-unit');
        if (num) num.textContent = d[0];
        if (unit) unit.textContent = d[1];
        var pop = $('kb-interval-pop');
        if (!pop) return;
        var opts = pop.querySelectorAll('.kb-opt');
        for (var i = 0; i < opts.length; i++) {
            opts[i].classList.toggle('sel', opts[i].getAttribute('data-v') === String(v));
        }
    }

    // 获取渠道:同款胶囊 + 下拉气泡。pref = '' 表示自动轮换。
    function renderSourceTrigger(pref) {
        var val = $('kb-source-val');
        if (val) val.textContent = pref || '自动';
        var pop = $('kb-source-pop');
        if (!pop) return;
        var opts = pop.querySelectorAll('.kb-opt');
        for (var i = 0; i < opts.length; i++) {
            opts[i].classList.toggle('sel', (opts[i].getAttribute('data-s') || '') === String(pref || ''));
        }
    }

    // ---------- protected apps: entry card ----------
    // Selection lives on the dedicated apps page (apps.html); the dashboard
    // shows one rectangular card: icon, title and how many apps are protected.
    function renderAppsEntry() {
        var card = $('apps');
        if (!card) return;
        var rooted = String(state.probe.uid).trim() === '0';
        card.hidden = !rooted;
        var sub = $('apps-entry-sub');
        if (!sub) return;
        var n = Object.keys(state.selected).length;
        if (!state.config) {
            sub.textContent = '配置不可读 · 点按查看详情';
        } else if (!n) {
            sub.textContent = '暂未选择保护的应用 · 点按开始';
        } else {
            sub.textContent = '已保护 ' + n + ' 个应用 · 点按管理';
        }
    }

    // ---------- status probe / refresh ----------
    var probing = false;
    // While a fetch runs, re-probe on a timer. The progress file is rewritten on
    // every stage, but the panel only re-reads it when refresh() runs — without this
    // it kept showing whatever stage happened to be live when the page loaded, which
    // is the field report "刚开始显示后台刷新中一直不更新". The budget (~10 min at 5s)
    // bounds the polling so a stuck lock cannot spin forever.
    var kbPollTimer = null, kbPollLeft = 0, kbWasRunning = false;
    function scheduleKbPoll() {
        if (kbPollTimer || kbPollLeft <= 0) return;
        kbPollTimer = setTimeout(function () {
            kbPollTimer = null;
            kbPollLeft--;
            refresh();
        }, 5000);
    }
    function refresh() {
        if (probing) return;
        probing = true;
        var spin = $('refresh');
        if (spin) spin.classList.add('spin');
        var lastErr = '';
        // one retry: the very first probe after page load can race shell setup
        exec(PROBE)
            .catch(function (e) {
                lastErr = (e && e.message) || 'unknown error';
                return exec(PROBE);
            })
            .catch(function (e) {
                lastErr = (e && e.message) || 'unknown error';
                return 'UID=none';
            })
            .then(function (out) {
                state.probe = parseProbe(out);
                return loadConfig().then(function (c) {
                    if (c.ok) {
                        state.config = c.config;
                        state.profileName = pickProfile(c.config);
                        var prof = state.config.profiles[state.profileName];
                        var sel = {};
                        ((prof && prof.apps) || []).forEach(function (e) {
                            if (VALID_ENTRY_RE.test(String(e))) sel[String(e)] = true;
                        });
                        state.selected = sel;
                    } else {
                        state.config = null;
                        state.profileName = null;
                        state.selected = {};
                    }
                    // Local revocation verdict against Google's official list
                    // (cached by keybox-fetch.sh / --revcheck). Never throws;
                    // 'unknown' degrades to today's community-status display.
                    return revDetect(state.probe).then(function (rev) {
                        state.kbrev = rev;
                    });
                }).then(function () {
                    renderStatus();
                    renderAppsEntry();
                    var nowRunning = String(state.probe.kbrun) === 'yes';
                    if (nowRunning && !kbWasRunning) kbPollLeft = 120;   // fresh fetch
                    kbWasRunning = nowRunning;
                    if (nowRunning) scheduleKbPoll();
                });
            })
            .catch(function () { /* render errors must never kill the bridge */ })
            .then(function () {
                probing = false;
                if (spin) spin.classList.remove('spin');
                if (lastErr) {
                    var noApi = $('noapi');
                    if (noApi) {
                        noApi.hidden = false;
                        noApi.textContent = '无法通过管理器接口读取状态（' + lastErr + '），点右上角 ↻ 重试。';
                    }
                }
            });
    }

    function parseProbe(out) {
        var st = {
            uid: '', daemon: '', hook: '', dver: '',
            pg: '', dex: '', sock: '',
            ver: '', keybox: '', kbmark: '', kbsrc: '', kbpref: '', ref: '24',
            kbg: '-1', kbage: '0', kbs: '', kberr: '', kbev: 'unknown', kbrs: '',
            kbcerts: '', revj: '', reva: '', pifsrc: '', zyg: '',
            pifst: 'ok', pifd: -1, pifauto: 'no', pifexp: '',
            bl1: '', bl2: '', bl3: '', bl4: ''
        };
        String(out || '').split('\n').forEach(function (line) {
            var i = line.indexOf('=');
            // trim: guards against stray \r / whitespace from the shell bridge
            if (i > 0) st[line.slice(0, i).toLowerCase().trim()] = line.slice(i + 1).replace(/\r/g, '').trim();
        });
        return st;
    }

    // ---------- Google revocation check (v2.2.9, local truth) ----------
    // The community key-status chips lag behind reality (field report: 🟢🟢🟢 on
    // screen while PIAC only passed BASIC) and say nothing about a user-imported
    // keybox. Google publishes the authoritative per-key revocation list —
    // keybox-fetch.sh (and its --revcheck hourly pass) caches that JSON; here we
    // extract the serial number of EVERY certificate in the DEPLOYED keybox and
    // look them up in the cached list. The WebUI itself never touches the
    // network: the only request is the fetch script's hourly cache refresh.
    //
    // Serial extraction is a minimal DER walk — Certificate ::= SEQUENCE {
    // tbsCertificate ::= SEQUENCE { [0] EXPLICIT version (optional),
    // serialNumber INTEGER, ... } } — no openssl on Android, and we only ever
    // touch those tags, so a full ASN.1 parser would be dead weight.
    function certSerialHex(b64) {
        try {
            var der = atob(String(b64 || '').replace(/[^A-Za-z0-9+/=]/g, ''));
            var i = 0;
            function rdLen() {
                var b = der.charCodeAt(i++);
                if (b < 0x80) return b;
                var n = b & 0x7f, v = 0;
                while (n-- > 0) v = v * 256 + der.charCodeAt(i++);
                return v;
            }
            if (der.charCodeAt(i++) !== 0x30) return '';   // Certificate SEQUENCE
            rdLen();
            if (der.charCodeAt(i++) !== 0x30) return '';   // tbsCertificate SEQUENCE
            rdLen();
            var tag = der.charCodeAt(i);
            if (tag === 0xA0) { i++; rdLen(); tag = der.charCodeAt(i); } // [0] version
            if (tag !== 0x02) return '';                   // serialNumber INTEGER
            i++;
            var n = rdLen(), hexs = '';
            for (var k = 0; k < n; k++) {
                var b = der.charCodeAt(i + k);
                hexs += (b < 16 ? '0' : '') + b.toString(16);
            }
            return hexs.replace(/^(00)+/, '');             // DER positive-int padding
        } catch (e) { return ''; }
    }
    function revDetect(probe) {
        if (probe.revj !== 'yes') return Promise.resolve('unknown');
        var serials = [];
        String(probe.kbcerts || '').split(';').forEach(function (c) {
            if (!c) return;
            var h = certSerialHex(c);
            // only hex reaches the grep pattern — no quoting games possible
            if (/^[0-9a-f]+$/.test(h) && serials.indexOf(h) === -1) serials.push(h);
        });
        if (!serials.length) return Promise.resolve('unknown');
        var pat = '"(?:' + serials.join('|') + ')"[[:space:]]*:[[:space:]]*\\{[^}]*}';
        return exec('grep -oE ' + q(pat) + ' ' + q(TEE_DIR + '/.revocation-status.json') +
            ' 2>/dev/null | head -n 1')
            .then(function (out) {
                var s = String(out || '');
                if (/REVOKED/.test(s)) return 'revoked';
                if (/SUSPENDED/.test(s)) return 'suspended';
                return 'ok';                               // cache present, no match
            }, function () { return 'unknown'; });
    }

    // ---------- keybox controls (v1.x semantics) ----------
    var refreshingKb = false;
    var kbImported = false; // last probe saw a user-imported box (set in render)
    // The fetch runs 30s+ (network download, keystore2 restart, DroidGuard kill)
    // and must NEVER ride the regular exec bridge: that bridge gives up at 5s and
    // its 1.5s backstop re-runs the command — with a long script this stacked
    // duplicate root shells and, on managers whose single-arg exec runs
    // synchronously, hard-froze the whole WebUI (white screen, manager had to be
    // swiped away; v2.2.6 field report). Instead: detach the script into a
    // background shell (returns instantly) and poll its lock file with fast
    // commands. The script's own mkdir guard makes overlapping fetches impossible.
    var KB_BTN_LABEL = '手动获取';
    function finishKbFetch(btn, msg) {
        refreshingKb = false;
        btn.textContent = msg;
        setTimeout(function () {
            btn.disabled = false;
            btn.textContent = KB_BTN_LABEL;
        }, 2500);
    }
    function pollKbFetch(startedAt, btn) {
        exec('[ -d ' + TEE_DIR + '/.kb-fetching.lock ] && echo running || echo done')
            .then(function (out) {
                if (/running/.test(String(out))) {
                    if (Date.now() - startedAt > 180000) {
                        // 3 min and still going — stop polling (every exec costs a
                        // root shell); the fetch itself continues and the next
                        // periodic refresh() shows the result.
                        finishKbFetch(btn, '后台仍在刷新…');
                    } else {
                        setTimeout(function () { pollKbFetch(startedAt, btn); }, 3000);
                    }
                    return;
                }
                finishKbFetch(btn, '已刷新');
                setTimeout(refresh, 800);
            }, function () {
                finishKbFetch(btn, '状态查询失败，稍后自动更新');
            });
    }
    function refreshKeyboxNow() {
        if (refreshingKb) return;
        // A deployed user-imported box is the one thing 手动获取 DESTROYS (it
        // force-fetches from the channel and takes over). Ask before pulling
        // the rug — the hint text alone did not stop the confusion (v3.0.3).
        if (kbImported && typeof window.confirm === 'function' &&
            !window.confirm('当前部署的是用户导入的 keybox。\n"手动获取"会从社区渠道重新抓取并接管（你的原文件保留备份，但界面将显示为社区自动管理）。\n\n继续吗？')) {
            return;
        }
        var btn = $('kb-now');
        refreshingKb = true;
        btn.disabled = true;
        btn.textContent = '启动中…';
        // If a fetch is already running (cron / boot pass), don't spawn another —
        // just follow the existing one.
        exec('[ -d ' + TEE_DIR + '/.kb-fetching.lock ] && echo running || echo idle')
            .then(function (out) {
                if (/running/.test(String(out))) {
                    btn.textContent = '刷新中…';
                    pollKbFetch(Date.now(), btn);
                    return;
                }
                // stdin/stdout/stderr all detached so the exec pipe closes the
                // moment the spawning shell exits — nohup guards against SIGHUP.
                exec('nohup ' + MODPATH + '/fusionctl keybox-fetch --force </dev/null >/dev/null 2>&1 & echo spawned')
                    .then(function () {
                        btn.textContent = '刷新中…';
                        pollKbFetch(Date.now(), btn);
                    }, function () {
                        finishKbFetch(btn, '刷新失败（接口异常，重试）');
                    });
            }, function () {
                finishKbFetch(btn, '刷新失败（接口异常，重试）');
            });
    }

    // ---------- fingerprint import (v3.0.5) ----------
    // Network-dead environments (CN networks reset developer.android.com) leave
    // pif-fetch retrying forever with NO fingerprint on the device — and no
    // fingerprint means BASIC no matter which keybox is deployed. A user-
    // supplied pif.json / pif.prop (exported from any working device) is the
    // instant way out. The file is read in JS, base64'd over the exec bridge
    // (no quoting games), written root-side and synced immediately: pif-sync
    // mirrors the identity into the TEE profile and bounces teesim+DroidGuard,
    // so the import is live without a reboot. .pif-auto is removed so the
    // auto-rotation leaves a user fingerprint permanently alone.
    function importPifFile(file) {
        var btn = $('pif-import-btn');
        var done = function (msg) {
            if (btn) btn.textContent = msg;
            setTimeout(function () { if (btn) btn.textContent = '导入指纹文件'; }, 3000);
        };
        if (!file || !btn) return;
        var isJson = /\.json$/i.test(String(file.name || ''));
        var reader = new FileReader();
        reader.onload = function () {
            var text = String(reader.result || '');
            // Sanity gate: a fingerprint file carries identity keys; anything
            // else is a mis-pick (wrong file, XML keybox, random text). The
            // quote tolerates the JSON dialect ("BRAND": "google").
            if (!/(BRAND|FINGERPRINT|DEVICE|PRODUCT|MODEL|MANUFACTURER|security_patch)"?\s*[={:]/i.test(text)) {
                done('文件不含指纹字段（缺 BRAND/FINGERPRINT 等）');
                return;
            }
            var b64;
            try {
                b64 = btoa(unescape(encodeURIComponent(text)));
            } catch (e) { done('读取失败（编码异常）'); return; }
            var target = MODPATH + (isJson ? '/custom.pif.json' : '/custom.pif.prop');
            var other = MODPATH + (isJson ? '/custom.pif.prop' : '/custom.pif.json');
            var cmd = 'printf %s ' + q(b64) + ' | base64 -d > ' + q(target) +
                ' && rm -f ' + q(other) + ' ' + q(MODPATH + '/.pif-auto') +
                // pif-fetch mirrors the imported file into the durable master
                // (survives module updates) and never touches a user file;
                // pif-sync then mirrors the identity into the TEE profile.
                ' && ' + MODPATH + '/fusionctl pif-fetch >/dev/null 2>&1' +
                ' && ' + MODPATH + '/fusionctl pif-sync >/dev/null 2>&1; echo applied';
            btn.disabled = true;
            btn.textContent = '导入中…';
            exec(cmd).then(function () {
                done('已导入 · 身份同步中');
                setTimeout(refresh, 1200);
            }, function () {
                btn.disabled = false;
                done('导入失败（接口异常，重试）');
            });
        };
        reader.onerror = function () { done('读取文件失败'); };
        reader.readAsText(file);
    }

    // ---------- wiring ----------
    document.addEventListener('DOMContentLoaded', function () {
        var hasApi = !!(window.ksu && typeof window.ksu.exec === 'function');
        var statusEl = $('status');
        if (statusEl) statusEl.hidden = !hasApi;
        var appsEl = $('apps');
        if (appsEl) appsEl.hidden = !hasApi;
        if (!hasApi) return;

        $('refresh').addEventListener('click', refresh);
        $('kb-now').addEventListener('click', refreshKeyboxNow);
        // 指纹导入:按钮代理到隐藏 file input;选完立即清 value 以便重选同名文件。
        var pifBtn = $('pif-import-btn'), pifFile = $('pif-import');
        if (pifBtn && pifFile) {
            pifBtn.addEventListener('click', function () { pifFile.click(); });
            pifFile.addEventListener('change', function () {
                var f = pifFile.files && pifFile.files[0];
                pifFile.value = '';
                if (f) importPifFile(f);
            });
        }
        // 刷新时间:触发器开关气泡;选档写入 keybox-refresh(数值约定不变)。
        var ivTrig = $('kb-interval-trigger'), ivPop = $('kb-interval-pop');
        ivTrig.addEventListener('click', function (e) {
            e.stopPropagation();
            var open = ivPop.classList.toggle('open');
            ivTrig.classList.toggle('on', open);
            ivTrig.setAttribute('aria-expanded', open ? 'true' : 'false');
        });
        ivPop.addEventListener('click', function (e) {
            var btn = e.target;
            while (btn && btn !== ivPop && !(btn.classList && btn.classList.contains('kb-opt'))) {
                btn = btn.parentNode;
            }
            if (!btn || btn === ivPop) return;
            var v = parseInt(btn.getAttribute('data-v'), 10);
            if (isNaN(v)) return;
            renderInterval(v); // optimistic: highlight + bar text immediately
            exec('echo ' + v + ' > ' + TEE_DIR + '/keybox-refresh')
                .then(refresh)
                .catch(function () { refresh(); });
            ivPop.classList.remove('open');
            ivTrig.classList.remove('on');
            ivTrig.setAttribute('aria-expanded', 'false');
        });
        document.addEventListener('click', function (e) {
            if (ivPop.classList.contains('open') && !ivPop.contains(e.target) && !ivTrig.contains(e.target)) {
                ivPop.classList.remove('open');
                ivTrig.classList.remove('on');
                ivTrig.setAttribute('aria-expanded', 'false');
            }
        });

        // 获取渠道:同款胶囊 + 气泡。'' = 自动轮换;选档只写偏好文件,
        // 不在此发起抓取(网络动作留在"手动获取"与定时循环里)。
        var srcTrig = $('kb-source-trigger'), srcPop = $('kb-source-pop');
        srcTrig.addEventListener('click', function (e) {
            e.stopPropagation();
            var open = srcPop.classList.toggle('open');
            srcTrig.classList.toggle('on', open);
            srcTrig.setAttribute('aria-expanded', open ? 'true' : 'false');
        });
        srcPop.addEventListener('click', function (e) {
            var btn = e.target;
            while (btn && btn !== srcPop && !(btn.classList && btn.classList.contains('kb-opt'))) {
                btn = btn.parentNode;
            }
            if (!btn || btn === srcPop) return;
            var s = btn.getAttribute('data-s') || '';
            renderSourceTrigger(s); // optimistic
            var cmd = s
                ? 'echo ' + q(s) + ' > ' + TEE_DIR + '/keybox-source-pref'
                : 'rm -f ' + TEE_DIR + '/keybox-source-pref';
            exec(cmd).then(refresh).catch(function () { refresh(); });
            srcPop.classList.remove('open');
            srcTrig.classList.remove('on');
            srcTrig.setAttribute('aria-expanded', 'false');
        });
        document.addEventListener('click', function (e) {
            if (srcPop.classList.contains('open') && !srcPop.contains(e.target) && !srcTrig.contains(e.target)) {
                srcPop.classList.remove('open');
                srcTrig.classList.remove('on');
                srcTrig.setAttribute('aria-expanded', 'false');
            }
        });

        // The apps page (apps.html) owns selection; "管理应用" is a plain link there.

        refresh();
    });
}());
