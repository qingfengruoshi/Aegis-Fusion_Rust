#!/usr/bin/env bash
# 差分测试：把同一批 fixture 喂给 shell 版 keybox-check.sh 与 Rust 版 fusionctl，
# 逐项比较「退出码 + stdout」。任何不一致都是重写引入的行为差异。
#
# Run: bash scripts/test-diff-keybox-check.sh
# 需要先构建 Rust 二进制：cargo +stable-x86_64-pc-windows-gnu build --release
#   （见 rust/fusionctl/）
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_CHK="$ROOT/module/keybox-check.sh"
RUST_BIN="$ROOT/rust/fusionctl/target/release/fusionctl.exe"
FIX="$ROOT/build/diff-keybox-check"

pass=0; fail=0; total=0

# --- 生成 fixture ------------------------------------------------------------
# emit_keybox <out> <algo> <ncerts> <cert-body>
#   body 用合成 base64（无真实密钥材料），与 shell 线 test-keybox-check.sh 同一约定
emit_keybox() {
    local out="$1" algo="$2" n="$3" body="$4" i
    printf '<Keybox DeviceID="suite">\n' > "$out"
    printf '  <Key algorithm="%s">\n' "$algo" >> "$out"
    for ((i = 1; i <= n; i++)); do
        printf '    <Certificate>\n%s\n    </Certificate>\n' "$body" >> "$out"
    done
    printf '  </Key>\n</Keybox>\n' >> "$out"
}

OK8='QUJDREVG'          # 8 字符，无填充
mkdir -p "$FIX"
rm -f "$FIX"/*.xml "$FIX"/* 2>/dev/null

# 1 合法：rsa + 2 证书
emit_keybox "$FIX/valid_rsa2.xml" rsa 2 "$OK8"
# 2 合法：ecdsa + 3 证书
emit_keybox "$FIX/valid_ecdsa3.xml" ecdsa 3 "$OK8"
# 3 链太短：rsa + 1 证书
emit_keybox "$FIX/chain_short.xml" rsa 1 "$OK8"
# 4 非法算法：ed25519 + 2 证书
emit_keybox "$FIX/unknown_algo.xml" ed25519 2 "$OK8"
# 5 混合：rsa(2, 可用) + ed25519(2, 警告)
{ printf '<Keybox DeviceID="suite">\n'
  printf '  <Key algorithm="rsa">\n    <Certificate>\n%s\n    </Certificate>\n    <Certificate>\n%s\n    </Certificate>\n  </Key>\n' "$OK8" "$OK8"
  printf '  <Key algorithm="ed25519">\n    <Certificate>\n%s\n    </Certificate>\n    <Certificate>\n%s\n    </Certificate>\n  </Key>\n' "$OK8" "$OK8"
  printf '</Keybox>\n'; } > "$FIX/mixed_algo.xml"
# 6 无 <Key> 元素
printf '<Keybox DeviceID="suite">\n<Keybox>\n' > "$FIX/no_key.xml"
# 7 无根元素
printf '<Foo>\n</Foo>\n' > "$FIX/no_root.xml"
# 8 根元素未闭合
printf '<Keybox DeviceID="suite">\n' > "$FIX/unclosed_root.xml"
# 9 HTML 页（下载失败存成 .xml）
printf '<!DOCTYPE html>\n<html><body>Not Found</body></html>\n' > "$FIX/html.xml"
# 10 空 <Certificate> 体（audit 的 n==0 分支）
{ printf '<Keybox DeviceID="suite">\n  <Key algorithm="rsa">\n'
  printf '    <Certificate>\n\n    </Certificate>\n    <Certificate>\n%s\n    </Certificate>\n' "$OK8"
  printf '  </Key>\n</Keybox>\n'; } > "$FIX/empty_body.xml"
# 11 InvalidLength：体长不是 4 的倍数
emit_keybox "$FIX/bad_len.xml" rsa 2 'QUJ'          # 3 字符
# 12 内嵌 "="（不在最后一组）
emit_keybox "$FIX/interior_eq.xml" rsa 2 'QUJ=REVH'  # 8 字符，= 在 idx 3
# 13 非 base64 字符
emit_keybox "$FIX/non_b64.xml" rsa 2 'QU!DREVH'      # idx 2 是 '!'
# 14 填充后仍有数据
emit_keybox "$FIX/after_pad.xml" rsa 2 'QU==REVH'    # = 之后还有数据
# 15 合法 + 每证书一个 <CertificateChain> 包裹（考察 find_cert 的前缀排除）
{ printf '<Keybox DeviceID="suite">\n  <Key algorithm="rsa">\n'
  printf '    <CertificateChain>\n    <Certificate>\n%s\n    </Certificate>\n    <Certificate>\n%s\n    </Certificate>\n    </CertificateChain>\n  </Key>\n' "$OK8" "$OK8"
  printf '</Keybox>\n'; } > "$FIX/chain_wrap.xml"
# 16 空文件
: > "$FIX/empty.xml"
# 17 PEM 壳包裹（decode_pem 的 armor 跳过路径）
{ printf '<Keybox DeviceID="suite">\n  <Key algorithm="rsa">\n'
  printf '    <Certificate>\n-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n    </Certificate>\n    <Certificate>\n%s\n    </Certificate>\n  </Key>\n' "$OK8" "$OK8"
  printf '</Keybox>\n'; } > "$FIX/pem_armor.xml"
# 18 CRLF 行尾（Windows 编辑过的 keybox）
sed 's/$/\r/' "$FIX/valid_rsa2.xml" > "$FIX/crlf.xml"

# --- 差分运行器 ---------------------------------------------------------------
run_both() {
    local name="$1"
    local f="$FIX/$name"
    local q="${2:-}"
    local s_out s_rc r_out r_rc
    # 保护性超时：任何一侧挂起都视为该 case 失败，而不是拖垮整个套件
    s_out=$(timeout 30 sh "$SHELL_CHK" "$f" $q 2>/dev/null); s_rc=$?
    # Rust 二进制是原生 Windows 程序：MSYS 的 /d/... 路径它解析不了，
    # 必须先转成 Windows 形式（与 shell 线 assemble.sh 的 cygpath 用法同源）。
    local rf
    rf=$(cygpath -m "$f" 2>/dev/null || echo "$f")
    r_out=$(timeout 30 "$RUST_BIN" keybox-check "$rf" $q 2>/dev/null); r_rc=$?
    # 归一化：错误信息里会回显传入的路径，Windows 形式（D:/...）与 POSIX 形式
    # （/d/...）不一致 —— 这只发生在宿主测试里，Android 上不存在（Linux 路径）。
    # 所以对比前把 Rust 输出里的路径形式换回 POSIX 形式。
    r_out="${r_out//$rf/$f}"
    total=$((total + 1))
    if [ "$s_out" = "$r_out" ] && [ "$s_rc" = "$r_rc" ]; then
        pass=$((pass + 1))
        echo "  PASS  $name (rc=$s_rc)"
        return 0
    fi
    fail=$((fail + 1))
    echo "  FAIL  $name"
    [ "$s_rc" != "$r_rc" ] && echo "          rc:   shell=$s_rc  rust=$r_rc"
    if [ "$s_out" != "$r_out" ]; then
        echo "          --- diff (shell ← / rust →) ---"
        diff <(printf '%s\n' "$s_out") <(printf '%s\n' "$r_out") 2>/dev/null \
            | head -14 | sed 's/^/          /'
    fi
    return 1
}

echo "== 差分：keybox-check（shell vs Rust）=="
run_both valid_rsa2.xml
run_both valid_ecdsa3.xml
run_both chain_short.xml
run_both unknown_algo.xml
run_both mixed_algo.xml
run_both no_key.xml
run_both no_root.xml
run_both unclosed_root.xml
run_both html.xml
run_both empty_body.xml
run_both bad_len.xml
run_both interior_eq.xml
run_both non_b64.xml
run_both after_pad.xml
run_both chain_wrap.xml
run_both pem_armor.xml
run_both crlf.xml
run_both "empty.xml"
run_both missing_really_absent.xml      # 文件不存在 → rc=2
run_both valid_rsa2.xml --quiet          # --quiet：好 keybox 应零输出

echo
echo "== 结果：$pass/$total 一致，$fail 处差异 =="
[ "$fail" -eq 0 ] || exit 1
