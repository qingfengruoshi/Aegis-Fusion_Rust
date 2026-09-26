/* Aegis Fusion — protected-apps page (apps.html).
 *
 * One job: show every app on the device with a checkbox; checked means the app
 * is written to /data/adb/teesim/config.json -> profiles.<active>.apps, which
 * the TEE daemon resolves live (no reboot). Filter chips (全部/系统/已选,
 * modeled on the TEESimulator scope page) narrow the list with selected rows
 * floating to the top; orphan chips surface saved-but-uninstalled entries for
 * one-tap removal; the batch row sweeps the visible set (全选/反选/清除).
 * The ⋮ menu holds auto-include newly installed apps — that one drives TEES'
 * native per-profile "autoIncludeNewApps" field in config.json (the daemon
 * folds post-baseline installs into the scope at resolve time; apps-sync.sh
 * only migrated the legacy flag over).
 *
 * Self-contained by design: duplicates the proven exec bridge from launcher.js
 * so the two pages never couple through shared JS.
 */
(function () {
    'use strict';

    // 常量唯一来源：js/conf.js。浏览器走 window.AEGIS；Node（scripts/test-apps.js
    // 会 require 本文件）没有 window，退回 require('./conf.js')。
    // 缺失即抛错，不静默回落。本页只用到 TEE_DIR（及其派生量），故不声明 MODPATH / PROC。
    var C = (typeof window !== 'undefined' && window.AEGIS) || null;
    if (!C && typeof require === 'function') { try { C = require('./conf.js'); } catch (e) { C = null; } }
    if (!C) throw new Error('aegis: js/conf.js 未加载（缺常量来源）');
    var TEE_DIR = C.TEE_DIR;
    var CONFIG = TEE_DIR + '/config.json';
    var HELPER = TEE_DIR + '/teesim-uds';
    var SOCK = TEE_DIR + '/admin.sock';
    var TOKEN_FILE = TEE_DIR + '/admin.token';
    var OPT_SYSTEM = TEE_DIR + '/apps-show-system';
    var LEGACY_AUTOADD = TEE_DIR + '/apps-auto-add'; // pre-migration flag; apps-sync deletes it
    var PM_LIST = 'cmd package list packages -3 2>/dev/null | cut -d: -f2 | sort -u';
    var FULL_PM_LIST = 'cmd package list packages 2>/dev/null | cut -d: -f2 | sort -u';

    // ---------- KernelSU WebUI exec bridge (identical to launcher.js) ----------
    function exec(cmd) {
        var ksu = window.ksu;
        if (!ksu || typeof ksu.exec !== 'function') {
            return Promise.reject(new Error('no-ksu-api'));
        }
        return new Promise(function (resolve, reject) {
            var settled = false;
            var name = '__fusion_apps_' + Date.now() + '_' + Math.floor(Math.random() * 1e5);
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
    function writeFileAtomic(path, text) {
        var b64 = btoa(unescape(encodeURIComponent(text)));
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

    // ---------- TEE daemon transport (KeyAdmin over the root-only unix socket) ----------
    // The admin token never crosses the exec bridge or JS memory: it is read
    // shell-side at execution time ("$(cat ...)"), so it appears only in the
    // argv of the short-lived root helper process — never in the WebView, the
    // bridge command lines, or any log. (The final argv hop is inherent to the
    // upstream helper's CLI; the 0700 socket dir makes the token useless to
    // anything that cannot already reach it.)
    function daemonRequest(method, path) {
        return exec(q(HELPER) + ' ' + q(SOCK) + ' ' + method + ' ' + q(path) +
                ' "$(cat ' + q(TOKEN_FILE) + ')"').then(function (out) {
            var data = null;
            try { data = JSON.parse(out); } catch (_) { /* leave null */ }
            if (data && data.ok === false) {
                return { ok: false, err: new Error(data.error || data.message || 'daemon error') };
            }
            return { ok: true, data: data };
        }, function (e) {
            return { ok: false, err: e };
        });
    }
    // ---------- icon pipeline (lazy, cached, rate-limited) ----------
    // Why not fetch icons eagerly? Each icon is one round-trip through the root
    // exec bridge; a several-hundred-row list firing all of them at once floods
    // the bridge and freezes the WebView (exactly the v2.1.0 on-device hang,
    // which is also why most icons never showed up: the late requests timed
    // out). So icons are: cached in memory for the page session, fetched with
    // at most MAX_INFLIGHT concurrent execs, and only for rows near the
    // viewport (IntersectionObserver; on ancient WebViews the first rows are
    // dripped in instead and the rest keep letter avatars).
    var ICON_MAX_INFLIGHT = 3;
    var ICON_FALLBACK_EAGER = 24;
    // Transport failures tolerated per icon before it is negative-cached for the
    // session. A render that kills the daemon is deterministic: after the daemon
    // respawns, re-asking the same icon kills it again (v2.2.2 on-device crash
    // loop). One retry covers a genuine hiccup; two strikes mean "this icon
    // aborts the daemon" — keep the letter avatar and leave the daemon alone.
    var ICON_MAX_RETRIES = 2;
    var iconCache = {};      // key -> dataURL | '' (daemon confirmed: no icon)
    var iconWaiters = {};    // key -> [avatar elements awaiting the fetch]
    var iconFetching = {};   // key -> true while a fetch is in flight
    var iconRetries = {};    // key -> transport failures so far
    var iconInflight = 0;
    var iconPending = [];    // [{ key, el }]
    var iconObserver = null; // created at boot when available

    function iconKey(pkg, userId) { return pkg + '@' + (userId || 0); }

    function swapIcon(av, url) {
        if (!av || !av.parentNode) return;
        var img = document.createElement('img');
        img.className = av.className;
        img.alt = '';
        img.src = url;
        av.parentNode.replaceChild(img, av);
    }

    function updateIconHint() {
        var h = $('icon-hint');
        if (!h) return;
        if (state.iconFails > 0) {
            h.hidden = false;
            h.textContent = ' · ' + state.iconFails + ' 个图标未能加载（重新搜索或滚动可重试）';
        } else {
            h.hidden = true;
        }
    }

    function fetchIcon(key) {
        // key = "<pkg>@<userId>"; package names cannot contain '@'.
        var at = key.lastIndexOf('@');
        var pkg = key.slice(0, at), user = key.slice(at + 1);
        var p = '/icon?pkg=' + encodeURIComponent(pkg) + '&user=' + encodeURIComponent(user);
        return exec(
            q(HELPER) + ' ' + q(SOCK) + ' GET ' + q(p) +
            ' "$(cat ' + q(TOKEN_FILE) + ')" --b64'
        ).then(function (out) {
            // Exit 0 + empty body = the daemon answered "no icon" (404):
            // cache that negatively so we never re-ask. Exit != 0 (transport
            // hiccup, daemon busy) rejects and stays retryable.
            out = String(out || '').trim();
            return out ? 'data:image/png;base64,' + out : '';
        }, function () {
            state.iconFails++;
            updateIconHint();
            throw new Error('icon transport');
        });
    }

    function pumpIcons() {
        while (iconInflight < ICON_MAX_INFLIGHT && iconPending.length) {
            var job = iconPending.shift();
            if (!job.el || !job.el.parentNode) continue; // row re-rendered away
            if (iconCache[job.key] != null) {
                if (iconCache[job.key]) swapIcon(job.el, iconCache[job.key]);
                continue; // '' = known missing
            }
            if (iconFetching[job.key]) continue;
            iconFetching[job.key] = true;
            iconInflight++;
            (iconWaiters[job.key] = iconWaiters[job.key] || []).push(job.el);
            (function (k) {
                fetchIcon(k).then(function (out) {
                    iconCache[k] = out;
                    (iconWaiters[k] || []).forEach(function (av) {
                        if (out) swapIcon(av, out);
                    });
                }, function () {
                    // Transport failure (fetchIcon already bumped the global
                    // counter + hint). Keep retrying on later renders — unless
                    // this icon already failed repeatedly, in which case it is
                    // very likely the icon itself aborts the daemon:
                    // negative-cache it so the next render cannot take the
                    // daemon down again.
                    iconRetries[k] = (iconRetries[k] || 0) + 1;
                    if (iconRetries[k] >= ICON_MAX_RETRIES) iconCache[k] = '';
                })
                    .then(function () {
                        delete iconWaiters[k];
                        iconFetching[k] = false;
                        iconInflight--;
                        pumpIcons();
                    });
            })(job.key);
        }
    }

    // Wire one freshly rendered avatar to the pipeline.
    function setupIcon(av, pkg, userId, eagerIndex) {
        var key = iconKey(pkg, userId);
        if (iconCache[key]) { swapIcon(av, iconCache[key]); return; }
        if (iconCache[key] === '') return;
        if (iconObserver) {
            av._iconKey = key;
            iconObserver.observe(av);
        } else if (eagerIndex < ICON_FALLBACK_EAGER) {
            iconPending.push({ key: key, el: av });
        }
    }

    function listPackages() {
        // The full pm list travels along: the daemon's enumeration has a
        // narrower view (e.g. it misses non-launchable / hidden apps — the
        // 小米换机 false-orphan report), so "已卸载" must never be claimed on
        // the daemon list alone when the full pm list still knows the package.
        return Promise.all([
            daemonRequest('GET', '/packages').then(function (r) {
                if (r.ok && r.data && r.data.ok !== false && Array.isArray(r.data.apps)) {
                    var apps = r.data.apps.map(function (a) {
                        var pkg = (a.packages && a.packages[0]) || '';
                        // Audit L7 (2026-09-16): the daemon branch used to skip
                        // the strict package regex the pm branch applies. Both
                        // sources now get the same gate — a malformed daemon
                        // entry is dropped instead of reaching the UI / scope.
                        if (!VALID_PKG_RE.test(pkg)) return null;
                        return {
                            pkg: pkg,
                            userId: a.userId || 0,
                            label: a.label || pkg,
                            system: !!a.system
                        };
                    }).filter(Boolean);
                    if (apps.length) return { apps: apps, source: 'daemon' };
                }
                return exec(PM_LIST).then(function (out) {
                    var apps = String(out || '').split('\n').map(function (s) { return s.trim(); })
                        .filter(Boolean)
                        .filter(function (pkg) { return VALID_PKG_RE.test(pkg); }) // drop error text
                        .map(function (pkg) {
                            return { pkg: pkg, userId: 0, label: pkg, system: false };
                        });
                    return { apps: apps, source: 'pm' };
                }, function () { return { apps: [], source: 'none' }; });
            }, function () { return { apps: [], source: 'none' }; }),
            exec(FULL_PM_LIST).then(function (out) {
                var set = {};
                String(out || '').split('\n').forEach(function (s) {
                    s = s.trim();
                    if (VALID_PKG_RE.test(s)) set[s] = true;
                });
                return set;
            }, function () { return {}; })
        ]).then(function (r) {
            r[0].full = r[1];
            return r[0];
        });
    }

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
    function pickProfile(cfg) {
        if (cfg.profiles.default) return 'default';
        return Object.keys(cfg.profiles)[0] || null;
    }
    function makeEntry(pkg, user) {
        return user && user !== 0 ? pkg + '@' + user : pkg;
    }
    // A real package name: dotted (every Android package has at least one dot),
    // alphanumeric plus . _ — optionally "@<userId>" for work-profile entries.
    // Anything else (shell error tokens like "cmd:" or "(32)", stray words) must
    // never reach config.json — that is exactly how the v2.2.0 pollution happened.
    var VALID_PKG_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$/;
    var VALID_ENTRY_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+(?:@\d+)?$/;
    function validEntry(e) { return VALID_ENTRY_RE.test(String(e || '')); }

    // ---------- tiny DOM helpers ----------
    function $(id) { return document.getElementById(id); }
    function el(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    }
    function avatarLetter(pkg) {
        var c = String(pkg || '?').replace(/[^A-Za-z0-9]/g, '');
        return (c.charAt(0) || '?').toUpperCase();
    }
    function hashColor(str) {
        var h = 0, s = String(str || '');
        for (var i = 0; i < s.length; i++) h = ((h * 31) + s.charCodeAt(i)) >>> 0;
        return 'hsl(' + (h % 360) + ' 52% 42%)';
    }

    // ---------- session state ----------
    // Draft/save model (v2.2.1, per user request): ticks only change the draft;
    // nothing is written until the floating save button is pressed, and it only
    // appears while the draft differs from the saved scope.
    var state = {
        apps: [],
        source: 'none',
        fullPkgs: {},        // full pm list (bare names) — the "已卸载" cross-check
        saved: {},           // entry -> true (what config.json holds, validated)
        draft: {},           // entry -> true (working copy, what ticks change)
        config: null,
        profileName: null,
        filter: 'all',       // 'all' (user apps) | 'system' (user + system) | 'selected'
        autoAdd: false,
        saving: false,
        iconFails: 0,
        loading: true       // first enumeration still in flight (drives the placeholder)
    };
    function draftDirty() {
        var a = Object.keys(state.saved).sort().join('\n');
        var b = Object.keys(state.draft).sort().join('\n');
        return a !== b;
    }

    // ---------- settings (⋮ menu) + filter chips ----------
    function applyMenu() {
        var a = $('opt-autoadd');
        if (a) a.setAttribute('aria-checked', state.autoAdd ? 'true' : 'false');
        applyChips();
        renderList();
    }
    function applyChips() {
        [['chip-all', 'all'], ['chip-system', 'system'], ['chip-selected', 'selected']]
            .forEach(function (p) {
                var b = $(p[0]);
                if (!b) return;
                var on = state.filter === p[1];
                b.classList.toggle('on', on);
                b.setAttribute('aria-pressed', on ? 'true' : 'false');
            });
    }
    function loadSettings() {
        return Promise.all([readFile(OPT_SYSTEM), readFile(LEGACY_AUTOADD)]).then(function (r) {
            // The legacy show-system flag seeds the default filter chip so a
            // user who preferred system apps keeps seeing them; the chips
            // themselves are session-only except that "系统" persists to the
            // same flag (same file, same meaning — no new state source).
            state.filter = String(r[0] || '').trim() === '1' ? 'system' : 'all';
            state._legacyAutoAdd = String(r[1] || '').trim() === '1';
            // Highlight the loaded chip now, but do NOT render the list yet:
            // state.apps is still empty until listPackages() resolves, and a
            // render here flashes "无法读取应用列表" — a false error — for as
            // long as the daemon query takes. The boot handler's applyMenu()
            // does the first real render once everything is in.
            applyChips();
        });
    }
    // Auto-include new installs: TEES-native "autoIncludeNewApps" on the active
    // profile (upstream allows it on at most one profile — the daemon refuses
    // to load a config where two profiles set it). Written straight to
    // config.json like a draft save; the daemon hot-reloads it. Legacy
    // migration lives in apps-sync.sh, which also ORs in the old flag file.
    function toggleAutoAdd() {
        if (!state.config || !state.profileName) {
            showErr(true, 'config.json 不可读，无法修改自动纳入设置。');
            return;
        }
        var on = !state.autoAdd;
        if (on) {
            // Upstream constraint: at most one profile may set this. If some
            // other profile already claims it, refuse instead of corrupting.
            for (var id in state.config.profiles) {
                if (id !== state.profileName && state.config.profiles[id] &&
                    state.config.profiles[id].autoIncludeNewApps) {
                    showErr(true, '配置中已有其他作用域开启了自动纳入（仅允许一个），请先在 TEES 管理器中关闭它。');
                    return;
                }
            }
        }
        state.autoAdd = on;
        applyMenu();
        state.config.profiles[state.profileName].autoIncludeNewApps = on;
        writeFileAtomic(CONFIG, JSON.stringify(state.config, null, 2) + '\n')
            .then(function (r) { if (!r.ok) showErr(true, r && r.error); })
            .catch(function (e) { showErr(true, (e && e.message) || '保存失败'); });
    }

    // ---------- list rendering ----------
    // Render cap: re-creating hundreds of rows per keystroke is the affordable
    // budget on old WebViews. The batch sweeps cut the SAME sorted sequence at
    // the same cap (see sortedVisible), so past the cap the rendered rows are
    // still exactly the swept rows.
    var RENDER_CAP = 500;
    function currentTerm() {
        var s = $('search');
        return s ? s.value : '';
    }
    function matches(app, term) {
        var t = String(term || '').toLowerCase();
        if (!t) return true;
        return app.label.toLowerCase().indexOf(t) !== -1 || app.pkg.toLowerCase().indexOf(t) !== -1;
    }
    // One filter chain for both rendering and batch sweeps: chips decide the
    // pool (user / user+system / selected), the search term narrows within it.
    function visibleApps() {
        var term = currentTerm();
        return state.apps.filter(function (a) {
            if (state.filter === 'selected') return !!state.draft[makeEntry(a.pkg, a.userId)];
            if (state.filter === 'system') return true;
            return !a.system;
        }).filter(function (a) { return matches(a, term); });
    }
    // One sort order shared by rendering AND the batch sweeps: selected rows
    // float to the top (the TEESimulator scope behavior — "inScope first"),
    // label A→Z within each group. Both consumers cut this same sequence at
    // RENDER_CAP rows, so what is rendered is exactly what 全选/反选/清除
    // sweep — even when the visible list exceeds the cap.
    function sortedVisible() {
        return visibleApps().sort(function (a, b) {
            var sa = state.draft[makeEntry(a.pkg, a.userId)] ? 0 : 1;
            var sb = state.draft[makeEntry(b.pkg, b.userId)] ? 0 : 1;
            if (sa !== sb) return sa - sb;
            return String(a.label).localeCompare(String(b.label));
        });
    }
    // Orphans = picked/saved entries the device can no longer resolve (the app
    // was uninstalled). The pm fallback only knows user-0 bare names, so
    // "@user" entries are unverifiable there and must not be flagged — a false
    // orphan would scare the user into removing a working work-profile entry.
    function installedSet() {
        var set = {};
        state.apps.forEach(function (a) { set[makeEntry(a.pkg, a.userId)] = true; });
        return set;
    }
    function orphanEntries() {
        var set = installedSet();
        var full = state.fullPkgs || {};
        return Object.keys(state.draft).filter(function (e) {
            if (set[e]) return false;
            if (state.source !== 'daemon' && /@\d+$/.test(e)) return false;
            // 守护进程的枚举视野更窄(漏掉非启动/被隐藏的应用——小米换机误报):
            // 裸条目与 @user 条目只要全量包列表(pm list packages)还认账,
            // 就不判"已卸载"。与 apps-sync.sh 的"全量列表为准"同一原则。
            var pkgOnly = e.replace(/@\d+$/, '');
            if (full[e] || full[pkgOnly]) return false;
            return true;
        }).sort();
    }
    function renderOrphans() {
        var box = $('orphans');
        if (!box) return;
        box.textContent = '';
        var orph = orphanEntries();
        if (!orph.length) { box.hidden = true; return; }
        box.hidden = false;
        box.appendChild(el('p', 'ap-orphans-title', '已保护但未安装 · ' + orph.length));
        orph.forEach(function (entry) {
            var chip = el('span', 'ap-orphan');
            chip.appendChild(el('span', 'ap-orphan-pkg', entry));
            chip.appendChild(el('span', 'ap-orphan-sub', '已卸载'));
            var x = el('button', 'ap-orphan-x', '✕');
            x.type = 'button';
            x.setAttribute('aria-label', '移除 ' + entry);
            x.addEventListener('click', function () {
                delete state.draft[entry];
                renderList();
                updateCount();
                updateFab();
            });
            chip.appendChild(x);
            box.appendChild(chip);
        });
    }
    function renderList() {
        var list = $('list');
        if (!list) return;
        // A re-render (search / filter toggle) invalidates every pending icon
        // job and observation from the previous pass.
        if (iconObserver) iconObserver.disconnect();
        iconPending = [];
        list.textContent = '';
        renderOrphans();
        var apps = sortedVisible();
        if (!apps.length) {
            var msg;
            // While the first enumeration is in flight the list is empty for a
            // reason that is NOT an error - say so explicitly. (Before
            // 2026-09-19 the page simply stayed blank until `pm list packages`
            // resolved; on-device that reads as "点一下卡住了". Rendering early
            // without this flag would have flashed the false "无法读取应用列表".)
            if (state.loading) msg = '正在读取应用列表…';
            else if (state.source === 'none') msg = '无法读取应用列表';
            else if (state.filter === 'selected') msg =
                Object.keys(state.draft).length ? '没有匹配的已选应用' : '还没有勾选任何应用';
            else if (state.filter === 'system') msg = '没有匹配的应用';
            else msg = '没有匹配的用户应用（切到"系统"筛选可显示）';
            list.appendChild(el('div', 'ap-empty', msg));
        }
        var eager = 0;
        apps.slice(0, RENDER_CAP).forEach(function (app) {
            var entry = makeEntry(app.pkg, app.userId);
            var sel = !!state.draft[entry];
            var row = el('div', 'app-row' + (sel ? ' sel' : ''));
            row.setAttribute('role', 'checkbox');
            row.setAttribute('aria-checked', sel ? 'true' : 'false');

            var av = el('span', 'app-avatar lg', avatarLetter(app.pkg));
            av.style.background = hashColor(app.pkg);
            row.appendChild(av);

            var body = el('div', 'app-row-body');
            body.appendChild(el('div', 'app-row-label', app.label || app.pkg));
            body.appendChild(el('div', 'app-row-pkg',
                app.pkg + (app.userId ? ' · 用户 ' + app.userId : '') + (app.system ? ' · 系统' : '')));
            row.appendChild(body);

            var box = el('span', 'app-check');
            box.appendChild(el('span', 'app-check-mark', '✓'));
            row.appendChild(box);

            // Real icon, best effort — the pipeline swaps the avatar for the
            // rendered PNG once the row is near the viewport.
            if (state.source === 'daemon') {
                setupIcon(av, app.pkg, app.userId, eager);
            }

            row.addEventListener('click', function () { toggleApp(entry, row); });
            list.appendChild(row);
            eager++;
        });
        pumpIcons();
        updateCount();
    }
    function updateCount() {
        var c = $('count');
        if (!c) return;
        var n = Object.keys(state.draft).length;
        c.textContent = '已选 ' + n + ' 个应用' + (draftDirty() ? ' · 有未保存的更改' : '');
    }
    function updateFab() {
        var f = $('save-fab');
        if (f) f.hidden = !draftDirty();
    }

    // ---------- selection (draft only) + explicit save ----------
    function toggleApp(entry, row) {
        if (state.draft[entry]) delete state.draft[entry];
        else state.draft[entry] = true;
        var sel = !!state.draft[entry];
        if (row) {
            row.classList.toggle('sel', sel);
            row.setAttribute('aria-checked', sel ? 'true' : 'false');
        }
        updateCount();
        updateFab();
    }

    // ---------- batch sweeps over the visible set (v2.2.3 全选, v2.2.7 三连) ----------
    // 全选/反选/清除 sweep exactly the rows the user can actually see: the
    // same sortedVisible() chain renderList uses (filter chips + search term,
    // cut at the same RENDER_CAP rows). With the "全部" chip the system apps
    // are never in the pool, so they can never be swept into the selection —
    // the visible set IS the scope. All three edit the draft only; the FAB
    // still gates writing config.json.
    function visibleEntries() {
        return sortedVisible().slice(0, RENDER_CAP)
            .map(function (a) { return makeEntry(a.pkg, a.userId); });
    }
    function selectVisible(mode) {
        var vis = visibleEntries();
        if (!vis.length) return;
        vis.forEach(function (e) {
            if (mode === 'all') state.draft[e] = true;
            else if (mode === 'clear') delete state.draft[e];
            else if (state.draft[e]) delete state.draft[e];
            else state.draft[e] = true;
        });
        renderList(); // refresh every row's tick state
        updateCount();
        updateFab();
    }
    function saveDraft() {
        if (state.saving || !draftDirty()) return;
        state.saving = true;
        var entries = Object.keys(state.draft).sort();
        var p;
        if (!state.config || !state.profileName) {
            p = Promise.resolve({ ok: false, error: 'config.json 不可读，无法保存' });
        } else {
            state.config.profiles[state.profileName].apps = entries;
            p = writeFileAtomic(CONFIG, JSON.stringify(state.config, null, 2) + '\n');
        }
        p.then(function (r) {
            if (r.ok) {
                // Saved scope is now exactly the draft.
                state.saved = {};
                entries.forEach(function (e) { state.saved[e] = true; });
                var ch = $('cfg-hint');
                if (ch) ch.hidden = true; // invalid entries (if any) are gone now
            } else {
                showErr(true, r && r.error);
            }
        }).catch(function (e) {
            showErr(true, (e && e.message) || '保存失败');
        }).then(function () {
            state.saving = false;
            updateCount();
            updateFab();
        });
    }
    function showErr(bad, msg) {
        var e = $('err');
        if (!e) return;
        e.hidden = !bad;
        e.textContent = bad ? (msg || '保存失败') : '';
    }

    // ---------- boot ----------
    document.addEventListener('DOMContentLoaded', function () {
        var hasApi = !!(window.ksu && typeof window.ksu.exec === 'function');
        if (!hasApi) {
            showErr(true, '无法通过管理器接口读取应用（可能未授权 Root）。');
            return;
        }

        // Icon loader: fetch a row's icon only when it approaches the viewport,
        // through the rate-limited pump above.
        iconObserver = (typeof IntersectionObserver === 'function')
            ? new IntersectionObserver(function (entries) {
                entries.forEach(function (en) {
                    if (!en.isIntersecting) return;
                    iconObserver.unobserve(en.target);
                    iconPending.push({ key: en.target._iconKey, el: en.target });
                    pumpIcons();
                });
            }, { rootMargin: '160px 0px' })
            : null;

        // ⋮ menu open/close
        var menuBtn = $('menu-btn'), menu = $('menu');
        if (menuBtn && menu) {
            menuBtn.addEventListener('click', function (e) {
                e.stopPropagation();
                menu.hidden = !menu.hidden;
                menuBtn.setAttribute('aria-expanded', menu.hidden ? 'false' : 'true');
            });
            document.addEventListener('click', function (e) {
                if (!menu.hidden && !menu.contains(e.target) && e.target !== menuBtn) {
                    menu.hidden = true;
                    menuBtn.setAttribute('aria-expanded', 'false');
                }
            });
        }
        $('opt-autoadd').addEventListener('click', toggleAutoAdd);

        // Floating save button: the only path that ever writes config.json.
        var fab = $('save-fab');
        if (fab) fab.addEventListener('click', saveDraft);

        // Filter chips: "系统" mirrors the legacy show-system flag so that
        // preference survives reboots; "已选" is session-only (the TEESimulator
        // scope filters never persist either).
        function bindChip(id, filter, flagValue) {
            var b = $(id);
            if (!b) return;
            b.addEventListener('click', function () {
                if (state.filter === filter) return; // already active: no re-render, no flag write
                state.filter = filter;
                applyChips();
                renderList();
                if (flagValue != null) writeFileAtomic(OPT_SYSTEM, flagValue + '\n');
            });
        }
        bindChip('chip-all', 'all', '0');
        bindChip('chip-system', 'system', '1');
        bindChip('chip-selected', 'selected', null);

        // Batch sweeps over the currently visible rows.
        var opMap = { 'ops-all': 'all', 'ops-invert': 'invert', 'ops-clear': 'clear' };
        Object.keys(opMap).forEach(function (id) {
            var b = $(id);
            if (b) b.addEventListener('click', function () { selectVisible(opMap[id]); });
        });

        // Search re-renders the whole list (hundreds of rows), so coalesce
        // fast typing with a short debounce; Enter renders immediately (the
        // TEESimulator scope page does exactly this, also at 140ms).
        var searchTimer = null;
        $('search').addEventListener('input', function () {
            if (searchTimer) clearTimeout(searchTimer);
            searchTimer = setTimeout(function () {
                searchTimer = null;
                renderList(); // reads the live input via currentTerm()
            }, 140);
        });
        $('search').addEventListener('keydown', function (e) {
            if (e && e.key === 'Enter') {
                if (searchTimer) { clearTimeout(searchTimer); searchTimer = null; }
                renderList();
            }
        });

        // Paint the shell before the first root shell-out. `pm list packages` (and
        // the daemon query behind it) take hundreds of milliseconds, and the page
        // used to stay completely blank until they resolved - which reads as a
        // frozen screen when you tap "受保护应用管理" (author, on-device).
        // renderList() while state.loading is true draws the honest
        // "正在读取应用列表…" placeholder instead.
        renderList();

        function boot() {
            Promise.all([loadSettings(), loadConfig(), listPackages()])
                .then(function (r) {
                    state.loading = false;
                    var cfg = r[1];
                    if (cfg.ok) {
                        state.config = cfg.config;
                        state.profileName = pickProfile(cfg.config);
                        var prof = state.config.profiles[state.profileName];
                        var bad = 0;
                        // Auto-include: native config field first; the legacy flag
                        // file (pre-native versions) ORs in until apps-sync
                        // migrates and deletes it.
                        state.autoAdd = !!(prof && prof.autoIncludeNewApps) || !!state._legacyAutoAdd;
                        // Fresh init = fresh scope (a page reload must not inherit
                        // any previous draft).
                        state.saved = {};
                        state.draft = {};
                        ((prof && prof.apps) || []).forEach(function (e) {
                            e = String(e);
                            if (validEntry(e)) state.saved[e] = true;
                            else bad++;
                        });
                        Object.keys(state.saved).forEach(function (e) { state.draft[e] = true; });
                        // Surface legacy garbage (e.g. the v2.2.0 pollution) without
                        // touching the file — the next explicit save writes only the
                        // validated entries and clears it.
                        var ch = $('cfg-hint');
                        if (ch && bad > 0) {
                            ch.hidden = false;
                            ch.textContent = '配置中有 ' + bad + ' 个无效条目已被忽略（如 "cmd:" 等错误文本），保存任意更改时会自动清除。';
                        }
                        updateCount();
                        updateFab();
                    } else {
                        showErr(true, 'config.json ' + (cfg.error || '不可读') + '，无法修改保护列表。');
                    }
                    state.apps = r[2].apps;
                    state.source = r[2].source;
                    state.fullPkgs = r[2].full || {};
                    var sh = $('src-hint');
                    if (sh) sh.hidden = state.source !== 'pm';
                    var opsEl = $('ops');
                    if (opsEl) opsEl.hidden = false;
                    applyMenu();
                })
                .catch(function (e) {
                    state.loading = false;
                    showErr(true, '初始化失败：' + ((e && e.message) || '未知错误'));
                });
        }

        // Yield one frame so the placeholder actually reaches the screen before
        // the shell-outs start competing with it for the main thread.
        if (typeof requestAnimationFrame === 'function') {
            requestAnimationFrame(function () { setTimeout(boot, 0); });
        } else {
            setTimeout(boot, 0);
        }
    });
}());
