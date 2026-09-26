/* Aegis Fusion — unified logs & diagnostics page (logs.html).
 *
 * One job: put the three places the module already logs into a single window —
 *   1. keybox-fetch.log  (community keybox auto-fetch / refresh, shell side)
 *   2. apps-sync.log     (scope janitor: migration, pruning, errors)
 *   3. daemon log        (the TEESim engine's in-memory buffer, over the
 *                         root-only admin socket: GET /logs?after=N&max=M)
 * — plus a one-tap diagnostics export that assembles everything a bug report
 * needs (versions, live status, BL props, log tails) into one text file under
 * /sdcard/Download.
 *
 * Redaction is a hard rule, not a filter the user can forget: the export never
 * reads keybox.xml's body (only its sha256 prefix + metadata), never touches
 * admin.token, and reduces the protected-apps scope to a count. Log TAILS are
 * included verbatim because they are the actual debugging payload — the UI
 * warns (here and in the generated header) that they may contain package
 * names and should be skimmed before sharing.
 *
 * Self-contained by design: duplicates the proven exec bridge from
 * launcher.js / apps.js so the three pages never couple through shared JS.
 */
(function () {
    'use strict';

    // 常量唯一来源：js/conf.js。浏览器走 window.AEGIS；Node（scripts/test-logs.js
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

    var KB_LOG = TEE_DIR + '/keybox-fetch.log';
    var SYNC_LOG = TEE_DIR + '/apps-sync.log';
    var PIFSYNC_LOG = TEE_DIR + '/pif-sync.log'; // 双端身份同步 —— verdict 路径的关键日志，报障必看
    var PIF_LOG = TEE_DIR + '/pif-fetch.log';
    var PIF_LAST = TEE_DIR + '/pif-fetch.last'; // autopif4's raw output — the only place a generation failure explains itself
    var DEBUG_LOG = TEE_DIR + '/debug.log';
    var DEBUG_FLAG = TEE_DIR + '/.debug';
    // The engine's own durable trace: LogTail (in-process native logd reader)
    // writes every TEESimulator-tagged line here — daemon, TA and both native
    // interceptors — through rotating files. Unlike logcat it survives rotation,
    // so the boot-time "did the config ever reach the interceptor?" verdict is
    // still readable hours later.
    var ENGINE_LOG = TEE_DIR + '/log/teesim.log';

    var TAIL = 300;        // lines pulled per text log
    var DAEMON_MAX = 2000; // one /logs pull (server caps max at 2000)
    var DISPLAY_CAP = 300; // lines rendered per tab

    // ---------- KernelSU WebUI exec bridge (identical to launcher.js) ----------
    function exec(cmd) {
        var ksu = window.ksu;
        if (!ksu || typeof ksu.exec !== 'function') {
            return Promise.reject(new Error('no-ksu-api'));
        }
        return new Promise(function (resolve, reject) {
            var settled = false;
            var name = '__fusion_logs_' + Date.now() + '_' + Math.floor(Math.random() * 1e5);
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
                    var direct = ksu.exec(cmd);
                    if (typeof direct === 'string' && direct.length > 0) {
                        finish(true, direct);
                        return;
                    }
                } catch (e2) { /* no 1-arg overload either */ }
                if (!callbackLaunched) finish(false, new Error('exec unavailable'));
            }, 1500);

            var giveUp = setTimeout(function () {
                finish(false, new Error('exec timeout (callback never fired)'));
            }, 5000);
        });
    }
    function q(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }
    function readFile(path) {
        return exec('cat ' + q(path)).then(function (out) { return String(out || ''); },
            function () { return ''; });
    }
    // Injection-safe atomic write (same shape as launcher.js / apps.js).
    function writeFileAtomic(path, text) {
        var b64 = btoa(unescape(encodeURIComponent(text)));
        var marker = 'FUSION_EOF_' + Math.random().toString(36).slice(2);
        var tmp = TEE_DIR + '/.write.tmp.' + Math.random().toString(36).slice(2);
        var script =
            'base64 -d > ' + q(tmp) + " <<'" + marker + "' && " +
            'mv -f ' + q(tmp) + ' ' + q(path) + ' && chmod 0600 ' + q(path) + '\n' +
            b64 + '\n' + marker + '\n';
        return exec(script).then(function () { return { ok: true }; }, function (e) {
            return { ok: false, error: (e && e.message) || 'write failed' };
        });
    }

    // ---------- TEE daemon transport (admin socket, like apps.js) ----------
    // Same token discipline as apps.js: the token is read shell-side at
    // execution time and never crosses the exec bridge or JS memory.
    function daemonGetRaw(path) {
        return exec(q(HELPER) + ' ' + q(SOCK) + ' GET ' + q(path) +
                ' "$(cat ' + q(TOKEN_FILE) + ')"')
            .then(function (out) { return String(out || ''); }, function () { return ''; });
    }
    function daemonGet(path) {
        return daemonGetRaw(path).then(function (out) {
            try { return JSON.parse(out); } catch (_) { return null; }
        });
    }

    // ---------- log sources ----------
    // Text logs: one tail per file. Daemon: /logs is cursor-based; after=0
    // returns the OLDEST window, so when the buffer is longer than one pull
    // (nextAfter beyond what we got) slide a second pull onto the tail end.
    var state = {
        tab: 'kb',            // 'kb' | 'sync' | 'daemon' | 'debug'
        loading: false,
        exporting: false,
        debugOn: null,        // null = unknown until the first probe
        sources: {
            kb: { lines: [], loaded: false, note: '' },
            sync: { lines: [], loaded: false, note: '' },
            daemon: { lines: [], loaded: false, note: '' },
            debug: { lines: [], loaded: false, note: '' }
        }
    };

    function textLines(file) {
        return exec('tail -n ' + TAIL + ' ' + q(file) + ' 2>/dev/null')
            .then(function (out) {
                return String(out || '').replace(/\r/g, '').split('\n').filter(function (l) { return l !== ''; });
            }, function () { return []; });
    }
    function fetchDaemonLog() {
        return daemonGet('/logs?after=0&max=' + DAEMON_MAX).then(function (d) {
            if (!d || d.ok === false || !Array.isArray(d.lines)) {
                return { lines: [], note: '无法读取（守护进程未运行或刚重启）' };
            }
            var lines = d.lines;
            // /logs is cursor-based and serves the OLDEST window first; there
            // is no total in the response. A short pull means we have every
            // line. A full pull means the buffer MAY be longer — switch to the
            // raw download route, which reassembles the rotating log files and
            // keeps the NEWEST bytes within its cap (true tail semantics).
            if (lines.length < DAEMON_MAX) {
                return { lines: lines, note: '' };
            }
            return daemonGetRaw('/logs/download?max=1').then(function (txt) {
                var tail = String(txt || '').replace(/\r/g, '').split('\n')
                    .filter(function (l) { return l !== ''; });
                if (tail.length) {
                    return { lines: tail.slice(-DISPLAY_CAP), note: '' };
                }
                return { lines: lines, note: '缓冲区超长，仅显示最早的 ' + DAEMON_MAX + ' 行' };
            });
        });
    }
    function fetchDaemonStatus() {
        return daemonGet('/status').then(function (d) {
            if (!d || d.ok === false) return { running: false };
            var lib = d.lib || {};
            return { running: true, version: d.version || '', hook: lib.hook || '' };
        });
    }
    function loadSource(name) {
        var job;
        if (name === 'daemon') job = fetchDaemonLog();
        else if (name === 'debug') {
            // Show the flag state in the meta line: an empty view with the
            // switch off is "expected", not an error.
            return probeDebugFlag().then(function (on) {
                state.debugOn = on;
                renderDebugToggle();
                return textLines(DEBUG_LOG).then(function (lines) {
                    state.sources.debug.lines = lines;
                    state.sources.debug.loaded = true;
                    state.sources.debug.note = on ? '' : 'Debug 模式当前关闭 — 打开后新日志会写入这里';
                    renderTab();
                });
            });
        } else job = textLines(name === 'kb' ? KB_LOG : SYNC_LOG).then(function (lines) {
            return { lines: lines, note: '' };
        });
        return job.then(function (r) {
            state.sources[name].lines = r.lines || [];
            state.sources[name].note = r.note || '';
            state.sources[name].loaded = true;
        });
    }
    function loadAll() {
        if (state.loading) return;
        state.loading = true;
        setMeta('读取中…');
        renderTab(); // clear view into the loading state
        probeDebugFlag().then(function (on) {
            state.debugOn = on;
            renderDebugToggle();
        });
        Promise.all([loadSource('kb'), loadSource('sync'), loadSource('daemon'), loadSource('debug')])
            .catch(function () { /* per-source state already holds the failure */ })
            .then(function () {
                state.loading = false;
                renderTab();
            });
    }

    // ---------- debug mode switch ----------
    // The flag is a plain file every script checks per call; toggling it never
    // needs a daemon or service restart.
    function probeDebugFlag() {
        return exec('test -f ' + q(DEBUG_FLAG) + ' && echo on || echo off')
            .then(function (out) { return String(out || '').trim() === 'on'; },
                function () { return false; });
    }
    function renderDebugToggle() {
        var btn = $('dbg-toggle'), label = $('dbg-state');
        if (btn) {
            btn.textContent = state.debugOn ? '关闭 Debug 模式' : '开启 Debug 模式';
            btn.disabled = false;
        }
        if (label) label.textContent = state.debugOn === null ? '检测中…' : (state.debugOn ? '· 开启中' : '· 已关闭');
    }
    function toggleDebug() {
        var btn = $('dbg-toggle');
        if (btn) { btn.disabled = true; btn.textContent = '切换中…'; }
        var turningOn = !state.debugOn;
        // Log the switch itself so the debug trail explains its own gaps.
        var line = '[' + new Date().toLocaleString() + '] [ui] debug mode ' + (turningOn ? 'ON' : 'OFF (user toggled)');
        var script = turningOn
            ? ('touch ' + q(DEBUG_FLAG) + ' && echo ' + q(line) + ' >> ' + q(DEBUG_LOG))
            : ('echo ' + q(line) + ' >> ' + q(DEBUG_LOG) + ' && rm -f ' + q(DEBUG_FLAG));
        exec(script).then(function () {
            state.debugOn = turningOn;
            renderDebugToggle();
            if (state.tab === 'debug') loadSource('debug');
        }, function () {
            renderDebugToggle();
        });
    }

    // ---------- rendering ----------
    function $(id) { return document.getElementById(id); }
    // Sources hold either structured daemon lines {level, tag, text} or plain
    // text lines (text-log tails and the /logs/download fallback).
    function lineClass(line, isDaemon) {
        if (typeof line === 'string') {
            if (line.indexOf('ERROR') !== -1) return 'err';
            if (line.indexOf('WARN') !== -1) return 'warn';
            return '';
        }
        if (isDaemon) {
            var lvl = String(line.level || '');
            if (/^e/i.test(lvl)) return 'err';
            if (/^w/i.test(lvl)) return 'warn';
            return '';
        }
        var t = String(line);
        if (t.indexOf('ERROR') !== -1) return 'err';
        if (t.indexOf('WARN') !== -1) return 'warn';
        return '';
    }
    function lineText(line, isDaemon) {
        if (typeof line === 'string') return line;
        if (isDaemon) {
            return '[' + (line.level || '?') + '] ' + (line.tag || 'teesim') + ': ' + (line.text || '');
        }
        return String(line);
    }
    function setMeta(text) {
        var m = $('lg-meta');
        if (m) m.textContent = text;
    }
    function renderTab() {
        var view = $('lg-view');
        if (!view) return;
        view.textContent = '';
        var src = state.sources[state.tab];
        var isDaemon = state.tab === 'daemon';
        if (!src || !src.loaded) {
            view.appendChild(el('div', 'lg-empty', '读取中…'));
            setMeta('读取中…');
            return;
        }
        var shown = src.lines.slice(-DISPLAY_CAP);
        shown.forEach(function (line) {
            var d = el('div', 'lg-line' + (lineClass(line, isDaemon) ? ' ' + lineClass(line, isDaemon) : ''),
                lineText(line, isDaemon));
            view.appendChild(d);
        });
        if (!shown.length) {
            view.appendChild(el('div', 'lg-empty',
                isDaemon ? '暂无日志（守护进程未运行或刚启动）' : '暂无日志（文件不存在或为空）'));
        }
        setMeta(shown.length + ' 行' + (src.lines.length > shown.length ? '（仅显示最新 ' + DISPLAY_CAP + ' 行）' : '') +
            (src.note ? ' · ' + src.note : ''));
    }
    function el(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    }

    // ---------- diagnostics export ----------
    // One root shell pass for everything static (KEY=VALUE lines, same style as
    // launcher.js's probe). Only metadata crosses here — never keybox content.
    var DIAG_PROBE =
        // RS 线：诊断探针已整体移植为 fusionctl 的 ui-probe logs 子命令
        //（77 键逐键差分对拍见 scripts/test-diff-ui-probe.sh）。脱敏仍由
        // 本文件的 maskDeviceIds 在导出侧执行（规格 §5，<redacted:len=N>）。
        MODPATH + '/fusionctl ui-probe logs';

// A real package entry — same validation as launcher.js / apps.js; the
    // diagnostics only ever report the COUNT of these, never their names.
    var VALID_ENTRY_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+(?:@\d+)?$/;

    function parseKeyed(out) {
        var o = {};
        String(out || '').split('\n').forEach(function (line) {
            var i = line.indexOf('=');
            if (i > 0) o[line.slice(0, i).trim()] = line.slice(i + 1).replace(/\r/g, '').trim();
        });
        return o;
    }
    function scopeCount() {
        return readFile(CONFIG).then(function (raw) {
            if (!raw || !raw.trim()) return 0;
            try {
                var cfg = JSON.parse(raw);
                var prof = cfg && cfg.profiles && (cfg.profiles.default || cfg.profiles[Object.keys(cfg.profiles)[0]]);
                var n = 0;
                ((prof && prof.apps) || []).forEach(function (e) {
                    if (VALID_ENTRY_RE.test(String(e))) n++;
                });
                return n;
            } catch (_) { return 0; }
        });
    }
    function buildDiagText(p, daemon) {
        var L = [];
        L.push('Aegis Fusion 诊断信息');
        L.push('生成时间: ' + new Date().toLocaleString());
        L.push('注意: 本文件不含 keybox 内容与管理员令牌; 受保护应用仅记录数量。');
        L.push('      日志尾部可能包含包名, 分享前请自查。');
        L.push('');
        L.push('== 环境 ==');
        L.push('模块版本: ' + (p.VER || '未知'));
        L.push('设备: ' + (p.MODEL || '?') + ' · Android ' + (p.AREL || '?') + ' (API ' + (p.API || '?') + ') · ' + (p.ABI || '?'));
        L.push('管理器: ' + (p.MGR || 'unknown'));
        L.push('Root: ' + (String(p.UID) === '0' ? '有效 (uid 0)' : '异常 (uid ' + (p.UID || '?') + ')'));
        L.push('');
        L.push('== 运行状态 ==');
        L.push('TEE 守护进程: ' + (daemon.running ? '运行中' + (daemon.version ? ' · ' + daemon.version : '') +
            ' · 注入: ' + (daemon.hook ? daemon.hook : '未上报') : '未运行'));
        // The single highest-signal check in this whole report. An engine-unusable
        // keybox is the observed cause of the "everything looks healthy yet PI is
        // stuck at BASIC" state: the profile is pushed, the interceptor answers
        // applied=0 failed=1, every profile is dropped, and every request is
        // forwarded to the real HAL while all other indicators stay green.
        L.push('Keybox 引擎可用性: ' + (p.KBCHK === 'ok'
            ? '通过 — 引擎能据此建出 TA'
            : p.KBCHK === 'bad'
                ? '★ 不通过 — 引擎建不出 TA，全部 profile 会被丢弃 = 恒定一绿（换 keybox）'
                : '未检测（模块版本较旧，无 keybox-check.sh）') +
            ' · 开机校验标记=' + (p.KBBAD || '?') +
            (p.KBLINK && p.KBLINK !== 'no' ? ' · keybox.xml 是符号链接 -> ' + p.KBLINK : ''));
        // Prefer the ENGINE's verdict over our own structural one: it is the device's
        // actual answer, and when it refuses it prints the reason (teesim_km_init_ex).
        //
        // The state decides whether a reason may be shown at all (v3.1.5). A reason
        // that survives from an earlier keybox produced the worst possible export:
        // "通过 — 引擎能据此建出 TA" directly above "★ 引擎给出的原因: base64:
        // InvalidByte(1887, 61)". A superseded complaint is history, and is labelled
        // as history.
        if (p.EISTATE === 'ok') {
            L.push('  本机实测: 引擎已接受当前 keybox（applied>0 failed=0），认证链来自它');
            if (p.EIHIST) {
                L.push('  历史（已被当前 keybox 取代，不是本机现状）: 更早的 keybox 曾被拒绝 — "' + p.EIHIST + '"');
            }
        } else if (p.EIREASON) {
            L.push('  ★ 引擎给出的原因（teesim_km_init_ex）: ' + p.EIREASON);
            L.push('    → 换一个能用的 keybox: sh ' + MODPATH + '/keybox-swap.sh --auto <候选1.xml> <候选2.xml>');
        } else if (p.EISTATE === 'stale') {
            L.push('  引擎判定已过期: keybox.xml 在上次判定之后被改过 → 等下一次 ack，或现在跑 sh ' +
                MODPATH + '/engine-verdict.sh once');
        } else {
            L.push('  尚无引擎判定（.engine-verdict 缺失，或本 boot 还没收到 ack）');
        }
        if (p.KBCHK === 'bad' || p.KBBAD === 'yes') {
            L.push('  校验详情请见引擎健康判定段下方的关键行；开机校验日志在 ' + TEE_DIR + '/keybox-bad.log');
        }
        L.push('引擎链路: 守护进程=' + (p.DAEMON || '?') +
            ' · keystore2 注入数=' + (p.INJECTED != null ? p.INJECTED : '?') +
            ' · 控制 socket=' + (p.CTL_SOCK || '?') +
            ' · GMS 映射含模块名=' + (p.PIFMAP != null ? p.PIFMAP : '?') +
            ' (仅供参考: 指纹半用 memfd 装载 dex, 0 属正常)');
        // The decisive engine counters, read off the durable trace once and used both
        // here and in the verdict section below.
        var epush = Number(p.EPUSH), eack = Number(p.EACK), estaged = Number(p.ESTAGED);
        var ebuild = Number(p.EBUILD), enever = Number(p.ENEVER), eresolve = Number(p.ERESOLVE);
        var et1 = Number(p.ET1), et0 = Number(p.ET0), eapp = Number(p.EAPP), efail = Number(p.EFAIL);
        var noEngLog = !p.ELOGSZ || Number(p.ELOGSZ) === 0;
        if (noEngLog) {
            L.push('引擎判定: 无持久日志 (' + TEE_DIR + '/log/teesim.log 为空) → 引擎从未上报过任何状态');
        } else if (enever > 0 && estaged === 0) {
            L.push('引擎判定: FAIL — 拦截器等不到配置("the daemon never pushed a config")');
            L.push('  推送=' + (epush || 0) + ' 次 · ack=' + (eack || 0) + ' 次 · 构建失败=' + (ebuild || 0) + ' 次 · 守护进程报错=' + (eresolve || 0) + ' 次');
            if (epush > 0 && eack > 0 && ebuild > 0) {
                L.push('  → daemon 推送成功但 lib 拒绝全部 profile: keybox 无法被引擎解析/使用');
                L.push('    引擎原因: ' + (p.EIREASON || '(无 teesim_km_init_ex 输出)') +
                       ' → 换 keybox: sh ' + MODPATH + '/keybox-swap.sh --auto <候选1.xml> <候选2.xml>');
            } else if (eresolve > 0) {
                L.push('  → daemon 侧就没能推送成功, 见下方 daemon 日志里的 resolve/push 报错');
            } else if (epush === 0) {
                L.push('  → daemon 从未推送过, 但也没有报错: 看 daemon.log 是否在启动后期崩溃');
            }
        } else if (estaged > 0) {
            L.push('引擎判定: OK — 配置已到达拦截器 (' + estaged + ' 条 staged profile)');
            L.push('  引擎已接管请求=' + (et1 || 0) + ' · 仍转发真机=' + (et0 || 0) +
                '   [自最后一次 ack 起 · 累计 ' + (p.ET1ALL || 0) + ' / ' + (p.ET0ALL || 0) + ']' +
                ' · 最后一次 ack: applied=' + (eapp < 0 ? '?' : eapp) + ' failed=' + (efail < 0 ? '?' : efail));
            if (et1 === 0 && et0 > 0) {
                L.push('  → 配置到位但一个请求都没匹配上: profile 的 apps/uid 与真实调用者对不上号');
            } else if (et1 === 0 && et0 === 0) {
                L.push('  → 自当前 keybox 的 ack 之后还没有应用发起认证请求（正常；跑一次完整性检查即可看到）');
            }
        } else {
            L.push('引擎判定: 未知 — 持久日志存在但既无 staged profile 也无 never-pushed 标记');
        }
        if (p.CTL_SOCK === 'missing') {
            L.push('  ! 控制 socket 缺失 → daemon 无法推送配置 → 引擎不接管任何请求（这是"一绿"的直接原因）');
        }
        L.push('Keybox: ' + (p.KEYBOX === 'yes' ? '已配置 · sha256 前缀 ' + (p.KBSHA || '?') + '…' +
            ' · ' + (p.KBMARK === 'yes' ? '社区自动管理' : '用户导入') : '未配置'));
        L.push('本机吊销检测缓存: ' + (p.REVJ === 'yes'
            ? '可用' + (Number(p.REVA) > 0 ? '（' + p.REVA + ' 小时前更新）' : '（刚更新）') + ' · 未在缓存中命中即视为未吊销'
            : '无缓存（联网后每小时自动与 Google 官方列表比对）'));
        // kbg < 0 is the deliberate "this channel publishes no status file at all"
        // sentinel written by keybox-fetch.sh — not an unknown value. Printing it raw
        // is how an export ended up reading "Google 源状态: -1 个有效".
        var kbgn = Number(p.KBG);
        var kbLabel = (p.KBG == null || p.KBG === '' || isNaN(kbgn) || kbgn < 0)
            ? '渠道未提供自述（该渠道不发布状态文件）'
            : kbgn + ' 个绿格（渠道自述）';
        // 间隔数值的第三处显示点（另两处：customize.sh 的安装总结、launcher.js
        // 的仪表盘）。规则必须一致，否则用户会看到"一个地方一个数"——那正是作者
        // 指出的问题。0 = 关闭，读作"已关闭"，不能印成 "0h"；胶囊档位之外的数值
        // 按原值打印（执行者 service.sh 对数值没有白名单）。launcher.js 里的
        // intervalNum/intervalText 是同一条规则，两边由 test-webui/test-logs 各自
        // 断言（0 -> 已关闭、6 -> 6h），任一处走偏都会红。
        var refN = parseInt(p.REF, 10);
        if (!isFinite(refN) || refN < 0) refN = 24;
        L.push('Google 源状态: ' + kbLabel +
            ' · 自动刷新间隔: ' + (refN === 0 ? '已关闭' : refN + 'h') + ' · 距上次刷新: ' + (p.KBAGE || 0) + ' 小时' +
            (p.KBRUN === 'yes'
                ? ' · 后台刷新中' + (p.KBPROG ? '：' + p.KBPROG : '') +
                  (Number(p.KBPROGT) > 0
                      ? '（本阶段已 ' + Math.max(0, Math.floor(Date.now() / 1000) - Number(p.KBPROGT)) + ' 秒）'
                      : '')
                : ''));
        L.push('受保护应用数量: ' + (p.SCOPE != null ? p.SCOPE : '?') + ' (仅数量)');
        // v3.1.7: the detector auto-exclusion is retired — the scope holds exactly
        // what the user ticks, and the -66 it used to dodge is fixed at the engine
        // layer (upstream patch 0005 rewrites the request's ATTESTATION_ID_* tags to
        // the profile's identity before the TA's gate sees them). Kept as a static
        // line so an export from a pre-0007 engine still gets the context.
        L.push('检测类应用(密钥认证/PIAC 等): v3.1.7 起不再自动排除, 勾选即保护; 若引擎二进制早于补丁 0005,' +
            ' 勾选后 ID 证明可能仍返回 -66 (CannotAttestIds), 由重构的引擎发布修复');
        L.push('Debug 模式: ' + (p.DBG === 'yes' ? '开启（debug.log 含详细决策）' : '关闭'));
        // 报障指引：debug 关闭时详细决策不落盘，报告者需要知道怎么补一份"深日志"。
        L.push(p.DBG === 'yes'
            ? '报障提示: Debug 已开启，本文件已含完整决策链，直接发给开发者即可。'
            : '报障提示: Debug 当前关闭，本文件只含各模块的常开日志。若问题可复现，建议先在"日志页 → Debug 开关"开启 Debug → 复现一次问题 → 重新导出，再发给开发者（分析会快得多）。');
        L.push('本文件不含 keybox、令牌与应用清单（仅数量）；设备标识（IMEI/序列号等）已自动脱敏，可放心分享。');
        L.push('');
        L.push('== 指纹层 ==');
        var pifsrc = String(p.PIFSRC || '');
        var pifLabel = '未生成 · 等待 pif-fetch 自动获取（需网络）';
        if (pifsrc.indexOf(MODPATH + '/') === 0) {
            pifLabel = pifsrc.indexOf('.json') !== -1 ? '内置 · 用户指纹' : '内置 · 自动指纹';
        } else if (pifsrc.indexOf('/modules/') !== -1) {
            pifLabel = '外部指纹模块: ' + pifsrc.replace(/^.*\/modules\//, '').replace(/\/[^/]*$/, '');
        } else if (pifsrc === '/data/adb/pif.json') {
            pifLabel = '外部 · pif.json (PIF 标准路径)';
        } else if (pifsrc) {
            pifLabel = '外部: ' + pifsrc;
        }
        L.push('指纹来源: ' + pifLabel);
        // 轮换阶段 (v3.2.2): 仅自动托管的指纹报告阶段/到期日/失败原因;
        // 用户导入的指纹不评级、不评判。预估到期日来自指纹文件内的
        // Estimated Expiry 注释, 解析不到就不出现这一行(绝不显示"—")。
        if (String(p.PIFAUTO || '') === 'yes' && String(p.PIFSRC || '') !== '') {
            var pifPhase = String(p.PIFST || 'ok');
            L.push('轮换状态: ' + (pifPhase === 'expired' ? '已过期 · 请重新获取'
                : pifPhase === 'soon' ? '即将到期（≤7 天）· 建议重新获取'
                : '正常（到期前自动更换）'));
            if (p.PIFEXP) L.push('预估到期日: ' + p.PIFEXP + '（来源: 指纹文件内 Estimated Expiry 注释, 为上游对 Canary 下架时间的估计, 非官方承诺）');
            if (p.PIFFAIL) L.push('上次抓取失败: ' + p.PIFFAIL);
        }
        L.push('Zygisk 环境: ' + (p.ZYG === 'yes' ? '已启用' : '未启用（指纹半不生效，verdict 上限 BASIC）'));
        L.push('');
        L.push('== 实验开关 / TEE Profile ==');
        L.push('.pif-off: ' + (p.PF_OFF === 'yes' ? '开（指纹半层整体挂起）' : '关') +
            ' · .pif-sync-off: ' + (p.PF_SYNCOFF === 'yes' ? '开（仅 TEE 同步抑制）' : '关'));
        L.push('config.json: mode=' + (p.CFG_MODE || '?') + ' osVersion=' + (p.CFG_OSVERSION || '?') +
            ' patchLevel(system/vendor/boot)=' + (p.CFG_SYSTEM || '?') + '/' + (p.CFG_VENDOR || '?') + '/' + (p.CFG_BOOT || '?'));
        L.push('Profile 身份(应跟随 PIF 伪装值): brand=' + (p.CFG_BRAND || '?') + ' device=' + (p.CFG_DEVICE || '?') +
            ' product=' + (p.CFG_PRODUCT || '?') + ' manufacturer=' + (p.CFG_MANUFACTURER || '?') + ' model=' + (p.CFG_MODEL || '?') +
            ' ← v3.1.0 起 profile 跟随 PIF 伪装身份(与 AS 三绿配置同构), TEE 生成的证书须与 DroidGuard 看到的 Build 一致;' +
            ' 若此处是真机值而 PIF 处于活动状态, 说明镜像未执行(检查 .pif-sync-off / pif-sync 日志)');
        L.push('真机补丁级: system=' + (p.SW_PATCH || '?') + ' vendor=' + (p.VEN_PATCH || '?') +
            ' ← 与上行 patchLevel 对照, 判断同步是否产生过实际差异 (attestation 只取年月)');
        L.push('');
        L.push('== BL / 环境属性 (当前值) ==');
        var blKeys = [
            ['BL_VBMETA', 'vbmeta.device_state'], ['BL_VBVENDOR', 'vendor.vbmeta.device_state'],
            ['BL_VBOOT', 'verifiedbootstate'], ['BL_FLASH', 'flash.locked'],
            ['BL_VERITY', 'veritymode'], ['BL_LOCKSTATE', 'secureboot.lockstate'],
            ['BL_TAGS', 'build.tags'], ['BL_BTYPE', 'build.type'],
            ['BL_DEBUGGABLE', 'debuggable'], ['BL_OEMUNLOCK', 'oem_unlock_allowed']
        ];
        blKeys.forEach(function (kv) {
            L.push(kv[1] + '=' + (p[kv[0]] != null && p[kv[0]] !== '' ? p[kv[0]] : '(未设置)'));
        });
        L.push('');
        L.push('== 挂载视图 (本进程 · 跨进程一致性排查) ==');
        L.push('本进程挂载项: ' + (p.MNT_TOTAL || '?') + ' · 含 /data/adb 的挂载: ' + (p.MNT_ADB || '0') +
            (p.MNT_ADB_PATHS ? ' (' + p.MNT_ADB_PATHS + ')' : ' (无)'));
        L.push('若检测器报 "cross-process mount tables diverge / 2 distinct views": 指部分进程的挂载表被' +
            '隐藏了模块挂载而另一些(通常是 isolated 辅助进程)没有——检查管理器(KSU 等)的"卸载模块挂载"' +
            '是否只对部分应用开启; 全局统一开或关可消除视图分裂。上面这行说明本进程属于哪一侧。');
        L.push('');
        L.push('== keybox-fetch.log (最后 100 行) ==');
        L = L.concat(p._kbTail.slice(-100));
        L.push('');
        L.push('== apps-sync.log (最后 100 行) ==');
        L = L.concat(p._syncTail.slice(-100));
        L.push('');
        L.push('== pif-sync.log (最后 100 行 · 双端身份同步) ==');
        L = L.concat((p._pifsyncTail || ['(空 — pif-sync 尚未运行过)']).slice(-100));
        L.push('');
        L.push('== pif-fetch.log (最后 100 行) ==');
        L = L.concat(p._pifTail.slice(-100));
        L.push('');
        L.push('== pif-fetch.last (最近一次 autopif4 原始输出 · 生成失败时的报错在这里) ==');
        L = L.concat((p._pifLastTail || ['(空 — 生成从未失败过)']).slice(-100));
        L.push('');
        L.push('== debug.log (最后 150 行 · Debug 模式: ' + (p.DBG === 'yes' ? '开启' : '关闭') + ') ==');
        L = L.concat((p._dbgTail || []).slice(-150));
        L.push('');
        L.push('== 守护进程日志 (最后 400 行 · 覆盖开机 Harvest/VBK 行) ==');
        p._daemonLines.slice(-400).forEach(function (l) {
            if (typeof l === 'string') { L.push(l); return; }
            L.push('[' + (l.level || '?') + '] ' + (l.tag || 'teesim') + ': ' + (l.text || ''));
        });
        L.push('');
        L.push('== daemon.log (守护进程 stdout/stderr 落盘 · 最后 120 行) ==');
        L.push('   崩溃栈、app_process 报错、Injector/Control 通道日志都在这里; 若为空说明守护进程连一行都没输出。');
        L = L.concat((p._daemonFileTail || ['(空)']).slice(-120));
        L.push('');
        L.push('== 引擎健康判定 (v3.1.2 修订) ==');
        // Primary source is the DURABLE trace (LogTail's ring files). The in-memory
        // daemon buffer / logcat are only fallbacks: logcat rotates the boot-time
        // decision trail away within minutes, which is exactly why the first two
        // rounds of debugging could not answer "did the config ever land?".
        var engFileText = (p._engineFileTail || []).join('\n');
        var engTxt = (p._daemonLines || []).map(function (l) {
            return typeof l === 'string' ? l : (l.text || '');
        }).join('\n');
        var all = engFileText + '\n' + engTxt + '\n' + (p._daemonFileTail || []).join('\n');
        if (!engFileText.trim()) {
            L.push('! 持久引擎日志为空 (' + ENGINE_LOG + ') —— 说明拦截器/守护进程从未上报过状态,');
            L.push('  或 daemon 连 LogTail 都还没起来就崩了。此时下面的 logcat 回退源才有意义。');
        }
        var pushed = (all.match(/control: pushed config/g) || []).length;
        var staged = all.match(/cfg: staged profile [^\n]*/g) || [];
        var buildFail = all.match(/failed to build[^\n]*/g) || [];
        var acks = all.match(/control: ack [^\n]*/g) || [];
        L.push('推送次数(control: pushed config) = ' + pushed + ' · ack 次数 = ' + acks.length + ' · staged profile 条数 = ' + staged.length);
        L.push('profile 构建失败次数 = ' + buildFail.length +
            ' · daemon 侧 resolve/push 报错 = ' + ((all.match(/Failed to resolve\/push config|No valid config to push/g) || []).length));
        // Counters that predate the last ack describe a PREVIOUS keybox. The window
        // here starts before the accept, so a naive count of the whole thing reported
        // "全部 12 次 generateKey 都是 target=0" for a keybox the engine had already
        // accepted — every one of those 12 calls happened before the accept, and the
        // warning described a state that no longer existed (v3.1.5 field export).
        var ackAt = all.lastIndexOf('control: ack');
        var postAck = ackAt >= 0 ? all.slice(ackAt) : '';
        var servedN = (postAck.match(/target=1/g) || []).length;
        var fwdN = (postAck.match(/target=0/g) || []).length;
        var servedAll = (all.match(/target=1/g) || []).length;
        var fwdAll = (all.match(/target=0/g) || []).length;
        L.push('引擎接管请求(target=1) = ' + servedN + ' · 转发真机(target=0) = ' + fwdN +
            '   [自最后一次 ack 起 · 本段日志累计 ' + servedAll + ' / ' + fwdAll + ']');
        acks.slice(-3).forEach(function (a) { L.push('   ack: ' + a.replace(/^.*control: ack /, '')); });
        if (buildFail.length) {
            L.push('FAIL: 有 profile 构建失败 —— 引擎会直接丢掉该 profile:');
            buildFail.slice(-3).forEach(function (s) { L.push('     ' + s); });
            L.push('  多半是 keybox 无法被引擎解析/使用。换一个 keybox 即可验证。');
        }
        if (staged.length) {
            L.push('OK: 配置已送达拦截器 (' + staged.length + ' 条):');
            staged.slice(-3).forEach(function (s) { L.push('     ' + s); });
        }
        if ((all.indexOf('the daemon never pushed a config') !== -1) && staged.length === 0) {
            L.push('FAIL: 拦截器等不到任何配置 —— 引擎不接管任何请求的直接证据:');
            L.push('      表现: 所有 generateKey 的 target=0 → 全部转发真机 HAL; 应用拿到真机解锁原文。');
            if (pushed > 0 && acks.length > 0 && buildFail.length > 0) {
                L.push('      归因: daemon 推送成功, 但 lib 拒绝全部 profile → keybox 不可用 (换 keybox)。');
            } else if (pushed === 0) {
                L.push('      归因: daemon 从未推送 → 看下面的 daemon.log / resolve 报错。');
            } else if (pushed > 0 && acks.length === 0) {
                L.push('      归因: daemon 推了但 lib 从未 ack → 控制 socket 通道断了 (见 CTL_SOCK)。');
            }
        }
        if (servedN > 0) {
            L.push('OK: 自当前 keybox 的 ack 之后, 有 ' + servedN + ' 次请求被引擎接管 (target=1)。');
        } else if (fwdN > 0) {
            L.push('注意: 自最后一次 ack 起 ' + fwdN + ' 次 generateKey 全部是 target=0 ——');
            L.push('      引擎没有生效 profile, 或调用者未被匹配 (注意这一段的确晚于 ack, 不是旧数据)。');
        } else if (acks.length > 0) {
            L.push('自最后一次 ack 起没有任何 generateKey —— 还没有应用发起认证请求;');
            L.push('      换 keybox 后需要先跑一次完整性检查, 才会出现新的 target=1/0 行。');
        }
        L.push('守护进程存活: ' + (p.DAEMON === 'running' || p.DAEMON === 'yes' ? '是' : String(p.DAEMON || '?')) +
            ' · 控制 socket: ' + (p.CTL_SOCK || '?'));
        L.push('');
        L.push('== 持久引擎日志 (' + ENGINE_LOG + ' · 最后 300 行) ==');
        L.push('   daemon / TA / 两个 native 拦截器的全部 TEESimulator 行; logcat 轮转不会影响这里。');
        L = L.concat((p._engineFileTail || ['(空)']).slice(-300));
        L.push('');
        return L.join('\n');
    }
    // v3.2.3 (audit H1): the engine/daemon log tails can contain the upstream
    // harvest line with PLAINTEXT IMEI/IMEI2/MEID/serial. Masked at this single
    // choke point so every exported section is covered. Presence + length keeps
    // the diagnostic signal ("len=15" = a sane IMEI shape, "blank" = nothing
    // harvested) without the identifying bytes; the real values stay in
    // root-only harvested.json / config.json.
    //
    // WHY THIS MUST BE FORM-INDEPENDENT (audit r5): the export lands in
    // /sdcard/Download — a directory any app holding storage permission can
    // read — so this function is the only control between the harvested
    // identifiers and third-party apps. It therefore must not depend on the
    // exact spelling upstream happens to use today (Harvester.kt logs
    // "imei='…'"; the Kotlin data-class toString of Record logs ", imei=…").
    // The unquoted rule used to accept only [A-Za-z0-9]{4,} right after '=' ,
    // which let four shapes through untouched: a hyphenated value
    // ("serial=SN-1234567"), a value whose first alphanumeric run was shorter
    // than four, a space-separated value, and a value on the following line.
    // All four are redacted now; the value class is "anything up to the next
    // delimiter". Over-masking is harmless here, under-masking is not — but the
    // rules still leave untargeted text (e.g. "serialVersionUID") intact.
    function maskDeviceIds(text) {
        return String(text || '')
            // (1) single-quoted — the Harvester.kt spelling:
            //     Harvest telephony IDs: imei='…' secondImei='…' meid='…' serial='…'
            .replace(/(secondImei|imei2|imei|meid|serialno|serial)='([^']*)'/gi, function (m, k, v) {
                return k + "='<redacted:len=" + v.length + ">'";
            })
            // (2) v3.2.3 (audit N1): the /status body embeds harvest data as JSON
            // ("key":"value" — no '=' so the other rules let it through).
            .replace(/"(secondImei|imei2|imei|meid|serialno|serial)"\s*:\s*"([^"]*)"/gi, function (m, k, v) {
                return '"' + k + '":"<redacted:len=' + v.length + '>"';
            })
            // (3) bare key=value — Kotlin's toString form (", imei=…, meid=…").
            //     The separator tolerates spaces and a line break, so a value
            //     that wrapped onto the next line is still covered.
            .replace(/(secondImei|imei2|imei|meid|serialno|serial)\s*=\s*([^\s'",;)\]}]+)/gi, function (m, k, v) {
                return k + '=<redacted:len=' + v.length + '>';
            })
            // (4) key<space>value, no separator at all ("imei 350000000000001").
            //     Same line only: a line that merely ENDS with the bare word must
            //     not swallow the first token of the next line.
            .replace(/\b(secondImei|imei2|imei|meid|serialno|serial)[ \t]+([^\s'",;)\]}]{4,})/gi, function (m, k, v) {
                return k + ' <redacted:len=' + v.length + '>';
            });
    }
    function exportDiag() {
        if (state.exporting) return;
        var btn = $('diag-btn'), out = $('diag-out'), err = $('diag-err');
        state.exporting = true;
        if (btn) { btn.disabled = true; btn.textContent = '收集中…'; } // busy state matches the multi-second wait
        if (out) out.hidden = true;
        if (err) err.hidden = true;
        var scope = scopeCount();
        var probe = exec(DIAG_PROBE).then(parseKeyed, function () { return {}; });
        var status = fetchDaemonStatus();
        var kbTail = state.sources.kb.loaded ? Promise.resolve(state.sources.kb.lines) : textLines(KB_LOG);
        var syncTail = state.sources.sync.loaded ? Promise.resolve(state.sources.sync.lines) : textLines(SYNC_LOG);
        var pifTail = textLines(PIF_LOG);
        var pifLastTail = textLines(PIF_LAST);
        var dbgTail = textLines(DEBUG_LOG);
        var pifsyncTail = textLines(PIFSYNC_LOG);
        var daemonFileTail = textLines(TEE_DIR + '/daemon.log');
        var engineFileTail = textLines(ENGINE_LOG);
        var daemonLines = state.sources.daemon.loaded ? Promise.resolve(state.sources.daemon.lines) : fetchDaemonLog().then(function (r) { return r.lines; });
        Promise.all([probe, status, scope, kbTail, syncTail, daemonLines, pifTail, dbgTail, pifLastTail, daemonFileTail, engineFileTail, pifsyncTail])
            .then(function (r) {
                var p = r[0];
                p.SCOPE = r[2];
                p._kbTail = r[3];
                p._syncTail = r[4];
                p._daemonLines = r[5];
                p._pifTail = r[6];
                p._dbgTail = r[7];
                p._pifLastTail = r[8];
                p._daemonFileTail = r[9];
                p._engineFileTail = r[10];
                p._pifsyncTail = r[11];
                return buildDiagText(p, r[1]);
            })
            .then(maskDeviceIds)
            .then(function (text) {
                return exec('mkdir -p /sdcard/Download 2>/dev/null; echo /sdcard/Download/aegis-diagnostics-$(date +%Y%m%d-%H%M%S).txt')
                    .then(function (p2) {
                        var path = String(p2 || '').trim().split('\n')[0];
                        if (path.indexOf('/sdcard/Download/') !== 0) throw new Error('无法确定输出路径');
                        return writeFileAtomic(path, text).then(function (w) {
                            if (!w.ok) throw new Error((w && w.error) || '写入失败');
                            return path;
                        });
                    });
            })
            .then(function (path) {
                if (out) { out.hidden = false; out.textContent = '已生成：' + path; }
            })
            .catch(function (e) {
                if (err) { err.hidden = false; err.textContent = '生成失败：' + ((e && e.message) || '未知错误'); }
            })
            .then(function () {
                state.exporting = false;
                if (btn) { btn.disabled = false; btn.textContent = '生成诊断文件'; }
            });
    }

    // ---------- boot ----------
    document.addEventListener('DOMContentLoaded', function () {
        var hasApi = !!(window.ksu && typeof window.ksu.exec === 'function');
        if (!hasApi) {
            var err = $('diag-err');
            if (err) { err.hidden = false; err.textContent = '无法通过管理器接口读取（可能未授权 Root）。'; }
            var btn = $('diag-btn');
            if (btn) btn.disabled = true;
            return;
        }

        // Source chips: native buttons with aria-pressed, same contract as the
        // apps page filters. Re-clicking the active tab is a no-op.
        var CHIPS = [['chip-kb', 'kb'], ['chip-sync', 'sync'], ['chip-daemon', 'daemon'], ['chip-debug', 'debug']];
        function applyChips() {
            CHIPS.forEach(function (p) {
                var c = $(p[0]);
                if (!c) return;
                var on = state.tab === p[1];
                c.classList.toggle('on', on);
                c.setAttribute('aria-pressed', on ? 'true' : 'false');
            });
        }
        function bindChip(id, tab) {
            var b = $(id);
            if (!b) return;
            b.addEventListener('click', function () {
                if (state.tab === tab) return;
                state.tab = tab;
                applyChips();
                renderTab();
            });
        }
        bindChip('chip-kb', 'kb');
        bindChip('chip-sync', 'sync');
        bindChip('chip-daemon', 'daemon');
        bindChip('chip-debug', 'debug');

        var dbgBtn = $('dbg-toggle');
        if (dbgBtn) dbgBtn.addEventListener('click', toggleDebug);

        var refreshBtn = $('lg-refresh');
        if (refreshBtn) refreshBtn.addEventListener('click', loadAll);
        var diagBtn = $('diag-btn');
        if (diagBtn) diagBtn.addEventListener('click', exportDiag);

        applyChips(); // highlight the default tab before the first render
        loadAll();
    });
}());
