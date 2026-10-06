#include "utf8.h"
#include "vt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char usage[] = "usage: vtdump [-r rows] [-c cols] [-s] [-cp437] [file ...]\n"
                            "\n"
                            "Feeds the bytes of each file (stdin when none, or -) to the fosforo\n"
                            "terminal core and prints the final screen as plain UTF-8 text.\n"
                            "\n"
                            "  -r rows   screen rows (default 25)\n"
                            "  -c cols   screen columns (default 80)\n"
                            "  -s        print the scrollback above the screen too\n"
                            "  -cp437    decode bytes >= 0x80 as IBM PC glyphs (BBS ANSI art)\n"
                            "  -h        this help\n"
                            "\n"
                            "Output: one line per row, trailing blanks trimmed.\n"
                            "Diagnostics go to stderr; exit 1 if any file could not be read.\n"
                            "\n"
                            "example: script -q /dev/null ls -la | vtdump -c 120\n";

static int parse_int(const char *s, int *out) {
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (end == s || *end != '\0' || v < 1 || v > 100000) {
        return -1;
    }
    *out = (int)v;
    return 0;
}

static int feed(vt *t, FILE *f) {
    uint8_t buf[65536];
    for (;;) {
        size_t n = fread(buf, 1, sizeof(buf), f);
        vt_write(t, buf, n);
        uint8_t discard[256];
        while (vt_reply(t, discard, sizeof(discard)) > 0) {
        }
        if (n < sizeof(buf)) {
            return ferror(f) ? -1 : 0;
        }
    }
}

static void print_row(const vt_cell *row, int cols) {
    int end = cols;
    while (end > 0 && (row[end - 1].cp == 0 || row[end - 1].cp == ' ')) {
        end--;
    }
    for (int i = 0; i < end; i++) {
        if ((row[i].flags & VT_CELL_WIDE_TAIL) != 0) {
            continue;
        }
        uint8_t b[UTF8_MAX_BYTES];
        size_t n = utf8_encode(b, row[i].cp == 0 ? ' ' : row[i].cp);
        fwrite(b, 1, n, stdout);
    }
    fputc('\n', stdout);
}

int main(int argc, char **argv) {
    int rows = 25;
    int cols = 80;
    int scrollback = 0;
    int cp437 = 0;
    int i = 1;
    for (; i < argc && argv[i][0] == '-' && argv[i][1] != '\0'; i++) {
        const char *a = argv[i];
        if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
            fputs(usage, stdout);
            return 0;
        }
        if (strcmp(a, "-s") == 0) {
            scrollback = 1;
            continue;
        }
        if (strcmp(a, "-cp437") == 0) {
            cp437 = 1;
            continue;
        }
        int *dst = NULL;
        if (strcmp(a, "-r") == 0) {
            dst = &rows;
        }
        if (strcmp(a, "-c") == 0) {
            dst = &cols;
        }
        if (dst == NULL || i + 1 >= argc || parse_int(argv[i + 1], dst) != 0) {
            fputs(usage, stderr);
            return 2;
        }
        i++;
    }
    vt *t = vt_new(rows, cols, 10000, NULL);
    if (t == NULL) {
        fputs("vtdump: invalid size\n", stderr);
        return 2;
    }
    if (cp437) {
        vt_set_encoding(t, VT_ENCODING_CP437);
    }
    int status = 0;
    if (i == argc && feed(t, stdin) != 0) {
        fputs("vtdump: stdin: read error\n", stderr);
        status = 1;
    }
    for (; i < argc; i++) {
        if (strcmp(argv[i], "-") == 0) {
            if (feed(t, stdin) != 0) {
                fputs("vtdump: stdin: read error\n", stderr);
                status = 1;
            }
            continue;
        }
        FILE *f = fopen(argv[i], "rb");
        if (f == NULL) {
            fputs("vtdump: cannot open ", stderr);
            fputs(argv[i], stderr);
            fputc('\n', stderr);
            status = 1;
            continue;
        }
        if (feed(t, f) != 0) {
            fputs("vtdump: read error on ", stderr);
            fputs(argv[i], stderr);
            fputc('\n', stderr);
            status = 1;
        }
        fclose(f);
    }
    int back = scrollback ? vt_history(t) : 0;
    vt_cell *cells = malloc((size_t)rows * (size_t)cols * sizeof(vt_cell));
    if (cells == NULL) {
        vt_free(t);
        return 1;
    }
    for (; back > 0; back -= rows) {
        vt_copy_screen(t, back, cells);
        int n = back < rows ? back : rows;
        for (int r = 0; r < n; r++) {
            print_row(cells + ((size_t)r * (size_t)cols), cols);
        }
    }
    vt_copy_screen(t, 0, cells);
    for (int r = 0; r < rows; r++) {
        print_row(cells + ((size_t)r * (size_t)cols), cols);
    }
    free(cells);
    vt_free(t);
    return status;
}
