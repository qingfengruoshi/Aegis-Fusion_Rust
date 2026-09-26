/* Mock-DOM end-to-end smoke tests for the IntegrityFusion apps page (apps.html).
 * Run: node scripts/test-apps.js
 *
 * Covers: list rendering (daemon source + pm fallback), filter chips
 * (全部/系统/已选, v2.2.7), orphan chips (saved-but-uninstalled entries),
 * selected-rows-float-to-top ordering, batch sweeps (全选/反选/清除),
 * check/uncheck -> draft + FAB save (fields preserved), the ⋮ auto-include
 * toggle, search (debounced), the icon pipeline, and the >500-row cap
 * consistency between rendering and sweeping (v2.2.8).
 */
'use strict';

// ---------- tiny DOM mock (same shape as test-webui.js) ----------
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
['menu-btn', 'menu', 'opt-autoadd', 'search', 'list', 'err', 'count', 'src-hint',
 'save-fab', 'cfg-hint', 'icon-hint', 'orphans', 'ops',
 'chip-all', 'chip-system', 'chip-selected', 'ops-all', 'ops-invert', 'ops-clear']
    .forEach(function (id) {
        var e = new El('div'); e.id = id; byId[id] = e;
    });
// mirror the initial HTML state
byId['menu'].hidden = true;
byId['err'].hidden = true;
byId['save-fab'].hidden = true;
byId['cfg-hint'].hidden = true;
byId['orphans'].hidden = true;
byId['ops'].hidden = true;
byId['src-hint'].textContent = ' · 离线列表（仅包名）';

var docListeners = {};
var documentMock = {
    getElementById: function (id) { return byId[id] || null; },
    createElement: function (tag) { return new El(tag); },
    addEventListener: function (ev, fn) { (docListeners[ev] = docListeners[ev] || []).push(fn); }
};

var windowMock = {};
var shellImpl = null;

windowMock.ksu = {
    exec: function (cmd, opts, cbName) {
        execLog.push(cmd);
        if (cbName) {
            setTimeout(function () {
                var out;
                try { out = shellImpl ? shellImpl(cmd) : ''; }
                catch (e) { windowMock[cbName](1, '', String((e && e.message) || 'fail')); return; }
                // shellImpl may return { __exit: N, out: '...' } to simulate a
                // nonzero exit (transport failure: daemon down / died mid-render).
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

require(require('path').join(__dirname, '..', 'module', 'webroot', 'js', 'apps.js'));

function fireDomReady() { (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); }); }
function $(id) { return byId[id]; }

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

var PACKAGES_JSON = JSON.stringify({
    ok: true, firstAppUid: 10000,
    users: [{ id: 0, name: 'Owner', managed: false }, { id: 10, name: 'Work', managed: true }],
    apps: [
        { uid: 10010, userId: 10, packages: ['com.bank.app'], label: '银行 App', system: false, launchable: true, enabled: 1 },
        { uid: 10002, userId: 0, packages: ['com.chat.app'], label: 'Chat', system: false, launchable: true, enabled: 1 },
        { uid: 10003, userId: 0, packages: ['com.android.settings'], label: '设置', system: true, launchable: true, enabled: 1 }
    ]
});

function baseShell(cmd) {
    if (cmd.indexOf('base64 -d >') !== -1) return ''; // writes succeed (captured by callers)
    if (cmd.indexOf('apps-show-system') !== -1) return ''; // default off
    if (cmd.indexOf('apps-auto-add') !== -1) return '';    // default off
    if (cmd.indexOf('/packages') !== -1) return PACKAGES_JSON;
    if (cmd.indexOf('/icon?') !== -1) return ''; // no icon -> avatar fallback
    // v2.2.8: the token is read shell-side ("$(cat ...)") inside helper
    // commands — it never travels as its own exec, so this branch only ever
    // serves legacy stand-alone reads (there are none left; kept for safety).
    if (cmd.indexOf('admin.token') !== -1) return 'tok-abc-123\n';
    if (cmd.indexOf('config.json') !== -1) return CONFIG_RAW;
    if (cmd.indexOf('cmd package list packages') !== -1) {
        if (cmd.indexOf('-3') !== -1) return 'com.a.b\n';
        return 'com.a.b\ncom.hidden.app\n'; // full list: still knows hidden/launchable-less apps
    }
    return '';
}

// Capture base64 writes: returns {path, text} of the last atomic write.
function lastWrite() {
    for (var i = execLog.length - 1; i >= 0; i--) {
        var m = execLog[i].match(/mv -f '[^']*' '([^']*)'/);
        var b = execLog[i].match(/\n([A-Za-z0-9+\/=]+)\nFUSION_EOF_/);
        if (m && b) {
            return {
                path: m[1],
                text: Buffer.from(b[1], 'base64').toString('utf8'),
                cmd: execLog[i]
            };
        }
    }
    return null;
}

var execLog = [];

(async function main() {
    shellImpl = baseShell;
    execLog = [];
    fireDomReady();
    // Paint-first (2026-09-19): the shell must be on screen - with an honest
    // placeholder - before the first root shell-out, because the enumerations
    // take hundreds of ms and a blank page reads as a frozen screen when you
    // tap "受保护应用管理". Asserted synchronously, before any timer fires.
    ok($('list').textContent.indexOf('正在读取应用列表') !== -1,
        'placeholder painted synchronously while the enumeration is in flight');
    ok($('list').textContent.indexOf('无法读取') === -1,
        'no false "无法读取应用列表" error while loading');
    ok(execLog.length === 0,
        'no root shell-out runs before the first paint, got ' + execLog.length);
    await sleep(80); // init chain: settings + config + packages
    ok($('list').textContent.indexOf('正在读取应用列表') === -1,
        'placeholder replaced by the real list once the enumeration lands');

    console.log('== initial render (daemon source, 全部 chip, system hidden) ==');
    ok($('list').children.length === 2, '2 user-app rows rendered (system hidden), got ' + $('list').children.length);
    var texts = [];
    $('list').children.forEach(function (r) { texts.push(r.textContent); });
    ok(texts.join('|').indexOf('银行 App') !== -1, 'labelled row rendered');
    ok(texts.join('|').indexOf('用户 10') !== -1, 'work-profile row carries user badge');
    ok(texts.join('|').indexOf('设置') === -1, 'system app hidden by default');
    var selRows = 0;
    $('list').children.forEach(function (r) { if (r.classList.contains('sel')) selRows++; });
    ok(selRows === 1, 'saved bank app pre-checked (com.bank.app@10), got ' + selRows);
    ok(texts[0].indexOf('银行') !== -1, 'selected row floats to the top (v2.2.7)');
    ok($('count').textContent.indexOf('已选 3') !== -1, 'count shows 3 saved apps');
    ok($('chip-all').classList.contains('on') && $('chip-all').getAttribute('aria-pressed') === 'true',
        'default chip is 全部');
    ok($('ops').hidden === false, 'batch row visible after init');
    ok($('opt-autoadd').getAttribute('aria-checked') === 'false', 'auto-add default off');
    // gms + vending are saved but absent from the device list -> orphans
    ok($('orphans').hidden === false, 'orphan section visible');
    ok($('orphans').textContent.indexOf('已保护但未安装 · 2') !== -1, 'orphan count shown');
    ok($('orphans').textContent.indexOf('com.google.android.gms') !== -1
        && $('orphans').textContent.indexOf('com.android.vending') !== -1,
        'both orphan chips rendered');

    console.log('== check/uncheck -> draft only, FAB save ==');
    // v2.2.1: ticking is draft-only; nothing is written until the FAB is used.
    ok($('save-fab').hidden === true, 'FAB hidden while draft matches saved scope');
    var chatRow = null;
    $('list').children.forEach(function (r) { if (r.textContent.indexOf('Chat') !== -1) chatRow = r; });
    chatRow.click();
    await sleep(30);
    ok(lastWrite() === null, 'ticking writes NOTHING (draft-only)');
    ok($('save-fab').hidden === false, 'FAB appears when the draft differs');
    ok($('count').textContent.indexOf('已选 4') !== -1
        && $('count').textContent.indexOf('未保存') !== -1, 'count marks unsaved changes');
    // explicit save
    $('save-fab').click();
    await sleep(80); // debounced save chain
    var w = lastWrite();
    ok(!!w && w.path === '/data/adb/teesim/config.json', 'FAB click wrote config.json atomically');
    var savedCfg = JSON.parse(w.text);
    ok(savedCfg.version === 1 && savedCfg.profiles.default.patchLevel.system === 'today'
        && savedCfg.profiles.default.keybox === 'keybox.xml', 'other config fields preserved');
    var apps = savedCfg.profiles.default.apps;
    ok(apps.length === 4 && apps.indexOf('com.chat.app') !== -1 && apps.indexOf('com.bank.app@10') !== -1
        && apps.indexOf('com.google.android.gms') !== -1,
        'apps array = prior picks + chat: ' + JSON.stringify(apps));
    ok($('count').textContent.indexOf('已选 4') !== -1
        && $('count').textContent.indexOf('未保存') === -1, 'count clean after save');
    ok($('save-fab').hidden === true, 'FAB hides again after saving');
    ok($('err').hidden === true, 'no error surfaced on success');

    // untick it again: draft, save
    chatRow.click();
    await sleep(30);
    ok($('save-fab').hidden === false, 'FAB reappears for the removal');
    $('save-fab').click();
    await sleep(80);
    var w2 = JSON.parse(lastWrite().text);
    ok(w2.profiles.default.apps.length === 3 && w2.profiles.default.apps.indexOf('com.chat.app') === -1,
        'saving after unticking removes the app');

    console.log('== filter chips (v2.2.7) ==');
    // "系统" chip: user + system apps; persists the legacy show-system flag
    // (same file, same meaning — no new state source).
    $('chip-system').click();
    await sleep(60);
    ok($('chip-system').classList.contains('on') && $('chip-all').classList.contains('on') === false,
        '系统 chip activates and 全部 deactivates');
    w = lastWrite();
    ok(!!w && w.path === '/data/adb/teesim/apps-show-system' && w.text.trim() === '1',
        '系统 chip persists the show-system flag as 1');
    ok($('list').children.length === 3, 'system app now visible in the list');
    // (Order within the unselected group is locale-dependent — Latin vs CJK
    // collation differs between ICU builds — so find the row, don't assume
    // its position.)
    var sysRow = null;
    $('list').children.forEach(function (r) {
        if (r.textContent.indexOf('com.android.settings') !== -1) sysRow = r;
    });
    ok(!!sysRow && sysRow.textContent.indexOf('系统') !== -1,
        'system row carries the 系统 badge');
    // back to 全部: flag 0, system hidden again
    $('chip-all').click();
    await sleep(60);
    w = lastWrite();
    ok(!!w && w.path === '/data/adb/teesim/apps-show-system' && w.text.trim() === '0',
        '全部 chip persists the show-system flag back as 0');
    ok($('list').children.length === 2, 'system app hidden again');
    // "已选" chip: session-only — no flag write, only draft-backed rows show
    var writes0 = execLog.filter(function (c) { return /mv -f '/.test(c); }).length;
    $('chip-selected').click();
    await sleep(60);
    var writes1 = execLog.filter(function (c) { return /mv -f '/.test(c); }).length;
    ok(writes1 === writes0, '已选 chip writes NOTHING (session-only)');
    ok($('chip-selected').classList.contains('on'), '已选 chip activates');
    ok($('list').children.length === 1
        && $('list').children[0].textContent.indexOf('银行') !== -1,
        '已选 chip lists only the checked device rows (orphans stay in the chip area)');
    $('chip-all').click();
    await sleep(30);
    ok($('list').children.length === 2, 'back to 全部');
    // v2.2.8: re-clicking the ACTIVE chip must not re-render or rewrite the
    // show-system flag — the guard short-circuits no-op chip clicks.
    var wrBefore = execLog.filter(function (c) { return /mv -f '/.test(c); }).length;
    $('chip-all').click();
    await sleep(30);
    ok(execLog.filter(function (c) { return /mv -f '/.test(c); }).length === wrBefore,
        're-clicking the active chip writes NOTHING (no-op guard)');
    ok($('list').children.length === 2, 're-clicking the active chip leaves the list alone');

    console.log('== ⋮ menu: auto-include (native config field) ==');
    $('menu-btn').click();
    ok($('menu').hidden === false, '⋮ opens the menu');
    // flip auto-include: now TEES-native, written into config.json on the
    // active profile — no flag file involved any more (v2.2.5).
    $('opt-autoadd').click();
    await sleep(60);
    w = lastWrite();
    ok(!!w && w.path === '/data/adb/teesim/config.json', 'auto-include toggle writes config.json');
    var autoCfg = JSON.parse(w.text);
    ok(autoCfg.profiles.default.autoIncludeNewApps === true, 'autoIncludeNewApps=true persisted on the profile');
    ok(autoCfg.profiles.default.apps.length === 3, 'toggle does not touch the apps array');
    // flip it back off
    $('opt-autoadd').click();
    await sleep(60);
    w = lastWrite();
    ok(!!w && JSON.parse(w.text).profiles.default.autoIncludeNewApps === false,
        'autoIncludeNewApps=false persisted after the second click');

    console.log('== search (debounced 140ms, like the TEES scope page) ==');
    var sfn = $('search')._listeners.input[0];
    $('search').value = 'chat';
    sfn.call($('search'));
    var immediate = [];
    $('list').children.forEach(function (r) { immediate.push(r.textContent); });
    ok(immediate.join('|').indexOf('银行') !== -1, 'no re-render before the debounce fires');
    await sleep(220);
    var searchTxts = [];
    $('list').children.forEach(function (r) { searchTxts.push(r.textContent); });
    ok(searchTxts.join('|').indexOf('Chat') !== -1 && searchTxts.join('|').indexOf('银行') === -1,
        'debounced search narrows to matching app');
    $('search').value = '';
    sfn.call($('search'));
    await sleep(220);

    console.log('== batch sweeps (visible set only, draft + FAB) ==');
    // v2.2.7: 全选/反选/清除 sweep exactly the rows currently displayed.
    // With system apps off the 全部 chip they can never be swept into the
    // selection. All three edit the draft only; the FAB still gates saving.
    function writeCount() {
        var n = 0;
        execLog.forEach(function (c) { if (/mv -f '/.test(c)) n++; });
        return n;
    }
    ok($('list').children.length === 2, 'precondition: 2 user rows visible');
    var wcBefore = writeCount();
    $('ops-all').click();
    await sleep(30);
    ok(writeCount() === wcBefore, 'select-all writes NOTHING (draft-only)');
    ok($('count').textContent.indexOf('已选 4') !== -1,
        'select-all added only the visible user apps (3 saved + chat), got: ' + $('count').textContent);
    ok($('save-fab').hidden === false, 'FAB armed after select-all');
    // invert flips every visible row: bank + chat go from selected to not
    $('ops-invert').click();
    await sleep(30);
    ok($('count').textContent.indexOf('已选 2') !== -1,
        'invert leaves only the off-screen saved orphans (gms/vending), got: ' + $('count').textContent);
    ok($('save-fab').hidden === false, 'draft differs from saved scope -> FAB stays');
    // restore: select-all again
    $('ops-all').click();
    await sleep(30);
    ok($('count').textContent.indexOf('已选 4') !== -1, 'select-all restores 4');
    // a narrowed search shrinks the sweep scope: 清除 then touches matches only
    $('search').value = 'chat';
    sfn.call($('search'));
    await sleep(220);
    $('ops-clear').click();
    await sleep(30);
    ok($('count').textContent.indexOf('已选 3') !== -1, '清除 under search drops only the matching app');
    $('search').value = '';
    sfn.call($('search'));
    await sleep(220);

    // v2.2.8: "已选" + a no-match search term must say "no match" — the draft
    // is not empty here (gms/vending/bank), so the old catch-all message
    // ("还没有勾选任何应用") was misleading.
    $('chip-selected').click();
    await sleep(30);
    $('search').value = 'zzz-no-match';
    sfn.call($('search'));
    await sleep(220);
    ok($('list').textContent.indexOf('没有匹配的已选应用') !== -1,
        '"已选"+no-match search says 没有匹配 (draft is not empty), got: "' + $('list').textContent + '"');
    $('search').value = '';
    sfn.call($('search'));
    await sleep(220);
    $('chip-all').click();
    await sleep(30);

    console.log('== orphan chips: remove a saved-but-uninstalled entry ==');
    // gms + vending remain saved but are not on the device. The ✕ edits the
    // draft only; the FAB still gates the actual write.
    function orphanX(entry) {
        var found = null;
        $('orphans').children.forEach(function (c) {
            if (c.textContent.indexOf(entry) === -1) return;
            c.children.forEach(function (x) { if (x.textContent === '✕') found = x; });
        });
        return found;
    }
    var gx = orphanX('com.google.android.gms');
    ok(!!gx, 'gms orphan chip has a ✕ button');
    gx.click();
    await sleep(30);
    ok($('count').textContent.indexOf('已选 2') !== -1,
        'removing the gms orphan leaves 2 (vending/bank), got: ' + $('count').textContent);
    ok($('orphans').textContent.indexOf('com.google.android.gms') === -1
        && $('orphans').textContent.indexOf('com.android.vending') !== -1,
        'gms chip gone, vending chip remains');
    ok($('save-fab').hidden === false, 'FAB armed by the orphan removal');
    $('save-fab').click();
    await sleep(80);
    var w3 = JSON.parse(lastWrite().text);
    ok(w3.profiles.default.apps.indexOf('com.google.android.gms') === -1
        && w3.profiles.default.apps.indexOf('com.android.vending') !== -1,
        'saving persists the orphan removal: ' + JSON.stringify(w3.profiles.default.apps));

    console.log('== icon pipeline (lazy + cached + negative-cached) ==');
    var iconFetches = {};
    var PACKAGES_WITH_ICON = JSON.stringify({
        ok: true, firstAppUid: 10000,
        users: [{ id: 0, name: 'Owner', managed: false }],
        apps: [
            { uid: 10011, userId: 0, packages: ['com.fresh.app'], label: 'Fresh', system: false, launchable: true, enabled: 1 },
            { uid: 10012, userId: 0, packages: ['com.bare.app'], label: 'Bare', system: false, launchable: true, enabled: 1 }
        ]
    });
    shellImpl = function (cmd) {
        if (cmd.indexOf('/icon?') !== -1) {
            iconFetches[cmd] = (iconFetches[cmd] || 0) + 1;
            if (cmd.indexOf('com.fresh.app') !== -1) return 'aWNvbg==';
            return ''; // daemon has no icon for this one
        }
        if (cmd.indexOf('/packages') !== -1) return PACKAGES_WITH_ICON;
        return baseShell(cmd);
    };
    function totalIconFetches() {
        var s = 0;
        Object.keys(iconFetches).forEach(function (k) { s += iconFetches[k]; });
        return s;
    }
    // fresh init: only two rows, icons drip in through the rate-limited pump
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(120);
    var imgs = 0;
    $('list').children.forEach(function (r) {
        r.children.forEach(function (c) { if (String(c.tagName).toUpperCase() === 'IMG') imgs++; });
    });
    ok($('list').children.length === 2, 'fresh init lists both apps');
    ok(imgs === 1, 'exactly the app with a rendered icon got an <img> swap, got ' + imgs);
    ok(totalIconFetches() === 2, 'one exec per distinct app (no floods), got ' + totalIconFetches());
    // re-render: cache serves both (positive + negative), zero new execs
    $('search').value = 'fresh';
    sfn.call($('search'));
    await sleep(220);
    $('search').value = '';
    sfn.call($('search'));
    await sleep(220);
    ok(totalIconFetches() === 2, 're-render serves icons from cache without re-fetching, got ' + totalIconFetches());

    console.log('== icon circuit breaker: an icon that kills the daemon gets dropped ==');
    // A render that SIGABRTs the daemon is deterministic (v2.2.2 on-device crash
    // loop): one retry is allowed, then the icon is negative-cached so the WebUI
    // stops hammering the daemon with it.
    var PACKAGES_BREAKER = JSON.stringify({
        ok: true, firstAppUid: 10000,
        users: [{ id: 0, name: 'Owner', managed: false }],
        apps: [
            { uid: 10021, userId: 0, packages: ['com.ok.app'], label: 'Ok', system: false, launchable: true, enabled: 1 },
            { uid: 10022, userId: 0, packages: ['com.bad.app'], label: 'Bad', system: false, launchable: true, enabled: 1 }
        ]
    });
    var breakerFetches = {};
    shellImpl = function (cmd) {
        if (cmd.indexOf('/icon?') !== -1) {
            breakerFetches[cmd] = (breakerFetches[cmd] || 0) + 1;
            if (cmd.indexOf('com.bad.app') !== -1) return { __exit: 1, out: '' }; // daemon died mid-render
            return 'aWNvbg==';
        }
        if (cmd.indexOf('/packages') !== -1) return PACKAGES_BREAKER;
        return baseShell(cmd);
    };
    function badFetches() {
        var s = 0;
        Object.keys(breakerFetches).forEach(function (k) {
            if (k.indexOf('com.bad.app') !== -1) s += breakerFetches[k];
        });
        return s;
    }
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(120);
    ok(badFetches() === 1, 'first render asked the bad icon once, got ' + badFetches());
    $('search').value = 'x';
    sfn.call($('search'));
    await sleep(220);
    $('search').value = '';
    sfn.call($('search'));
    await sleep(220);
    ok(badFetches() === 2, 'second render retried the bad icon once more, got ' + badFetches());
    $('search').value = 'x';
    sfn.call($('search'));
    await sleep(220);
    $('search').value = '';
    sfn.call($('search'));
    await sleep(220);
    ok(badFetches() === 2, 'third render stopped asking: breaker negative-cached the bad icon, got ' + badFetches());

    console.log('== invalid config entries are ignored, purged on save ==');
    // Simulates the v2.2.0 pollution: shell error tokens inside config.json apps[].
    var DIRTY_CONFIG = JSON.stringify({
        version: 1,
        profiles: {
            default: {
                keybox: 'keybox.xml',
                apps: ['com.google.android.gms', 'cmd:', 'Failure', 'com.ok.app@10', '(32)']
            }
        }
    }, null, 2);
    shellImpl = function (cmd) {
        if (cmd.indexOf('config.json') !== -1) return DIRTY_CONFIG;
        return baseShell(cmd);
    };
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(80);
    ok($('count').textContent.indexOf('已选 2') !== -1,
        'only valid entries counted (2), got "' + $('count').textContent + '"');
    ok($('cfg-hint').hidden === false && $('cfg-hint').textContent.indexOf('3 个无效条目') !== -1,
        'notice lists the ignored invalid entries');
    ok($('save-fab').hidden === true, 'purge alone does not arm the FAB (no draft change)');
    var chatRow2 = null;
    $('list').children.forEach(function (r) { if (r.textContent.indexOf('Chat') !== -1) chatRow2 = r; });
    chatRow2.click();
    $('save-fab').click();
    await sleep(80);
    var cleaned = JSON.parse(lastWrite().text).profiles.default.apps;
    ok(cleaned.length === 3 && cleaned.indexOf('cmd:') === -1 && cleaned.indexOf('(32)') === -1
        && cleaned.indexOf('com.ok.app@10') !== -1 && cleaned.indexOf('com.chat.app') !== -1,
        'a save purges invalid entries while keeping valid ones: ' + JSON.stringify(cleaned));
    ok($('cfg-hint').hidden === true, 'notice cleared after the cleaning save');

    console.log('== pm fallback ==');
    shellImpl = function (cmd) {
        if (cmd.indexOf('/packages') !== -1) return 'not-json'; // daemon garbage -> fallback
        if (cmd.indexOf('cmd package list packages') !== -1) {
            // What cut -f2 emits when `pm` prints its error banner among the list.
            // What the full pipe (pm | cut -d: -f2 | sort -u) emits when `pm`
            // prints its error banner among the list: bare names + error text.
            return 'com.a.b\n Failure calling service package\ncom.c.d\n';
        }
        return baseShell(cmd);
    };
    // reload the page state via a fresh DOMContentLoaded is not possible in one
    // process; the fallback path is exercised by the launcher test for icons and
    // here by re-firing init listeners directly.
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(80);
    var fbTexts = [];
    $('list').children.forEach(function (r) { fbTexts.push(r.textContent); });
    ok(fbTexts.join('|').indexOf('com.a.b') !== -1, 'pm fallback lists bare package names');
    ok(fbTexts.join('|').indexOf('Failure') === -1, 'pm fallback drops shell error text (validation)');
    ok($('src-hint').hidden === false && $('src-hint').textContent.indexOf('离线') !== -1,
        'offline hint shown in pm fallback');
    // The pm list only knows user-0 bare names: "@user" entries are
    // unverifiable there and must NOT be flagged (false orphan), while bare
    // entries absent from the list still are.
    ok($('orphans').textContent.indexOf('com.ok.app@10') === -1
        && $('orphans').textContent.indexOf('com.google.android.gms') !== -1,
        'pm fallback: @user entries unverifiable (not flagged), bare orphans still flagged');

    console.log('== full-pm cross-check: daemon-missing but installed apps are NOT orphans (v2.2.8 小米换机 case) ==');
    // The daemon's /packages enumeration has a narrower view (misses
    // non-launchable / hidden apps — the field-reported 小米换机 false orphan).
    // A saved entry missing from the DAEMON list must not be called 已卸载
    // while the full pm list still knows it — same "full list is the truth"
    // principle apps-sync.sh prunes by.
    var HIDDEN_CONFIG = JSON.stringify({
        version: 1,
        profiles: { default: { keybox: 'keybox.xml', apps: ['com.hidden.app', 'com.google.android.gms'] } }
    }, null, 2);
    shellImpl = function (cmd) {
        if (cmd.indexOf('cmd package list packages') !== -1) {
            if (cmd.indexOf('-3') !== -1) return 'com.a.b\n';
            return 'com.a.b\ncom.hidden.app\n'; // full list still knows the app
        }
        if (cmd.indexOf('config.json') !== -1) return HIDDEN_CONFIG;
        return baseShell(cmd);
    };
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(120);
    ok($('orphans').textContent.indexOf('com.hidden.app') === -1,
        'daemon-missing but pm-installed app is NOT flagged 已卸载');
    ok($('orphans').textContent.indexOf('com.google.android.gms') !== -1,
        'truly absent app is still flagged');
    ok($('count').textContent.indexOf('已选 2') !== -1,
        'both entries still count as selected, got: ' + $('count').textContent);

    console.log('== unreadable config surfaces an error ==');
    shellImpl = function (cmd) {
        if (cmd.indexOf('config.json') !== -1) return '';
        return baseShell(cmd);
    };
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(80);
    ok($('err').hidden === false && $('err').textContent.indexOf('config.json') !== -1,
        'missing config.json shows an explanatory error');

    console.log('== auto-include guard: another profile already claims it ==');
    // Upstream allows autoIncludeNewApps on at most ONE profile (the daemon
    // refuses to load a config where two set it). Toggling on when some other
    // profile claims it must be refused with a visible error and zero writes.
    // Kept last: it swaps CONFIG_RAW, which must not leak into other sections.
    shellImpl = baseShell;
    CONFIG_RAW = JSON.stringify({
        version: 1,
        profiles: {
            default: {
                keybox: 'keybox.xml', mode: 'patch',
                patchLevel: { system: 'today', vendor: 'YYYY-MM-05', boot: 'YYYY-MM-05' },
                apps: ['com.google.android.gms']
            },
            work: { keybox: 'keybox.xml', mode: 'patch', apps: [], autoIncludeNewApps: true }
        }
    }, null, 2);
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(120);
    var writesBefore = execLog.filter(function (c) { return c.indexOf('base64 -d') !== -1; }).length;
    $('opt-autoadd').click();
    await sleep(60);
    ok($('err').hidden === false && $('err').textContent.indexOf('仅允许一个') !== -1,
        'toggling on while another profile claims auto-include is refused with an error');
    var writesAfter = execLog.filter(function (c) { return c.indexOf('base64 -d') !== -1; }).length;
    ok(writesAfter === writesBefore, 'the refusal wrote nothing');
    ok($('opt-autoadd').getAttribute('aria-checked') === 'false', 'toggle stays off after the refusal');

    console.log('== >500 visible rows: swept set == rendered set (v2.2.8 cap fix) ==');
    // renderList sorts THEN cuts at RENDER_CAP; the batch sweeps used to cut
    // the UNSORTED list at 500 — with >500 visible rows the two sets diverged.
    // 'Aaa App' sits at insertion index 599 but sorts first, so it renders in
    // the top 500; 全选 must sweep it (plus exactly the other 499 rendered).
    var MANY_PKGS = (function () {
        var apps = [];
        for (var i = 0; i < 600; i++) {
            apps.push({
                uid: 20000 + i, userId: 0, packages: ['com.many.app' + i],
                label: i === 599 ? 'Aaa App' : 'App ' + i,
                system: false, launchable: true, enabled: 1
            });
        }
        return JSON.stringify({ ok: true, firstAppUid: 10000, users: [{ id: 0, name: 'Owner', managed: false }], apps: apps });
    })();
    var MANY_CONFIG = JSON.stringify({ version: 1, profiles: { default: { keybox: 'keybox.xml', apps: [] } } }, null, 2);
    shellImpl = function (cmd) {
        if (cmd.indexOf('/packages') !== -1) return MANY_PKGS;
        if (cmd.indexOf('config.json') !== -1) return MANY_CONFIG;
        return baseShell(cmd);
    };
    (docListeners.DOMContentLoaded || []).forEach(function (f) { f(); });
    await sleep(150);
    ok($('list').children.length === 500, 'render capped at 500 rows, got ' + $('list').children.length);
    ok($('list').children[0].textContent.indexOf('Aaa App') !== -1,
        'the globally-first-sorted app renders inside the cap');
    $('ops-all').click();
    await sleep(30);
    ok($('list').children[0].classList.contains('sel'),
        'select-all swept the rendered-first row (sorted cap, not unsorted cap)');
    ok($('count').textContent.indexOf('已选 500') !== -1,
        'sweep covered exactly the 500 rendered rows, got: ' + $('count').textContent);

    console.log('');
    console.log(passed + ' passed, ' + failed + ' failed');
    process.exit(failed ? 1 : 0);
})().catch(function (e) { console.error('RUNNER ERROR', e); process.exit(2); });
