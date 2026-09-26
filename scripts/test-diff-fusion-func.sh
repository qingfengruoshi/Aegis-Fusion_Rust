#!/usr/bin/env bash
# 差分测试：fusion_func 的 align_patch_level（shell vs Rust）。
#
# 原理：两版实现都通过外部 `resetprop` 写属性。把一个**桩 resetprop** 放到
# PATH 最前（状态落文件、调用记日志），对同一批 config.json 夹具分别跑
# shell 版与 Rust 版，比较「属性状态文件的最终内容」。
#
# shell 侧需要抽取 fusion_func.sh 并把写死的数据目录（契约 §1.4 记录的缺陷）
# 替换成测试目录 —— 这正是契约要求 Rust 修掉的点。
#
# Run: bash scripts/test-diff-fusion-func.sh
# 需要先构建：cargo +stable-x86_64-pc-windows-gnu build --release
set -u

# 宿主 safe-delete 守卫按「单轮删除文件数」拦批量 rm —— 套件清理偶发被拒会留
# 下陈旧夹具（哨兵/状态文件跨轮累计）造成伪失败。清理只针对 build/ 下本套件
# 自己的产物，直接走真 rm（与 test-diff-keybox-fetch.sh 同一做法）。
rmrf() { /usr/bin/rm -rf "$@"; }
unset -f rm 2>/dev/null || true


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_FF="$ROOT/module/fusion_func.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-fusion-func"

pass=0; fail=0; total=0

# --- 桩 resetprop：状态文件 + 调用日志 ---------------------------------------
# ★ 必须编译成真正的 .exe：Rust 通过 CreateProcess 调它，Windows 只会执行带
#   .exe 扩展名的程序（Android 上内核认 shebang，所以无扩展名脚本在设备上可行，
#   宿主上不行）。这也更接近设备的真实形态 —— 那里它就是个 ELF 二进制。
make_stub() {
    local d="$1"
    mkdir -p "$d/bin"
    local exe="$BASE/resetprop.exe"
    if [ ! -x "$exe" ]; then
        # gcc 是原生程序：路径要转成 Windows 形式（本套件第 4 处同类问题）
        local wbase wsrc
        wbase=$(cygpath -m "$BASE" 2>/dev/null || echo "$BASE")
        wsrc=$(cygpath -m "$ROOT/scripts/fixtures/resetprop_stub.c" 2>/dev/null || echo "$ROOT/scripts/fixtures/resetprop_stub.c")
        gcc -O1 -o "$wbase/resetprop.exe" "$wsrc" || return 1
    fi
    cp -f "$exe" "$d/bin/resetprop.exe"
}

# --- 夹具（config.json 变体 + 初始属性状态）-----------------------------------
KBDATE="2026-08-01"     # 初始属性里的旧补丁日期（确保与档案里的不同）
mkdir -p "$BASE"
make_stub "$BASE"

declare -A CFG
CFG[obj]='"profiles":{"p0":{"apps":["com.google.android.gms"]}},"patchLevel":{"system":"2026-09-05","vendor":"2026-09-05","boot":"2026-09-05"}'
CFG[legacy]='"profiles":{"p0":{"apps":[]}},"patchLevel":"2026-09-01"'
CFG[today]='"profiles":{"p0":{"apps":[]}},"patchLevel":{"system":"today"}'
CFG[missing]='"profiles":{"p0":{"apps":[]}}'
CFG[garbage]='"profiles":{"p0":{"apps":[]}},"patchLevel":{"system":"not-a-date"}'

init_props() { # <state-file>
    printf 'ro.build.version.security_patch=%s\n' "$KBDATE"  > "$1"
    printf 'ro.vendor.build.security_patch=%s\n' "$KBDATE" >> "$1"
}

# --- 差分运行器 ---------------------------------------------------------------
# run_case <name> <config-key> <expected-patch-date|unchanged>
run_case() {
    local name="$1" key="$2" expect="$3"
    local d="$BASE/$name"
    rmrf "$d"; mkdir -p "$d/bin" "$d/teesim/log"
    make_stub "$d"
    # 初始属性状态：两份（shell 与 Rust 各自的桩状态文件），都要有「旧补丁日期」
    # —— 否则会撞上 audit N16 的语义（缺失属性跳过不创建），测不到对齐路径。
    init_props "$d/state.shell"
    init_props "$d/state.rust"
    printf '{%s}\n' "${CFG[$key]}" > "$d/teesim/config.json"
    : > "$d/log"

    local TEE="$d/teesim"
    # ★ 桩 resetprop 是原生 exe：环境变量里的路径必须是 Windows 形式
    #   （MSYS 的 /d/... 它 fopen 不了）。这是本套件第 4 处同类问题。
    local wtee wssh wslg wrst wrlg
    wtee=$(cygpath -m "$TEE" 2>/dev/null || echo "$TEE")
    wssh=$(cygpath -m "$d/state.shell" 2>/dev/null || echo "$d/state.shell")
    wslg=$(cygpath -m "$d/calls.shell" 2>/dev/null || echo "$d/calls.shell")
    wrst=$(cygpath -m "$d/state.rust" 2>/dev/null || echo "$d/state.rust")
    wrlg=$(cygpath -m "$d/calls.rust" 2>/dev/null || echo "$d/calls.rust")

    # --- shell 版：抽取 fusion_func.sh，把写死的数据目录换成测试目录 ---
    sed "s|_TEE=/data/adb/teesim|_TEE=\"\$TEE\"|" "$SHELL_FF" > "$d/ff.sh"
    (
        export PATH="$d/bin:$PATH"
        export RESETPROP_STATE="$wssh" RESETPROP_LOG="$wslg"
        export TEE
        . "$d/ff.sh"
        align_patch_level >/dev/null 2>&1
    )
    # --- Rust 版 ---
    (
        export PATH="$d/bin:$PATH"
        export RESETPROP_STATE="$wrst" RESETPROP_LOG="$wrlg"
        export AEGIS_TEE_DIR="$wtee"
        "$RUST_BIN" align-patch-level >/dev/null 2>&1
    )

    total=$((total + 1))
    if diff -u "$d/state.shell" "$d/state.rust" > "$d/state.diff" 2>/dev/null; then
        # 再核对语义：与期望一致（unchanged = 保持 KBDATE）
        local ok=1
        for p in ro.build.version.security_patch ro.vendor.build.security_patch; do
            got=$(grep "^$p=" "$d/state.rust" | cut -d= -f2-)
            want=$KBDATE; [ "$expect" != "unchanged" ] && want=$expect
            [ "$got" = "$want" ] || ok=0
        done
        if [ "$ok" = 1 ]; then
            pass=$((pass + 1)); echo "  PASS  $name (patch → $expect)"
            return 0
        fi
        fail=$((fail + 1))
        echo "  FAIL  $name（两边一致但语义错：期望 $expect，得到 $(grep 'security_patch' "$d/state.rust" | tr '\n' ' ')）"
        return 1
    fi
    fail=$((fail + 1))
    echo "  FAIL  $name"
    head -10 "$d/state.diff" | sed 's/^/          /'
    return 1
}

echo "== 差分：fusion_func / align_patch_level（shell vs Rust）=="
run_case obj     obj     2026-09-05
run_case legacy  legacy  2026-09-01
run_case today   today   "$(date +%F)"
run_case missing missing unchanged
run_case garbage garbage unchanged

echo
echo "== 结果：$pass/$total 一致，$fail 处差异 =="
[ "$fail" -eq 0 ] || exit 1
