#!/usr/bin/env bash
# 差分测试：WebUI 探针（launcher.js 内联 shell 探针 vs fusionctl ui-probe）。
#
# 方法：用 Node 把 launcher.js 里的 `var PROBE = …` 表达式求值成 shell 脚本
#（注入与页面同一组常量 TEE_DIR/MODPATH/PROC/HELPER/SOCK），与 Rust 实现跑在
# 同一夹具树上，逐行比较 KEY=VALUE 输出。
#
# ⚠️ 两条宿主铁律在此交汇：
#  a) Node 是 Windows 程序 ⇒ 传给它的路径必须 cygpath -m（POSIX 形式会被
#     误解析成 D:\d\Storage）；
#  b) #!/bin/sh 桩在 MSYS 下用 D:/ 盘符路径 exec 会 127，POSIX 路径
#     才能回退到 sh —— 所以 shell 探针里烘焙 POSIX 形式路径，rust 侧用
#     Windows 形式（fs 需要真实路径），比较时两侧路径各自归一。
#
# 桩：getprop（夹具值）/ pidof（空）/ teesim-uds（canned /status）。
# 时间敏感键（KBAGE/REVA）用新建夹具 ⇒ 小时数恒 0。
# Run: bash scripts/test-diff-ui-probe.sh
set -u
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
unset -f rm 2>/dev/null || true
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Node 解析顺序：NODE_EXE 环境变量 → PATH 上的 node
NODE="${NODE_EXE:-node}"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-ui-probe"

pass=0; fail=0; total=0
rmrf() { /usr/bin/rm -rf "$@"; }

mkdir -p "$BASE/bin"
cat > "$BASE/bin/getprop" <<'EOF'
#!/bin/sh
cat "$GETPROPFIX/$1" 2>/dev/null
EOF
cat > "$BASE/bin/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$BASE/bin/"*

# teesim-uds 桩：canned /status
make_uds() { # <tee-dir>
    cat > "$1/teesim-uds" <<'EOS'
#!/bin/sh
case "$3" in
  /status)
    cat <<'JSON'
{"ok":true,"hook":"libteesim.so","version":"v4.0-canary","push":{"last":1726900000},"ack":{"last":1726900001,"applied":1,"failed":0}}
JSON
    exit 0 ;;
esac
exit 1
EOS
    chmod +x "$1/teesim-uds"
    : > "$1/admin.sock"
    printf 'tok-123\n' > "$1/admin.token"
}

# --- 从 JS 提取 shell 探针（Node；入参一律 Windows 形式路径）-------------------
extract_probe() { # <js-win> <var> <end-mark> <out-win>
    "$NODE" - "$1" "$2" "$3" "$4" <<'NODEOF'
const fs = require('fs');
const [,, jsFile, varName, endMark, outFile] = process.argv;
const src = fs.readFileSync(jsFile, 'utf8');
const start = src.indexOf('var ' + varName + ' =');
if (start < 0) { console.error('probe not found'); process.exit(1); }
const end = src.indexOf(endMark, start);
if (end < 0) { console.error('end mark not found'); process.exit(1); }
let expr = src.slice(start + ('var ' + varName + ' =').length, end).trim();
expr = expr.replace(/;\s*$/, '');
const TEE_DIR = process.env.AEGIS_TEE_DIR;
const MODPATH = process.env.AEGIS_MODDIR;
const PROC = 'teesim';
const MODID = process.env.AEGIS_MODID || 'aegisfusion_rs';
const HELPER = TEE_DIR + '/teesim-uds';
const SOCK = TEE_DIR + '/admin.sock';
const TOKEN_FILE = TEE_DIR + '/admin.token';
const probe = eval(expr);
fs.writeFileSync(outFile, probe);
NODEOF
}

# --- 夹具 ----------------------------------------------------------------------
make_fixture() { # <d>
    local d="$1"
    mkdir -p "$d/teesim/log" "$d/mod" "$d/bin" "$d/getprop"
    printf 'version=3.2.4\nversionCode=32\n' > "$d/mod/module.prop"
    printf '<Keybox DeviceID="suite">\n  <Key algorithm="rsa">\n    <Certificate>\nQUJDREVG\n    </Certificate>\n    <Certificate>\nMTIzNDU2\n    </Certificate>\n  </Key>\n</Keybox>\n' > "$d/teesim/keybox.xml"
    printf 'bd860482755565f61c72d4cd204c4533a217678a7b288113b8e73b8f01d9f945' > "$d/teesim/.auto-keybox"
    printf 'Megatron\n' > "$d/teesim/.keybox-source"
    printf 'Megatron\n' > "$d/teesim/keybox-source-pref"
    printf '48\n' > "$d/teesim/keybox-refresh"
    printf '2\n' > "$d/teesim/.key-status-n"
    printf '\xf0\x9f\x9f\xa2\xf0\x9f\x9f\xa2\n' > "$d/teesim/key-status.txt"
    printf '2026-09-26 10:00:00 I teesim: some line\n2026-09-26 10:01:00 E teesim: ERROR: deploy failed\n2026-09-26 10:02:00 I teesim: ok\n' > "$d/teesim/keybox-fetch.log"
    # kbhash 缺 → kbtm 兜底：kbtm 设为当前 keybox mtime ⇒ 非 stale。
    # 两次 make_fixture 的 mtime 不同 ⇒ 各自按各自的 mtime 重写，两侧一致。
    printf 'state=ok\nreason=\nack_applied=1\nack_failed=0\nack=ack line\nkbtm=%s\n' "$(stat -c %Y "$d/teesim/keybox.xml")" > "$d/teesim/.engine-verdict"
    printf '1726900000\n下载候选\nMegatron · 第 1/3 次尝试\n' > "$d/teesim/.kb-fetch.progress"
    printf '1726900000\n' > "$d/teesim/.kb-last-fetch"
    printf '{"entries":{}}\n' > "$d/teesim/.revocation-status.json"
    printf 'seed\n' > "$d/teesim/.pif-source"
    printf '1726900000\n1727000000\n' > "$d/mod/.pif-auto"
    printf 'BRAND=google\nMODEL=Pixel 9 Pro\n# Estimated Expiry: 2027-12-31\n' > "$d/mod/custom.pif.prop"
    for k in ro.boot.vbmeta.device_state ro.boot.verifiedbootstate ro.build.tags ro.boot.flash.locked; do
        printf 'locked\n' > "$d/getprop/$k"
    done
    printf '%s\n' 'I TEESimulator: control: pushed config epoch=9 profiles=2' \
        'I TEESimulator: control: ack epoch=10 ok=true applied=1 failed=0' \
        'I TEESimulator: cfg: staged profile p0 target=1' \
        'I TEESimulator: keystore2 request target=1 served by engine' \
        'I TEESimulator: keystore2 request target=0 forwarded' \
        'E TEESimulator: teesim_km_init_ex: RSA: expected at least 2 certificates, found 1' > "$d/teesim/log/teesim.log"
    printf '2026-09-26 10:00:00 I teesim: generation failed (network)\n' > "$d/teesim/pif-fetch.log"
    printf '{"profiles":{"p0":{"mode":"ib","osVersion":"","system":"2026-08-01","vendor":"2026-08-01","boot":"2026-08-01","brand":"google","device":"caiman","product":"caiman_beta","manufacturer":"google","model":"Pixel 9 Pro","apps":[]}}}' > "$d/teesim/config.json"
    make_uds "$d/teesim"
    export GETPROPFIX="$d/getprop"
}

run_probe_case() { # <name> <page>
    local name="$1" page="$2"
    local d="$BASE/$name"
    local wtee wmod
    wtee=$(cygpath -m "$d/teesim"); wmod=$(cygpath -m "$d/mod")

    # --- shell 版（探针里烘焙 POSIX 路径，见文件头铁律 b）---
    make_fixture "$d"
    # 参考实现 = shell 线仓库的探针（RS 的 launcher.js 已换成 fusionctl 调用，
    # 提取不到旧探针是预期）；MODPATH 仍烘焙 RS 的模块目录（夹具在这边）。
    local shell_line_default; shell_line_default="$(dirname "$ROOT")/Hide/IntegrityFusion"
    local SHELL_LINE_JS="${SHELL_LINE_ROOT:-$shell_line_default}/module/webroot/js/launcher.js"
    local js_win; js_win=$(cygpath -m "$SHELL_LINE_JS")
    local out_win; out_win=$(cygpath -m "$d/probe.launcher.sh")
    AEGIS_TEE_DIR="$d/teesim" AEGIS_MODDIR="$d/mod" \
        extract_probe "$js_win" "PROBE" "// ---------- TEE daemon transport" "$out_win" \
        || { echo "  ❌ $name（探针提取失败）"; total=$((total+1)); fail=$((fail+1)); return; }
    local rc1
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$d/teesim" AEGIS_MODDIR="$d/mod" LC_ALL=C
      cd "$d" && sh "$d/probe.launcher.sh" ) > "$BASE/$name.out.shell" 2>/dev/null
    rc1=$?

    # --- rust 版（重置夹具；Windows 形式路径）---
    make_fixture "$d"
    local rc2
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" LC_ALL=C
      cd "$d" && "$RUST_BIN" ui-probe "$page" ) > "$BASE/$name.out.rust" 2>/dev/null
    rc2=$?

    # --- 比较（两侧路径各自归一）---
    sed "s|$wtee|<TEE>|g; s|$wmod|<MOD>|g" "$BASE/$name.out.rust" > "$BASE/$name.norm.rust"
    sed "s|$d/teesim|<TEE>|g; s|$d/mod|<MOD>|g; s|$d|<TEE>|g" "$BASE/$name.out.shell" > "$BASE/$name.norm.shell"

    total=$((total + 1))
    if [ "$rc1" = "$rc2" ] && diff -u "$BASE/$name.norm.shell" "$BASE/$name.norm.rust" > "$BASE/$name.diff" 2>&1; then
        pass=$((pass + 1)); echo "  ✅ $name"
    else
        fail=$((fail + 1)); echo "  ❌ $name（rc1=$rc1 rc2=$rc2；diff: $BASE/$name.diff）"
    fi
}

echo "== ui-probe 差分 =="
run_probe_case launcher launcher

# logs 页：DIAG_PROBE 提取 + MNT_* 经 AEGIS_MOUNTS_FILE 接缝（rust 侧读
# shell 同瞬间的 /proc/self/mounts 快照，两侧行数一致）
run_logs_case() {
    local name="$1"
    local d="$BASE/$name"
    local wtee wmod
    wtee=$(cygpath -m "$d/teesim"); wmod=$(cygpath -m "$d/mod")

    make_fixture "$d"
    local shell_line_default; shell_line_default="$(dirname "$ROOT")/Hide/IntegrityFusion"
    local SHELL_LINE_JS="${SHELL_LINE_ROOT:-$shell_line_default}/module/webroot/js/logs.js"
    local js_win; js_win=$(cygpath -m "$SHELL_LINE_JS")
    local out_win; out_win=$(cygpath -m "$d/probe.logs.sh")
    AEGIS_TEE_DIR="$d/teesim" AEGIS_MODDIR="$d/mod" AEGIS_MODID="aegisfusion_rs" \
        extract_probe "$js_win" "DIAG_PROBE" "// A real package entry" "$out_win" \
        || { echo "  ❌ $name（探针提取失败）"; total=$((total+1)); fail=$((fail+1)); return; }
    # MNT 快照：给 rust 侧用（shell 侧直接读活的 /proc/self/mounts）
    cat /proc/self/mounts > "$d/mounts.fix.tmp" 2>/dev/null || : > "$d/mounts.fix.tmp"
    mv -f "$d/mounts.fix.tmp" "$d/mounts.fix"

    local rc1
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$d/teesim" AEGIS_MODDIR="$d/mod" LC_ALL=C
      cd "$d" && sh "$d/probe.logs.sh" ) > "$BASE/$name.out.shell" 2>/dev/null
    rc1=$?

    make_fixture "$d"
    cat /proc/self/mounts > "$d/mounts.fix.tmp" 2>/dev/null || : > "$d/mounts.fix.tmp"
    mv -f "$d/mounts.fix.tmp" "$d/mounts.fix"
    local rc2
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" \
            AEGIS_MOUNTS_FILE="$(cygpath -m "$d/mounts.fix")" LC_ALL=C
      cd "$d" && "$RUST_BIN" ui-probe logs ) > "$BASE/$name.out.rust" 2>/dev/null
    rc2=$?

    sed "s|$wtee|<TEE>|g; s|$wmod|<MOD>|g" "$BASE/$name.out.rust" > "$BASE/$name.norm.rust"
    sed "s|$d/teesim|<TEE>|g; s|$d/mod|<MOD>|g; s|$d|<TEE>|g" "$BASE/$name.out.shell" > "$BASE/$name.norm.shell"

    total=$((total + 1))
    if [ "$rc1" = "$rc2" ] && diff -u "$BASE/$name.norm.shell" "$BASE/$name.norm.rust" > "$BASE/$name.diff" 2>&1; then
        pass=$((pass + 1)); echo "  ✅ $name"
    else
        fail=$((fail + 1)); echo "  ❌ $name（rc1=$rc1 rc2=$rc2；diff: $BASE/$name.diff）"
    fi
}
run_logs_case logs

echo
echo "结果: $pass/$total 通过, $fail 失败"
[ "$fail" -eq 0 ]
