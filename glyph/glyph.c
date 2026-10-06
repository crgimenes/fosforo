#include "glyph.h"

#include "box_table.h"

#include <math.h>
#include <string.h>

#define BOX_DASH (1U << 8U) /* yagni: dashed lines drawn solid */
#define BOX_ARC (1U << 9U)
#define BOX_RISING (1U << 10U)
#define BOX_FALLING (1U << 11U)

enum {
    ARM_UP = 0,
    ARM_RIGHT = 1,
    ARM_DOWN = 2,
    ARM_LEFT = 3,
    W_NONE = 0,
    W_LIGHT = 1,
    W_HEAVY = 2,
    W_DOUBLE = 3,
};

typedef struct {
    uint8_t *px;
    int w;
    int h;
} canvas;

static void rect(const canvas *c, int x0, int y0, int x1, int y1, uint8_t v) {
    x0 = x0 < 0 ? 0 : x0;
    y0 = y0 < 0 ? 0 : y0;
    x1 = x1 > c->w ? c->w : x1;
    y1 = y1 > c->h ? c->h : y1;
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            uint8_t *p = &c->px[(y * c->w) + x];
            if (v > *p) {
                *p = v;
            }
        }
    }
}

/* From the narrow side: a double band (3 lines) must fit a short cell too. */
static int light_width(int w, int h) {
    int side = w < h / 2 ? w : h / 2;
    int t = (side + 4) / 8;
    return t < 1 ? 1 : t;
}

static int thickness(int weight, int lt) {
    if (weight == W_HEAVY) {
        return lt * 2;
    }
    if (weight == W_DOUBLE) {
        return lt * 3;
    }
    return lt;
}

static int arm(uint16_t e, int d) {
    return (int)(((uint32_t)e >> (uint32_t)(2 * d)) & 3U);
}

/* Band thickness where arms meet: the widest arm crossing in that axis. */
static int junction(uint16_t e, int a, int b, int lt) {
    int ta = thickness(arm(e, a), lt);
    int tb = thickness(arm(e, b), lt);
    return ta > tb ? ta : tb;
}

static void single_arm(const canvas *c, int d, int t, int tv, int th) {
    int w = c->w;
    int h = c->h;
    int x0 = (w - t) / 2;
    int y0 = (h - t) / 2;
    int jx = (w - tv) / 2; /* vertical band where horizontal arms end */
    int jy = (h - th) / 2;
    switch (d) {
    case ARM_UP:
        rect(c, x0, 0, x0 + t, jy + th, 255);
        break;
    case ARM_DOWN:
        rect(c, x0, jy, x0 + t, h, 255);
        break;
    case ARM_LEFT:
        rect(c, 0, y0, jx + tv, y0 + t, 255);
        break;
    default:
        rect(c, jx, y0, w, y0 + t, 255);
        break;
    }
}

/* Double arms: the line on the side of a perpendicular arm stops at the
   inner corner, the other runs to the outer one, which is what nests the
   corners of ╔ ╬ ╠ instead of crossing them. */
static void double_arm(const canvas *c, uint16_t e, int d, int lt) {
    int w = c->w;
    int h = c->h;
    int x0 = (w - (3 * lt)) / 2;
    int y0 = (h - (3 * lt)) / 2;
    int up = arm(e, ARM_UP) != W_NONE;
    int down = arm(e, ARM_DOWN) != W_NONE;
    int left = arm(e, ARM_LEFT) != W_NONE;
    int right = arm(e, ARM_RIGHT) != W_NONE;
    switch (d) {
    case ARM_UP:
        rect(c, x0, 0, x0 + lt, left ? y0 + lt : y0 + (3 * lt), 255);
        rect(c, x0 + (2 * lt), 0, x0 + (3 * lt), right ? y0 + lt : y0 + (3 * lt), 255);
        break;
    case ARM_DOWN:
        rect(c, x0, left ? y0 + (2 * lt) : y0, x0 + lt, h, 255);
        rect(c, x0 + (2 * lt), right ? y0 + (2 * lt) : y0, x0 + (3 * lt), h, 255);
        break;
    case ARM_LEFT:
        rect(c, 0, y0, up ? x0 + lt : x0 + (3 * lt), y0 + lt, 255);
        rect(c, 0, y0 + (2 * lt), down ? x0 + lt : x0 + (3 * lt), y0 + (3 * lt), 255);
        break;
    default:
        rect(c, up ? x0 + (2 * lt) : x0, y0, w, y0 + lt, 255);
        rect(c, down ? x0 + (2 * lt) : x0, y0 + (2 * lt), w, y0 + (3 * lt), 255);
        break;
    }
}

/* Antialiased stroke of width t along segment a-b: coverage falls off over
   one pixel from the stroke edge, so an axis-aligned stroke of integer
   width centred on a band lands exactly on the band's pixels. */
static void segment(const canvas *c, double ax, double ay, double bx, double by, double t) {
    double dx = bx - ax;
    double dy = by - ay;
    double len2 = (dx * dx) + (dy * dy);
    for (int y = 0; y < c->h; y++) {
        for (int x = 0; x < c->w; x++) {
            double px = x + 0.5;
            double py = y + 0.5;
            double k = len2 > 0 ? (((px - ax) * dx) + ((py - ay) * dy)) / len2 : 0;
            if (k < 0) {
                k = 0;
            }
            if (k > 1) {
                k = 1;
            }
            double ex = px - (ax + (k * dx));
            double ey = py - (ay + (k * dy));
            double cov = (t / 2) + 0.5 - sqrt((ex * ex) + (ey * ey));
            if (cov > 0) {
                rect(c, x, y, x + 1, y + 1, (uint8_t)(cov >= 1 ? 255 : cov * 255));
            }
        }
    }
}

static const double half_pi = 1.57079632679489661923;

/* Rounded corner: a quarter circle joining the two arms, radius half the
   narrow side, straight runs out to the cell edges. */
static void arc(const canvas *c, uint16_t e, int lt) {
    int band_x = (c->w - lt) / 2; /* the straight lines' pixel band */
    int band_y = (c->h - lt) / 2;
    double cx = band_x + (lt / 2.0);
    double cy = band_y + (lt / 2.0);
    double r = (c->w < c->h ? c->w : c->h) / 2.0;
    double sx = arm(e, ARM_RIGHT) != W_NONE ? 1 : -1;
    double sy = arm(e, ARM_DOWN) != W_NONE ? 1 : -1;
    double ox = cx + (sx * r);
    double oy = cy + (sy * r);
    enum { STEPS = 16 };
    double px = cx;
    double py = oy;
    for (int i = 1; i <= STEPS; i++) {
        double a = half_pi * i / (double)STEPS;
        double qx = ox - (sx * r * cos(a));
        double qy = oy - (sy * r * sin(a));
        segment(c, px, py, qx, qy, lt);
        px = qx;
        py = qy;
    }
    segment(c, cx, oy, cx, sy > 0 ? c->h + 1.0 : -1.0, lt);
    segment(c, ox, cy, sx > 0 ? c->w + 1.0 : -1.0, cy, lt);
}

static void box(const canvas *c, uint16_t e) {
    int lt = light_width(c->w, c->h);
    if ((e & (BOX_RISING | BOX_FALLING)) != 0) {
        if ((e & BOX_RISING) != 0) {
            segment(c, c->w, 0, 0, c->h, lt);
        }
        if ((e & BOX_FALLING) != 0) {
            segment(c, 0, 0, c->w, c->h, lt);
        }
        return;
    }
    if ((e & BOX_ARC) != 0) {
        arc(c, e, lt);
        return;
    }
    int tv = junction(e, ARM_UP, ARM_DOWN, lt);
    int th = junction(e, ARM_LEFT, ARM_RIGHT, lt);
    for (int d = ARM_UP; d <= ARM_LEFT; d++) {
        int wt = arm(e, d);
        if (wt == W_DOUBLE) {
            double_arm(c, e, d, lt);
            continue;
        }
        if (wt != W_NONE) {
            single_arm(c, d, thickness(wt, lt), tv == 0 ? lt : tv, th == 0 ? lt : th);
        }
    }
}

static int eighths(int n, int k) {
    return ((n * k) + 4) / 8;
}

static void quadrants(const canvas *c, int ul, int ur, int ll, int lr) {
    int mx = eighths(c->w, 4);
    int my = c->h - eighths(c->h, 4);
    if (ul) {
        rect(c, 0, 0, mx, my, 255);
    }
    if (ur) {
        rect(c, mx, 0, c->w, my, 255);
    }
    if (ll) {
        rect(c, 0, my, mx, c->h, 255);
    }
    if (lr) {
        rect(c, mx, my, c->w, c->h, 255);
    }
}

static void block(const canvas *c, uint32_t cp) {
    int w = c->w;
    int h = c->h;
    /* quadrant bits for U+2596..259F: ul, ur, ll, lr */
    static const uint8_t quads[10] = {0x2, 0x1, 0x8, 0xB, 0x9, 0xE, 0xD, 0x4, 0x6, 0x7};
    if (cp == 0x2580) {
        rect(c, 0, 0, w, h - eighths(h, 4), 255);
    } else if (cp >= 0x2581 && cp <= 0x2588) {
        rect(c, 0, h - eighths(h, (int)(cp - 0x2580)), w, h, 255);
    } else if (cp >= 0x2589 && cp <= 0x258F) {
        rect(c, 0, 0, eighths(w, (int)(0x2590 - cp)), h, 255);
    } else if (cp == 0x2590) {
        rect(c, eighths(w, 4), 0, w, h, 255);
    } else if (cp >= 0x2591 && cp <= 0x2593) {
        rect(c, 0, 0, w, h, (uint8_t)(64 * (cp - 0x2590)));
    } else if (cp == 0x2594) {
        rect(c, 0, 0, w, eighths(h, 1), 255);
    } else if (cp == 0x2595) {
        rect(c, w - eighths(w, 1), 0, w, h, 255);
    } else {
        uint8_t q = quads[cp - 0x2596];
        quadrants(c, (q & 8U) != 0, (q & 4U) != 0, (q & 2U) != 0, (q & 1U) != 0);
    }
}

static void braille(const canvas *c, uint32_t cp) {
    static const int col[8] = {0, 0, 0, 1, 1, 1, 0, 1};
    static const int row[8] = {0, 1, 2, 0, 1, 2, 3, 3};
    uint32_t bits = cp - 0x2800;
    int s = c->w / 4;
    s = s < 1 ? 1 : s;
    for (int i = 0; i < 8; i++) {
        if ((bits & (1U << (uint32_t)i)) == 0) {
            continue;
        }
        int x = ((c->w * ((2 * col[i]) + 1)) / 4) - (s / 2);
        int y = ((c->h * ((2 * row[i]) + 1)) / 8) - (s / 2);
        rect(c, x, y, x + s, y + s, 255);
    }
}

static void triangle(const canvas *c, int right) {
    enum { SS = 4 };
    for (int y = 0; y < c->h; y++) {
        for (int x = 0; x < c->w; x++) {
            int in = 0;
            for (int sy = 0; sy < SS; sy++) {
                for (int sx = 0; sx < SS; sx++) {
                    double px = (x + ((sx + 0.5) / (double)SS)) / c->w;
                    double py = (y + ((sy + 0.5) / (double)SS)) / c->h;
                    double reach = 1 - (fabs(py - 0.5) * 2);
                    in += right ? px <= reach : (1 - px) <= reach;
                }
            }
            rect(c, x, y, x + 1, y + 1, (uint8_t)((in * 255) / (SS * SS)));
        }
    }
}

static void powerline(const canvas *c, uint32_t cp) {
    double w = c->w;
    double h = c->h;
    double lt = light_width(c->w, c->h);
    switch (cp) {
    case 0xE0B0:
        triangle(c, 1);
        break;
    case 0xE0B2:
        triangle(c, 0);
        break;
    case 0xE0B1:
        segment(c, 0, 0, w - (lt / 2), h / 2, lt);
        segment(c, w - (lt / 2), h / 2, 0, h, lt);
        break;
    default:
        segment(c, w, 0, lt / 2, h / 2, lt);
        segment(c, lt / 2, h / 2, w, h, lt);
        break;
    }
}

int glyph_is_graphic(uint32_t cp) {
    return (cp >= 0x2500 && cp <= 0x259F) || (cp >= 0x2800 && cp <= 0x28FF) ||
           (cp >= 0xE0B0 && cp <= 0xE0B3);
}

int glyph_draw(uint32_t cp, int w, int h, uint8_t *out) {
    if (!glyph_is_graphic(cp) || w < 1 || h < 1) {
        return 0;
    }
    memset(out, 0, (size_t)w * (size_t)h);
    canvas c = {out, w, h};
    if (cp <= 0x257F) {
        box(&c, box_table[cp - 0x2500]);
    } else if (cp <= 0x259F) {
        block(&c, cp);
    } else if (cp <= 0x28FF) {
        braille(&c, cp);
    } else {
        powerline(&c, cp);
    }
    return 1;
}
