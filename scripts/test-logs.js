/* Mock-DOM end-to-end smoke tests for the Aegis Fusion logs & diagnostics page (logs.html).
 * Run: node scripts/test-logs.js
 *
 * Covers: the three log tabs (keybox-fetch / apps-sync tails, daemon in-memory
 * log over the admin socket incl. level classification), tab switching chips,
 * refresh, and the one-tap diagnostics export — with hard redaction assertions:
 * the generated file must NEVER contain the keybox body, the admin token, or
 * package names from config.json (log tails are included verbatim by design,
 * and the file carries a share-warning banner saying exactly that).
 */
'use strict';

// ---------- tiny DOM mock (same shape as test-apps.js) ----------
function El(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.style = {};
    this.attrs = {};
    this._cls = new Set();
    this.hidden = false;
    this.textContent = '';
    this.value = '';
    this.parentNode = null;
    this._listeners = {};
    var self = this;
    this.classList = {
        add: function () { for (var i = 0; i < arguments.length; i++) self._cls.add(arguments[i]); },
        remove: function () { for (var i = 0; i < arguments.length; i++) self._cls.delete(arguments[i]); },
        toggle: function (c, f) { if (f === undefined) f = !self._cls.has(c); if (f) self._cls.add(c); else self._cls.delete(c); return f; },
        contains: function (c) { return self._cls.has(c); }
    };
}
El.prototype.appendChild = function (n) { n.parentNode = this; this.children.push(n); return n; };
El.prototype.contains = function () { return false; };
El.prototype.replaceChild = function (n, old) {
    var i = this.children.indexOf(old);
    if (i >= 0) this.children[i] = n;
    n.parentNode = this;
    return old;
};
El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
El.prototype.getAttribute = function (k) { return this.attrs[k] != null ? this.attrs[k] : null; };
El.prototype.addEventListener = function (ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); };
El.prototype.click = function () {
    var self = this;
    (this._listeners.click || []).forEach(function (f) {
        f.call(self, { target: self, classList: self.classList, stopPropagation: function () {} });
    });
};
Object.defineProperty(El.prototype, 'textContent', {
    get: function () {
        if (!this.children.length) return this._text || '';
        var agg = this._text || '';
        (function walk(n) {
            n.children.forEach(function (c) {
                agg += (c._text || '');
                walk(c);
            });
        })(this);
        return agg;
    },
    set: function (v) { this._text = String(v); this.children = []; }
});
Object.defineProperty(El.prototype, 'className', {
    get: function () { return Array.from(this._cls).join(' '); },
    set: function (v) {
        var self = this;
        self._cls = new Set();
        String(v || '').split(/\s+/).filter(Boolean).forEach(function (c) { self._cls.add(c); });
    }
});

var byId = {};
['chip-kb', 'chip-sync', 'chip-daemon', 'chip-debug', 'dbg-toggle', 'dbg-state',
 'lg-meta', 'lg-refresh', 'lg-view',
 'diag-btn', 'diag-out', 'diag-err'].forEach(function (id) {
    var e = new El('div'); e.id = id; byId[id] = e;
});
// mirror the initial HTML state
byId['diag-out'].hidden = true;
byId['diag-err'].hidden = true;

var docListeners = {};
var documentMock = {
    getElementById: function (id) { return byId[id] || null; },
    createElement: function (tag) { return new El(tag); },
    addEventListener: function (ev, fn) { (docListeners[ev] = docListeners[ev] || []).push(fn); }
};

var windowMock = {};
var shellImpl = null;
var execLog = [];

windowMock.ksu = {
    exec: function (cmd, opts, cbName) {
        execLog.push(cmd);
        if (cbName) {
            setTimeout(function () {
                var out;
                try { out = shellImpl ? shellImpl(cmd) : ''; }
                catch (e) { windowMock[cbName](1, '', String((e && e.message) || 'fail')); return; }
                if (out && typeof out === 'object' && '__exit' in out) {
                    windowMock[cbName](out.__exit, out.out || '', '');
                    return;
                }
                windowMock[cbName](0, String(out), '');
            }, 0);
            return;
        }
        return shellImpl ? String(shellImpl(cmd)) : '';
    }
};

global.window = windowMock;
global.document = documentMock;
global.setTimeout = setTimeout;
global.clearTimeout = clearTimeout;
global.btoa = function (s) { return Buffer.from(s, 'binary').toString('base64'); };
global.unescape = unescape;

require(require('path').join(__dirname, '..', 'module', 'webroot', 'js', 'logs.js'));

function fireDomReady() { (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); }); }
function $(id) { return byId[id]; }

var passed = 0, failed = 0;
function ok(cond, name) {
    if (cond) { passed++; console.log('  PASS ' + name); }
    else { failed++; console.log('  FAIL ' + name); }
}
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
// Poll until fn() returns truthy (or timeout -> null). CI runners are slow and
// a fixed sleep() raced the async export chain; waiting on the CONDITION makes
// the suite deterministic at any machine speed.
function waitFor(fn, timeout) {
    var deadline = Date.now() + (timeout || 3000);
    return new Promise(function (resolve) {
        (function poll() {
            var v;
            try { v = fn(); } catch (e) { v = null; }
            if (v) return resolve(v);
            if (Date.now() > deadline) return resolve(null);
            setTimeout(poll, 25);
        }());
    });
}
function writeCount() {
    var n = 0;
    execLog.forEach(function (c) { if (/base64 -d >/.test(c)) n++; });
    return n;
}

// ---------- shell fixtures ----------
var DAEMON_LOG = JSON.stringify({
    ok: true,
    lines: [
        { seq: 1, level: 'I', tag: 'Control', text: 'daemon started' },
        { seq: 2, level: 'W', tag: 'Harvest', text: 'slow path' },
        { seq: 3, level: 'E', tag: 'KeyAdmin', text: 'bad request' }
    ],
    nextAfter: 4
});
var STATUS_JSON = JSON.stringify({
    ok: true, version: 'v4.0-canary-66',
    lib: { hook: '/data/adb/teesim/inject.so', api: 'api26' }
});
var KB_LOG =
    '[2026-09-06 08:00:00] key-status refreshed: 3 green circle(s)\n' +
    '[2026-09-06 08:00:05] keybox updated (sha256 abcd1234abcd5678)\n' +
    '[2026-09-06 09:00:00] ERROR: keybox download failed (downloader: curl; network?)\n' +
    '[2026-09-06 09:05:00] done\n';
var SYNC_LOG =
    '[2026-09-06 08:05:00] cleaned, removed: com.removed.app\n' +
    '[2026-09-06 08:10:00] ERROR: rewritten config failed sanity check; left untouched\n';
var PIF_LOG =
    '[2026-09-06 08:02:00] generating a fresh Pixel Canary fingerprint (strong preset)\n' +
    '[2026-09-06 08:03:30] fingerprint ready at /data/adb/modules/aegisfusion_rs/custom.pif.prop\n' +
    '[2026-09-06 08:03:30] syncing the new identity into the TEE profile\n';
var DEBUG_LOG =
    '[2026-09-06 08:00:00] [kbfetch] lock acquired by pid 1234\n' +
    '[2026-09-06 08:00:02] [kbfetch] download ok: attempt 1, 4821 bytes\n' +
    '[2026-09-06 08:00:05] [appssync] seeded com.google.android.gms into the attestation scope\n' +
    '[2026-09-06 08:03:31] [piffetch] identity changed — bouncing teesim + DroidGuard\n' +
    '[2026-09-06 08:03:31] [service] tick: interval=24 tick=999 gcount=0\n';
// Scope names are NEVER exported — only the count. The name below must not
// appear anywhere in the generated diagnostics even though it is saved here.
var CONFIG_RAW = JSON.stringify({
    version: 1,
    profiles: { default: { keybox: 'keybox.xml', apps: ['com.secret.bank', 'com.google.android.gms', 'com.ok.app@10'] } }
}, null, 2);
var DIAG_PROBE_OUT = [
    'UID=0',
    'VER=v2.2.8 (TEESim v4.0-canary-66)',
    'AREL=16', 'API=36', 'MODEL=Pixel 9', 'ABI=arm64-v8a', 'MGR=KernelSU',
    'KEYBOX=yes', 'KBSHA=abcd1234abcd', 'KBMARK=yes', 'REF=24', 'KBG=3', 'KBAGE=5', 'KBRUN=no', 'KBRUNM=0',
    'REVJ=yes', 'REVA=7', 'DBG=yes',
    'PIFSRC=/data/adb/modules/aegisfusion_rs/custom.pif.prop', 'ZYG=yes',
    'PIFST=ok', 'PIFD=-1', 'PIFAUTO=yes', 'PIFEXP=2026-10-01', 'PIFFAIL=',
    'PF_OFF=no', 'PF_SYNCOFF=no',
    'SW_PATCH=2026-08-01', 'VEN_PATCH=2026-09-05',
    'CFG_MODE=patch', 'CFG_OSVERSION=170000', 'CFG_SYSTEM=2026-08-01', 'CFG_VENDOR=2026-09-05', 'CFG_BOOT=2026-09-05',
    'CFG_BRAND=Xiaomi', 'CFG_DEVICE=mithor', 'CFG_PRODUCT=mithor', 'CFG_MANUFACTURER=Xiaomi', 'CFG_MODEL=2312DRAABC',
    'BL_VBMETA=locked', 'BL_VBVENDOR=locked', 'BL_VBOOT=green', 'BL_FLASH=1',
    'BL_VERITY=enforcing', 'BL_LOCKSTATE=locked', 'BL_TAGS=release-keys', 'BL_BTYPE=user',
    'BL_DEBUGGABLE=0', 'BL_OEMUNLOCK=0',
    'MNT_TOTAL=37', 'MNT_ADB=0', 'MNT_ADB_PATHS=', ''
].join('\n');

function baseShell(cmd) {
    if (cmd.indexOf('base64 -d >') !== -1) return ''; // writes succeed (captured)
    // NOTE: the helper commands now embed the token path ("$(cat admin.token)")
    // — the daemon endpoints below MUST be matched before any token check.
    if (cmd.indexOf('ui-probe logs') !== -1) return DIAG_PROBE_OUT; // the whole DIAG probe (MUST precede log-file rules: the probe itself reads pif-fetch.log)
    if (cmd.indexOf('teesim-uds') !== -1 && cmd.indexOf('/status') !== -1) return STATUS_JSON;
    if (cmd.indexOf('teesim-uds') !== -1 && cmd.indexOf('/logs') !== -1) return DAEMON_LOG;
    if (cmd.indexOf('keybox-fetch.log') !== -1) return KB_LOG;
    if (cmd.indexOf('apps-sync.log') !== -1) return SYNC_LOG;
    if (cmd.indexOf('pif-fetch.log') !== -1) return PIF_LOG;
    if (cmd.indexOf('debug.log') !== -1) return DEBUG_LOG;
    if (cmd.indexOf('config.json') !== -1) return CONFIG_RAW;
    if (cmd.indexOf('sdcard/Download') !== -1) return '/sdcard/Download/aegis-diagnostics-20260906-120000.txt\n';
    if (cmd.indexOf('grep -m1') !== -1) return 'version=v2.2.8 (TEESim v4.0-canary-66)\n';
    if (cmd.indexOf('admin.token') !== -1) return 'tok-abc-123\n';
    return '';
}

(async function main() {
    shellImpl = baseShell;
    execLog = [];
    fireDomReady();
    await sleep(120); // init chain: token + three sources

    console.log('== boot: three tabs, keybox log active ==');
    ok($('chip-kb').classList.contains('on') && $('chip-kb').getAttribute('aria-pressed') === 'true',
        'default tab is Keybox 获取');
    ok($('chip-sync').getAttribute('aria-pressed') === 'false'
        && $('chip-daemon').getAttribute('aria-pressed') === 'false', 'other tabs unpressed');
    ok($('lg-view').children.length === 4, 'keybox log lines rendered, got ' + $('lg-view').children.length);
    ok($('lg-meta').textContent.indexOf('4 行') !== -1, 'line count shown in the header, got: ' + $('lg-meta').textContent);
    var errLines = 0;
    $('lg-view').children.forEach(function (l) { if (l.classList.contains('err')) errLines++; });
    ok(errLines === 1, 'the ERROR line is classified .err, got ' + errLines);
    ok($('lg-view').textContent.indexOf('keybox download failed') !== -1, 'log text rendered verbatim');

    console.log('== tab switching ==');
    $('chip-sync').click();
    await sleep(30);
    ok($('chip-sync').classList.contains('on') && $('chip-kb').classList.contains('on') === false,
        'sync chip activates, keybox chip deactivates');
    ok($('lg-view').children.length === 2, 'sync log lines rendered');
    ok($('lg-view').textContent.indexOf('com.removed.app') !== -1, 'sync log content shown');
    $('chip-daemon').click();
    await sleep(30);
    ok($('lg-view').children.length === 3, 'daemon log lines rendered, got ' + $('lg-view').children.length);
    ok($('lg-view').textContent.indexOf('[E] KeyAdmin: bad request') !== -1,
        'daemon lines formatted as [level] tag: text');
    var dErr = 0, dWarn = 0;
    $('lg-view').children.forEach(function (l) {
        if (l.classList.contains('err')) dErr++;
        if (l.classList.contains('warn')) dWarn++;
    });
    ok(dErr === 1 && dWarn === 1, 'daemon E/W levels classified, got err=' + dErr + ' warn=' + dWarn);
    var writes0 = writeCount();
    $('chip-daemon').click(); // already active
    await sleep(30);
    ok($('lg-view').children.length === 3 && writeCount() === writes0,
        're-clicking the active tab is a no-op');

    console.log('== debug tab + toggle ==');
    // The chips only switch the rendered source; the flag probe runs on
    // loadAll (boot/refresh). Override the probe, then refresh to re-probe.
    shellImpl = function (cmd) {
        if (cmd.indexOf('test -f') === 0) return 'on\n';
        return baseShell(cmd);
    };
    $('chip-debug').click();
    await sleep(50);
    ok($('chip-debug').classList.contains('on'), 'debug chip activates');
    ok($('lg-view').children.length === 5, 'debug.log lines rendered, got ' + $('lg-view').children.length);
    ok($('lg-view').textContent.indexOf('[kbfetch] lock acquired') !== -1
        && $('lg-view').textContent.indexOf('[service] tick:') !== -1, 'debug content shown (multi-tag)');
    $('lg-refresh').click(); // re-probe with debug=on
    await sleep(150);
    ok($('dbg-toggle').textContent.indexOf('关闭 Debug 模式') !== -1,
        'toggle offers OFF while debug is on, got: ' + $('dbg-toggle').textContent);
    shellImpl = function (cmd) {
        if (cmd.indexOf('test -f') === 0) return 'off\n';
        return baseShell(cmd);
    };
    $('dbg-toggle').click(); // OFF: logs the switch, removes the flag, re-probes (off)
    await sleep(100);
    ok(execLog.some(function (c) { return c.indexOf('.debug') !== -1 && c.indexOf('rm -f') !== -1; }),
        'toggling off removes the flag file');
    ok($('dbg-toggle').textContent.indexOf('开启 Debug 模式') !== -1,
        'toggle now offers ON, got: ' + $('dbg-toggle').textContent);
    shellImpl = function (cmd) {
        if (cmd.indexOf('test -f') === 0) return 'on\n';
        return baseShell(cmd);
    };
    $('dbg-toggle').click(); // ON again
    await sleep(100);
    ok(execLog.some(function (c) { return c.indexOf('touch') !== -1 && c.indexOf('.debug') !== -1; }),
        'toggling on touches the flag file');
    shellImpl = baseShell;
    $('chip-daemon').click(); // restore the tab the later assertions expect
    await sleep(50);

    console.log('== refresh ==');
    var execs0 = execLog.length;
    $('lg-refresh').click();
    await sleep(120);
    ok(execLog.length > execs0 && $('lg-view').children.length === 3, 'refresh re-pulls all sources');

    console.log('== diagnostics export: content ==');
    $('diag-btn').click();
    var w = await waitFor(function () {
        for (var i = execLog.length - 1; i >= 0; i--) {
            var m = execLog[i].match(/mv -f '[^']*' '([^']*)'/);
            var b = execLog[i].match(/\n([A-Za-z0-9+\/=]+)\nFUSION_EOF_/);
            if (m && b) return { path: m[1], text: Buffer.from(b[1], 'base64').toString('utf8') };
        }
        return null;
    }, 5000);
    await sleep(80); // let the success-path UI settle after the write resolves
    ok(!!w, 'export wrote a file');
    ok(!!w && w.path.indexOf('/sdcard/Download/aegis-diagnostics-') === 0,
        'file lands in /sdcard/Download with a timestamped name: ' + (w && w.path));
    var t = w ? w.text : '';
    ok(t.indexOf('Aegis Fusion 诊断信息') === 0, 'file starts with the diagnostics header');
    ok(t.indexOf('v2.2.8 (TEESim v4.0-canary-66)') !== -1, 'module version included');
    ok(t.indexOf('Pixel 9') !== -1 && t.indexOf('Android 16') !== -1 && t.indexOf('KernelSU') !== -1,
        'device / manager info included');
    ok(t.indexOf('sha256 前缀 abcd1234abcd') !== -1 && t.indexOf('社区自动管理') !== -1,
        'keybox metadata (sha prefix, auto-managed) included');
    ok(t.indexOf('本机吊销检测缓存: 可用（7 小时前更新）') !== -1,
        'revocation-cache state included (so a false-clean keybox report is traceable)');
    ok(t.indexOf('运行中') !== -1 && t.indexOf('v4.0-canary-66') !== -1 && t.indexOf('inject.so') !== -1,
        'daemon status (running, version, hook) included');
    ok(t.indexOf('受保护应用数量: 3') !== -1, 'scope reduced to a count');
    ok(t.indexOf('检测类应用(密钥认证/PIAC 等): v3.1.7 起不再自动排除') !== -1,
        'detector note states the retired exclusion (v3.1.7)');
    ok(t.indexOf('vbmeta.device_state=locked') !== -1 && t.indexOf('verifiedbootstate=green') !== -1
        && t.indexOf('release-keys') !== -1, 'live BL prop values included');
    ok(t.indexOf('本进程挂载项: 37 · 含 /data/adb 的挂载: 0') !== -1,
        'mount-view baseline included (cross-process divergence diagnosis)');
    ok(t.indexOf('卸载模块挂载') !== -1, 'mount split names the manager-side toggle to check');
    ok(t.indexOf('[E] KeyAdmin: bad request') !== -1 && t.indexOf('keybox download failed') !== -1,
        'all three log tails included');

    console.log('== diagnostics export: fingerprint section ==');
    ok(t.indexOf('== 指纹层 ==') !== -1 && t.indexOf('内置 · 自动指纹') !== -1,
        'fingerprint section shows the bundled auto fingerprint');
    ok(t.indexOf('轮换状态: 正常（到期前自动更换）') !== -1,
        'rotation phase included for auto-managed fingerprints');
    ok(t.indexOf('预估到期日: 2026-10-01') !== -1,
        'estimated expiry date included when the prop carries the comment');
    ok(t.indexOf('Zygisk 环境: 已启用') !== -1, 'zygisk env state included');
    ok(t.indexOf('fingerprint ready at') !== -1, 'pif-fetch.log tail included');
    ok(t.indexOf('Debug 模式: 开启') !== -1, 'debug mode state included in the status section');
    ok(t.indexOf('debug.log (最后 150 行 · Debug 模式: 开启)') !== -1
        && t.indexOf('[kbfetch] lock acquired') !== -1, 'debug.log tail included in diagnostics');
    console.log('== diagnostics export: experiment-switch & profile section ==');
    ok(t.indexOf('== 实验开关 / TEE Profile ==') !== -1
        && t.indexOf('.pif-off: 关') !== -1 && t.indexOf('.pif-sync-off: 关') !== -1,
        'experiment switch states included');
    ok(t.indexOf('patchLevel(system/vendor/boot)=2026-08-01/2026-09-05/2026-09-05') !== -1
        && t.indexOf('Profile 身份(应跟随 PIF 伪装值): brand=Xiaomi') !== -1,
        'config.json profile summary included (identity flagged as PIF-following)');
    ok(t.indexOf('真机补丁级: system=2026-08-01') !== -1,
        'real device patch levels included for sync-diff judgement');
    // no-fingerprint + no-zygisk variant must say so instead of pretending
    var noPifProbe = DIAG_PROBE_OUT
        .replace('PIFSRC=/data/adb/modules/aegisfusion_rs/custom.pif.prop', 'PIFSRC=')
        .replace('ZYG=yes', 'ZYG=no');
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe logs') !== -1) return noPifProbe;
        return baseShell(cmd);
    };
    // Only look at writes made AFTER this click: earlier exports (the main one
    // above and the detector variants) also land in execLog, and a global
    // "second write" matcher would happily return one of those.
    var noPifMark = execLog.length;
    $('diag-btn').click();
    var w2 = null;
    await waitFor(function () {
        for (var i = execLog.length - 1; i >= noPifMark; i--) {
            var b = execLog[i].match(/\n([A-Za-z0-9+\/=]+)\nFUSION_EOF_/);
            if (b) { w2 = Buffer.from(b[1], 'base64').toString('utf8'); return true; }
        }
        return false;
    }, 5000);
    var t2 = w2 || '';
    shellImpl = baseShell;
    await sleep(200); // let the second export's success-path microtasks settle (busy flag + button)
    ok(t2.indexOf('指纹来源: 未生成 · 等待 pif-fetch 自动获取（需网络）') !== -1,
        'no fingerprint anywhere -> honest 未生成 wording');
    ok(t2.indexOf('轮换状态') === -1 && t2.indexOf('预估到期日') === -1,
        'no fingerprint -> no rotation phase lines (quiet unless wrong)');
    ok(t2.indexOf('Zygisk 环境: 未启用（指纹半不生效，verdict 上限 BASIC）') !== -1,
        'no zygisk -> explicit consequence wording');
    ok(t.indexOf('分享前请自查') !== -1, 'share-warning banner present (log tails may contain package names)');
    ok(t.indexOf('com.removed.app') !== -1, 'log-tail package names included BY DESIGN (banner warns)');

    console.log('== diagnostics: the engine verdict is anchored to the CURRENT keybox ==');
    // Field export 2026-09-11-164428. The engine had ACCEPTED the keybox at
    // 16:44:22 (ack applied=1 failed=0, two pre-existing keys re-rooted), and yet
    // the report printed, four lines apart:
    //   Keybox 引擎可用性: 通过 — 引擎能据此建出 TA
    //   ★ 引擎给出的原因（teesim_km_init_ex）: base64: InvalidByte(1887, 61)
    // Both lines were true — about DIFFERENT keyboxes. The reason came from the box
    // that had just been replaced, and it was read straight out of the durable log
    // (which keeps every refusal it has ever printed) instead of out of
    // .engine-verdict, the one file engine-verdict.sh clears on acceptance.
    var HIST = 'base64: InvalidByte(1887, 61)';
    var ENGINE_FAKE =
        '09-11 16:42:37.510  1492  1523 I TEESimulator: generateKey: level=1, 23 param(s), caller_uid=10250, target=0\n' +
        '09-11 16:42:42.852  1492 11499 I TEESimulator: generateKey: level=1, 14 param(s), caller_uid=10296, target=0\n' +
        '09-11 16:44:22.354  4389  7902 I TEESimulator: control: pushed config (epoch=1)\n' +
        "09-11 16:44:22.370  1492  7707 I TEESimulator: cfg: staged profile 'default' (mode=generation, security_level=1, 55 package(s), 55 uid(s))\n" +
        '09-11 16:44:22.371  4389  7670 I TEESimulator: control: ack epoch=1789116261073 ok=true applied=1 failed=0\n' +
        // audit H1 regression fixture: the upstream harvest line printed these in
        // plaintext; the export must mask them (patch 0006 stops it at the source,
        // but old logs on a device still contain the line verbatim).
        "09-11 16:44:23.100  4389  7902 I TEESimulator: Harvest telephony IDs: imei='350000000000001' secondImei='' meid='A0000000DEADBEEF' serial='0123456789ABCDEF'\n";
    var ENGINE_KEYS = 'EPUSH=1\nEACK=1\nESTAGED=1\nEBUILD=1\nENEVER=0\nERESOLVE=0\nELOGSZ=4096\n' +
        'ET1=0\nET0=0\nET1ALL=76\nET0ALL=11\nEAPP=1\nEFAIL=0\n' +
        'KBCHK=ok\nKBBAD=no\nKBLINK=no\nDAEMON=running\nCTL_SOCK=present\nINJECTED=3\nPIFMAP=0\n' +
        'KBPROG=\nKBPROGT=0\n';

    // Export with a given probe + engine-trace fixture, and return the file text.
    async function exportProbe(probe, engineText) {
        var before = execLog.length;
        shellImpl = function (cmd) {
            if (cmd.indexOf('ui-probe logs') !== -1) return probe;
            if (engineText && cmd.indexOf('teesim.log') !== -1) return engineText;
            return baseShell(cmd);
        };
        $('diag-btn').click();
        var txt = await waitFor(function () {
            for (var i = execLog.length - 1; i >= before; i--) {
                var b = execLog[i].match(/\n([A-Za-z0-9+\/=]+)\nFUSION_EOF_/);
                if (b) return Buffer.from(b[1], 'base64').toString('utf8');
            }
            return null;
        }, 5000);
        await sleep(150);
        shellImpl = baseShell;
        return txt || '';
    }

    var tAcc = await exportProbe(DIAG_PROBE_OUT + '\n' + ENGINE_KEYS +
        'EISTATE=ok\nEIREASON=\nEIHIST=' + HIST + '\n', ENGINE_FAKE);
    ok(tAcc.indexOf('本机实测: 引擎已接受当前 keybox') !== -1,
        'accepted keybox: the engine verdict is stated positively');
    ok(tAcc.indexOf('★ 引擎给出的原因') === -1,
        'accepted keybox: NO live failure reason printed (the field contradiction)');
    ok(tAcc.indexOf('历史（已被当前 keybox 取代') !== -1 && tAcc.indexOf(HIST) !== -1,
        'accepted keybox: the superseded reason survives as labelled history');
    ok(tAcc.indexOf('Google 源状态: 3 个绿格（渠道自述）') !== -1,
        'green count rendered as a channel self-report, not a device verdict');
    ok(tAcc.indexOf('引擎接管请求(target=1) = 0 · 转发真机(target=0) = 0') !== -1,
        'request counters are scoped to the last ack');
    ok(tAcc.indexOf('自最后一次 ack 起没有任何 generateKey') !== -1,
        'no requests since the ack is stated as normal, not as a fault');
    ok(tAcc.indexOf('全部 2 次 generateKey 都是 target=0') === -1,
        'pre-ack generateKey lines are NOT reported as the current state');

    var tRej = await exportProbe(DIAG_PROBE_OUT + '\n' + ENGINE_KEYS +
        'EISTATE=rejected\nEIREASON=' + HIST + '\nEIHIST=' + HIST + '\n', ENGINE_FAKE);
    ok(tRej.indexOf('★ 引擎给出的原因（teesim_km_init_ex）: ' + HIST) !== -1,
        'refused keybox: the engine reason IS printed');
    ok(tRej.indexOf('本机实测: 引擎已接受') === -1,
        'refused keybox: no "accepted" claim anywhere');

    // kbg = -1 is keybox-fetch.sh's deliberate "this channel publishes no status
    // file" sentinel (Yurikey). Rendered raw it read "Google 源状态: -1 个有效".
    var tNeg = await exportProbe(DIAG_PROBE_OUT.replace('KBG=3', 'KBG=-1') + '\n' + ENGINE_KEYS +
        'EISTATE=ok\nEIREASON=\nEIHIST=\n', ENGINE_FAKE);
    ok(tNeg.indexOf('-1 个有效') === -1, 'no-status channel: no negative green count, got "' +
        (tNeg.match(/Google 源状态: [^\n]*/) || [''])[0] + '"');
    ok(tNeg.indexOf('渠道未提供自述（该渠道不发布状态文件）') !== -1,
        'no-status channel: says the channel publishes no status file');

    // The interval number has three display sites (this export, the dashboard
    // and the installer summary) and the fetcher honours whatever the file
    // holds - there is no whitelist. Two ways to lie, both pinned here.
    var tOff = await exportProbe(DIAG_PROBE_OUT.replace('REF=24', 'REF=0') + '\n' + ENGINE_KEYS +
        'EISTATE=ok\nEIREASON=\nEIHIST=\n', ENGINE_FAKE);
    ok(tOff.indexOf('自动刷新间隔: 已关闭') !== -1,
        'disabled interval is exported as 已关闭, never "0h", got "'
        + (tOff.match(/自动刷新间隔: [^\n·]*/) || [''])[0] + '"');
    var tSix = await exportProbe(DIAG_PROBE_OUT.replace('REF=24', 'REF=6') + '\n' + ENGINE_KEYS +
        'EISTATE=ok\nEIREASON=\nEIHIST=\n', ENGINE_FAKE);
    ok(tSix.indexOf('自动刷新间隔: 6h') !== -1,
        'an interval outside the pill row is exported as itself, got "'
        + (tSix.match(/自动刷新间隔: [^\n·]*/) || [''])[0] + '"');

    console.log('== diagnostics export: device-id masking (audit H1) ==');
    // The engine-log fixture carries the upstream harvest line verbatim; the
    // export must show the line in MASKED form (values gone, length kept).
    var tMask = await exportProbe(DIAG_PROBE_OUT + '\n' + ENGINE_KEYS +
        'EISTATE=ok\nEIREASON=\nEIHIST=\n', ENGINE_FAKE);
    ok(tMask.indexOf("350000000000001") === -1, 'IMEI never exported');
    ok(tMask.indexOf("A0000000DEADBEEF") === -1, 'MEID never exported');
    ok(tMask.indexOf("0123456789ABCDEF") === -1, 'serial never exported');
    ok(tMask.indexOf("imei='<redacted:len=15>'") !== -1,
        'harvest line survives with the value masked and the length kept');
    ok(tMask.indexOf("secondImei='<redacted:len=0>'") !== -1,
        'blank second IMEI reported as blank, not as a value');

    console.log('== diagnostics export: JSON-form masking (audit N1) ==');
    // /status embeds the harvest record as JSON ("key":"value" — no '='), a
    // shape the original two mask rules let through verbatim (audit N1). The
    // export must mask it too, in case any source starts carrying JSON.
    var tJson = await exportProbe(DIAG_PROBE_OUT + '\n' + ENGINE_KEYS +
        'EISTATE=ok\nEIREASON=\nEIHIST=\n',
        ENGINE_FAKE + '{"harvest":{"brand":"generic","model":"Pixel","serial":"0123456789ABCDEF","imei":"350000000000001","meid":"A0000000DEADBEEF"}}\n');
    ok(tJson.indexOf("350000000000001") === -1, 'JSON-form IMEI never exported');
    ok(tJson.indexOf("0123456789ABCDEF") === -1, 'JSON-form serial never exported');
    ok(tJson.indexOf("A0000000DEADBEEF") === -1, 'JSON-form MEID never exported');
    ok(tJson.indexOf('"imei":"<redacted:len=15>"') !== -1,
        'JSON-form imei masked with the length kept');
    ok(tJson.indexOf('"serial":"<redacted:len=16>"') !== -1,
        'JSON-form serial masked with the length kept');

    console.log('== diagnostics export: masking is form-independent (audit r5) ==');
    // Until audit r5 the unquoted rule accepted only [A-Za-z0-9]{4,} immediately
    // after '=', so four shapes reached the export untouched: a hyphenated
    // value, a value whose first alphanumeric run was shorter than four, a
    // space-separated value, and the `serialno` property the engine actually
    // reads ("ro.serialno=…"). The file lands on world-readable
    // /sdcard/Download, so these are pinned here; the shell copies are covered
    // by scripts/test-mask-ids.sh.
    var FORM_FAKE = ENGINE_FAKE +
        '09-11 16:44:24.100  4389  7902 I TEESimulator: Record(harvestFailed=false, harvestedAt=1789116261073, imei=350000000000001, imei2=, meid=A0000000DEADBEEF, serial=SN-1234567)\n' +
        '09-11 16:44:24.200  4389  7902 I TEESimulator: Harvest: device ids not supplied; ro.serialno=SN-1234567\n' +
        '09-11 16:44:24.300  4389  7902 I TEESimulator: Harvest telephony IDs: imei 350000000000001\n' +
        '09-11 16:44:24.400  4389  7902 I TEESimulator: teesim: imei=\n350000000000001\n' +
        '09-11 16:44:24.500  4389  7902 I TEESimulator: java.io.InvalidClassException: serialVersionUID mismatch\n';
    var tForm = await exportProbe(DIAG_PROBE_OUT + '\n' + ENGINE_KEYS +
        'EISTATE=ok\nEIREASON=\nEIHIST=\n', FORM_FAKE);
    ok(tForm.indexOf('SN-1234567') === -1,
        'hyphenated serial absent (was the [A-Za-z0-9]{4,} escape)');
    ok(tForm.indexOf('350000000000001') === -1, 'IMEI absent in the quoted, bare, spaced and wrapped forms');
    ok(tForm.indexOf('A0000000DEADBEEF') === -1, 'MEID absent in the Kotlin toString form');
    ok(tForm.indexOf('serial=<redacted:len=10>') !== -1,
        'hyphenated serial masked, length still reported (signal kept)');
    ok(tForm.indexOf('serialVersionUID mismatch') !== -1,
        'negative control: untargeted text (serialVersionUID) survives, no over-redaction');

    console.log('== diagnostics export: redaction (hard rules) ==');
    ok(t.indexOf('PrivateKey') === -1, 'keybox body never exported');
    ok(t.indexOf('tok-abc-123') === -1, 'admin token never exported');
    ok(t.indexOf('com.secret.bank') === -1, 'config scope names never exported');
    ok(t.indexOf('com.ok.app') === -1,
        'no other saved scope entries leaked');
    // com.google.android.gms appears ONLY via the debug.log tail (the seed
    // action legitimately names the package) — the same verbatim-by-design
    // class as com.removed.app above, never from the config.json parse.
    ok($('diag-out').hidden === false && $('diag-out').textContent.indexOf('/sdcard/Download/') !== -1,
        'success path surfaced in the UI');
    ok($('diag-btn').textContent === '生成诊断文件' && $('diag-btn').disabled === false,
        'export button restored after completion');

    console.log('== diagnostics export: busy guard ==');
    var wc0 = writeCount();
    $('diag-btn').click();
    $('diag-btn').click(); // second click while the first is in flight
    await waitFor(function () { return writeCount() > wc0; }, 5000);
    await sleep(150); // give a hypothetical second write time to land — there must be none
    ok(writeCount() === wc0 + 1, 'double click exports exactly one file, got ' + (writeCount() - wc0));

    console.log('== diagnostics export: write failure surfaces an error ==');
    shellImpl = function (cmd) {
        if (cmd.indexOf('base64 -d >') !== -1) return { __exit: 1, out: '' };
        return baseShell(cmd);
    };
    $('diag-btn').click();
    var failShown = await waitFor(function () {
        return $('diag-err').hidden === false && $('diag-btn').disabled === false;
    }, 5000);
    ok(!!failShown && $('diag-err').textContent.indexOf('生成失败') !== -1,
        'write failure shows an explanatory error');
    ok($('diag-btn').disabled === false, 'button re-enabled after the failure');

    console.log('== daemon unreachable: note + empty state ==');
    shellImpl = function (cmd) {
        if (cmd.indexOf('teesim-uds') !== -1 && cmd.indexOf('/logs') !== -1) return 'not-json';
        return baseShell(cmd);
    };
    fireDomReady();
    await sleep(150);
    $('chip-daemon').click();
    await sleep(30);
    ok($('lg-view').textContent.indexOf('暂无日志') !== -1, 'unreachable daemon shows the empty state');
    ok($('lg-meta').textContent.indexOf('无法读取') !== -1, 'failure note surfaced in the header');

    console.log('== daemon buffer longer than one pull: download route gives the true tail ==');
    // /logs is cursor-based and serves the OLDEST window first; a full 2000-line
    // window may mean the buffer is longer. The page must then switch to the
    // raw /logs/download route (keeps the NEWEST bytes) instead of showing the
    // stale head as if it were the tail.
    var FULL_LINES = [];
    for (var fi = 1; fi <= 2000; fi++) {
        FULL_LINES.push({ seq: fi, level: 'I', tag: 'Control', text: 'head-line-' + fi });
    }
    shellImpl = function (cmd) {
        if (cmd.indexOf('teesim-uds') !== -1 && cmd.indexOf('/logs?') !== -1) {
            return JSON.stringify({ ok: true, lines: FULL_LINES, nextAfter: 2001 });
        }
        if (cmd.indexOf('teesim-uds') !== -1 && cmd.indexOf('/logs/download') !== -1) {
            return 'old-context-a\nold-context-b\nraw-marker-tail-line\n';
        }
        return baseShell(cmd);
    };
    $('lg-refresh').click();
    await sleep(250);
    ok($('lg-view').textContent.indexOf('raw-marker-tail-line') !== -1,
        'window-full buffer falls back to the download-route tail');
    ok($('lg-view').textContent.indexOf('head-line-1') === -1,
        'the stale JSON head is NOT shown as the tail');
    ok($('lg-view').children.length === 3, 'download-route raw lines rendered, got ' + $('lg-view').children.length);

    console.log('');
    console.log(passed + ' passed, ' + failed + ' failed');
    process.exit(failed ? 1 : 0);
})().catch(function (e) { console.error('RUNNER ERROR', e); process.exit(2); });
