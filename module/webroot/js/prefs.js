/* prefs.js — Aegis Fusion 主页「显示设置」+ 签放判定语聚合。
 *
 * 纯呈现层：本文件不解析任何 shell 输出、不做任何模块判断，
 * 只读取 launcher.js 已渲染到 DOM 的状态行 class（ok/warn/err/unknown）
 * 聚合顶部判定语，并持久化布局/主题偏好（localStorage）。
 * launcher.js 零改动；本文件缺失时页面功能完整，仅无设置入口与判定语。
 */
(function () {
    'use strict';

    var root = document.documentElement;
    var body = document.body;
    var store = {
        get: function (k) { try { return window.localStorage.getItem(k); } catch (e) { return null; } },
        set: function (k, v) { try { window.localStorage.setItem(k, v); } catch (e) { /* 隐私模式等场景下静默降级 */ } }
    };

    /* ---------- 布局与主题 ---------- */

    function setLayout(mode) {
        if (mode !== 'brick' && mode !== 'manifest') return;
        body.setAttribute('data-layout', mode);
        store.set('af-layout', mode);
        var btns = document.querySelectorAll('.seg-btn[data-layout]');
        for (var i = 0; i < btns.length; i++) {
            btns[i].setAttribute('aria-pressed', String(btns[i].getAttribute('data-layout') === mode));
        }
        refreshSum();
    }

    function setTheme(mode) {
        if (mode === 'auto') root.removeAttribute('data-theme');
        else if (mode === 'light' || mode === 'dark') root.setAttribute('data-theme', mode);
        else return;
        store.set('af-theme', mode);
        var btns = document.querySelectorAll('.seg-btn[data-theme-mode]');
        for (var i = 0; i < btns.length; i++) {
            btns[i].setAttribute('aria-pressed', String(btns[i].getAttribute('data-theme-mode') === mode));
        }
        refreshSum();
    }

    function refreshSum() {
        var sum = document.getElementById('setSum');
        if (!sum) return;
        var layout = body.getAttribute('data-layout') === 'brick' ? '状态砖' : '签放清单';
        var t = root.getAttribute('data-theme');
        var theme = t === 'light' ? '浅色' : t === 'dark' ? '深色' : '跟随系统';
        sum.textContent = layout + ' · ' + theme;
    }

    function bindSeg(attr, handler) {
        var btns = document.querySelectorAll('.seg-btn[' + attr + ']');
        for (var i = 0; i < btns.length; i++) {
            (function (btn) {
                btn.addEventListener('click', function () { handler(btn.getAttribute(attr)); });
            })(btns[i]);
        }
    }

    bindSeg('data-layout', setLayout);
    bindSeg('data-theme-mode', setTheme);

    var savedLayout = store.get('af-layout');
    if (savedLayout) setLayout(savedLayout);
    var savedTheme = store.get('af-theme');
    if (savedTheme) setTheme(savedTheme);
    refreshSum();

    /* ---------- 签放判定语（聚合呈现，非判断逻辑） ----------
     * launcher.js 的 setState() 会给 #st-tee / #st-keybox / #st-bl / #st-pif
     * 写入 ok / warn / err / unknown 等级 class。这里只读取这些 class
     * 聚合出顶部一句话与放行章的等级，不参与任何模块决策。 */

    var ROW_IDS = ['st-tee', 'st-keybox', 'st-bl', 'st-pif'];

    function updateVerdict() {
        var box = document.getElementById('verdict');
        if (!box || !ROW_IDS.length) return;
        var rows = [];
        for (var i = 0; i < ROW_IDS.length; i++) {
            var el = document.getElementById(ROW_IDS[i]);
            if (!el) return;
            rows.push(el);
        }
        var pending = 0, warn = 0, err = 0, ok = 0;
        for (var j = 0; j < rows.length; j++) {
            var cls = rows[j].className || '';
            if (/\berr\b/.test(cls)) err++;
            else if (/\bwarn\b/.test(cls)) warn++;
            else if (/\bok\b/.test(cls)) ok++;
            else pending++;
        }
        var line = document.getElementById('verdict-line');
        var word = document.getElementById('verdict-word');
        box.classList.remove('v-ok', 'v-warn', 'v-err');
        if (!line || !word) return;
        if (pending > 0) {
            line.textContent = '正在检查…';
            word.textContent = '检查';
        } else if (err > 0) {
            line.textContent = err + ' 项检查未通过 · 详见下方';
            word.textContent = '复核';
            box.classList.add('v-err');
        } else if (warn > 0) {
            line.textContent = '四项通过 · ' + warn + ' 项需要注意';
            word.textContent = '注意';
            box.classList.add('v-warn');
        } else {
            line.textContent = '四项检查，全部通过';
            word.textContent = '放行';
            box.classList.add('v-ok');
        }
    }

    /* 等级行由 launcher.js 直接写 className；用 MutationObserver 监听
     * class 变化（状态仅在刷新/定时循环时变化，无持续开销）。
     * 极老 WebView 无 MutationObserver 时退化为 4s 轮询，仅读 className。 */
    if (typeof MutationObserver !== 'undefined') {
        var mo = new MutationObserver(updateVerdict);
        for (var k = 0; k < ROW_IDS.length; k++) {
            var row = document.getElementById(ROW_IDS[k]);
            if (row) mo.observe(row, { attributes: true, attributeFilter: ['class'] });
        }
    } else {
        window.setInterval(updateVerdict, 4000);
    }
    updateVerdict();
})();
