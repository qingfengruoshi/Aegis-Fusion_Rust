/* pm 桩（测试夹具）—— 差分测试用。
 *
 * ★ 必须编译成 .exe：Rust 通过 CreateProcess 调它（Windows 只执行带 .exe
 *   扩展名的程序）；shell 版也调它（MSYS 的 sh 能执行 .exe）。
 * 行为（由 $PM_FIXTURE 提供 canonical 的 `package:xxx` 列表）：
 *   pm list packages   → 原样输出该文件
 *   pm path <pkg>      → 列表里含 package:<pkg> 则输出并 exit 0，否则 exit 1
 * 编译：gcc -O1 -o pm.exe pm_stub.c
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static char line[1024];

int main(int argc, char **argv) {
    const char *fx = getenv("PM_FIXTURE");
    if (!fx) return 1;
    if (argc >= 3 && !strcmp(argv[1], "list") && !strcmp(argv[2], "packages")) {
        FILE *f = fopen(fx, "rb");
        if (f) { size_t n; while ((n = fread(line, 1, sizeof line, f)) > 0) fwrite(line, 1, n, stdout); fclose(f); }
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "path")) {
        char want[512];
        snprintf(want, sizeof want, "package:%s", argv[2]);
        FILE *f = fopen(fx, "rb");
        if (f) {
            while (fgets(line, sizeof line, f)) {
                line[strcspn(line, "\r\n")] = 0;
                if (!strcmp(line, want)) { printf("%s\n", want); fclose(f); return 0; }
            }
            fclose(f);
        }
        return 1;
    }
    return 1;
}
