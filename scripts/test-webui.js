/* Mock-DOM end-to-end smoke tests for the IntegrityFusion v2 WebUI launcher.
 * Run: node scripts/test-webui.js
 *
 * The selection UI lives on apps.html and is covered by test-apps.js; this file
 * covers the dashboard: probe parsing, status lights (incl. the four TEE-engine
 * states), keybox controls and the protected-apps entry card.
 */
'use strict';

const cp = require('child_process');

// ---------- tiny DOM mock ----------
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
El.prototype.replaceChild = function (n, old) {
    var i = this.children.indexOf(old);
    if (i >= 0) this.children[i] = n;
    n.parentNode = this;
    return old;
};
El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
El.prototype.getAttribute = function (k) { return this.attrs[k] != null ? this.attrs[k] : null; };
El.prototype.querySelector = function (sel) {
    var cls = sel.replace(/^\./, '');
    for (var i = 0; i < this.children.length; i++) {
        if (this.children[i]._cls.has(cls)) return this.children[i];
    }
    return null;
};
El.prototype.querySelectorAll = function (sel) {
    var cls = sel.replace(/^\./, '');
    var out = [];
    (function walk(n) {
        n.children.forEach(function (c) {
            if (c._cls.has(cls)) out.push(c);
            walk(c);
        });
    })(this);
    return out;
};
// textContent reads aggregate the subtree (like a real DOM); writes stash to _text.
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
// className assignment must stay in sync with the classList mock.
Object.defineProperty(El.prototype, 'className', {
    get: function () { return Array.from(this._cls).join(' '); },
    set: function (v) {
        var self = this;
        self._cls = new Set();
        String(v || '').split(/\s+/).filter(Boolean).forEach(function (c) { self._cls.add(c); });
    }
});
El.prototype.addEventListener = function (ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); };
El.prototype.click = function () {
    var self = this;
    var l = (this._listeners.click || []);
    l.forEach(function (f) { f.call(self, { target: self, classList: self.classList, stopPropagation: function () {} }); });
};

var registry = {};
function reg(id) { var e = new El('div'); e.id = id; registry[id] = e; return e; }

var byId = {};
['status', 'st-tee', 'st-keybox', 'st-bl', 'st-pif', 'kb-ctrl', 'kb-hint', 'noapi', 'refresh',
 'kb-interval-trigger', 'kb-interval-pop', 'kb-interval-num',
 'kb-interval-unit', 'kb-source-trigger', 'kb-source-pop', 'kb-source-val',
 'kb-now', 'apps', 'apps-entry-sub',
 'kb-detail-sum', 'kb-d-src', 'kb-d-refresh', 'kb-d-status-row', 'kb-d-status', 'kb-d-err',
 'pif-detail', 'pif-detail-sum', 'pif-d-src', 'pif-d-warn', 'pif-import-btn', 'pif-import'
].forEach(function (id) { byId[id] = reg(id); });
byId['kb-d-status-row'].hidden = true; // 在线状态行仅用户导入时出现
byId['pif-detail'].hidden = true;      // 指纹详情栏与 HTML 一致，初始隐藏、root 渲染后展开

// status rows need .dot/.value children
['st-tee', 'st-keybox', 'st-bl', 'st-pif'].forEach(function (id) {
    var dot = new El('span'); dot.classList.add('dot');
    var val = new El('span'); val.classList.add('value');
    byId[id].appendChild(dot); byId[id].appendChild(val);
});
// interval trigger carries its num/unit display spans
byId['kb-interval-trigger'].appendChild(byId['kb-interval-num']);
byId['kb-interval-trigger'].appendChild(byId['kb-interval-unit']);
// interval options inside the bubble (data-v = file value; data-n/u = display)
[['0', 'off', ''], ['12', '12', 'h'], ['24', '24', 'h'], ['72', '3', 'd'], ['168', '1', 'w']]
    .forEach(function (o) {
        var c = new El('button');
        c.setAttribute('data-v', o[0]); c.setAttribute('data-n', o[1]); c.setAttribute('data-u', o[2]);
        c.classList.add('kb-opt');
        c.textContent = o[1] + o[2];
        byId['kb-interval-pop'].appendChild(c);
    });
// channel trigger + bubble (data-s)
byId['kb-source-trigger'].appendChild(byId['kb-source-val']);
['', 'Megatron', 'Yurikey', 'KOWX712'].forEach(function (s) {
    var c = new El('button'); c.setAttribute('data-s', s); c.classList.add('kb-opt');
    c.textContent = s || '自动';
    byId['kb-source-pop'].appendChild(c);
});

var docListeners = {};
var documentMock = {
    getElementById: function (id) { return byId[id] || null; },
    createElement: function (tag) { return new El(tag); },
    addEventListener: function (ev, fn) { (docListeners[ev] = docListeners[ev] || []).push(fn); },
    querySelectorAll: function () { return []; }
};

var windowMock = {};

// ---------- ksu.exec mock ----------
var shellImpl = null; // function(cmd) -> stdout string
var execLog = [];   // per-section log, cleared by the sections that need a delta
// Never cleared: the final shell-hygiene pass has to see EVERY command the
// WebUI built during the whole run (execLog is reset several times above).
var allExec = [];
windowMock.ksu = {
    exec: function (cmd, opts, cbName) {
        execLog.push(cmd);
        allExec.push(cmd);
        if (cbName) {
            setTimeout(function () {
                var out = shellImpl ? String(shellImpl(cmd)) : '';
                if (windowMock[cbName]) windowMock[cbName](0, out, '');
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
// FileReader mock: readAsText delivers file._content through onload, like a real one.
global.FileReader = function () {
    var self = this;
    self.readAsText = function (file) {
        setTimeout(function () {
            self.result = file._content;               // read off the reader itself
            self.target = { result: file._content };
            if (self.onload) self.onload({ target: self });
        }, 0);
    };
};

require(require('path').join(__dirname, '..', 'module', 'webroot', 'js', 'launcher.js'));

function fireDomReady() { (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); }); }
function $(id) { return byId[id]; }

// ---------- assertions ----------
var passed = 0, failed = 0;
function ok(cond, name) {
    if (cond) { passed++; console.log('  PASS ' + name); }
    else { failed++; console.log('  FAIL ' + name); }
}
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

var CONFIG_RAW = JSON.stringify({
    version: 1,
    profiles: {
        default: {
            keybox: 'keybox.xml', mode: 'patch',
            patchLevel: { system: 'today', vendor: 'YYYY-MM-05', boot: 'YYYY-MM-05' },
            apps: ['com.google.android.gms', 'com.android.vending', 'com.bank.app@10']
        }
    }
}, null, 2);

// The full PROBE script — one shell invocation, detected by its markers.
// daemonState: 'up' (socket ok) | 'pg' (process but no socket) | 'no' | 'nodex'
// probeExtra carries optional extra KEY=VALUE lines (R7-1 provenance tests).
var probeExtra = '';
// Test-only: simulate a keybox-refresh value the pill list does not know (or 0).
// The fetcher honours any number, so the WebUI has to display the real one.
var refOverride = null;
function probeOutput(daemonState) {
    var daemon = daemonState === 'up' ? 'yes' : 'no';
    var hook = daemonState === 'up' ? 'lsplt' : '';
    var dver = daemonState === 'up' ? 'v4.0-canary' : '';
    var pg = (daemonState === 'no' || daemonState === 'nodex') ? 'no' : 'yes';
    var dex = daemonState === 'nodex' ? 'no' : 'yes';
    var sock = daemonState === 'up' ? 'yes' : 'no';
    return [
        'UID=0', 'DAEMON=' + daemon, 'HOOK=' + hook, 'DVER=' + dver,
        'PG=' + pg, 'DEX=' + dex, 'SOCK=' + sock,
        'VER=v3.0.0', 'KEYBOX=yes', 'KBMARK=yes', 'KBSRC=Megatron', 'KBPREF=', 'REF=24', 'KBG=3',
        'KBAGE=4', 'KBS=🟢🟢🟢', 'KBERR=', 'KBCERTS=', 'REVJ=no', 'REVA=-1',
        'KBEV=unknown', 'KBRS=',
        'BL1=locked', 'BL2=green', 'BL3=release-keys', 'BL4=1',
        'PIFSRC=/data/adb/modules/aegisfusion_rs/custom.pif.prop', 'ZYG=yes'
    ].concat(probeExtra ? probeExtra.split('\n') : []).join('\n');
}

// Minimal DER certificate fixture for the revocation check: hand-built
// Certificate ::= SEQUENCE { tbsCertificate ::= SEQUENCE { [0] version,
// serialNumber INTEGER } }. `pad` grows the DER past 127 bytes so the
// long-form length encoding (0x81) branch of the parser is covered too.
function makeCertB64(serialHex, pad) {
    var sbytes = Buffer.from(serialHex, 'hex');
    if (sbytes[0] & 0x80) sbytes = Buffer.concat([Buffer.from([0]), sbytes]);
    var intDer = Buffer.concat([Buffer.from([0x02, sbytes.length]), sbytes]);
    var versionBlock = Buffer.from([0xA0, 0x03, 0x02, 0x01, 0x02]);
    var filler = pad ? Buffer.alloc(150, 0xAA) : Buffer.alloc(0);
    var tbs = Buffer.concat([versionBlock, intDer, filler]);
    var tbsW = tbs.length > 127
        ? Buffer.concat([Buffer.from([0x30, 0x81, tbs.length]), tbs])
        : Buffer.concat([Buffer.from([0x30, tbs.length]), tbs]);
    var cert = tbsW.length > 127
        ? Buffer.concat([Buffer.from([0x30, 0x81, tbsW.length]), tbsW])
        : Buffer.concat([Buffer.from([0x30, tbsW.length]), tbsW]);
    return cert.toString('base64');
}

function baseShell(cmd) {
    if (cmd.indexOf('ui-probe launcher') !== -1) {
        // RS 线：探针是 fusionctl ui-probe（root 由 KernelSU 授予，命令串里不再
        // 出现 id -u），非 root 分支的模拟随之退休 —— 套件里没有依赖它的断言。
        // stateful like the real device: the probe reads back whatever interval
        // was last written to keybox-refresh during this test run
        var ref = 24;
        execLog.forEach(function (c) {
            var m = c.match(/echo (\d+) > \/data\/adb\/teesim\/keybox-refresh/);
            if (m) ref = parseInt(m[1], 10);
        });
        if (refOverride !== null) ref = refOverride;
        return probeOutput('up').replace('REF=24', 'REF=' + ref);
    }
    if (cmd.indexOf('id -u') !== -1) return '0';
    if (cmd.indexOf('grep -m1 ^version=') !== -1) return 'version=v2.1.0';
    if (cmd.indexOf('pgrep') !== -1) return '12345';
    if (cmd.indexOf('keybox-refresh') !== -1) return '24';
    if (cmd.indexOf('.key-status-n') !== -1) return '3';
    if (cmd.indexOf('key-status.txt') !== -1) return '🟢🟢🟢';
    if (cmd.indexOf('keybox-fetch.log') !== -1) return '';
    if (cmd.indexOf('stat -c') !== -1) return String(Math.floor(Date.now() / 1000) - 4 * 3600);
    if (cmd.indexOf('getprop') !== -1) {
        if (cmd.indexOf('vbmeta.device_state') !== -1) return 'locked';
        if (cmd.indexOf('verifiedbootstate') !== -1) return 'green';
        if (cmd.indexOf('build.tags') !== -1) return 'release-keys';
        if (cmd.indexOf('flash.locked') !== -1) return '1';
        return '';
    }
    if (cmd.indexOf('config.json') !== -1 && cmd.indexOf('base64') === -1) return CONFIG_RAW;
    return '';
}

(async function main() {
    shellImpl = baseShell;
    execLog = [];
    fireDomReady();
    await sleep(80); // let the probe chain settle

    console.log('== status rendering ==');
    ok($('status').hidden === false, 'status section visible with ksu api');
    var teeVal = $('st-tee').querySelector('.value').textContent;
    ok(teeVal.indexOf('运行中') !== -1 && teeVal.indexOf('注入已生效') !== -1 && teeVal.indexOf('v4.0-canary') !== -1,
        'TEE light: running + hook attached + daemon version, got "' + teeVal + '"');
    var kbVal = $('st-keybox').querySelector('.value').textContent;
    // v3.1.3: the greens are the CHANNEL's self-report, and they now say so —
    // leaving them bare is how "🟢🟢🟢" got read as a device verdict while the
    // engine was refusing the keybox ("three greens, but actually one").
    ok(kbVal.indexOf('🟢🟢🟢') !== -1 && kbVal.indexOf('渠道自述') !== -1 && kbVal.indexOf('本机实测') === -1,
        'keybox light: channel greens carry their provenance, got "' + kbVal + '"');
    ok(kbVal.indexOf('来源') === -1 && kbVal.indexOf('小时') === -1,
        'keybox light stays short (channel/age live in the collapsible)');
    ok($('kb-d-refresh').textContent.indexOf('4 小时') !== -1
        && $('kb-d-refresh').textContent.indexOf('24') !== -1,
        'collapsible: refresh age + interval, got "' + $('kb-d-refresh').textContent + '"');
    ok($('kb-detail-sum').textContent.indexOf('Megatron') !== -1,
        'collapsed bar shows the effective channel');
    ok($('kb-d-status-row').hidden === true,
        'auto-managed: the online-status row stays hidden (the light already shows the cells)');
    ok($('st-keybox').querySelector('.value').textContent.indexOf('证书已过期') === -1,
        'valid cert never touches the light (validity row removed)');
    ok($('st-keybox').querySelector('.value').textContent.indexOf('Google 源') === -1,
        'keybox light: no Google 源 overclaim (v2.2.8)');
    ok($('st-bl').querySelector('.value').textContent === '已生效',
        'BL light is the single word 已生效, got "' + $('st-bl').querySelector('.value').textContent + '"');
    ok($('st-pif').querySelector('.value').textContent.indexOf('内置 · 自动指纹') !== -1
        && $('st-pif').querySelector('.value').textContent.indexOf('身份已同步') !== -1,
        'bundled auto fingerprint -> green 内置 · 自动指纹');

    console.log('== fingerprint layer: user-provided / external / absent / no zygisk ==');
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up')
                .replace('PIFSRC=/data/adb/modules/aegisfusion_rs/custom.pif.prop',
                    'PIFSRC=/data/adb/modules/aegisfusion_rs/custom.pif.json');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-pif').querySelector('.value').textContent.indexOf('内置 · 用户指纹') !== -1,
        'user custom.pif.json in the module dir -> 内置 · 用户指纹');
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('PIFSRC=/data/adb/modules/aegisfusion_rs/custom.pif.prop',
                'PIFSRC=/data/adb/pif.json');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-pif').querySelector('.value').textContent.indexOf('外部指纹模块') !== -1,
        'standalone pif.json -> 外部指纹模块 (still synced by pif-sync)');
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('PIFSRC=/data/adb/modules/aegisfusion_rs/custom.pif.prop',
                'PIFSRC=');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-pif').querySelector('.value').textContent.indexOf('指纹未生成') !== -1,
        'no fingerprint anywhere -> 指纹未生成 warn (auto-fetch pending)');
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('ZYG=yes', 'ZYG=no');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-pif').querySelector('.value').textContent.indexOf('Zygisk 未启用') !== -1,
        'no zygisk env -> honest warn (fingerprint half inert, BASIC ceiling)');
    shellImpl = baseShell;
    $('refresh').click();
    shellImpl = baseShell;
    $('refresh').click();
    await sleep(80);
    ok($('noapi').hidden === true, 'noapi hidden when rooted');
    ok($('kb-ctrl').hidden === false, 'keybox controls visible');

    ok($('kb-detail-sum').textContent === '现用 Megatron · 24h' && $('kb-interval-num').textContent === '24'
        && $('kb-interval-unit').textContent === 'h', 'interval rendered as 24h (trigger + collapsed bar)');
    var sel24 = null;
    $('kb-interval-pop').children.forEach(function (c) { if (c.classList.contains('sel')) sel24 = c; });
    ok(sel24 && sel24.getAttribute('data-v') === '24', '24h option marked selected in the bubble');

    console.log('== interval: the three displays must never disagree (2026-09-19) ==');
    // The fetcher (service.sh) honours ANY number in keybox-refresh - there is no
    // whitelist - so a value outside the pill row (hand-edited file, or one
    // written by another version) used to render as a comfortable "24h" while the
    // engine ran on the real one. The installer summary reads the same file, so
    // the user would see two different numbers: exactly the contradiction the
    // author called out. Both must now show the real value.
    refOverride = '6';
    $('refresh').click();
    await sleep(80);
    ok($('kb-interval-num').textContent === '6' && $('kb-interval-unit').textContent === 'h',
        'unmapped interval 6 shows as 6h in the pill, got "'
        + $('kb-interval-num').textContent + $('kb-interval-unit').textContent + '"');
    ok($('kb-detail-sum').textContent.indexOf('6h') !== -1,
        'collapsed summary follows the real interval, got "' + $('kb-detail-sum').textContent + '"');
    ok($('kb-d-refresh').textContent.indexOf('6 小时') !== -1,
        'detail row follows the real interval, got "' + $('kb-d-refresh').textContent + '"');
    // 0 = auto-fetch disabled: "0 小时" (or a fabricated 24h) both read as a lie.
    refOverride = '0';
    $('refresh').click();
    await sleep(80);
    ok($('kb-interval-num').textContent === 'off' && $('kb-interval-unit').textContent === '',
        'disabled interval shows off, got "' + $('kb-interval-num').textContent + '"');
    ok($('kb-d-refresh').textContent.indexOf('已关闭') !== -1,
        'disabled interval reads 已关闭 in the detail row, got "' + $('kb-d-refresh').textContent + '"');
    refOverride = null;

    console.log('== TEE engine states (socket probe) ==');
    // daemon down but process visible via pgrep -> control-channel failure
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) return probeOutput('pg');
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-tee').querySelector('.value').textContent.indexOf('控制通道不通') !== -1,
        'pg-only: control-channel failure surfaced');
    // no process, no dex -> payload missing
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) return probeOutput('nodex');
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-tee').querySelector('.value').textContent.indexOf('引擎文件缺失') !== -1,
        'no process + no dex: engine files missing surfaced');
    // no process, dex present, no socket -> plain not-running
    var out2 = probeOutput('no').replace('PG=no', 'PG=no');
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('no');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-tee').querySelector('.value').textContent.indexOf('未运行') !== -1,
        'not running: plain not-running message');
    // restore healthy
    shellImpl = baseShell;
    $('refresh').click();
    await sleep(80);
    ok($('st-tee').querySelector('.value').textContent.indexOf('注入已生效') !== -1, 'healthy state restored');

    console.log('== protected-apps entry card ==');
    ok($('apps').hidden === false, 'apps entry card visible');
    ok($('apps-entry-sub').textContent.indexOf('已保护 3 个应用') !== -1,
        'entry shows protected count (3, incl. the @10 work-profile entry), got "'
        + $('apps-entry-sub').textContent + '"');
    ok($('apps-entry-sub').textContent.indexOf('点按管理') !== -1, 'entry invites management');

    console.log('== interval selector (collapsible + bubble) ==');
    // trigger toggles the bubble
    var fnTrig = $('kb-interval-trigger')._listeners.click[0];
    fnTrig.call($('kb-interval-trigger'), { target: $('kb-interval-trigger'), classList: $('kb-interval-trigger').classList, stopPropagation: function () {} });
    ok($('kb-interval-pop').classList.contains('open')
        && $('kb-interval-trigger').getAttribute('aria-expanded') === 'true', 'trigger opens the bubble');
    fnTrig.call($('kb-interval-trigger'), { target: $('kb-interval-trigger'), classList: $('kb-interval-trigger').classList, stopPropagation: function () {} });
    ok($('kb-interval-pop').classList.contains('open') === false
        && $('kb-interval-trigger').getAttribute('aria-expanded') === 'false', 'trigger closes the bubble');
    // picking an option writes the numeric interval + updates trigger/bar text
    execLog = [];
    var opt72 = null;
    $('kb-interval-pop').children.forEach(function (c) { if (c.getAttribute('data-v') === '72') opt72 = c; });
    var fn = $('kb-interval-pop')._listeners.click[0];
    fn.call($('kb-interval-pop'), { target: opt72, classList: opt72.classList });
    await sleep(60);
    ok(execLog.join('\n').indexOf('echo 72 > /data/adb/teesim/keybox-refresh') !== -1,
        'clicking 3 天 writes 72 to the interval file');
    ok($('kb-interval-num').textContent === '3' && $('kb-interval-unit').textContent === 'd'
        && $('kb-detail-sum').textContent === '现用 Megatron · 3d', 'trigger + collapsed bar switch to 3d optimistically');
    var selAfter = null;
    $('kb-interval-pop').children.forEach(function (c) { if (c.classList.contains('sel')) selAfter = c; });
    ok(selAfter && selAfter.getAttribute('data-v') === '72', 'selection highlight moved to 3 天');

    console.log('== keybox channel selector (v2.2.8 capsule + bubble) ==');
    var autoOpt = null, yuriOpt = null;
    $('kb-source-pop').children.forEach(function (c) {
        if (c.getAttribute('data-s') === '') autoOpt = c;
        if (c.getAttribute('data-s') === 'Yurikey') yuriOpt = c;
    });
    ok($('kb-source-val').textContent === '自动' && autoOpt.classList.contains('sel'),
        '自动 default selected (no preference file)');
    // stateful shell: the probe reports whatever preference was actually written,
    // like the real device does (click -> write -> refresh confirms the trigger)
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            var pref = '';
            execLog.forEach(function (c) {
                if (c.indexOf('keybox-source-pref') !== -1 && c.indexOf("echo 'Yurikey'") !== -1) pref = 'Yurikey';
                if (c.indexOf('rm -f /data/adb/teesim/keybox-source-pref') !== -1) pref = '';
            });
            return probeOutput('up').replace('KBPREF=', 'KBPREF=' + pref);
        }
        return baseShell(cmd);
    };
    var fnSrc = $('kb-source-pop')._listeners.click[0];
    fnSrc.call($('kb-source-pop'), { target: yuriOpt, classList: yuriOpt.classList });
    await sleep(80);
    ok(execLog.join('\n').indexOf("echo 'Yurikey' > /data/adb/teesim/keybox-source-pref") !== -1,
        'clicking Yurikey writes the preference file');
    ok($('kb-source-val').textContent === 'Yurikey' && yuriOpt.classList.contains('sel'),
        'trigger shows Yurikey after selection');
    fnSrc.call($('kb-source-pop'), { target: autoOpt, classList: autoOpt.classList });
    await sleep(80);
    ok(execLog.join('\n').indexOf('rm -f /data/adb/teesim/keybox-source-pref') !== -1,
        'clicking 自动 removes the preference file');
    ok($('kb-source-val').textContent === '自动' && autoOpt.classList.contains('sel'),
        '自动 selected again after clearing the preference');
    shellImpl = baseShell;

    console.log('== keybox refresh: fire-and-forget spawn + lock poll (v2.2.6) ==');
    // Regression for the field-reported freeze: clicking 立即刷新 used to run the
    // 30s+ fetch THROUGH the 5s-giveup exec bridge — its 1.5s backstop re-ran the
    // script and managers with a synchronous single-arg exec hard-froze the whole
    // WebUI (white screen, manager swiped away). Now: detached background spawn,
    // then fast lock-file polls.
    var kbFetchRunning = false;
    shellImpl = function (cmd) {
        if (cmd.indexOf('nohup') !== -1) { kbFetchRunning = true; return 'spawned'; }
        if (cmd.indexOf('.kb-fetching.lock') !== -1 && cmd.indexOf('echo running') !== -1) {
            return kbFetchRunning ? 'running' : 'done';
        }
        return baseShell(cmd);
    };
    execLog = [];
    $('kb-now').click();
    await sleep(40);
    var joined = execLog.join('\n');
    ok(joined.indexOf('nohup /data/adb/modules/aegisfusion_rs/fusionctl keybox-fetch --force') !== -1
        && joined.indexOf('& echo spawned') !== -1, 'fetch detached into a background shell');
    ok(joined.indexOf('EXIT=$?') === -1, 'no blocking through-bridge script exec any more');
    ok($('kb-now').textContent === '刷新中…', 'button shows 刷新中… while the lock is held');
    kbFetchRunning = false;
    await sleep(3300); // poll #2 fires ~3s after poll #1
    ok($('kb-now').textContent === '已刷新', 'lock released -> 已刷新');
    await sleep(3400); // trailing refresh() + 2.5s label restore
    ok($('kb-now').textContent === '手动获取' && $('kb-now').disabled === false, 'button restored after finish');
    // A fetch already running (cron / boot pass): clicking follows, never double-spawns.
    kbFetchRunning = true;
    var spawnsBefore = execLog.filter(function (c) { return c.indexOf('nohup') !== -1; }).length;
    $('kb-now').click();
    await sleep(40);
    var spawnsAfter = execLog.filter(function (c) { return c.indexOf('nohup') !== -1; }).length;
    ok(spawnsAfter === spawnsBefore, 'clicking while a fetch runs does NOT spawn a second one');
    ok($('kb-now').textContent === '刷新中…', 'follows the already-running fetch');
    // Drain the pending poll chain + label-restore timer fully before the next
    // section, so its timers cannot race the KBRUN render assertions below.
    kbFetchRunning = false;
    await sleep(3300); // poll #2 -> done -> 已刷新
    await sleep(2700); // 2.5s label restore
    shellImpl = baseShell;

    console.log('== keybox light semantics: user-imported keybox (v2.2.8) ==');
    // No .auto-keybox marker -> the deployed keybox was imported by the user;
    // the community status describes the CHANNEL's keybox, not this one, so it
    // must be presented as reference-only, never as "Google 源有效".
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBMARK=yes', 'KBMARK=no').replace('KBSRC=Megatron', 'KBSRC=');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    var impVal = $('st-keybox').querySelector('.value').textContent;
    ok(impVal.indexOf('用户导入') !== -1, 'user-imported light is short, got "' + impVal + '"');
    ok($('kb-d-status-row').hidden === false,
        'imported: online-status row appears with the missing-cache hint');
    ok($('kb-d-status').textContent.indexOf('本机实测数据暂缺') !== -1,
        'imported: unknown revocation state explains itself');
    ok($('kb-detail-sum').textContent.indexOf('用户导入') !== -1, 'collapsed bar shows 用户导入');
    ok($('kb-now').disabled === false && $('kb-now').textContent === '手动获取',
        '手动获取 stays available for imported keyboxes (force takeover is the recovery path)');
    ok(impVal.indexOf('社区源报告有效') === -1, 'user-imported does NOT claim the community status as its own');

    // v3.0.3: 手动获取 on a deployed IMPORTED box asks before taking over —
    // the hint text alone sent a field user into destroying their import.
    console.log('== manual fetch on an imported box asks first (v3.0.3) ==');
    var confirmMsg = null, confirmAnswer = false;
    windowMock.confirm = function (msg) { confirmMsg = msg; return confirmAnswer; };
    var kbFetchImp = false;
    shellImpl = function (cmd) {
        if (cmd.indexOf('nohup') !== -1) { kbFetchImp = true; return 'spawned'; }
        if (cmd.indexOf('.kb-fetching.lock') !== -1 && cmd.indexOf('echo running') !== -1) {
            return kbFetchImp ? 'running' : 'done';
        }
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBMARK=yes', 'KBMARK=no').replace('KBSRC=Megatron', 'KBSRC=');
        }
        return baseShell(cmd);
    };
    execLog = [];
    $('kb-now').click();
    await sleep(40);
    ok(confirmMsg !== null && confirmMsg.indexOf('接管') !== -1,
        'imported state: 手动获取 warns about the takeover before doing anything');
    ok(execLog.join('\n').indexOf('nohup') === -1, 'declined: the imported box is untouched, nothing spawned');
    confirmAnswer = true;
    $('kb-now').click();
    await sleep(40);
    ok(execLog.join('\n').indexOf('nohup') !== -1, 'confirmed: the force fetch spawns normally');
    windowMock.confirm = undefined;
    kbFetchImp = false;
    await sleep(3300);  // poll #2 -> done
    await sleep(3400);  // trailing refresh + label restore
    // a no-status channel (e.g. Yurikey): green count -1 is keybox-fetch.sh's
    // deliberate "this channel publishes no status file" sentinel, NOT an unknown
    // value. v3.1.5 field report: "-1 个有效" in the export and "状态未知" next to
    // "引擎已加载" in the WebUI both read as problems when the only real fact is
    // that the channel has no self-report feed.
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBG=3', 'KBG=-1').replace('KBSRC=Megatron', 'KBSRC=Yurikey').replace('KBS=🟢🟢🟢', 'KBS=');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    var unkVal = $('st-keybox').querySelector('.value').textContent;
    ok(unkVal.indexOf('渠道无自述') !== -1, 'no-status channel: light says the channel has no self-report');
    ok(unkVal.indexOf('状态未知') === -1, 'no-status channel: no longer claims the state is unknown');
    ok($('kb-detail-sum').textContent.indexOf('Yurikey') !== -1
        && $('kb-d-src').textContent.indexOf('Yurikey') !== -1,
        'channel shown in the collapsed bar + details');
    shellImpl = baseShell;
    $('refresh').click();
    await sleep(80);

    console.log('== certificate-expiry feature: removed (v2.2.10) ==');
    // KBEXP never parsed on real devices (no openssl, fragile DER grep), the
    // row always showed "—" — feature and its tests are gone entirely.
    ok($('kb-d-validity') === null || $('kb-d-validity') === undefined,
        'validity row no longer exists in the UI');

    console.log('== three-cell key status display (v2.2.8) ==');
    // reds fill the remaining cells so the level reads at a glance: 2/3 -> 🟢🟢🔴
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBG=3', 'KBG=2');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    var twoVal = $('st-keybox').querySelector('.value').textContent;
    ok(twoVal.indexOf('🟢🟢🔴') !== -1 && twoVal.indexOf('受限') !== -1,
        '2 greens render as 🟢🟢🔴 + 受限, got "' + twoVal + '"');
    ok($('st-keybox').classList.contains('warn'), '2 greens carry the warn class');
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBG=3', 'KBG=1');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-keybox').querySelector('.value').textContent.indexOf('🟢🔴🔴') !== -1
        && $('st-keybox').querySelector('.value').textContent.indexOf('严重受限') !== -1,
        '1 green renders as 🟢🔴🔴 + 严重受限');
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBG=3', 'KBG=0');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    var zeroVal = $('st-keybox').querySelector('.value').textContent;
    ok(zeroVal.indexOf('🔴🔴🔴') !== -1 && zeroVal.indexOf('已吊销') !== -1
        && $('st-keybox').classList.contains('err'), '0 greens render as 🔴🔴🔴 + 已吊销 (err)');
    shellImpl = baseShell;
    $('refresh').click();
    await sleep(80);

    console.log('== engine verdict overrides the channel self-report (v3.1.3) ==');
    // The engine accepted: the light says so, and stays green.
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBEV=unknown', 'KBEV=ok');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    var engOk = $('st-keybox').querySelector('.value').textContent;
    ok(engOk.indexOf('引擎已加载') !== -1 && $('st-keybox').classList.contains('ok'),
        'engine accepted -> the light confirms the device side, got "' + engOk + '"');
    // The engine REFUSED it while the channel still claims three greens: the exact
    // contradiction the module used to hide. It must go red, keep the channel's
    // cells for contrast, and print the engine's own reason.
    var REASON = 'RSA: expected at least 2 certificates, found 1';
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up')
                .replace('KBEV=unknown', 'KBEV=rejected')
                .replace('KBRS=', 'KBRS=' + REASON);
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    var rejVal = $('st-keybox').querySelector('.value').textContent;
    ok(rejVal.indexOf('引擎拒绝') !== -1 && rejVal.indexOf(REASON) !== -1
        && rejVal.indexOf('🟢🟢🟢') !== -1 && $('st-keybox').classList.contains('err'),
        'engine refused -> red light + reason + channel greens kept for contrast, got "' + rejVal + '"');
    ok($('kb-d-err').textContent.indexOf(REASON) !== -1,
        'detail row carries the engine reason, got "' + $('kb-d-err').textContent + '"');
    // keybox.xml changed since the verdict was recorded -> never show it as current.
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBEV=unknown', 'KBEV=stale');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    var staleVal = $('st-keybox').querySelector('.value').textContent;
    ok(staleVal.indexOf('待引擎确认') !== -1 && staleVal.indexOf('引擎拒绝') === -1,
        'a stale verdict is never presented as the current one, got "' + staleVal + '"');
    shellImpl = baseShell;
    $('refresh').click();
    await sleep(80);

    console.log('== unrooted device ==');
    // RS 线：非 root 由探针输出 UID=2000 表达（fusionctl 由 KernelSU 授权执行，
    // 命令串里不再出现 id -u）—— 被测对象是 JS 对 UID 的处理。
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('UID=0', 'UID=2000');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(80);
    ok($('st-tee').querySelector('.value').textContent.indexOf('读取失败') !== -1, 'unrooted: lights show read-failure');
    ok($('apps').hidden === true, 'unrooted: apps entry hidden');

    console.log('== KBRUN=yes: probe surfaces a background fetch ==');
    // The row must stay short but it must MOVE. A frozen "后台刷新中…" with no stage
    // and no elapsed time is indistinguishable from a hang (v3.1.5 field report:
    // "刚开始显示后台刷新中一直不更新"). keybox-fetch.sh rewrites .kb-fetch.progress at
    // every stage; the row carries the elapsed seconds, the collapsed panel the stage.
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            var t = Math.floor(Date.now() / 1000) - 42;
            return probeOutput('up').replace('BL1=locked',
                'KBRUN=yes\nKBPROG=下载候选 · Yurikey · 第 2/3 次尝试\nKBPROGT=' + t + '\nBL1=locked');
        }
        return baseShell(cmd);
    };
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(80);
    var runVal = $('st-keybox').querySelector('.value').textContent;
    ok(runVal.indexOf('刷新中') !== -1 && /[0-9]+\s*s/.test(runVal),
        'keybox row shows a running fetch WITH elapsed seconds, got "' + runVal + '"');
    ok($('kb-now').disabled === true && $('kb-now').textContent === '后台刷新中…',
        'refresh button disabled with 后台刷新中… label while a fetch runs');
    ok($('kb-d-refresh').textContent.indexOf('下载候选') !== -1
        && $('kb-d-refresh').textContent.indexOf('Yurikey') !== -1,
        'collapsed panel names the stage and the channel being fetched');

    console.log('== local revocation check: REVOKED serial overrides everything ==');
    // v2.2.9: the WebUI compares the deployed keybox's certificate serials
    // against Google's cached revocation list. A REVOKED verdict wins over
    // community chips — including for a user-imported box (KBMARK=no), which
    // has no chips at all. The fixture uses the long-form DER length encoding.
    var certRevoked = makeCertB64('abcd1234deadbeef', true);
    shellImpl = function (cmd) {
        if (cmd.indexOf('grep -oE') === 0 && cmd.indexOf('.revocation-status.json') !== -1) {
            return '"abcd1234deadbeef" : {\n      "status" : "REVOKED",\n      "reason" : "KEY_COMPROMISE"\n    }';
        }
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up')
                .replace('KBMARK=yes', 'KBMARK=no')
                .replace('KBCERTS=', 'KBCERTS=' + certRevoked)
                .replace('REVJ=no', 'REVJ=yes').replace('REVA=-1', 'REVA=1');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(150);
    ok($('st-keybox').querySelector('.value').textContent.indexOf('已被 Google 吊销') !== -1,
        'REVOKED serial: light shows the local verdict, not community chips');
    ok($('st-keybox').querySelector('.value').textContent.indexOf('手动获取') !== -1,
        'revoked light names the recovery path (手动获取)');
    ok($('kb-d-status').textContent.indexOf('已被 Google 吊销') !== -1,
        'imported-box detail row carries the revocation verdict');

    console.log('== local revocation check: clean serials on a user-imported box ==');
    var certOk = makeCertB64('0123456789abcdef', false);
    shellImpl = function (cmd) {
        if (cmd.indexOf('grep -oE') === 0 && cmd.indexOf('.revocation-status.json') !== -1) return ''; // no match
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up')
                .replace('KBMARK=yes', 'KBMARK=no')
                .replace('KBCERTS=', 'KBCERTS=' + certOk)
                .replace('REVJ=no', 'REVJ=yes').replace('REVA=-1', 'REVA=2');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(150);
    ok($('st-keybox').querySelector('.value').textContent.indexOf('用户导入') !== -1
        && $('st-keybox').querySelector('.value').textContent.indexOf('本机实测') === -1,
        'clean serials: imported light stays quiet (the detail row carries the verdict)');
    ok($('kb-d-status').textContent.indexOf('未在 Google 吊销列表') !== -1
        && $('kb-d-status').textContent.indexOf('2 小时前更新') !== -1,
        'imported-box detail row shows the clean verdict with cache age');

    console.log('== local revocation check: clean serials on an auto-managed box ==');
    shellImpl = function (cmd) {
        if (cmd.indexOf('grep -oE') === 0 && cmd.indexOf('.revocation-status.json') !== -1) return '';
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up')
                .replace('KBCERTS=', 'KBCERTS=' + certOk)
                .replace('REVJ=no', 'REVJ=yes').replace('REVA=-1', 'REVA=0');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(150);
    ok($('st-keybox').querySelector('.value').textContent.indexOf('🟢🟢🟢') !== -1
        && $('st-keybox').querySelector('.value').textContent.indexOf('本机实测') === -1,
        'auto-managed: bare community chips; a clean local check stays silent');

    console.log('== local revocation check: no cache -> degrade silently ==');
    // imported probe: the detail row only renders for user-imported boxes
    shellImpl = function (cmd) {
        if (cmd.indexOf('ui-probe launcher') !== -1) {
            return probeOutput('up').replace('KBMARK=yes', 'KBMARK=no');
        }
        return baseShell(cmd);
    };
    $('refresh').click();
    await sleep(150);
    ok($('st-keybox').querySelector('.value').textContent.indexOf('本机实测') === -1,
        'without the cache the light keeps today\'s wording (no fake verdict)');
    ok($('kb-d-status').textContent.indexOf('本机实测数据暂缺') !== -1,
        'imported-box detail row explains the missing cache and the hourly refresh');

    console.log('== fingerprint import (v3.0.5) ==');
    // Root render unhides the collapsible fingerprint panel (HTML ships it hidden).
    shellImpl = baseShell;
    $('refresh').click();
    await sleep(150);
    ok($('pif-detail').hidden === false, 'root render unhides the fingerprint detail panel');
    ok($('pif-detail-sum').textContent.indexOf('自动指纹') !== -1,
        'detail summary mirrors the probed fingerprint source');

    // R7-1 (2026-09-19): every provenance state must render its own label, the
    // model next to it, and its own hint copy - the breakdown is what tells a
    // user whether they are on a device-specific identity or the shared seed.
    console.log('== fingerprint provenance (R7-1) ==');
    var provCases = [
        ['install-fetch', '本机专属（安装时随机抓取）', 'Pixel 9 Pro', '本机专属身份'],
        ['runtime-fetch', '本机专属（运行时随机抓取）', 'Pixel 8', '本机专属身份'],
        ['seed', '包内种子（保底中）', 'Pixel 7a', '共享保底身份'],
        ['user', '用户导入（自有文件）', 'Pixel 6', '你导入的指纹文件'],
        ['legacy', '已有身份（升级前继承，来源未记录）', 'Pixel 9', '升级前继承的身份']
    ];
    for (var pi = 0; pi < provCases.length; pi++) {
        var pc = provCases[pi];
        probeExtra = 'PIFPROV=' + pc[0] + '\nPIFMODEL=' + pc[2];
        execLog.length = 0;
        $('refresh').click();
        await sleep(150);
        ok($('pif-d-src').textContent.indexOf(pc[1]) !== -1,
            'provenance ' + pc[0] + ': source label rendered');
        ok($('pif-d-src').textContent.indexOf(pc[2]) !== -1,
            'provenance ' + pc[0] + ': model rendered beside the label');
        ok($('pif-d-warn').hidden === false && $('pif-d-warn').textContent.indexOf(pc[3]) !== -1,
            'provenance ' + pc[0] + ': hint visible with the matching copy');
    }
    probeExtra = '';
    execLog.length = 0;
    $('refresh').click();
    await sleep(150);
    ok($('pif-d-warn').hidden === true,
        'no provenance in the probe -> no hint (upgrade path stays quiet)');

    // Happy path: a JSON fingerprint is written as custom.pif.json, the auto
    // marker is cleared (rotation must never touch a user file) and pif-sync
    // runs immediately so no reboot is needed.
    execLog.length = 0;
    $('pif-import-btn').disabled = false;
    byId['pif-import'].files = [{ name: 'pif.json', _content: '{ "BRAND": "google", "FINGERPRINT": "google/canary/canary:16/BP41/user-release-keys" }' }];
    (byId['pif-import']._listeners.change || []).forEach(function (f) { f.call(byId['pif-import']); });
    await sleep(150);
    var importCmd = execLog.filter(function (c) { return c.indexOf('base64 -d') !== -1; })[0] || '';
    ok(importCmd.indexOf('/custom.pif.json') !== -1, 'json import writes custom.pif.json (dialect by extension)');
    ok(importCmd.indexOf('.pif-auto') !== -1 && importCmd.indexOf('rm -f') !== -1,
        'import clears the auto-rotation marker so user files stay user files');
    ok(importCmd.indexOf('fusionctl pif-sync') !== -1, 'import runs pif-sync immediately (no reboot)');
    ok($('pif-import-btn').textContent.indexOf('已导入') !== -1, 'button reports the import outcome');

    // Prop dialect: a .prop file lands at custom.pif.prop instead.
    execLog.length = 0;
    $('pif-import-btn').disabled = false;
    byId['pif-import'].files = [{ name: 'custom.pif.prop', _content: 'BRAND=google\nMODEL=Pixel 9 Pro\n' }];
    (byId['pif-import']._listeners.change || []).forEach(function (f) { f.call(byId['pif-import']); });
    await sleep(150);
    var propCmd = execLog.filter(function (c) { return c.indexOf('base64 -d') !== -1; })[0] || '';
    ok(propCmd.indexOf('base64 -d > ') !== -1 && propCmd.indexOf('/custom.pif.prop') !== -1
        && propCmd.indexOf('/custom.pif.json') !== -1 && propCmd.indexOf('rm -f') !== -1,
        'prop import writes custom.pif.prop and clears the json twin');

    // Mis-pick: content without any identity key never reaches a root write.
    execLog.length = 0;
    $('pif-import-btn').disabled = false;
    byId['pif-import'].files = [{ name: 'note.txt', _content: 'hello world, nothing to see' }];
    (byId['pif-import']._listeners.change || []).forEach(function (f) { f.call(byId['pif-import']); });
    await sleep(150);
    ok(execLog.every(function (c) { return c.indexOf('base64 -d') === -1; }),
        'non-fingerprint content is rejected before any root write');
    ok($('pif-import-btn').textContent.indexOf('指纹字段') !== -1,
        'rejection explains why the file was refused');

    console.log('');
    console.log('== shell hygiene: every command the WebUI execs must PARSE ==');
    // Everything above reads the MOCKED output of exec(), so a typo inside one of
    // these shell one-liners (they are assembled by string concatenation at
    // runtime) is invisible to the whole file - and on-device the symptom is a
    // WebUI that silently shows nothing. Parse each command for real instead.
    var cmds = allExec.filter(function (c) { return c && c.length > 20; });
    var syntaxBad = [];
    cmds.forEach(function (c, i) {
        var r = cp.spawnSync('sh', ['-n'], { input: c, encoding: 'utf8' });
        if (r.status !== 0) {
            syntaxBad.push('#' + i + ' ' + String((r.stderr || '')).trim().split('\n').pop());
        }
    });
    ok(cmds.length > 20 && syntaxBad.length === 0,
        'all ' + cmds.length + ' exec\'d shell commands parse (must be non-empty)'
        + (syntaxBad.length ? ' - first: ' + syntaxBad[0] : ''));
    // The engine-verdict staleness rule (F-6: kbhash anchor, mtime fallback) now
    // lives INSIDE `fusionctl ui-probe` — its implementation is covered by the
    // Rust-side differential (scripts/test-diff-ui-probe.sh + engine-verdict
    // show-branch diff). Here we assert the page is fed by that fused probe.
    var probe = allExec.filter(function (c) { return c.indexOf('ui-probe launcher') !== -1; })[0] || '';
    ok(probe.indexOf('fusionctl ui-probe launcher') !== -1,
        'probe data source is the fused ui-probe (staleness rule diff-covered in Rust)');

    console.log('');
    console.log(passed + ' passed, ' + failed + ' failed');
    process.exit(failed ? 1 : 0);
})().catch(function (e) { console.error('RUNNER ERROR', e); process.exit(2); });
