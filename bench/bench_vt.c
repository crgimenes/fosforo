#include "vt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { TOTAL = 64 * 1024 * 1024, CHUNK = 64 * 1024 };

typedef struct {
    uint8_t *data;
    size_t len;
} corpus;

static void append(corpus *c, const char *s) {
    size_t n = strlen(s);
    if (c->len + n > TOTAL) {
        return;
    }
    memcpy(c->data + c->len, s, n);
    c->len += n;
}

static corpus make(int kind) {
    corpus c = {malloc(TOTAL), 0};
    char line[256];
    unsigned i = 0;
    while (c.len + sizeof(line) < TOTAL) {
        switch (kind) {
        case 0:
            snprintf(line, sizeof(line),
                     "%08u the quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJ\r\n",
                     i);
            break;
        case 1:
            snprintf(
                line, sizeof(line),
                "\x1b[38;5;%um%u \x1b[1;38;2;%u;%u;%umbold\x1b[0m \x1b[4;44mcolored\x1b[m text\r\n",
                i % 256, i, i % 256, (i * 7) % 256, (i * 13) % 256);
            break;
        case 3: /* yes through a tty: a scroll for every two bytes */
            snprintf(line, sizeof(line), "y\r\n");
            break;
        default:
            snprintf(line, sizeof(line),
                     "%u ação coração não é \xe4\xb8\xad\xe6\x96\x87 \xf0\x9f\x98\x80 "
                     "\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90\r\n",
                     i);
            break;
        }
        append(&c, line);
        i++;
    }
    return c;
}

static double seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void run(const char *name, int kind) {
    corpus c = make(kind);
    vt *t = vt_new(50, 200, 10000, NULL);
    double start = seconds();
    for (size_t off = 0; off < c.len; off += CHUNK) {
        size_t n = c.len - off < CHUNK ? c.len - off : CHUNK;
        vt_write(t, c.data + off, n);
    }
    double dt = seconds() - start;
    printf("%-8s %6.1f MB in %.3fs = %7.1f MB/s\n", name, (double)c.len / 1e6, dt,
           (double)c.len / 1e6 / dt);
    vt_free(t);
    free(c.data);
}

int main(void) {
    run("ascii", 0);
    run("sgr", 1);
    run("utf8", 2);
    run("short", 3);
    return 0;
}
