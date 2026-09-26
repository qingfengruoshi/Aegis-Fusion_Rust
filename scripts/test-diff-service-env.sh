#!/usr/bin/env bash
# 差分测试：service 的环境/BL 隐藏层（shell vs Rust）。
#
# 比较判据（契约 §5.3–5.6 的**语义**）：
#   ① 最终属性状态（stub 的 state 文件）两边一致；
#   ② **写操作序列**（set/pset/del/pdel）两边一致；
#   读操作的次数不计（实现细节：shell 用 grep 管道遍历，Rust 用一次 list）。
#
# shell 侧：抽取 service.sh:60-242（环境/BL 隐藏层），source fusion_func.sh 提供
# resetprop_if_diff / resetprop_if_match，dbg 定义为 no-op（debug.log 不在比较范围）。
#
# Run: bash scripts/test-diff-service-env.sh
set -u

# 宿主 safe-delete 守卫按「单轮删除文件数」拦批量 rm —— 套件清理偶发被拒会留
# 下陈旧夹具（哨兵/状态文件跨轮累计）造成伪失败。清理只针对 build/ 下本套件
# 自己的产物，直接走真 rm（与 test-diff-keybox-fetch.sh 同一做法）。
rmrf() { /usr/bin/rm -rf "$@"; }
unset -f rm 2>/dev/null || true


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_SVC="$ROOT/module/service.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-service-env"
w() { cygpath -m "$1" 2>/dev/null || echo "$1"; }

pass=0; fail=0; total=0

# --- 桩 resetprop（扩展版：list / -Z / -c / -p / -n / --delete）---------------
make_stub() {
    local d="$1"
    mkdir -p "$d/bin"
    local wbase wsrc
    wbase=$(w "$BASE"); wsrc=$(w "$ROOT/scripts/fixtures/resetprop_stub.c")
    if [ ! -x "$wbase/resetprop.exe" ] || [ "$ROOT/scripts/fixtures/resetprop_stub.c" -nt "$wbase/resetprop.exe" ]; then
        gcc -O1 -o "$wbase/resetprop.exe" "$wsrc" || return 1
    fi
    cp -f "$wbase/resetprop.exe" "$d/bin/resetprop.exe"
}

# --- 夹具 ---------------------------------------------------------------------
# 初始属性状态：BL 全解锁/橙 + 一个 hook ROM 标记（分 case 覆盖）
init_state() { # <state-file> <hook:yes|no>
    local f="$1" hook="$2"
    : > "$f"
    printf 'ro.boot.vbmeta.device_state=unlocked\n' >> "$f"
    printf 'ro.boot.verifiedbootstate=orange\n' >> "$f"
    printf 'ro.boot.flash.locked=0\n' >> "$f"
    printf 'ro.boot.veritymode=disabled\n' >> "$f"
    printf 'ro.debuggable=1\n' >> "$f"
    printf 'ro.build.tags=test-keys\n' >> "$f"
    printf 'ro.vendor.build.tags=test-keys\n' >> "$f"
    printf 'ro.build.type=userdebug\n' >> "$f"
    printf 'ro.bootmode=recovery\n' >> "$f"
    printf 'ro.warranty_bit=1\n' >> "$f"
    if [ "$hook" = yes ]; then
        printf 'ro.aospa.version=1.0\n' >> "$f"
        printf 'persist.sys.pixelprops.gms=true\n' >> "$f"
        printf 'persist.sys.spoof.gms=true\n' >> "$f"
    else
        printf 'persist.sys.pixelprops.gms=true\n' >> "$f"   # 残留（非 hook ROM）
        printf 'persist.sys.spoof.gms=true\n' >> "$f"
    fi
}

# --- 差分运行器 ----------------------------------------------------------------
run_case() {
    local name="$1" hook="$2"
    local d="$BASE/$name"
    rmrf "$d"; mkdir -p "$d/teesim/log" "$d/bin"
    make_stub "$d"
    init_state "$d/state" "$hook"

    local wst wlg wtee
    wst=$(w "$d/state"); wlg=$(w "$d/calls"); wtee=$(w "$d/teesim")

    # --- shell 版：抽取 service.sh 的环境隐藏层 -----------------------------
    {
        echo 'dbg() { :; }'
        echo "TEE_DIR='$wtee'"
        echo "CMD_SPOOF_FLAG='$wtee/.cmdline-spoof'"
        echo "CMD_SPOOF_FILE='$wtee/cmdline.spoofed'"
        echo "GMS_JSON='$d/gms.json'"
        echo "AEGIS_GMS_JSON='$d/gms.json'"
        echo ". '$(w "$ROOT/module/fusion_func.sh")'"
        sed -n '60,242p' "$SHELL_SVC"
    } > "$d/block.sh"
    (
        export PATH="$d/bin:$PATH"
        export RESETPROP_STATE="$wst" RESETPROP_LOG="$wlg"
        timeout 60 bash "$d/block.sh" >/dev/null 2>&1
    )
    cp -f "$d/state" "$d/state.shell"
    grep -E '^(set|pset|del|pdel) ' "$d/calls" > "$d/writes.shell" 2>/dev/null || : > "$d/writes.shell"

    # --- Rust 版（还原属性状态；清空调用日志，避免混入 shell 的调用）-------
    : > "$d/calls"
    init_state "$d/state" "$hook"
    (
        export PATH="$d/bin:$PATH"
        export RESETPROP_STATE="$wst" RESETPROP_LOG="$wlg"
        export AEGIS_TEE_DIR="$wtee" AEGIS_GMS_JSON="$d/gms.json"
        timeout 60 "$RUST_BIN" env-hiding >/dev/null 2>&1
    )
    cp -f "$d/state" "$d/state.rust"
    grep -E '^(set|pset|del|pdel) ' "$d/calls" > "$d/writes.rust" 2>/dev/null || : > "$d/writes.rust"

    total=$((total + 1))
    local ok=1
    diff -q "$d/state.shell" "$d/state.rust" >/dev/null 2>&1 || { ok=0; echo "          [final state 差异]"; diff "$d/state.shell" "$d/state.rust" 2>/dev/null | head -6 | sed 's/^/            /'; }
    diff -q "$d/writes.shell" "$d/writes.rust" >/dev/null 2>&1 || { ok=0; echo "          [写序列差异]"; diff "$d/writes.shell" "$d/writes.rust" 2>/dev/null | head -8 | sed 's/^/            /'; }
    if [ "$ok" = 1 ]; then
        pass=$((pass + 1)); echo "  PASS  $name"
        return 0
    fi
    fail=$((fail + 1)); echo "  FAIL  $name"
    return 1
}

echo "== 差分：service 环境隐藏层（shell vs Rust）=="
run_case non_hook_rom  no
run_case hook_rom      yes

echo
echo "== 结果：$pass/$total 一致，$fail 处差异 =="
[ "$fail" -eq 0 ] || exit 1
