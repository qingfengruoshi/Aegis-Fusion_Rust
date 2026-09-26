#!/usr/bin/env python3
"""apps-sync 差分比较器（**语义级**，用 JSON 解析）。

用法：compare_apps.py <shell-config> <rust-config>
判定：两边的 config.json 都必须是合法 JSON，且**解析出的对象完全相等**。
理由（契约 §12.2 / §3.11）：ConfigStore 只要求合法 JSON；两个实现的插入
格式（空白/换行）本来就可能不同，字节等价是错误的判据；**语义等价**
（解析出的 apps 数组、autoIncludeNewApps 等字段一致）才是契约要求的。
"""
import json
import sys


def diff_obj(a, b, path=""):
    """递归找两个 dict/list 的差异，返回人读的描述列表。"""
    out = []
    if type(a) is not type(b):
        out.append(f"{path}: 类型不同 {type(a).__name__} vs {type(b).__name__} ({a!r} vs {b!r})")
        return out
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"{path}.{k}: 只在 rust 侧 ({b[k]!r})")
            elif k not in b:
                out.append(f"{path}.{k}: 只在 shell 侧 ({a[k]!r})")
            else:
                out.extend(diff_obj(a[k], b[k], f"{path}.{k}"))
    elif isinstance(a, list):
        if a != b:
            out.append(f"{path}: 列表不同\n    shell={a}\n    rust ={b}")
    elif a != b:
        out.append(f"{path}: {a!r} vs {b!r}")
    return out


def main():
    shell_p, rust_p = sys.argv[1], sys.argv[2]
    try:
        s = json.load(open(shell_p, encoding="utf-8"))
    except Exception as e:
        print(f"DIFF\n  shell 侧不是合法 JSON: {e}")
        sys.exit(1)
    try:
        r = json.load(open(rust_p, encoding="utf-8"))
    except Exception as e:
        print(f"DIFF\n  rust 侧不是合法 JSON: {e}")
        sys.exit(1)

    problems = diff_obj(s, r)
    if problems:
        print("DIFF")
        for p in problems:
            print("  " + p)
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    main()
