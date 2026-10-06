#include "glyph.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: CHECK(%s) w=%d h=%d\n", __FILE__, __LINE__, #cond, w, h);      \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

enum { MAXPX = 64 * 64 };

typedef struct {
    uint8_t px[MAXPX];
} img;

static img draw(uint32_t cp, int w, int h) {
    img m;
    memset(&m, 0, sizeof(m));
    if (!glyph_draw(cp, w, h, m.px)) {
        fprintf(stderr, "glyph_draw(U+%04X) refused\n", (unsigned)cp);
        exit(1);
    }
    return m;
}

/* Ink pattern of one column (or row) as a bitmask of lit pixels: what a
   neighbour cell has to continue for the line to look unbroken. */
static uint64_t column(const img *m, int w, int h, int x) {
    uint64_t bits = 0;
    for (int y = 0; y < h; y++) {
        if (m->px[(y * w) + x] >= 128) {
            bits |= 1ULL << (unsigned)y;
        }
    }
    return bits;
}

static uint64_t row(const img *m, int w, int y) {
    uint64_t bits = 0;
    for (int x = 0; x < w; x++) {
        if (m->px[(y * w) + x] >= 128) {
            bits |= 1ULL << (unsigned)x;
        }
    }
    return bits;
}

static int all(const img *m, int n, uint8_t v) {
    for (int i = 0; i < n; i++) {
        if (m->px[i] != v) {
            return 0;
        }
    }
    return 1;
}

static int complement(const img *a, const img *b, int n) {
    for (int i = 0; i < n; i++) {
        if (a->px[i] + b->px[i] != 255) {
            return 0;
        }
    }
    return 1;
}

static void check_size(int w, int h) {
    int n = w * h;
    img full = draw(0x2588, w, h);
    CHECK(all(&full, n, 255));
    img upper = draw(0x2580, w, h);
    img lower = draw(0x2584, w, h);
    CHECK(complement(&upper, &lower, n));
    img left = draw(0x258C, w, h);
    img right = draw(0x2590, w, h);
    CHECK(complement(&left, &right, n));
    img ll = draw(0x2596, w, h);
    for (int i = 0; i < n; i++) {
        int both = left.px[i] == 255 && lower.px[i] == 255;
        CHECK((ll.px[i] == 255) == both);
    }
    img shade = draw(0x2591, w, h);
    CHECK(all(&shade, n, 64));

    /* straight lines continue across cell borders */
    img hline = draw(0x2500, w, h);
    img vline = draw(0x2502, w, h);
    uint64_t hrows = column(&hline, w, h, 0);
    uint64_t vcols = row(&vline, w, 0);
    CHECK(hrows != 0 && vcols != 0);
    CHECK(column(&hline, w, h, w - 1) == hrows);
    CHECK(row(&vline, w, h - 1) == vcols);
    uint32_t joins[] = {0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C};
    for (size_t i = 0; i < sizeof(joins) / sizeof(joins[0]); i++) {
        img j = draw(joins[i], w, h);
        uint64_t l = column(&j, w, h, 0);
        uint64_t r = column(&j, w, h, w - 1);
        uint64_t t = row(&j, w, 0);
        uint64_t b = row(&j, w, h - 1);
        CHECK(l == 0 || l == hrows);
        CHECK(r == 0 || r == hrows);
        CHECK(t == 0 || t == vcols);
        CHECK(b == 0 || b == vcols);
    }

    /* double lines: ═ ║ continue into ╔ ╗ ╚ ╝ ╬ */
    img dh = draw(0x2550, w, h);
    img dv = draw(0x2551, w, h);
    uint64_t drows = column(&dh, w, h, 0);
    uint64_t dcols = row(&dv, w, 0);
    CHECK(column(&dh, w, h, w - 1) == drows);
    uint32_t dj[] = {0x2554, 0x2557, 0x255A, 0x255D, 0x256C, 0x2560, 0x2563, 0x2566, 0x2569};
    for (size_t i = 0; i < sizeof(dj) / sizeof(dj[0]); i++) {
        img j = draw(dj[i], w, h);
        uint64_t l = column(&j, w, h, 0);
        uint64_t r = column(&j, w, h, w - 1);
        uint64_t t = row(&j, w, 0);
        uint64_t b = row(&j, w, h - 1);
        CHECK(l == 0 || l == drows);
        CHECK(r == 0 || r == drows);
        CHECK(t == 0 || t == dcols);
        CHECK(b == 0 || b == dcols);
    }

    /* rounded corner ╭ meets │ below and ─ to the right */
    img arc = draw(0x256D, w, h);
    CHECK(row(&arc, w, h - 1) == vcols);
    CHECK(column(&arc, w, h, w - 1) == hrows);
    CHECK(row(&arc, w, 0) == 0);

    img dot = draw(0x2801, w, h);
    int lit = 0;
    for (int i = 0; i < n; i++) {
        lit += dot.px[i] == 255;
    }
    CHECK(lit > 0);
    img pl = draw(0xE0B0, w, h);
    CHECK(pl.px[(h / 2) * w] == 255 && pl.px[w - 1] == 0);
}

int main(void) {
    int w = 0;
    int h = 0;
    uint8_t px[4];
    CHECK(glyph_draw('A', 2, 2, px) == 0);
    CHECK(glyph_is_graphic(0x2588) && !glyph_is_graphic(0x2600));
    for (w = 5; w <= 40; w++) {
        for (h = 10; h <= 64 && w * h <= MAXPX; h += 3) {
            check_size(w, h);
        }
    }
    if (failures > 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
