#!/usr/bin/env bash
# 差分测试：uninstall（shell vs Rust）。
#
# shell 版的删除目标全部硬编码（/data/adb/teesim、/data/data/...）——宿主上不可
# 重定向，本套件可比的是：**resetprop 调用序列**（audit R8-5 的 12 个残留 prop
# 的存在性判定 + --delete/-p --delete 顺序）与退出码。目录抹除/注入物清理在
# Rust 侧由 AEGIS_TEE_DIR 接缝实现，设备行为由装配后的真机验证覆盖。
#
# 桩：resetprop —— 记录 "resetprop <args>"；存在性按夹具文件应答（列出的 prop
#     get/-p get 返回 0，其余返回 1）。
# Run: bash scripts/test-diff-uninstall.sh
set -u
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export LC_ALL=C

# safe-delete 还会导出 rm 函数并穿透到子 shell（$d/bin 的直通桩被绕过），
# 在 harness 顶层断掉继承，让子进程的 rm 走 PATH 上的直通桩。
unset -f rm 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_US="$ROOT/module/uninstall.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
BASE="$ROOT/build/diff-uninstall"

pass=0; fail=0; total=0

make_stub() { # <bin-dir> <props-exist 夹具>
    mkdir -p "$1"
    cat > "$1/resetprop" <<EOF
#!/bin/sh
printf 'resetprop %s\\n' "\$*" >> "\$RPLOG"
case "\$*" in
  --delete*|-p[[:space:]]--delete*) exit 0 ;;
  -p) # -p PROP 存在性
    grep -Fxq "\$2" "\$PROPS_EXIST" 2>/dev/null && exit 0 || exit 1 ;;
  "") exit 0 ;;
  *) grep -Fxq "\$1" "\$PROPS_EXIST" 2>/dev/null && exit 0 || exit 1 ;;
esac
EOF
    chmod +x "$1/resetprop"
}

run_case() { # <name> <有桩？> <props 夹具内容>
    local name="$1" with_stub="$2" props="$3"
    local d="$BASE/$name"
    /usr/bin/rm -rf "$d" "$BASE/$name.out.shell" "$BASE/$name.out.rust"
    mkdir -p "$d/teesim" "$d/bin"

    # --- shell 版 ---
    if [ "$with_stub" = yes ]; then make_stub "$d/bin" "$props"; fi
    printf '%s\n' "$props" > "$d/props.exist"
    local rc1
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$(cygpath -m "$d/teesim")" \
            RPLOG="$d/rplog.shell" PROPS_EXIST="$d/props.exist" LC_ALL=C
      : > "$d/rplog.shell"
      sh "$SHELL_US" ) > "$BASE/$name.out.shell" 2>/dev/null
    rc1=$?

    # --- Rust 版 ---
    if [ "$with_stub" = yes ]; then make_stub "$d/bin" "$props"; fi
    local rc2
    ( export PATH="$d/bin:$PATH" AEGIS_TEE_DIR="$(cygpath -m "$d/teesim")" \
            RPLOG="$d/rplog.rust" PROPS_EXIST="$d/props.exist" LC_ALL=C
      : > "$d/rplog.rust"
      "$RUST_BIN" uninstall ) > "$BASE/$name.out.rust" 2>/dev/null
    rc2=$?

    total=$((total + 1))
    if [ "$rc1" = "$rc2" ] && diff -u "$d/rplog.shell" "$d/rplog.rust" > "$d/rplog.diff" 2>&1; then
        pass=$((pass + 1)); echo "  ✅ $name"
    else
        fail=$((fail + 1))
        echo "  ❌ $name（rc1=$rc1 rc2=$rc2；diff: $d/rplog.diff）"
    fi
}

echo "== uninstall 差分 =="
run_case props_partial yes 'persist.sys.pihooks.first_api_level
persist.sys.pixelprops.gms
persist.sys.spoof.gms'
run_case no_resetprop no ''

echo
echo "结果: $pass/$total 通过, $fail 失败"
[ "$fail" -eq 0 ]
