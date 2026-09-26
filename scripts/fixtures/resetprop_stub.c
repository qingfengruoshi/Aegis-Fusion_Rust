/* resetprop 桩（测试夹具）—— 差分测试用。
 *
 * 行为：状态存 $RESETPROP_STATE（key=value 行），调用记到 $RESETPROP_LOG。
 *   resetprop <name>                → 打印值（无则空）
 *   resetprop -n <name> <value>     → 覆盖/追加
 *   resetprop --delete <name>       → 删除
 *
 * ★ 先整体读入内存、关闭，再写回 —— 不能边读边截断同一个文件（那会把上一条
 *   属性抹掉，导致后续的 if_diff 看到缺失而按 audit N16 语义跳过）。
 * ★ 全部用二进制模式（"rb"/"wb"/"ab"）—— Windows 文本模式会把 \n 写成 CRLF，
 *   污染比较。
 * 编译：gcc -O1 -o resetprop.exe resetprop.c
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* 从 buf 里滤掉 name=... 的行，返回重建后的内容（调用者 free） */
static char *filter_lines(const char *buf, const char *name) {
    size_t nl = strlen(name);
    char *out = malloc(strlen(buf) + 2);
    size_t o = 0;
    const char *line = buf;
    while (line && *line) {
        const char *eol = strchr(line, '\n');
        size_t len = eol ? (size_t)(eol - line) : strlen(line);
        int drop = (len == nl && strncmp(line, name, nl) == 0)
                || (len > nl && strncmp(line, name, nl) == 0 && line[nl] == '=');
        if (!drop) {
            memcpy(out + o, line, len);
            o += len;
            out[o++] = '\n';
        }
        line = eol ? eol + 1 : NULL;
    }
    out[o] = 0;
    return out;
}

static char *read_all(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    size_t got = fread(buf, 1, sz, f);
    buf[got] = 0;
    fclose(f);
    return buf;
}

static void write_all(const char *path, const char *data) {
    FILE *f = fopen(path, "wb");
    if (f) { fputs(data, f); fclose(f); }
}

int main(int argc, char **argv) {
    const char *st = getenv("RESETPROP_STATE");
    const char *lg = getenv("RESETPROP_LOG");
    if (!st || !lg) return 0;
    FILE *lf = fopen(lg, "ab");
    if (!lf) return 0;
    /* 无参数 = 列出全部（service.sh 的构建信号遍历用） */
    if (argc < 2) {
        /* 真机 resetprop（无参数）只输出【属性名】，不含 =value */
        char l2[1024];
        FILE *f = fopen(st, "rb");
        if (f) { while (fgets(l2, sizeof l2, f)) { char *eq = strchr(l2, '='); if (eq) *eq = 0; fputs(l2, stdout); } fclose(f); }
        fclose(lf);
        return 0;
    }
    if (!strcmp(argv[1], "-c")) { fprintf(lf, "clear\n"); fclose(lf); return 0; }
    if (!strcmp(argv[1], "-Z") && argc >= 3) {
        printf("u:object_r:default_prop:s0\n");
        fprintf(lf, "ctx  %s\n", argv[2]);
        fclose(lf);
        return 0;
    }
    if (!strcmp(argv[1], "-p") && argc >= 2) {
        /* 持久化前缀：-p --delete <name> / -p <name>(读) 交给下方递归处理不便，
           这里直接记录并按语义处理 */
        if (argc >= 4 && !strcmp(argv[2], "--delete")) {
            FILE *in = fopen(st, "rb"), *out = fopen(st, "wb");
            char l2[1024]; size_t nl = strlen(argv[3]);
            if (in) { while (fgets(l2, sizeof l2, in))
                if (strncmp(l2, argv[3], nl) || l2[nl] != '=') fputs(l2, out);
                fclose(in); }
            fclose(out);
            fprintf(lf, "pdel %s\n", argv[3]);
            fclose(lf);
            return 0;
        }
        if (argc >= 4) {
            FILE *sf = fopen(st, "ab");
            if (sf) { fprintf(sf, "%s=%s\n", argv[2], argv[3]); fclose(sf); }
            fprintf(lf, "pset %s=%s\n", argv[2], argv[3]);
            fclose(lf);
            return 0;
        }
        /* -p <name>（读）：缺失同样返回非零 */
        {
            int found = 0;
            FILE *f = fopen(st, "rb");
            char l2[1024]; size_t nl = strlen(argv[2]);
            if (f) { while (fgets(l2, sizeof l2, f))
                if (!strncmp(l2, argv[2], nl) && l2[nl] == '=') { fputs(l2 + nl + 1, stdout); found = 1; }
                fclose(f); }
            fprintf(lf, "pget %s\n", argv[2]);
            fclose(lf);
            return found ? 0 : 1;
        }
    }

    if (!strcmp(argv[1], "-n") && argc >= 4) {
        char *old = read_all(st);
        char *nw = filter_lines(old ? old : "", argv[2]);
        write_all(st, nw);
        FILE *sf = fopen(st, "ab");
        if (sf) { fprintf(sf, "%s=%s\n", argv[2], argv[3]); fclose(sf); }
        fprintf(lf, "set  %s=%s\n", argv[2], argv[3]);
        free(old); free(nw);
    } else if (!strcmp(argv[1], "--delete") && argc >= 3) {
        char *old = read_all(st);
        char *nw = filter_lines(old ? old : "", argv[2]);
        write_all(st, nw);
        fprintf(lf, "del  %s\n", argv[2]);
        free(old); free(nw);
    } else {
        char *buf = read_all(st);
        size_t nl = strlen(argv[1]);
        int found = 0;
        if (buf) {
            const char *line = buf;
            while (line && *line) {
                const char *eol = strchr(line, '\n');
                size_t len = eol ? (size_t)(eol - line) : strlen(line);
                if (len > nl && strncmp(line, argv[1], nl) == 0 && line[nl] == '=') {
                    fwrite(line + nl + 1, 1, len - nl - 1, stdout), fputc('\n', stdout);
                    found = 1;
                }
                line = eol ? eol + 1 : NULL;
            }
        }
        fprintf(lf, "get  %s\n", argv[1]);
        fclose(lf);
        return found ? 0 : 1;
        free(buf);
    }
    fclose(lf);
    return 0;
}
