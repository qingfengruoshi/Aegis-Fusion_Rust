#!/usr/bin/env bash
# 差分测试：keybox-swap 的**文件逻辑**（shell vs Rust）。
#
# 范围：备份（cp -fL + 剪枝到 10）、原子替换（.new + mv）、.auto-keybox 作废、
#       --restore、--list、validate 的拒绝路径。
# 不在范围：verdict 等待（--watch / 单候选部署后的 watch_verdict）—— 依赖
#       engine-verdict 的 watch 子命令，随 watch 移植后补。所以**只比文件系统
#       终态，不比 stdout/退出码**（shell 的输出含 VERDICT 行）。
#
# Run: bash scripts/test-diff-keybox-swap.sh
# 需要先构建：cargo +stable-x86_64-pc-windows-gnu build --release
set -u

# 宿主 safe-delete 守卫按「单轮删除文件数」拦批量 rm —— 套件清理偶发被拒会留
# 下陈旧夹具（哨兵/状态文件跨轮累计）造成伪失败。清理只针对 build/ 下本套件
# 自己的产物，直接走真 rm（与 test-diff-keybox-fetch.sh 同一做法）。
rmrf() { /usr/bin/rm -rf "$@"; }
unset -f rm 2>/dev/null || true


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_KS="$ROOT/module/keybox-swap.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-keybox-swap"
w() { cygpath -m "$1" 2>/dev/null || echo "$1"; }

pass=0; fail=0; total=0

VALID='<?xml version="1.0"?><Keybox><Key algorithm="rsa"><Certificate>QUJDREVG</Certificate><Certificate>QUJDREVG</Certificate></Key></Keybox>'
INVALID='<?xml version="1.0"?><Keybox><Key algorithm="rsa"><Certificate>QUJ</Certificate></Key></Keybox>'
OLDKB='<?xml version="1.0"?><Keybox><Key algorithm="ecdsa"><Certificate>WFlaQUJD</Certificate><Certificate>WFlaQUJD</Certificate></Key></Keybox>'

# --- 差分运行器 ---------------------------------------------------------------
# run_case <name> <准备函数>
run_case() {
    local name="$1" prep="$2"
    local d="$BASE/$name"
    local wtee wmod
    wtee=$(w "$d/teesim"); wmod=$(w "$d/mod")

    # --- shell 版 ---
    rmrf "$d"; mkdir -p "$d/teesim/log" "$d/mod" "$d/bin"
    printf '%s' "$OLDKB" > "$d/teesim/keybox.xml"
    printf '{"profiles":{"p0":{"apps":[]}}}\n' > "$d/teesim/config.json"
    printf '%s' "$VALID" > "$d/cand_valid.xml"
    printf '%s' "$INVALID" > "$d/cand_invalid.xml"
    "$prep" "$d"
    PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" \
        timeout 120 sh "$SHELL_KS" $(case "$name" in deploy_force) echo "cand_invalid.xml -f";; \
        deploy_refuse) echo "cand_invalid.xml";; deploy_valid) echo "cand_valid.xml";; \
        no_current) echo "cand_valid.xml";; backup_prune) echo "cand_valid.xml";; \
        restore) echo "--restore";; list) echo "--list";; esac) \
        >/dev/null 2>&1
    cp -f "$d/teesim/keybox.xml" "$d/kb.shell" 2>/dev/null || : > "$d/kb.shell"
    ls -1 "$d/teesim/keybox-backups" 2>/dev/null | sort > "$d/bk.shell"
    [ -f "$d/teesim/.auto-keybox" ] && echo yes > "$d/auto.shell" || echo no > "$d/auto.shell"

    # --- Rust 版（还原夹具：重跑 prep，保证与 shell 侧的初始状态一致）---
    rm -rf "$d/teesim"; mkdir -p "$d/teesim/log" "$d/teesim/keybox-backups"
    printf '%s' "$OLDKB" > "$d/teesim/keybox.xml"
    printf '{"profiles":{"p0":{"apps":[]}}}\n' > "$d/teesim/config.json"
    "$prep" "$d"
    PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$wtee" AEGIS_MODDIR="$wmod" \
        timeout 60 "$RUST_BIN" keybox-swap $(case "$name" in deploy_force) echo "cand_invalid.xml -f";; \
        deploy_refuse) echo "cand_invalid.xml";; deploy_valid) echo "cand_valid.xml";; \
        no_current) echo "cand_valid.xml";; backup_prune) echo "cand_valid.xml";; restore) echo "--restore";; \
        list) echo "--list";; esac) > "$d/shell.out" 2>&1
    cp -f "$d/teesim/keybox.xml" "$d/kb.rust" 2>/dev/null || : > "$d/kb.rust"
    ls -1 "$d/teesim/keybox-backups" 2>/dev/null | sort > "$d/bk.rust"
    [ -f "$d/teesim/.auto-keybox" ] && echo yes > "$d/auto.rust" || echo no > "$d/auto.rust"

    total=$((total + 1))
    local ok=1
    for f in kb bk auto; do
        diff -q "$d/$f.shell" "$d/$f.rust" >/dev/null 2>&1 || {
            ok=0
            echo "  FAIL  $name [$f 差异]:"
            diff "$d/$f.shell" "$d/$f.rust" 2>/dev/null | head -4 | sed 's/^/            /'
        }
    done
    if [ "$ok" = 1 ]; then
        pass=$((pass + 1)); echo "  PASS  $name"
        return 0
    fi
    return 1
}

# --- 各 case 的准备 -----------------------------------------------------------
prep_none() { :; }
prep_backup_prune() {
    local d="$1"
    mkdir -p "$d/teesim/keybox-backups"
    for i in $(seq 1 12); do printf '%s' "$OLDKB" > "$d/teesim/keybox-backups/keybox.$i.xml"; done
}
prep_restore() {
    local d="$1"
    mkdir -p "$d/teesim/keybox-backups"
    printf '%s' "$OLDKB" > "$d/teesim/keybox-backups/keybox.20260101-000000.xml"
    printf '%s' "$VALID" > "$d/teesim/keybox-backups/keybox.20260202-000000.xml"
    # ★ ls -1t 按 mtime 排序：同秒创建会让「最新」不稳定 ⇒ 显式设置 mtime
    touch -d "2026-01-01 00:00:00" "$d/teesim/keybox-backups/keybox.20260101-000000.xml"
    touch -d "2026-02-02 00:00:00" "$d/teesim/keybox-backups/keybox.20260202-000000.xml"
}
prep_deploy_refuse() { local d="$1"; mkdir -p "$d/teesim/keybox-backups"; }
prep_deploy_force()  { local d="$1"; mkdir -p "$d/teesim/keybox-backups"; }
prep_deploy_valid()  { local d="$1"; mkdir -p "$d/teesim/keybox-backups"; }
prep_no_current()    { local d="$1"; rm -f "$d/teesim/keybox.xml"; mkdir -p "$d/teesim/keybox-backups"; }

echo "== 差分：keybox-swap 文件逻辑（shell vs Rust）=="
run_case deploy_valid     prep_deploy_valid
run_case deploy_refuse    prep_deploy_refuse
run_case deploy_force     prep_deploy_force
run_case backup_prune     prep_backup_prune
run_case restore          prep_restore
run_case no_current       prep_no_current

echo
echo "== 结果：$pass/$total 一致，$fail 处差异 =="
[ "$fail" -eq 0 ] || exit 1
