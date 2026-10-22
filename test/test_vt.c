#include "grid.h"
#include "utf8.h"
#include "vt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond);                      \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

static void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (p == NULL) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return p;
}

static vt *mk(int rows, int cols) {
    vt *t = vt_new(rows, cols, 100, NULL);
    if (t == NULL) {
        fprintf(stderr, "vt_new(%d, %d) failed\n", rows, cols);
        exit(1);
    }
    return t;
}

static void w(vt *t, const char *s) {
    vt_write(t, (const uint8_t *)s, strlen(s));
}

static vt_cell cell(const vt *t, int r, int c) {
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    vt_cell *cells = xmalloc((size_t)rows * (size_t)cols * sizeof(vt_cell));
    vt_copy_screen(t, 0, cells);
    vt_cell out = cells[r * cols + c];
    free(cells);
    return out;
}

/* Row r as UTF-8, trailing blanks trimmed, `back` lines into the scrollback. */
static void row_text_back(const vt *t, int back, int r, char *out, size_t cap) {
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    vt_cell *cells = xmalloc((size_t)rows * (size_t)cols * sizeof(vt_cell));
    vt_copy_screen(t, back, cells);
    const vt_cell *row = cells + (size_t)r * (size_t)cols;
    int end = cols;
    while (end > 0 && row[end - 1].cp == 0) {
        end--;
    }
    size_t n = 0;
    for (int i = 0; i < end; i++) {
        if ((row[i].flags & VT_CELL_WIDE_TAIL) != 0) {
            continue;
        }
        uint8_t b[UTF8_MAX_BYTES];
        size_t k = utf8_encode(b, row[i].cp == 0 ? ' ' : row[i].cp);
        if (n + k + 1 > cap) {
            break;
        }
        memcpy(out + n, b, k);
        n += k;
    }
    out[n] = '\0';
    free(cells);
}

static int row_is(const vt *t, int r, const char *want) {
    char got[1024];
    row_text_back(t, 0, r, got, sizeof(got));
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "  row %d: got \"%s\" want \"%s\"\n", r, got, want);
        return 0;
    }
    return 1;
}

static int back_row_is(const vt *t, int back, int r, const char *want) {
    char got[1024];
    row_text_back(t, back, r, got, sizeof(got));
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "  back %d row %d: got \"%s\" want \"%s\"\n", back, r, got, want);
        return 0;
    }
    return 1;
}

static int reply_is(vt *t, const char *want) {
    uint8_t buf[512];
    size_t n = vt_reply(t, buf, sizeof(buf) - 1);
    buf[n] = '\0';
    if (strcmp((const char *)buf, want) != 0) {
        fprintf(stderr, "  reply: got \"%s\" want \"%s\"\n", (const char *)buf + (n > 0), want + 1);
        return 0;
    }
    return 1;
}

static int cursor_at(const vt *t, int row, int col) {
    vt_cursor c = vt_get_cursor(t);
    if (c.row != row || c.col != col) {
        fprintf(stderr, "  cursor: got %d,%d want %d,%d\n", c.row, c.col, row, col);
        return 0;
    }
    return 1;
}

static void test_text(void) {
    vt *t = mk(5, 10);
    w(t, "hello\r\nworld");
    CHECK(row_is(t, 0, "hello"));
    CHECK(row_is(t, 1, "world"));
    CHECK(cursor_at(t, 1, 5));
    w(t, "\bX\tY");
    CHECK(row_is(t, 1, "worlX   Y"));
    vt_free(t);
}

static void test_deferred_wrap(void) {
    vt *t = mk(3, 5);
    w(t, "abcde");
    CHECK(cursor_at(t, 0, 4));
    CHECK(row_is(t, 1, ""));
    w(t, "\r\nx");
    CHECK(row_is(t, 0, "abcde"));
    CHECK(row_is(t, 1, "x"));
    w(t, "\x1b[H"
         "12345"
         "6");
    CHECK(row_is(t, 0, "12345"));
    CHECK(row_is(t, 1, "6"));
    w(t, "\x1b[?7l\x1b[3;1Habcdefg");
    CHECK(row_is(t, 2, "abcdg"));
    vt_free(t);
}

static void test_wide(void) {
    vt *t = mk(3, 5);
    w(t, "ab\xe4\xb8\xad"
         "c");
    CHECK(row_is(t, 0,
                 "ab\xe4\xb8\xad"
                 "c"));
    CHECK((cell(t, 0, 2).flags & VT_CELL_WIDE) != 0);
    CHECK((cell(t, 0, 3).flags & VT_CELL_WIDE_TAIL) != 0);
    w(t, "\x1b[1;4HZ");
    CHECK(row_is(t, 0, "ab Zc"));
    w(t, "\x1b[2;5H\xe4\xb8\xad");
    CHECK((cell(t, 1, 4).flags & VT_CELL_PAD) != 0);
    CHECK(row_is(t, 2, "\xe4\xb8\xad"));
    vt_free(t);
}

static void test_combining(void) {
    vt *t = mk(2, 10);
    w(t, "c\xcc\xa7"
         "a\xcc\x83"
         "o e\xcc\x81 x\xcc\xb8");
    CHECK(row_is(t, 0, "\xc3\xa7\xc3\xa3o \xc3\xa9 x"));
    w(t, "\r\na\xcc\x82\xcc\x81");
    CHECK(row_is(t, 1, "\xe1\xba\xa5"));
    vt_free(t);
}

static void test_sgr(void) {
    vt *t = mk(2, 20);
    w(t, "\x1b[1;31mA\x1b[22;38;5;196mB\x1b[38;2;1;2;3mC\x1b[38:2::4:5:6mD\x1b[38:2:7:8:9mE");
    w(t, "\x1b[0;4:3;48;5;17;92mF\x1b[24;49;39mG\x1b[38;5m");
    CHECK(cell(t, 0, 0).fg == VT_COLOR_INDEX(1));
    CHECK((cell(t, 0, 0).attr & VT_ATTR_BOLD) != 0);
    CHECK(cell(t, 0, 1).fg == VT_COLOR_INDEX(196));
    CHECK((cell(t, 0, 1).attr & VT_ATTR_BOLD) == 0);
    CHECK(cell(t, 0, 2).fg == VT_COLOR_RGB(1, 2, 3));
    CHECK(cell(t, 0, 3).fg == VT_COLOR_RGB(4, 5, 6));
    CHECK(cell(t, 0, 4).fg == VT_COLOR_RGB(7, 8, 9));
    vt_cell f = cell(t, 0, 5);
    CHECK(((f.attr & VT_ATTR_UL_MASK) >> VT_ATTR_UL_SHIFT) == VT_UL_CURLY);
    CHECK(f.bg == VT_COLOR_INDEX(17));
    CHECK(f.fg == VT_COLOR_INDEX(10));
    vt_cell g = cell(t, 0, 6);
    CHECK(g.attr == 0 && g.fg == VT_COLOR_DEFAULT && g.bg == VT_COLOR_DEFAULT);
    w(t, "\x1b[38;2;999;0;0mH");
    CHECK(cell(t, 0, 7).fg == VT_COLOR_RGB(255, 0, 0));
    vt_free(t);
}

static void test_erase_bce(void) {
    vt *t = mk(3, 6);
    w(t, "aaaaaa\r\nbbbbbb\r\ncccccc");
    w(t, "\x1b[2;3H\x1b[44m\x1b[K");
    CHECK(row_is(t, 1, "bb"));
    CHECK(cell(t, 1, 4).bg == VT_COLOR_INDEX(4));
    w(t, "\x1b[1K");
    CHECK(row_is(t, 1, ""));
    w(t, "\x1b[0m\x1b[1;4H\x1b[1J");
    CHECK(row_is(t, 0, "    aa"));
    w(t, "\x1b[3;2H\x1b[2X");
    CHECK(row_is(t, 2, "c  ccc"));
    w(t, "\x1b[2J");
    CHECK(row_is(t, 0, "") && row_is(t, 2, ""));
    vt_free(t);
}

static void test_region(void) {
    vt *t = mk(5, 10);
    w(t, "1\r\n2\r\n3\r\n4\r\nstatus");
    w(t, "\x1b[1;4r");
    CHECK(cursor_at(t, 0, 0));
    w(t, "\x1b[4;1H\n\n");
    CHECK(row_is(t, 0, "3"));
    CHECK(row_is(t, 1, "4"));
    CHECK(row_is(t, 4, "status"));
    CHECK(vt_history(t) == 0);
    w(t, "\x1b[1;1H\x1bM");
    CHECK(row_is(t, 0, "") && row_is(t, 1, "3") && row_is(t, 4, "status"));
    w(t, "\x1b[r\x1b[5;1H\n");
    CHECK(vt_history(t) == 1);
    CHECK(back_row_is(t, 1, 0, ""));
    vt_free(t);
}

static void test_history_cap(void) {
    vt *t = vt_new(2, 10, 3, NULL);
    for (int i = 0; i < 10; i++) {
        char line[16];
        snprintf(line, sizeof(line), "%d\r\n", i);
        w(t, line);
    }
    CHECK(vt_history(t) == 3);
    CHECK(back_row_is(t, 3, 0, "6"));
    CHECK(row_is(t, 0, "9"));
    CHECK(vt_base(t) == 6); /* "0" to "5" left the ring: "6" is line 0 now */
    w(t, "\x1b[3J");
    CHECK(vt_history(t) == 0);
    CHECK(vt_base(t) == 9);
    vt_free(t);
}

static void test_edit(void) {
    vt *t = mk(4, 8);
    w(t, "abcdef\x1b[1;3H\x1b[2@");
    CHECK(row_is(t, 0, "ab  cdef"));
    w(t, "\x1b[3P");
    CHECK(row_is(t, 0, "abdef"));
    w(t, "\x1b[4hXY\x1b[4l");
    CHECK(row_is(t, 0, "abXYdef"));
    w(t, "\x1b[2;1H1\r\n2\r\n3\x1b[2;1H\x1b[L");
    CHECK(row_is(t, 1, "") && row_is(t, 2, "1") && row_is(t, 3, "2"));
    w(t, "\x1b[2M");
    CHECK(row_is(t, 1, "2") && row_is(t, 2, "") && row_is(t, 0, "abXYdef"));
    w(t, "\x1b[4;1Hz\x1b"
         "b\x1b[3b");
    CHECK(row_is(t, 3, "zzzz"));
    vt_free(t);
}

static void test_alt_screen(void) {
    vt *t = mk(3, 10);
    w(t, "shell$ \x1b[?1049h");
    CHECK((vt_modes(t) & VT_MODE_ALT_SCREEN) != 0);
    CHECK(row_is(t, 0, ""));
    w(t, "\x1b[2;2Hvim\r\n\r\n\n\n");
    CHECK(vt_history(t) == 0);
    w(t, "\x1b[?1049l");
    CHECK(row_is(t, 0, "shell$ "));
    CHECK(cursor_at(t, 0, 7));
    vt_free(t);
}

static void test_charsets(void) {
    vt *t = mk(2, 10);
    w(t, "\x1b(0lqk\x1b(Bq");
    CHECK(row_is(t, 0, "\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90q"));
    w(t, "\r\n\x1b)0a\x0eq\x0fq");
    CHECK(row_is(t, 1, "a\xe2\x94\x80q"));
    vt_free(t);
}

static void test_tabs(void) {
    vt *t = mk(2, 30);
    w(t, "\tA\x1b[3g\x1b[1;5H\x1bH\r\tB");
    CHECK(row_is(t, 0, "    B   A"));
    w(t, "\x1b[1;20H\x1b[Z!");
    CHECK(cursor_at(t, 0, 5));
    vt_free(t);
}

static void test_replies(void) {
    vt *t = mk(24, 80);
    w(t, "\x1b[c");
    CHECK(reply_is(t, "\x1b[?62;22c"));
    w(t, "\x1b[>c");
    CHECK(reply_is(t, "\x1b[>1;10;0c"));
    w(t, "\x1b[5;7H\x1b[6n");
    CHECK(reply_is(t, "\x1b[5;7R"));
    w(t, "\x1b[3;10r\x1b[?6h\x1b[2;2H\x1b[6n\x1b[?6l\x1b[r");
    CHECK(reply_is(t, "\x1b[2;2R"));
    w(t, "\x1b[?2026$p\x1b[?2026h\x1b[?2026$p\x1b[?9999$p");
    CHECK(reply_is(t, "\x1b[?2026;2$y\x1b[?2026;1$y\x1b[?9999;0$y"));
    w(t, "\x1b[>q");
    CHECK(reply_is(t, "\x1bP>|fosforo 0.0\x1b\\"));
    vt_config_color(t, VT_SLOT_BG, 0x102030);
    w(t, "\x1b]11;?\x07\x1b]4;1;?\x1b\\");
    CHECK(reply_is(t, "\x1b]11;rgb:1010/2020/3030\x1b\\\x1b]4;1;rgb:cdcd/0000/0000\x1b\\"));
    w(t, "\x1b[18t");
    CHECK(reply_is(t, "\x1b[8;24;80t"));
    vt_free(t);
}

static void test_osc_colors(void) {
    vt *t = mk(2, 10);
    w(t, "\x1b]4;1;#112233;2;rgb:f/ff/fff\x07");
    CHECK(vt_color(t, 1) == 0x112233);
    CHECK(vt_color(t, 2) == 0xFFFFFF);
    w(t, "\x1b]104;1\x07");
    CHECK(vt_color(t, 1) == 0xCD0000);
    w(t, "\x1b]10;#010203;#040506\x07");
    CHECK(vt_color(t, VT_SLOT_FG) == 0x010203 && vt_color(t, VT_SLOT_BG) == 0x040506);
    w(t, "\x1b]111\x07");
    CHECK(vt_color(t, VT_SLOT_BG) == 0x000000);
    vt_free(t);
}

static uint32_t seen_osc;
static size_t seen_len;

static void on_osc(void *user, uint32_t id, const uint8_t *data, size_t len) {
    (void)user;
    (void)data;
    seen_osc = id;
    seen_len = len;
}

static int bells;

static void on_bell(void *user) {
    (void)user;
    bells++;
}

/* Cmd+K: the cursor's line goes to the top, the rest and the history go. */
static void test_clear_and_bell(void) {
    vt_host host = {NULL, NULL, on_bell};
    vt *t = vt_new(3, 10, 100, &host);
    w(t, "one\r\ntwo\r\nthree\r\nfour\r\n$ ");
    CHECK(vt_history(t) == 2);
    vt_clear(t);
    CHECK(vt_history(t) == 0);
    CHECK(row_is(t, 0, "$ "));
    CHECK(row_is(t, 1, ""));
    CHECK(vt_get_cursor(t).row == 0 && vt_get_cursor(t).col == 2);
    w(t, "\x07");
    CHECK(bells == 1);
    vt_free(t);
}

static void test_osc(void) {
    vt_host host = {NULL, on_osc, NULL};
    vt *t = vt_new(2, 10, 0, &host);
    w(t, "\x1b]0;my title\x07");
    CHECK(strcmp(vt_title(t), "my title") == 0);
    w(t, "\x1b]2;sp");
    w(t, "lit\x1b\\x");
    CHECK(strcmp(vt_title(t), "split") == 0);
    CHECK(row_is(t, 0, "x"));
    w(t, "\x1b]52;c;aGVsbG8=\x07");
    CHECK(seen_osc == 52 && seen_len == 10);
    w(t, "\x1b]7;file://host/tmp\x07");
    CHECK(strcmp(vt_cwd(t), "file://host/tmp") == 0);
    seen_osc = 0;
    w(t, "\x1b]133;"); /* the prompt mark reaches the host too, split or not */
    w(t, "A\x1b\\");
    CHECK(seen_osc == 133 && seen_len == 1);
    seen_osc = 0;
    w(t, "\x1b]52;");
    char *big = xmalloc(70000);
    memset(big, 'A', 69999);
    big[69999] = '\0';
    w(t, big);
    free(big);
    w(t, "\x07y");
    CHECK(seen_osc == 0);
    CHECK(row_is(t, 0, "xy"));
    vt_free(t);
}

static void test_utf8_edges(void) {
    vt *t = mk(2, 10);
    w(t, "\xc3");
    w(t, "\xa9");
    CHECK(row_is(t, 0, "\xc3\xa9"));
    w(t, "\xff"
         "a\xe4\xb8"
         "b");
    CHECK(row_is(t, 0,
                 "\xc3\xa9\xef\xbf\xbd"
                 "a\xef\xbf\xbd"
                 "b"));
    w(t, "\r\n\xe4\x1b[1mz");
    CHECK(row_is(t, 1, "\xef\xbf\xbdz"));
    CHECK((cell(t, 1, 1).attr & VT_ATTR_BOLD) != 0);
    vt_free(t);
}

static void test_cancel_and_params(void) {
    vt *t = mk(3, 10);
    w(t, "a\x1b[31\x18"
         "b");
    CHECK(row_is(t, 0, "ab"));
    CHECK(cell(t, 0, 1).fg == VT_COLOR_DEFAULT);
    w(t, "\x1b[99999999999;99999999999H");
    CHECK(cursor_at(t, 2, 9));
    w(t, "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;"
         "30;31;32;33;34;35;36m");
    w(t, "\x1b[H\x1b[?1;2;3$$$$h");
    CHECK(cursor_at(t, 0, 0));
    vt_free(t);
}

static void test_save_restore(void) {
    vt *t = mk(5, 10);
    w(t, "\x1b[3;4H\x1b[31m\x1b"
         "7\x1b[H\x1b[0m\x1b"
         "8X");
    CHECK(row_is(t, 2, "   X"));
    CHECK(cell(t, 2, 3).fg == VT_COLOR_INDEX(1));
    vt_free(t);
}

static void test_reset(void) {
    vt *t = mk(3, 10);
    w(t, "junk\x1b[?25l\x1b[31m\x1b]0;t\x07\x1b"
         "c");
    CHECK(row_is(t, 0, ""));
    CHECK((vt_modes(t) & VT_MODE_CURSOR_VISIBLE) != 0);
    CHECK(vt_title(t)[0] == '\0');
    w(t, "\x1b#8");
    CHECK(row_is(t, 1, "EEEEEEEEEE"));
    vt_free(t);
}

static void test_reflow(void) {
    vt *t = mk(4, 10);
    w(t, "0123456789abcdef\r\nnext");
    CHECK(row_is(t, 0, "0123456789") && row_is(t, 1, "abcdef"));
    CHECK(vt_resize(t, 4, 20) == 0);
    CHECK(row_is(t, 0, "0123456789abcdef"));
    CHECK(row_is(t, 1, "next"));
    CHECK(cursor_at(t, 1, 4));
    CHECK(vt_base(t) == 4); /* renumbered: every old address is behind base */
    CHECK(vt_resize(t, 4, 5) == 0);
    CHECK(row_is(t, 0, "56789") && row_is(t, 3, "next"));
    CHECK(vt_history(t) == 1);
    CHECK(cursor_at(t, 3, 4));
    CHECK(vt_base(t) == 8);
    CHECK(vt_resize(t, 6, 5) == 0);
    CHECK(vt_history(t) == 0);
    CHECK(vt_base(t) == 13);
    CHECK(row_is(t, 0, "01234"));
    CHECK(cursor_at(t, 4, 4));
    vt_free(t);
    /* a wide glyph through a one-column grid and back: one cell there, two
       again here, with its tail */
    t = mk(3, 4);
    w(t, "\xe4\xb8\xad"
         "X");
    CHECK(vt_resize(t, 3, 1) == 0);
    CHECK(cell(t, 0, 0).cp == 0x4E2D && (cell(t, 0, 0).flags & VT_CELL_WIDE) == 0);
    CHECK(vt_resize(t, 3, 4) == 0);
    CHECK(cell(t, 0, 0).cp == 0x4E2D && (cell(t, 0, 0).flags & VT_CELL_WIDE) != 0);
    CHECK((cell(t, 0, 1).flags & VT_CELL_WIDE_TAIL) != 0 && cell(t, 0, 2).cp == 'X');
    vt_free(t);
}

static void test_reflow_rows_only(void) {
    vt *t = mk(5, 10);
    w(t, "a\r\nb\r\nc\r\nd\r\ne");
    CHECK(vt_resize(t, 3, 10) == 0);
    CHECK(row_is(t, 0, "c") && row_is(t, 2, "e"));
    CHECK(vt_history(t) == 2);
    CHECK(vt_resize(t, 5, 10) == 0);
    CHECK(row_is(t, 0, "a") && vt_history(t) == 0);
    w(t, "\x1b[H");
    CHECK(vt_resize(t, 2, 10) == 0);
    CHECK(cursor_at(t, 0, 0) && row_is(t, 0, "a"));
    vt_free(t);
}

static void test_resize_alt(void) {
    vt *t = mk(4, 10);
    w(t, "prompt\x1b[?1049h\x1b[4;10Hx");
    CHECK(vt_resize(t, 2, 5) == 0);
    CHECK(cursor_at(t, 1, 4));
    w(t, "\x1b[?1049l");
    CHECK(row_is(t, 0, "promp") && row_is(t, 1, "t"));
    CHECK(vt_resize(t, 0, 5) == -1);
    vt_free(t);
}

static int bytes_are(const uint8_t *got, size_t n, const char *want, size_t wn) {
    if (n != wn || memcmp(got, want, n) != 0) {
        fprintf(stderr, "  bytes: got %zu:", n);
        for (size_t i = 0; i < n; i++) {
            fprintf(stderr, " %02x", got[i]);
        }
        fprintf(stderr, " want %zu:", wn);
        for (size_t i = 0; i < wn; i++) {
            fprintf(stderr, " %02x", (unsigned)(uint8_t)want[i]);
        }
        fprintf(stderr, "\n");
        return 0;
    }
    return 1;
}

#define KEY_IS(t, key, mods, want)                                                                 \
    do {                                                                                           \
        uint8_t o_[VT_INPUT_MAX];                                                                  \
        size_t n_ = vt_key(t, key, mods, o_);                                                      \
        CHECK(bytes_are(o_, n_, want, sizeof(want) - 1));                                          \
    } while (0)

#define TEXT_IS(t, cp, mods, want)                                                                 \
    do {                                                                                           \
        uint8_t o_[VT_INPUT_MAX];                                                                  \
        size_t n_ = vt_text(t, cp, mods, o_);                                                      \
        CHECK(bytes_are(o_, n_, want, sizeof(want) - 1));                                          \
    } while (0)

#define MOUSE_IS(t, ev, btn, row, col, mods, want)                                                 \
    do {                                                                                           \
        uint8_t o_[VT_INPUT_MAX];                                                                  \
        size_t n_ = vt_mouse(t, ev, btn, row, col, mods, o_);                                      \
        CHECK(bytes_are(o_, n_, want, sizeof(want) - 1));                                          \
    } while (0)

static void test_keys(void) {
    vt *t = mk(2, 10);
    KEY_IS(t, VT_KEY_UP, 0, "\x1b[A");
    KEY_IS(t, VT_KEY_HOME, 0, "\x1b[H");
    KEY_IS(t, VT_KEY_UP, VT_MOD_CTRL, "\x1b[1;5A");
    KEY_IS(t, VT_KEY_F1, 0, "\x1bOP");
    KEY_IS(t, VT_KEY_F1 + 4, VT_MOD_SHIFT, "\x1b[15;2~");
    KEY_IS(t, VT_KEY_F12, 0, "\x1b[24~");
    KEY_IS(t, VT_KEY_DELETE, 0, "\x1b[3~");
    KEY_IS(t, VT_KEY_PAGE_DOWN, VT_MOD_ALT | VT_MOD_SHIFT, "\x1b[6;4~");
    KEY_IS(t, VT_KEY_ENTER, 0, "\r");
    KEY_IS(t, VT_KEY_ENTER, VT_MOD_ALT, "\x1b\r");
    KEY_IS(t, VT_KEY_TAB, VT_MOD_SHIFT, "\x1b[Z");
    KEY_IS(t, VT_KEY_BACKSPACE, 0, "\x7f");
    KEY_IS(t, VT_KEY_BACKSPACE, VT_MOD_CTRL, "\b");
    KEY_IS(t, VT_KEY_BACKSPACE, VT_MOD_ALT, "\x1b\x7f");
    KEY_IS(t, VT_KEY_ESCAPE, 0, "\x1b");
    KEY_IS(t, VT_KEY_KP_ENTER, 0, "\r");
    w(t, "\x1b[?1h\x1b=\x1b[20h");
    KEY_IS(t, VT_KEY_UP, 0, "\x1bOA");
    KEY_IS(t, VT_KEY_END, 0, "\x1bOF");
    KEY_IS(t, VT_KEY_KP_ENTER, 0, "\x1bOM");
    KEY_IS(t, VT_KEY_ENTER, 0, "\r\n");
    TEXT_IS(t, 'a', 0, "a");
    TEXT_IS(t, 'c', VT_MOD_CTRL, "\x03");
    TEXT_IS(t, '[', VT_MOD_CTRL, "\x1b");
    TEXT_IS(t, ' ', VT_MOD_CTRL, "\0");
    TEXT_IS(t, 'x', VT_MOD_ALT, "\x1bx");
    TEXT_IS(t, 'c', VT_MOD_CTRL | VT_MOD_ALT, "\x1b\x03");
    TEXT_IS(t, 0xE7, 0, "\xc3\xa7");
    vt_free(t);
}

static void test_mouse(void) {
    vt *t = mk(24, 80);
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_LEFT, 0, 0, 0, "");
    w(t, "\x1b[?1000h");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_LEFT, 0, 0, 0, "\x1b[M !!");
    MOUSE_IS(t, VT_MOUSE_RELEASE, VT_BUTTON_LEFT, 1, 2, 0, "\x1b[M##\"");
    MOUSE_IS(t, VT_MOUSE_MOTION, VT_BUTTON_LEFT, 0, 0, 0, "");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_WHEEL_DOWN, 0, 0, VT_MOD_CTRL, "\x1b[Mq!!");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_LEFT, 0, 300, 0, "");
    w(t, "\x1b[?1002h");
    MOUSE_IS(t, VT_MOUSE_MOTION, VT_BUTTON_LEFT, 0, 0, 0, "\x1b[M@!!");
    MOUSE_IS(t, VT_MOUSE_MOTION, VT_BUTTON_NONE, 0, 0, 0, "");
    w(t, "\x1b[?1006h");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_RIGHT, 4, 9, VT_MOD_SHIFT, "\x1b[<6;10;5M");
    MOUSE_IS(t, VT_MOUSE_RELEASE, VT_BUTTON_RIGHT, 4, 9, 0, "\x1b[<2;10;5m");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_WHEEL_UP, 2, 4, 0, "\x1b[<64;5;3M");
    MOUSE_IS(t, VT_MOUSE_RELEASE, VT_BUTTON_WHEEL_UP, 2, 4, 0, "");
    w(t, "\x1b[?1006l\x1b[?1005h");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_LEFT, 0, 299, 0, "\x1b[M \xc5\x8c!");
    w(t, "\x1b[?9h");
    MOUSE_IS(t, VT_MOUSE_RELEASE, VT_BUTTON_LEFT, 0, 0, 0, "");
    uint8_t o[VT_INPUT_MAX];
    CHECK(vt_focus(t, 1, o) == 0);
    w(t, "\x1b[?1004h");
    CHECK(bytes_are(o, vt_focus(t, 0, o), "\x1b[O", 3));
    vt_free(t);
}

static void test_paste(void) {
    vt *t = mk(2, 10);
    const char plain[] = "a\nb\r\nc";
    uint8_t out[64];
    size_t n = vt_paste(t, (const uint8_t *)plain, sizeof(plain) - 1, out);
    CHECK(bytes_are(out, n, "a\rb\rc", 5));
    w(t, "\x1b[?2004h");
    const char evil[] = "x\x1b[201~rm -rf\n";
    n = vt_paste(t, (const uint8_t *)evil, sizeof(evil) - 1, out);
    const char want[] = "\x1b[200~x[201~rm -rf\r\x1b[201~";
    CHECK(bytes_are(out, n, want, sizeof(want) - 1));
    vt_free(t);
}

static void test_cp437(void) {
    vt *t = mk(2, 10);
    vt_set_encoding(t, VT_ENCODING_CP437);
    w(t, "\xb0\xdb\xc9\xcd\x80");
    CHECK(row_is(t, 0, "\xe2\x96\x91\xe2\x96\x88\xe2\x95\x94\xe2\x95\x90\xc3\x87"));
    vt_set_encoding(t, VT_ENCODING_UTF8);
    w(t, "\r\n\xc3\xa9");
    CHECK(row_is(t, 1, "\xc3\xa9"));
    vt_free(t);
}

static int copy_is(const vt *t, int l0, int c0, int l1, int c1, const char *want) {
    uint8_t buf[512];
    size_t n = vt_copy_text(t, l0, c0, l1, c1, buf, sizeof(buf) - 1);
    buf[n] = '\0';
    if (strcmp((const char *)buf, want) != 0) {
        fprintf(stderr, "  copy: got \"%s\" want \"%s\"\n", (const char *)buf, want);
        return 0;
    }
    return 1;
}

static void test_copy(void) {
    vt *t = mk(3, 8);
    w(t, "one  \r\nabcdefghijk\r\n\xe4\xb8\xad\xc3\xa7");
    CHECK(vt_lines(t) == 4);
    int top = vt_lines(t) - 3;
    CHECK(copy_is(t, top - 1, 0, top - 1, 7, "one"));
    CHECK(copy_is(t, top, 0, top + 1, 7, "abcdefghijk"));
    CHECK(copy_is(t, top - 1, 1, top, 1, "ne\nab"));
    CHECK(copy_is(t, top + 2, 0, top + 2, 7, "\xe4\xb8\xad\xc3\xa7"));
    CHECK(copy_is(t, top + 1, 2, top - 1, 2, "e\nabcdefghijk"));
    uint8_t small[4];
    CHECK(vt_copy_text(t, 0, 0, 3, 7, small, sizeof(small)) <= sizeof(small));
    CHECK(!vt_wrapped(t, top - 1) && vt_wrapped(t, top) && !vt_wrapped(t, top + 1));
    CHECK(!vt_wrapped(t, top + 2) && !vt_wrapped(t, -1) && !vt_wrapped(t, 99));
    vt_free(t);
}

static int found(const vt *t, const char *ascii, int back, int line, int col, int want_line,
                 int want_col, int want_end) {
    uint32_t needle[32] = {0};
    int n = 0;
    for (; ascii[n] != 0; n++) {
        needle[n] = (uint8_t)ascii[n];
    }
    int end = -1;
    int hit = vt_find(t, needle, n, back, &line, &col, &end);
    if (want_line < 0) {
        return hit == 0;
    }
    return hit == 1 && line == want_line && col == want_col && end == want_end;
}

static void test_find(void) {
    vt *t = mk(3, 10);
    w(t, "foo bar\r\nxx FOO\r\n\xe4\xb8\xad"
         "foo\r\nlast");
    int lines = vt_lines(t);
    CHECK(lines == 4);
    /* from the bottom back: the latest first, case ignored */
    CHECK(found(t, "foo", 1, lines, 0, 2, 2, 4)); /* after the wide glyph */
    CHECK(found(t, "foo", 1, 2, 2, 1, 3, 5));
    CHECK(found(t, "foo", 1, 1, 3, 0, 0, 2));
    CHECK(found(t, "foo", 1, 0, 0, -1, 0, 0));
    /* forward from the top */
    CHECK(found(t, "FoO", 0, -1, 0, 0, 0, 2));
    CHECK(found(t, "foo", 0, 0, 0, 1, 3, 5));
    CHECK(found(t, "bar", 0, 0, 3, 0, 4, 6));
    CHECK(found(t, "zzz", 1, lines, 0, -1, 0, 0));
    const uint32_t wide[] = {0x4E2D, 'f'};
    int line = lines;
    int col = 0;
    int end = 0;
    CHECK(vt_find(t, wide, 2, 1, &line, &col, &end) == 1 && line == 2 && col == 0 && end == 2);
    vt_free(t);
}

static int link_is(const vt *t, int r, int c, const char *uri) {
    const char *got = vt_link(t, cell(t, r, c).link);
    if (uri == NULL) {
        return got == NULL;
    }
    return got != NULL && strcmp(got, uri) == 0;
}

static void test_hyperlinks(void) {
    vt *t = mk(3, 20);
    w(t, "a\x1b]8;;https://x.io/a\x1b\\bc\x1b[0md\x1b]8;;\x1b\\e");
    CHECK(link_is(t, 0, 0, NULL));
    CHECK(link_is(t, 0, 1, "https://x.io/a"));
    CHECK(link_is(t, 0, 3, "https://x.io/a")); /* SGR 0 does not end it */
    CHECK(link_is(t, 0, 4, NULL));
    w(t, "\x1b]8;;https://x.io/a\x07"
         "f\x1b]8;id=2;https://x.io/a\x07g\x1b]8;;\x07");
    CHECK(cell(t, 0, 5).link == cell(t, 0, 1).link); /* same link, same id */
    CHECK(cell(t, 0, 6).link != cell(t, 0, 5).link); /* id= makes another */
    CHECK(link_is(t, 0, 6, "https://x.io/a"));
    w(t, "\x1b]8;;https://x.io/\xc3\xa9\x07"
         "h\x1b]8;;\x07"); /* raw UTF-8: refused */
    CHECK(link_is(t, 0, 7, NULL));
    vt *c = vt_clone(t);
    CHECK(c != NULL && link_is(c, 0, 1, "https://x.io/a"));
    vt_free(c);
    w(t, "\x1b"
         "c");
    CHECK(link_is(t, 0, 0, NULL));
    vt_free(t);

    /* far more links than ids: an old cell keeps its own URI or none */
    t = vt_new(3, 10, 1000, NULL);
    char buf[64];
    for (int i = 0; i < 700; i++) {
        snprintf(buf, sizeof(buf), "\x1b]8;;u%d\x07x\x1b]8;;\x07\r\n", i);
        w(t, buf);
    }
    int total = vt_lines(t);
    vt_cell *cells = xmalloc((size_t)total * 10 * sizeof(vt_cell));
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    int bad = 0;
    int kept = 0;
    for (int back = 0; back <= vt_history(t); back += rows) {
        vt_copy_screen(t, back, cells);
        for (int r = 0; r < rows; r++) {
            int line = total - rows - back + r;
            if (line >= 700 || cells[r * 10].link == 0) {
                continue;
            }
            snprintf(buf, sizeof(buf), "u%d", line);
            const char *got = vt_link(t, cells[r * 10].link);
            bad += got == NULL || strcmp(got, buf) != 0;
            kept++;
        }
    }
    free(cells);
    CHECK(bad == 0);
    CHECK(kept > 100); /* recent ones survive */
    vt_free(t);
}

static void test_prompt_marks(void) {
    vt *t = mk(4, 20);
    /* a shell with integration: mark, prompt, command, output */
    for (int i = 0; i < 3; i++) {
        w(t, "\x1b]133;A\x07$ ls\r\x1b]133;C\x07\nout\r\n");
    }
    w(t, "\x1b]133;A\x1b\\\xe4\xb8\xad> "); /* the mark lands on a wide glyph too */
    int last = vt_lines(t) - 1;
    CHECK(cell(t, 3, 0).flags == (VT_CELL_WIDE | VT_CELL_PROMPT));
    CHECK(vt_prompt(t, last + 1, 1) == last);
    CHECK(vt_prompt(t, last, 1) == last - 2);
    CHECK(vt_prompt(t, last - 2, 1) == last - 4);
    CHECK(vt_prompt(t, last - 4, 1) == last - 6);
    CHECK(vt_prompt(t, last - 6, 1) == -1);
    CHECK(vt_prompt(t, last - 6, 0) == last - 4);
    CHECK(vt_prompt(t, last, 0) == -1);
    w(t, "\x1b[2J"); /* erased with its prompt */
    CHECK(vt_prompt(t, last + 1, 1) == last - 4);
    vt *c = vt_clone(t);
    CHECK(c != NULL && vt_prompt(c, last + 1, 1) == last - 4);
    vt_free(c);
    CHECK(vt_resize(t, 4, 5) == 0); /* reflow keeps the marks */
    CHECK(vt_prompt(t, vt_lines(t), 1) >= 0);
    vt_free(t);
}

static int same_screen(const vt *a, const vt *b) {
    int rows;
    int cols;
    vt_size(a, &rows, &cols);
    for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
            vt_cell x = cell(a, r, c);
            vt_cell y = cell(b, r, c);
            if (x.cp != y.cp || x.fg != y.fg || x.bg != y.bg || x.attr != y.attr ||
                x.flags != y.flags) {
                fprintf(stderr, "  cell %d,%d: %x/%x fg %x/%x bg %x/%x attr %x/%x fl %x/%x\n", r, c,
                        x.cp, y.cp, x.fg, y.fg, x.bg, y.bg, x.attr, y.attr, x.flags, y.flags);
                return 0;
            }
        }
    }
    vt_cursor ca = vt_get_cursor(a);
    vt_cursor cb = vt_get_cursor(b);
    uint32_t keep = VT_MODE_CURSOR_KEYS | VT_MODE_MOUSE_SGR | VT_MODE_MOUSE_DRAG |
                    VT_MODE_BRACKETED_PASTE | VT_MODE_KEYPAD | VT_MODE_CURSOR_VISIBLE;
    return ca.row == cb.row && ca.col == cb.col && ca.visible == cb.visible &&
           ca.style == cb.style && (vt_modes(a) & keep) == (vt_modes(b) & keep) &&
           strcmp(vt_title(a), vt_title(b)) == 0;
}

/* Line addresses are identities only within one grid: Cmd+K without history,
   the alternate screen and a reset each move the base past every old one. */
static void test_base_identity(void) {
    vt *t = vt_new(3, 8, 0, NULL);
    w(t, "A\r\nB\r\nC");
    CHECK(vt_base(t) == 0);
    vt_clear(t); /* the cursor's line C goes to the top: A and B are gone */
    CHECK(vt_base(t) == 2);
    CHECK(row_is(t, 0, "C"));
    uint64_t b = vt_base(t);
    w(t, "\x1b[?1049h\x1b[HXYZ"); /* the alternate screen: nothing of before */
    CHECK(vt_base(t) >= b + 3);
    b = vt_base(t);
    w(t, "ab\r\ncd\r\nef\r\ngh"); /* the alternate screen scrolls: lines lost there too */
    CHECK(vt_base(t) == b + 1);
    b = vt_base(t);
    w(t, "\x1b[?1049l");
    CHECK(vt_base(t) >= b + 3);
    CHECK(row_is(t, 0, "C"));
    b = vt_base(t);
    w(t, "\x1b"
         "c"); /* RIS */
    CHECK(vt_base(t) >= b + 3);
    vt_free(t);
    t = vt_new(2, 8, 4, NULL); /* with history, Cmd+K counts the history and the rows above */
    w(t, "1\r\n2\r\n3\r\n4\r\n5");
    CHECK(vt_history(t) == 3 && vt_base(t) == 0);
    vt_clear(t);
    CHECK(vt_base(t) == 4 && vt_history(t) == 0 && row_is(t, 0, "5"));
    vt_free(t);
}

/* DL and IL over the whole screen move screen lines, not the history: an
   address kept in the history still names the same text afterwards. */
static void test_base_keeps_history_on_line_edits(void) {
    vt *t = vt_new(2, 8, 4, NULL);
    w(t, "1\r\n2\r\n3\r\n4\r\n5");
    CHECK(vt_history(t) == 3 && vt_base(t) == 0);
    w(t, "\x1b[H\x1b[M"); /* DL at the top row with the default region */
    CHECK(vt_base(t) == 0 && vt_history(t) == 3 && row_is(t, 0, "5"));
    uint8_t text[16];
    size_t n = vt_copy_text(t, 1, 0, 1, 7, text, sizeof(text));
    CHECK(n == 1 && text[0] == '2');
    w(t, "\x1b[H\x1b[L"); /* IL at the top: the bottom row falls off, nothing lost above */
    CHECK(vt_base(t) == 0 && vt_history(t) == 3 && row_is(t, 1, "5"));
    w(t, "\x1b[2;1H\x1b[S"); /* SU over the whole screen scrolls into the history */
    CHECK(vt_base(t) == 0 && vt_history(t) == 4);
    w(t, "6\r\n7"); /* the history is full: the first line goes, and the base says so */
    CHECK(vt_history(t) == 4 && vt_base(t) == 1);
    n = vt_copy_text(t, 2 - 1, 0, 2 - 1, 7, text, sizeof(text));
    CHECK(n == 1 && text[0] == '3'); /* address 2 was "3": it still is, one lower */
    vt_free(t);
}

/* The wide-glyph invariant: every head has its tail right after it and
   every tail its head right before; the renderer and the copy rely on it. */
static int wide_ok(const vt *t) {
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
            vt_cell x = cell(t, r, c);
            if ((x.flags & VT_CELL_WIDE) != 0 &&
                (c + 1 >= cols || (cell(t, r, c + 1).flags & VT_CELL_WIDE_TAIL) == 0)) {
                return 0;
            }
            if ((x.flags & VT_CELL_WIDE_TAIL) != 0 &&
                (c == 0 || (cell(t, r, c - 1).flags & VT_CELL_WIDE) == 0)) {
                return 0;
            }
        }
    }
    return 1;
}

/* ICH and DCH over a wide glyph: whichever half the shift breaks, both go. */
static void test_wide_edits(void) {
    vt *t = mk(2, 8);
    w(t, "A\xe4\xb8\xad"
         "BC\x1b[1;1H\x1b[2P"); /* DCH 2 takes A and the head: the tail goes too, as a blank */
    CHECK(wide_ok(t) && row_is(t, 0, " BC"));
    vt_free(t);
    t = mk(2, 8);
    w(t, "A\xe4\xb8\xad"
         "BC\x1b[1;3H\x1b[@"); /* ICH on the tail: the glyph goes, BC move right */
    CHECK(wide_ok(t) && row_is(t, 0, "A   BC"));
    vt_free(t);
    t = mk(2, 5);
    w(t,
      "abc\xe4\xb8\xad\x1b[1;1H\x1b[@"); /* ICH pushes the head to the last column: no tail fits */
    CHECK(wide_ok(t) && row_is(t, 0, " abc"));
    vt_free(t);
    t = mk(2, 8);
    w(t, "AB\xe4\xb8\xad"
         "C\x1b[1;2H\x1b[2P"); /* DCH 2 ends on the head: its tail goes */
    CHECK(wide_ok(t) && row_is(t, 0, "A C"));
    vt_free(t);
    t = mk(2, 8);
    w(t, "\xe4\xb8\xad\xe4\xb8\xad\xe4\xb8\xad"
         "X\x1b[1;2H\x1b[3P"); /* DCH 3 from a tail across a glyph */
    CHECK(wide_ok(t) && row_is(t, 0, " \xe4\xb8\xadX"));
    vt_free(t);
}

/* The last column written leaves the wrap pending; a resize keeps that
   insertion point: after the character, wherever it landed. */
static void test_resize_keeps_pending_wrap(void) {
    vt *t = mk(3, 5);
    w(t, "abcde");
    CHECK(vt_resize(t, 4, 5) == 0); /* only the height */
    w(t, "F");
    CHECK(row_is(t, 0, "abcde") && row_is(t, 1, "F"));
    vt_free(t);
    t = mk(3, 5);
    w(t, "abcde");
    CHECK(vt_resize(t, 3, 8) == 0); /* wider: a plain column now */
    w(t, "F");
    CHECK(row_is(t, 0, "abcdeF"));
    vt_free(t);
    t = mk(3, 5);
    w(t, "abcde");
    CHECK(vt_resize(t, 3, 3) == 0); /* narrower: abc / de, the cursor after e */
    w(t, "F");
    CHECK(row_is(t, 0, "abc") && row_is(t, 1, "deF"));
    vt_free(t);
    t = mk(3, 6);
    w(t, "abcd\xe4\xb8\xad"); /* a wide glyph ends the row */
    CHECK(vt_resize(t, 3, 9) == 0);
    w(t, "F");
    CHECK(row_is(t, 0,
                 "abcd\xe4\xb8\xad"
                 "F"));
    vt_free(t);
    t = mk(3, 5);
    w(t, "\x1b[?1049habcde"); /* the alternate screen keeps it when the width stays */
    CHECK(vt_resize(t, 4, 5) == 0);
    w(t, "F");
    CHECK(row_is(t, 0, "abcde") && row_is(t, 1, "F"));
    vt_free(t);
}

/* Tab stops set with HTS survive a resize: all of them when only the
   height changes, the ones that still fit when the width shrinks, the
   defaults beyond the old width when it grows. */
static void test_resize_keeps_tabs(void) {
    vt *t = mk(3, 16);
    w(t, "\x1b[3g\x1b[1;4H\x1bH\x1b[1;1H"); /* clear all, one stop at column 4 */
    CHECK(vt_resize(t, 4, 16) == 0);
    w(t, "\tX");
    CHECK(row_is(t, 0, "   X"));
    CHECK(vt_resize(t, 4, 24) == 0); /* wider: the stop stays, defaults past 16 */
    w(t, "\r\n\t\tY");
    CHECK(row_is(t, 1, "                Y"));
    vt_free(t);
    t = mk(3, 16);
    w(t, "\x1b[3g\x1b[1;4H\x1bH\x1b[1;1H");
    CHECK(vt_resize(t, 3, 3) == 0); /* narrower than the stop: it is gone with its column */
    CHECK(vt_resize(t, 3, 16) == 0);
    w(t, "\tZ");
    CHECK(row_is(t, 0, "        Z"));
    vt_free(t);
}

/* A cursor saved with the wrap pending (DECSC in the last column) and
   restored after the width grew: the wrap belongs to the old width. */
static void test_saved_cursor_forgets_pending_on_width_change(void) {
    vt *t = mk(3, 5);
    w(t, "abcde\x1b"
         "7"); /* pending, saved */
    CHECK(vt_resize(t, 3, 8) == 0);
    w(t, "\x1b"
         "8F");
    CHECK(row_is(t, 0, "abcdeF")); /* after the e, on the same line */
    vt_free(t);
    t = mk(3, 5);
    w(t, "abcde\x1b"
         "7");
    CHECK(vt_resize(t, 4, 5) == 0); /* only the height: the pending wrap stays */
    w(t, "\x1b"
         "8F");
    CHECK(row_is(t, 0, "abcde") && row_is(t, 1, "F"));
    vt_free(t);
}

extern int vt_testing_fail_at;

/* Sizes, history, cursor and screen alike: what a failed resize leaves. */
static int same_state(const vt *a, const vt *b) {
    int ar;
    int ac;
    int br;
    int bc;
    vt_size(a, &ar, &ac);
    vt_size(b, &br, &bc);
    if (ar != br || ac != bc || vt_history(a) != vt_history(b) || vt_lines(a) != vt_lines(b)) {
        return 0;
    }
    vt_cursor ca = vt_get_cursor(a);
    vt_cursor cb = vt_get_cursor(b);
    if (ca.row != cb.row || ca.col != cb.col) {
        return 0;
    }
    size_t n = (size_t)ar * (size_t)ac;
    vt_cell *x = xmalloc(n * sizeof(vt_cell));
    vt_cell *y = xmalloc(n * sizeof(vt_cell));
    vt_copy_screen(a, 0, x);
    vt_copy_screen(b, 0, y);
    int same = memcmp(x, y, n * sizeof(vt_cell)) == 0;
    free(x);
    free(y);
    return same;
}

/* Every allocation of a resize made to fail in turn, shrinking and
   growing, on both screens: -1 leaves the terminal as it was, and sound. */
static void test_resize_fails_whole(void) {
    static const struct {
        int rows;
        int cols;
        const char *alt;
    } cases[] = {{1, 2, ""}, {6, 20, ""}, {2, 3, "\x1b[?1049h"}, {5, 12, "\x1b[?1049h"}};
    for (size_t k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
        for (int at = 1; at < 64; at++) {
            vt *t = vt_new(3, 8, 4, NULL);
            w(t, "one\r\ntwo\r\nthree\r\nfour\r\n\xe4\xb8\xad"
                 "x");
            w(t, cases[k].alt);
            w(t, "ABCDEFGH");
            vt *before = vt_clone(t);
            CHECK(before != NULL);
            vt_testing_fail_at = at;
            int rc = vt_resize(t, cases[k].rows, cases[k].cols);
            vt_testing_fail_at = 0;
            if (rc == 0) { /* past the last allocation: the whole thing went through */
                CHECK(at > 2);
                vt_free(before);
                vt_free(t);
                break;
            }
            CHECK(same_state(t, before));
            w(t, "ABCDEFGH\r\n\xe4\xb8\xad"); /* still a sound terminal, under ASan */
            CHECK(vt_resize(t, cases[k].rows, cases[k].cols) == 0);
            w(t, "after\r\n");
            CHECK(wide_ok(t));
            vt_free(before);
            vt_free(t);
        }
    }
}

static void test_clone_and_repaint(void) {
    vt *t = mk(6, 20);
    w(t, "\x1b]2;titulo\x07plain \x1b[1;31mred\x1b[0m \x1b[4:3;38;2;1;2;3mcurly\x1b[0m\r\n"
         "\x1b[44m  bg  \x1b[0m\xe4\xb8\xad\xe6\x96\x87 a\xcc\x81\r\n"
         "\x1b[7;38;5;200;48;5;17minv\x1b[0m\x1b(0lqk\x1b(B\r\n"
         "\x1b[?1h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b=\x1b[5 q\x1b[5;7H\x1b[32m");
    vt *c = vt_clone(t);
    CHECK(c != NULL);
    CHECK(same_screen(t, c));
    w(c, "\x1b[H\x1b[2Jchanged");
    CHECK(row_is(t, 0, "plain red curly"));
    CHECK(row_is(c, 0, "changed"));
    vt_free(c);

    uint8_t small[8];
    size_t need = vt_repaint(t, small, sizeof(small));
    uint8_t *buf = xmalloc(need);
    CHECK(vt_repaint(t, buf, need) == need);
    vt *fresh = mk(6, 20);
    w(fresh, "junk everywhere\x1b[?25l\x1b[41m");
    vt_write(fresh, buf, need);
    CHECK(same_screen(t, fresh));
    w(t, "X");
    w(fresh, "X");
    CHECK(same_screen(t, fresh));
    free(buf);
    vt_free(fresh);
    vt_free(t);
    /* what a screen is beyond its cells: the wrap pending, the soft wraps
       (the copy joins them) and the charset in use all come across */
    static const struct {
        const char *setup;
        const char *then;
    } cases[] = {
        {"abcde", "F"},                      /* pending: F goes to the next line */
        {"abcdefgh\x1b[1;4H", "Z"},          /* soft wrap: one line when copied */
        {"\x1b(0qwerty", "x"},               /* DEC graphics stay in force */
        {"ab\xe4\xb8\xad\xe4\xb8\xad", "F"}, /* a wide glyph padded past the edge */
        {"\x1b[?7labcdefgh", "F"},           /* autowrap off: the edge holds */
        {"abc\x1b)0\x0e"
         "qwe\x0f",
         "r"},                                     /* G1 designated and shifted back out */
        {"abcd\xe4\xb8\xad\x1b[2;1HG", "x"},       /* a pad, then the wide glyph overwritten */
        {"abcd\xe4\xb8\xad\x1b[2;1H\x1b[2X", "x"}, /* a pad before an empty continuation */
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        vt *src = mk(3, 5);
        w(src, cases[i].setup);
        size_t n = vt_repaint(src, NULL, 0);
        uint8_t *stream = xmalloc(n);
        CHECK(vt_repaint(src, stream, n) == n);
        vt *dst = mk(3, 5);
        w(dst, "\x1b(0\x1b[?7l\x1b[4hzzzzz\x1b[2;3H"); /* a destination in another state */
        vt_write(dst, stream, n);
        free(stream);
        CHECK(same_screen(src, dst));
        w(src, cases[i].then);
        w(dst, cases[i].then);
        CHECK(same_screen(src, dst));
        uint8_t a[64];
        uint8_t b[64];
        size_t na = vt_copy_text(src, 0, 0, vt_lines(src) - 1, 4, a, sizeof(a));
        size_t nb = vt_copy_text(dst, 0, 0, vt_lines(dst) - 1, 4, b, sizeof(b));
        CHECK(na == nb && memcmp(a, b, na) == 0); /* the soft wraps too: the copy joins them */
        vt_free(dst);
        vt_free(src);
    }
}

/* Pads a scroll moved: under the pending cursor (no stream can rewrite
   it: the text wins, the pending bit goes) and on the last row (the wide
   glyph that makes it must not scroll). Both found by the fuzz. */
static int same_text(const vt *a, const vt *b) {
    uint8_t x[256];
    uint8_t y[256];
    int cols;
    int rows;
    vt_size(a, &rows, &cols);
    size_t nx = vt_copy_text(a, 0, 0, vt_lines(a) - 1, cols - 1, x, sizeof(x));
    size_t ny = vt_copy_text(b, 0, 0, vt_lines(b) - 1, cols - 1, y, sizeof(y));
    return vt_lines(a) == vt_lines(b) && nx == ny && memcmp(x, y, nx) == 0;
}

static vt *repainted(const vt *src, int rows, int cols) {
    size_t n = vt_repaint(src, NULL, 0);
    uint8_t *stream = xmalloc(n);
    CHECK(vt_repaint(src, stream, n) == n);
    vt *dst = mk(rows, cols);
    w(dst, "\x1b[?6h\x1b[2;3H"); /* origin mode on: the body must not trust it */
    vt_write(dst, stream, n);
    free(stream);
    return dst;
}

static void test_repaint_keeps_moved_pads(void) {
    vt *src = mk(6, 2);
    w(src, "\t\xe4\xb8\xad\x1b[T");
    CHECK(cell(src, 1, 1).flags == VT_CELL_PAD && vt_get_cursor(src).row == 1);
    vt *dst = repainted(src, 6, 2);
    CHECK(same_text(src, dst) && cell(dst, 1, 1).flags == VT_CELL_PAD);
    vt_free(dst);
    vt_free(src);
    src = mk(3, 5);
    w(src, "abcd\xe4\xb8\xad\x1b[2T"); /* the padded row scrolled down to the last row */
    CHECK(cell(src, 2, 4).flags == VT_CELL_PAD && vt_wrapped(src, 1) == 0);
    dst = repainted(src, 3, 5);
    CHECK(same_text(src, dst) && cell(dst, 2, 4).flags == VT_CELL_PAD && row_is(dst, 2, "abcd"));
    vt_free(dst);
    vt_free(src);
    src = mk(3, 3); /* the row before wraps into the padded last row: no CUP between them */
    w(src, "abcde\xe4\xb8\xad\x1b[T");
    CHECK(cell(src, 2, 2).flags == VT_CELL_PAD && vt_wrapped(src, 1) && row_is(src, 2, "de"));
    dst = repainted(src, 3, 3);
    CHECK(same_text(src, dst) && cell(dst, 2, 2).flags == VT_CELL_PAD && row_is(dst, 2, "de"));
    CHECK(vt_wrapped(dst, 1) && row_is(dst, 0, ""));
    vt_free(dst);
    vt_free(src);
    src = mk(2, 2); /* too small for the trick: the pad becomes a blank, the text stays */
    w(src, "\t\xe4\xb8\xad\x1b[T");
    CHECK(cell(src, 1, 1).flags == VT_CELL_PAD);
    dst = repainted(src, 2, 2);
    CHECK(same_text(src, dst) && vt_lines(dst) == 2);
    vt_free(dst);
    vt_free(src);
}

/* CUU/CUD/CUF/CUB and their kin: the edges, the scroll region, and a move
   cancels the wrap the last column left pending. */
static void test_cursor_moves(void) {
    vt *t = mk(10, 20);
    w(t, "\x1b[5;5H\x1b[2A");
    CHECK(cursor_at(t, 2, 4));
    w(t, "\x1b[A");
    CHECK(cursor_at(t, 1, 4));
    w(t, "\x1b[99A");
    CHECK(cursor_at(t, 0, 4));
    w(t, "\x1b[3B");
    CHECK(cursor_at(t, 3, 4));
    w(t, "\x1b[e"); /* VPR */
    CHECK(cursor_at(t, 4, 4));
    w(t, "\x1b[99B");
    CHECK(cursor_at(t, 9, 4));
    w(t, "\x1b[3C");
    CHECK(cursor_at(t, 9, 7));
    w(t, "\x1b[a"); /* HPR */
    CHECK(cursor_at(t, 9, 8));
    w(t, "\x1b[99C");
    CHECK(cursor_at(t, 9, 19));
    w(t, "\x1b[4D");
    CHECK(cursor_at(t, 9, 15));
    w(t, "\x1b[99D");
    CHECK(cursor_at(t, 9, 0));
    w(t, "\x1b[5;5H\x1b[2E"); /* CNL */
    CHECK(cursor_at(t, 6, 0));
    w(t, "\x1b[3;9H\x1b[F"); /* CPL */
    CHECK(cursor_at(t, 1, 0));
    w(t, "\x1b[99E");
    CHECK(cursor_at(t, 9, 0));
    w(t, "\x1b[99F");
    CHECK(cursor_at(t, 0, 0));
    w(t, "\x1b[7G"); /* CHA */
    CHECK(cursor_at(t, 0, 6));
    w(t, "\x1b[3`"); /* HPA */
    CHECK(cursor_at(t, 0, 2));
    w(t, "\x1b[0G");
    CHECK(cursor_at(t, 0, 0));
    w(t, "\x1b[99G");
    CHECK(cursor_at(t, 0, 19));
    w(t, "\x1b[1;1H\x1b[2I"); /* CHT: two default stops */
    CHECK(cursor_at(t, 0, 16));
    w(t, "\x1b[4d"); /* VPA keeps the column */
    CHECK(cursor_at(t, 3, 16));
    w(t, "\x1b[99d");
    CHECK(cursor_at(t, 9, 16));

    /* the region stops a move that starts inside it */
    w(t, "\x1b[3;6r\x1b[4;1H\x1b[9A");
    CHECK(cursor_at(t, 2, 0));
    w(t, "\x1b[9B");
    CHECK(cursor_at(t, 5, 0));
    w(t, "\x1b[9F");
    CHECK(cursor_at(t, 2, 0));
    w(t, "\x1b[9E");
    CHECK(cursor_at(t, 5, 0));
    w(t, "\x1b[1;1H\x1b[9B"); /* above it: down to its bottom */
    CHECK(cursor_at(t, 5, 0));
    w(t, "\x1b[9;1H\x1b[9B"); /* below it: down to the screen's */
    CHECK(cursor_at(t, 9, 0));
    w(t, "\x1b[9A"); /* below it, up: stops at its top */
    CHECK(cursor_at(t, 2, 0));
    w(t, "\x1b[r");
    vt_free(t);

    /* the pending wrap goes: the next glyph lands on the moved cursor */
    t = mk(3, 5);
    w(t, "abcde\x1b[CX");
    CHECK(row_is(t, 0, "abcdX") && row_is(t, 1, ""));
    w(t, "\x1b[1;5HY\x1b[DZ");
    CHECK(row_is(t, 0, "abcZY") && row_is(t, 1, ""));
    w(t, "\x1b[1;5HQ\x1b[3GR");
    CHECK(row_is(t, 0, "abRZQ") && row_is(t, 1, ""));
    w(t, "\x1b[1;5HS\x1b[BT");
    CHECK(row_is(t, 1, "    T") && row_is(t, 2, ""));
    vt_free(t);
}

/* SCOSC/SCORC: CSI s and CSI u save and restore as ESC 7 and ESC 8 do. */
static void test_csi_save_restore(void) {
    vt *t = mk(5, 10);
    w(t, "\x1b[3;4H\x1b[31m\x1b[s\x1b[H\x1b[0m\x1b[uX");
    CHECK(row_is(t, 2, "   X"));
    CHECK(cell(t, 2, 3).fg == VT_COLOR_INDEX(1));
    w(t, "\x1b[2;3H\x1b[?1048h\x1b[H\x1b[?1048lY"); /* the same through private mode 1048 */
    CHECK(row_is(t, 1, "  Y"));
    w(t, "\x1b[2;4r\x1b[?6h\x1b[s\x1b[?6l\x1b[u"); /* origin mode comes back with the cursor */
    CHECK((vt_modes(t) & VT_MODE_ORIGIN) != 0);
    vt_free(t);
}

static void fill_rows(vt *t) {
    w(t, "\x1b[H\x1b[2Jaaaaaa\r\nbbbbbb\r\ncccccc\r\ndddddd\r\neeeeee");
}

/* ED and EL in every mode with the cursor mid-screen; the soft wraps the
   erased rows had go with them. */
static void test_erase_modes(void) {
    vt *t = vt_new(5, 6, 10, NULL);
    fill_rows(t);
    w(t, "\x1b[3;3H\x1b[J");
    CHECK(row_is(t, 0, "aaaaaa") && row_is(t, 1, "bbbbbb") && row_is(t, 2, "cc"));
    CHECK(row_is(t, 3, "") && row_is(t, 4, ""));
    fill_rows(t);
    w(t, "\x1b[3;3H\x1b[1J");
    CHECK(row_is(t, 0, "") && row_is(t, 1, "") && row_is(t, 2, "   ccc"));
    CHECK(row_is(t, 3, "dddddd"));
    fill_rows(t);
    w(t, "\x1b[3;3H\x1b[2K");
    CHECK(row_is(t, 2, "") && row_is(t, 1, "bbbbbb") && row_is(t, 3, "dddddd"));
    w(t, "\x1b[4;3H\x1b[9K\x1b[9J"); /* modes past 3: nothing */
    CHECK(row_is(t, 3, "dddddd") && row_is(t, 4, "eeeeee"));
    w(t, "\x1b[4;3H\x1b[?K"); /* DECSEL as EL */
    CHECK(row_is(t, 3, "dd"));
    w(t, "\x1b[?2J"); /* DECSED as ED */
    CHECK(row_is(t, 0, "") && row_is(t, 4, ""));

    int top = vt_lines(t) - 5;
    w(t, "\x1b[4;1Hxxxxxxyy\x1b[2;1H"); /* row 3 wraps into row 4 */
    CHECK(vt_wrapped(t, top + 3));
    w(t, "\x1b[J");
    CHECK(!vt_wrapped(t, top + 3) && row_is(t, 4, ""));
    w(t, "\x1b[1;1Hxxxxxxyy\x1b[3;2H"); /* row 0 wraps into row 1 */
    CHECK(vt_wrapped(t, top));
    w(t, "\x1b[1J");
    CHECK(!vt_wrapped(t, top) && row_is(t, 1, ""));
    w(t, "\x1b[1;1Hxxxxxxyy\x1b[1;3H");
    w(t, "\x1b[2K");
    CHECK(!vt_wrapped(t, top) && row_is(t, 0, "") && row_is(t, 1, "yy"));

    /* ED 3 on the alternate screen leaves the primary's history alone */
    w(t, "\x1b[5;1H\n\n\n");
    int kept = vt_history(t);
    CHECK(kept > 0);
    w(t, "\x1b[?1049h\x1b[3J\x1b[?1049l");
    CHECK(vt_history(t) == kept);
    vt_free(t);

    /* an erase that starts on a tail or ends on a head takes the whole glyph */
    t = mk(2, 8);
    w(t, "A\xe4\xb8\xad"
         "B\x1b[1;3H\x1b[K");
    CHECK(wide_ok(t) && row_is(t, 0, "A"));
    w(t, "\x1b[2;1HA\xe4\xb8\xad"
         "B\x1b[2;2H\x1b[1K");
    CHECK(wide_ok(t) && row_is(t, 1, "   B"));
    vt_free(t);
}

/* DSR 5 and 6 (and DECXCPR), DECRQM for the ANSI modes and for the modes
   only a query reaches. */
static void test_status_reports(void) {
    vt *t = mk(24, 80);
    w(t, "\x1b[5n");
    CHECK(reply_is(t, "\x1b[0n"));
    w(t, "\x1b[7n\x1b[n");
    CHECK(reply_is(t, ""));
    w(t, "\x1b[3;10r\x1b[?6h\x1b[2;5H\x1b[?6n");
    CHECK(reply_is(t, "\x1b[?2;5R"));
    w(t, "\x1b[99;1H\x1b[6n"); /* origin mode: the region's last row */
    CHECK(reply_is(t, "\x1b[8;1R"));
    w(t, "\x1b[?6l\x1b[r");
    w(t, "\x1b[4$p\x1b[4h\x1b[4$p\x1b[4l\x1b[20$p\x1b[3$p");
    CHECK(reply_is(t, "\x1b[4;2$y\x1b[4;1$y\x1b[20;2$y\x1b[3;0$y"));
    w(t, "\x1b[?1049$p\x1b[?1049h\x1b[?1049$p\x1b[?1049l");
    CHECK(reply_is(t, "\x1b[?1049;2$y\x1b[?1049;1$y"));
    w(t, "\x1b[?66$p\x1b[?66h\x1b[?66$p");
    CHECK(reply_is(t, "\x1b[?66;2$y\x1b[?66;1$y"));
    CHECK((vt_modes(t) & VT_MODE_KEYPAD) != 0);
    w(t, "\x1b[?66l");
    CHECK((vt_modes(t) & VT_MODE_KEYPAD) == 0);
    w(t, "\x1b[?47$p\x1b[?1047$p");
    CHECK(reply_is(t, "\x1b[?47;2$y\x1b[?1047;2$y"));
    w(t, "\x1b[=c\x1b[?q\x1b[?5x\x1b[c\x1b[1c"); /* only the plain DA answers */
    CHECK(reply_is(t, "\x1b[?62;22c"));
    for (int i = 0; i < 1100; i++) { /* a host that never reads: the replies stop at the cap */
        w(t, "\x1b[5n");
    }
    uint8_t *all = xmalloc(8192);
    CHECK(vt_reply(t, all, 8192) == 4096 && memcmp(all + 4092, "\x1b[0n", 4) == 0);
    CHECK(vt_reply(t, all, 8192) == 0);
    free(all);
    vt_free(t);
}

/* 47 and 1047 switch screens without saving the cursor; only 1047 and
   1049 clear the alternate screen on the way out. */
static void test_private_modes(void) {
    vt *t = mk(3, 10);
    w(t, "shell\x1b[?47h");
    CHECK((vt_modes(t) & VT_MODE_ALT_SCREEN) != 0 && row_is(t, 0, "") && cursor_at(t, 0, 5));
    w(t, "\x1b[Halt\x1b[?47l");
    CHECK((vt_modes(t) & VT_MODE_ALT_SCREEN) == 0 && row_is(t, 0, "shell"));
    CHECK(cursor_at(t, 0, 3));
    w(t, "\x1b[?1047h");
    CHECK(row_is(t, 0, "alt"));
    w(t, "\x1b[?1047h\x1b[?1047l\x1b[?1047l"); /* twice either way: no change */
    CHECK(row_is(t, 0, "shell"));
    w(t, "\x1b[?47h");
    CHECK(row_is(t, 0, ""));
    w(t, "\x1b[?47l");

    uint32_t before = vt_modes(t);
    w(t, "\x1b[?9999h\x1b[?5h");
    CHECK(vt_modes(t) == (before | VT_MODE_REVERSE));
    w(t, "\x1b[?5l\x1b[?1000h\x1b[?1002h");
    CHECK((vt_modes(t) & (VT_MODE_MOUSE_BUTTON | VT_MODE_MOUSE_DRAG)) == VT_MODE_MOUSE_DRAG);
    w(t, "\x1b[?1006h\x1b[?1015h");
    CHECK((vt_modes(t) & (VT_MODE_MOUSE_SGR | VT_MODE_MOUSE_URXVT)) == VT_MODE_MOUSE_URXVT);
    w(t, "\x1b[4 q");
    CHECK(vt_get_cursor(t).style == 4);
    w(t, "\x1b[9 q");
    CHECK(vt_get_cursor(t).style == 6);
    w(t, "\x1b[ q");
    CHECK(vt_get_cursor(t).style == 0);
    vt_free(t);
}

/* DECSTR: a soft reset keeps the screens, the mouse and paste modes and
   autowrap, and resets the pen, charsets, region and saved cursor. */
static void test_soft_reset(void) {
    vt *t = mk(6, 10);
    w(t, "\x1b[?1049hkeep\x1b[3;3H\x1b"
         "7\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1004h\x1b[?7l\x1b[?25l\x1b[4h\x1b[?1h"
         "\x1b[31;1m\x1b(0\x1b[2;4r");
    w(t, "\x1b[!p");
    CHECK(vt_modes(t) ==
          (VT_MODE_ALT_SCREEN | VT_MODE_MOUSE_BUTTON | VT_MODE_MOUSE_SGR | VT_MODE_BRACKETED_PASTE |
           VT_MODE_FOCUS | VT_MODE_AUTOWRAP | VT_MODE_CURSOR_VISIBLE));
    w(t, "\x1b[1;1Hq"); /* insert mode off, ASCII in G0, the default pen */
    CHECK(row_is(t, 0, "qeep"));
    vt_cell q = cell(t, 0, 0);
    CHECK(q.fg == VT_COLOR_DEFAULT && q.attr == 0);
    w(t, "\x1b"
         "8");
    CHECK(cursor_at(t, 0, 0));
    w(t, "\x1b[5;5H\x1b[?6h"); /* the region is the whole screen again */
    CHECK(cursor_at(t, 0, 0));
    w(t, "\x1b[99;1H");
    CHECK(cursor_at(t, 5, 0));
    vt_free(t);
}

/* SGR forms the first test leaves out: each attribute on and off, the
   colon forms, the bright backgrounds, underline color consumed whole and
   sub-parameters after a plain attribute skipped. */
static void test_sgr_forms(void) {
    vt *t = mk(2, 30);
    w(t, "\x1b[1;31mA\x1b[mB");
    CHECK(cell(t, 0, 1).attr == 0 && cell(t, 0, 1).fg == VT_COLOR_DEFAULT);
    w(t, "\x1b[2;3;5;7;8;9;53mC\x1b[6mD");
    uint16_t all = VT_ATTR_DIM | VT_ATTR_ITALIC | VT_ATTR_BLINK | VT_ATTR_INVERSE |
                   VT_ATTR_INVISIBLE | VT_ATTR_STRIKE | VT_ATTR_OVERLINE;
    CHECK(cell(t, 0, 2).attr == all);
    w(t, "\x1b[1;22;23;25;27;28;29;55mE");
    CHECK(cell(t, 0, 4).attr == 0);
    w(t, "\x1b[21mF\x1b[4:9mG\x1b[4:5mH\x1b[0m");
    CHECK(((cell(t, 0, 5).attr & VT_ATTR_UL_MASK) >> VT_ATTR_UL_SHIFT) == VT_UL_DOUBLE);
    CHECK(((cell(t, 0, 6).attr & VT_ATTR_UL_MASK) >> VT_ATTR_UL_SHIFT) == VT_UL_SINGLE);
    CHECK(((cell(t, 0, 7).attr & VT_ATTR_UL_MASK) >> VT_ATTR_UL_SHIFT) == VT_UL_DASHED);
    w(t, "\x1b[38:5:200mI\x1b[33;38mJ\x1b[0m");
    CHECK(cell(t, 0, 8).fg == VT_COLOR_INDEX(200));
    CHECK(cell(t, 0, 9).fg == VT_COLOR_INDEX(3)); /* 38 alone: nothing to take, fg stays */
    w(t, "\x1b[58;2;1;2;3;31mK\x1b[58:5:9;32mL\x1b[58;5;9;33mM\x1b[0m");
    CHECK(cell(t, 0, 10).fg == VT_COLOR_INDEX(1));
    CHECK(cell(t, 0, 11).fg == VT_COLOR_INDEX(2));
    CHECK(cell(t, 0, 12).fg == VT_COLOR_INDEX(3));
    CHECK(cell(t, 0, 10).attr == 0 && cell(t, 0, 10).bg == VT_COLOR_DEFAULT);
    w(t, "\x1b[101;97mN\x1b[107;90mO\x1b[0m");
    CHECK(cell(t, 0, 13).bg == VT_COLOR_INDEX(9) && cell(t, 0, 13).fg == VT_COLOR_INDEX(15));
    CHECK(cell(t, 0, 14).bg == VT_COLOR_INDEX(15) && cell(t, 0, 14).fg == VT_COLOR_INDEX(8));
    w(t, "\x1b[1:5;3mP\x1b[0m");
    CHECK(cell(t, 0, 15).attr == (VT_ATTR_BOLD | VT_ATTR_ITALIC));
    w(t, "\x1b[48:5:300mQ\x1b[0m"); /* clamped like the ;-form */
    CHECK(cell(t, 0, 16).bg == VT_COLOR_INDEX(255));
    vt_free(t);
}

/* Bright colors, overline and a scroll region survive a repaint. */
static void test_repaint_bright_and_region(void) {
    vt *src = mk(4, 6);
    w(src, "\x1b[91;102;53mX\x1b[0m\x1b[2;3r\x1b[1;2H");
    size_t n = vt_repaint(src, NULL, 0);
    uint8_t *stream = xmalloc(n);
    CHECK(vt_repaint(src, stream, n) == n);
    vt *dst = mk(4, 6);
    vt_write(dst, stream, n);
    free(stream);
    CHECK(same_screen(src, dst));
    vt_cell x = cell(dst, 0, 0);
    CHECK(x.fg == VT_COLOR_INDEX(9) && x.bg == VT_COLOR_INDEX(10) && x.attr == VT_ATTR_OVERLINE);
    w(src, "\x1b[?6h\x1b[99;1H\x1b[6n");
    w(dst, "\x1b[?6h\x1b[99;1H\x1b[6n");
    CHECK(reply_is(src, "\x1b[2;1R") && reply_is(dst, "\x1b[2;1R"));
    vt_free(dst);
    vt_free(src);
    src = mk(3, 5);
    w(src, "abcdef\x1b[2;1H\x1b[X"); /* row 0 wraps into a row left empty */
    CHECK(vt_wrapped(src, 0) && row_is(src, 1, ""));
    dst = repainted(src, 3, 5);
    CHECK(same_screen(src, dst) && vt_wrapped(dst, 0));
    vt_free(dst);
    vt_free(src);
}

static int link_at(const vt *t, int c) {
    return cell(t, 0, c).link;
}

/* OSC 8 edges: no URI field at all keeps the link in force; a URI too
   long for the table ends it; the longest that fits is taken. */
static void test_link_edges(void) {
    vt *t = mk(2, 20);
    w(t, "\x1b]8;;u\x07"
         "a\x1b]8\x07"
         "b\x1b]8;id=x\x07"
         "c\x1b]8;;\x07"
         "d");
    CHECK(link_is(t, 0, 0, "u") && link_is(t, 0, 1, "u") && link_is(t, 0, 2, "u"));
    CHECK(link_at(t, 3) == 0);
    enum { URI = 4096 };
    char *seq = xmalloc(URI + 16);
    memcpy(seq, "\x1b]8;;", 5);
    memset(seq + 5, 'x', URI - 2); /* params "" ; uri: 4095 bytes with the ';' */
    memcpy(seq + 5 + URI - 2,
           "\x07"
           "e",
           3);
    w(t, seq);
    CHECK(link_at(t, 4) != 0 && strlen(vt_link(t, link_at(t, 4))) == URI - 2);
    memset(seq + 5, 'y', URI - 1); /* one more: past the cap */
    memcpy(seq + 5 + URI - 1,
           "\x07"
           "f",
           3);
    w(t, seq);
    CHECK(link_at(t, 5) == 0);
    free(seq);
    vt_free(t);
}

static void osc_put_str(vt *t, const char *body) {
    w(t, "\x1b]");
    w(t, body);
    w(t, "\x07");
}

/* Color specs: both forms, either case, and every malformed one leaves the
   color as it was. */
static void test_color_specs(void) {
    vt *t = mk(2, 10);
    osc_put_str(t, "4;1;#AABBCC");
    CHECK(vt_color(t, 1) == 0xAABBCC);
    osc_put_str(t, "4;1;rgb:ABCD/ef/0");
    CHECK(vt_color(t, 1) == 0xABEF00);
    static const char *const bad[] = {
        "4;1;#GG0000",   "4;1;#12345",  "4;1;rgb:1/2",  "4;1;rgb:12345/0/0",
        "4;1;rgb:/0/0",  "4;1;xyz",     "4;1;rgb:1/2/", "4;1;rgb:g/0/0",
        "4;256;#ffffff", "4;x;#ffffff", "4;1",          "4;123456;#ffffff",
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        osc_put_str(t, bad[i]);
        CHECK(vt_color(t, 1) == 0xABEF00);
    }
    osc_put_str(t, "12;#010203;#040506"); /* past the cursor slot: nothing more */
    CHECK(vt_color(t, VT_SLOT_CURSOR) == 0x010203);
    osc_put_str(t, "112");
    CHECK(vt_color(t, VT_SLOT_CURSOR) == 0xE5E5E5);
    osc_put_str(t, "10;#123456");
    osc_put_str(t, "110");
    CHECK(vt_color(t, VT_SLOT_FG) == 0xE5E5E5);
    osc_put_str(t, "4;2;#020202");
    osc_put_str(t, "104;x;999999");
    CHECK(vt_color(t, 1) == 0xABEF00 && vt_color(t, 2) == 0x020202);
    osc_put_str(t, "104");
    CHECK(vt_color(t, 1) == 0xCD0000 && vt_color(t, 2) == 0x00CD00);
    vt_free(t);
}

/* OSC ids the core ignores, malformed ids, and a title over the cap. */
static void test_osc_edges(void) {
    vt *t = mk(2, 10);
    osc_put_str(t, "2;kept");
    osc_put_str(t, "1;icon");
    osc_put_str(t, "2x;bad");
    osc_put_str(t, ";none");
    CHECK(strcmp(vt_title(t), "kept") == 0);
    char *big = xmalloc(2010);
    memcpy(big, "2;", 2);
    memset(big + 2, 'T', 2000);
    big[2002] = '\0';
    osc_put_str(t, big);
    free(big);
    CHECK(strlen(vt_title(t)) == 1023);
    vt_free(t);
}

/* Bumped by what can change the picture, and only by that. */
static void test_generation(void) {
    vt *t = mk(3, 10);
    uint64_t g = vt_generation(t);
    w(t, "x");
    CHECK(vt_generation(t) > g);
    g = vt_generation(t);
    uint8_t buf[16];
    vt_reply(t, buf, sizeof(buf));
    vt_cell *cells = xmalloc(30 * sizeof(vt_cell));
    vt_copy_screen(t, 0, cells);
    free(cells);
    CHECK(vt_resize(t, 3, 10) == 0);
    CHECK(vt_generation(t) == g);
    CHECK(vt_resize(t, 4, 10) == 0);
    CHECK(vt_generation(t) > g);
    g = vt_generation(t);
    vt_config_color(t, VT_SLOT_BG, 0x101010);
    CHECK(vt_generation(t) > g);
    g = vt_generation(t);
    vt_config_color(t, VT_SLOT_COUNT, 0x101010); /* no such slot */
    CHECK(vt_generation(t) == g && vt_color(t, VT_SLOT_COUNT) == 0 && vt_color(t, -1) == 0);
    vt_clear(t);
    CHECK(vt_generation(t) > g);
    vt *c = vt_clone(t);
    CHECK(c != NULL && vt_generation(c) == vt_generation(t));
    vt_free(c);
    vt_free(t);
}

/* vt_new and vt_clone refuse bad sizes and fail whole when an allocation
   does; the original is untouched. */
static void test_new_and_clone_fail(void) {
    CHECK(vt_new(0, 10, 0, NULL) == NULL && vt_new(10, 0, 0, NULL) == NULL);
    CHECK(vt_new(VT_MAX_ROWS + 1, 10, 0, NULL) == NULL);
    CHECK(vt_new(10, VT_MAX_COLS + 1, 0, NULL) == NULL);
    CHECK(vt_new(10, 10, -1, NULL) == NULL && vt_new(10, 10, VT_MAX_HISTORY + 1, NULL) == NULL);
    for (int at = 1; at <= 6; at++) {
        vt_testing_fail_at = at;
        vt *t = vt_new(3, 10, 5, NULL);
        vt_testing_fail_at = 0;
        CHECK(t == NULL);
        vt_free(t);
    }
    vt_free(NULL);
    vt *t = mk(3, 10);
    w(t, "\x1b]8;;u\x07linked\x1b]8;;\x07");
    int done = 0;
    for (int at = 1; at < 16 && !done; at++) {
        vt_testing_fail_at = at;
        vt *c = vt_clone(t);
        vt_testing_fail_at = 0;
        if (c != NULL) {
            CHECK(at == 7); /* three allocations per grid, two grids */
            CHECK(same_screen(t, c) && link_is(c, 0, 0, "u"));
            vt_free(c);
            done = 1;
        }
    }
    CHECK(done);
    CHECK(row_is(t, 0, "linked"));
    vt_free(t);
}

/* Bytes the state machine takes in odd places: DEL, C0 inside a CSI,
   strings that are skipped, intermediates where they cannot be. */
static void test_parser_edges(void) {
    vt *t = mk(4, 10);
    w(t, "a\x7f"
         "\x01\x1b[5y"
         "b");
    CHECK(row_is(t, 0, "ab") && cursor_at(t, 0, 2));
    w(t, "c\x1b[1\bD"); /* BS runs inside the CSI, then CUB 1 */
    CHECK(cursor_at(t, 0, 1));
    w(t, "\x1b[2\x7f;3H");
    CHECK(cursor_at(t, 1, 2));
    w(t, "\x1b[1;1H\x1bPqdata\x1b\\1\x1bXsos\x1b\\2\x1b^pm\x1b\\3\x1b_apc\x07x\x1b\\4");
    CHECK(row_is(t, 0, "1234"));
    w(t, "\x1b[2 q\x1b[ 5;5q"); /* a parameter after an intermediate: ignored */
    CHECK(vt_get_cursor(t).style == 2);
    w(t, "\x1b[25?l"); /* a prefix after a parameter: ignored */
    CHECK((vt_modes(t) & VT_MODE_CURSOR_VISIBLE) != 0);
    w(t, "\x1b[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;31mZ");
    CHECK(cell(t, 0, 4).fg == VT_COLOR_DEFAULT); /* past 32 parameters: the 31 is dropped */
    w(t, "\x1b[0m\x1b(%5q\x1b(((Bq");            /* two or three intermediates: no designation */
    CHECK(row_is(t, 0, "1234Zqq"));
    w(t, "\x1b(A#\x1b(B#"); /* the UK set */
    CHECK(row_is(t, 0, "1234Zqq\xc2\xa3#"));
    vt_free(t);

    t = mk(4, 10);
    w(t, "\x1b[2;5H\x1b"
         "D");
    CHECK(cursor_at(t, 2, 4));
    w(t, "\x1b"
         "E");
    CHECK(cursor_at(t, 3, 0));
    w(t, "x\x1b"
         "D"); /* IND at the bottom scrolls */
    CHECK(row_is(t, 2, "x") && cursor_at(t, 3, 1));
    w(t, "\x1b[3;1H\x1bM"); /* RI off the top just moves up */
    CHECK(cursor_at(t, 1, 0));
    w(t, "\x1b[20h\x1b[1;1Hab\ncd\x0b"
         "e\x0c"
         "f\x1b[20l");
    CHECK(row_is(t, 1, "cd") && row_is(t, 2, "e") && row_is(t, 3, "f"));
    w(t, "\x1b[H\x1b[2J\x1b[1;9H\x1b[g\r\tT"); /* TBC 0: the stop at 8 goes */
    CHECK(cursor_at(t, 0, 9));
    w(t, "\x1b[2;99r\x1b[?6h\x1b[99;1H"); /* the bottom clamped to the screen */
    CHECK(cursor_at(t, 3, 0));
    w(t, "\x1b[3;2r\x1b[H"); /* top past bottom: refused, the region stays */
    CHECK(cursor_at(t, 1, 0));
    w(t, "\x1b[?6l\x1b[r");
    vt_free(t);

    t = mk(2, 4);
    w(t, "\xcc\x81x"); /* a combining mark with nothing before it */
    CHECK(row_is(t, 0, "x"));
    w(t, "\x1b[?7l\x1b[1;4H\xe4\xb8\xad"); /* no room and no wrap: dropped */
    CHECK(row_is(t, 0, "x") && cell(t, 0, 3).cp == 0);
    w(t, "\x1b[?7h\x1b[1;1H\xe4\xb8\xad\xcc\x81"); /* after a wide glyph: it has no composed form */
    CHECK(wide_ok(t) && row_is(t, 0, "\xe4\xb8\xad") && cursor_at(t, 0, 2));
    w(t, "\x1b[2;1H\xed\xa0\x80"
         "z"); /* a surrogate: one replacement */
    CHECK(row_is(t, 1, "\xef\xbf\xbdz"));
    vt_free(t);
}

/* SU and SD by more than the region or the whole buffer. */
static void test_scroll_counts(void) {
    vt *t = vt_new(4, 4, 2, NULL);
    w(t, "a\r\nb\r\nc\r\nd\x1b[200S");
    CHECK(vt_history(t) == 2 && row_is(t, 0, "") && row_is(t, 3, ""));
    w(t, "\x1b[H1\r\n2\r\n3\r\n4\x1b[2;3r\x1b[50S");
    CHECK(row_is(t, 0, "1") && row_is(t, 1, "") && row_is(t, 2, "") && row_is(t, 3, "4"));
    w(t, "\x1b[2;1H2\x1b[3;1H3\x1b[50T");
    CHECK(row_is(t, 0, "1") && row_is(t, 1, "") && row_is(t, 2, "") && row_is(t, 3, "4"));
    w(t, "\x1b[2;1H2\x1b[3;1H3\x1b[4;1H\x1b[L\x1b[M\x1b[1;1H\x1b[2L\x1b[2M"); /* outside: nothing */
    CHECK(row_is(t, 0, "1") && row_is(t, 1, "2") && row_is(t, 2, "3") && row_is(t, 3, "4"));
    vt_free(t);
}

/* A reflow narrower than a wide glyph's place pads the row; wide again,
   the pad goes and the glyph is back on its line. */
static void test_reflow_pads(void) {
    vt *t = mk(3, 5);
    w(t, "abc\xe4\xb8\xad");
    CHECK(vt_resize(t, 3, 4) == 0);
    CHECK(row_is(t, 0, "abc") && cell(t, 0, 3).flags == VT_CELL_PAD);
    CHECK(row_is(t, 1, "\xe4\xb8\xad") && vt_wrapped(t, vt_lines(t) - 3));
    CHECK(vt_resize(t, 3, 5) == 0);
    CHECK(row_is(t, 0, "abc\xe4\xb8\xad") && (cell(t, 0, 3).flags & VT_CELL_WIDE) != 0);
    vt_free(t);
    t = mk(3, 6);
    w(t, "\xe4\xb8\xad\x1b[1;2H"); /* the cursor on the tail stays on it */
    CHECK(vt_resize(t, 3, 8) == 0);
    CHECK(cursor_at(t, 0, 1));
    vt_free(t);
}

/* A resize that fails leaves the grid whole; one that succeeds is a new
   grid the caller installs. */
static int reflow(vt_grid *g, int rows, int cols, int *crow, int *ccol) {
    vt_grid out;
    if (grid_reflow_into(g, rows, cols, crow, ccol, &out) != 0) {
        return -1;
    }
    grid_free(g);
    *g = out;
    return 0;
}

static int clip(vt_grid *g, int rows, int cols, int *crow, int *ccol) {
    vt_grid out;
    if (grid_clip_into(g, rows, cols, crow, ccol, &out) != 0) {
        return -1;
    }
    grid_free(g);
    *g = out;
    return 0;
}

static void test_grid_resize_into(void) {
    vt_grid g;
    CHECK(grid_init(&g, 2, 4, 2) == 0);
    const char *text = "abcdef";
    for (int i = 0; i < 6; i++) {
        grid_row(&g, i / 4)[i % 4].cp = (uint32_t)text[i];
    }
    *grid_wrapped(&g, 0) = 1;
    int crow = 1;
    int ccol = 2;
    CHECK(reflow(&g, 2, 8, &crow, &ccol) == 0);
    CHECK(g.cols == 8 && g.rows == 2 && crow == 0 && ccol == 6);
    CHECK(grid_row(&g, 0)[5].cp == 'f' && grid_row(&g, 1)[0].cp == 0);
    CHECK(reflow(&g, 0, 4, &crow, &ccol) == -1 && g.cols == 8);
    vt_testing_fail_at = 1;
    CHECK(reflow(&g, 2, 3, &crow, &ccol) == -1);
    vt_testing_fail_at = 0;
    CHECK(g.cols == 8 && grid_row(&g, 0)[5].cp == 'f');
    CHECK(clip(&g, 1, 3, &crow, &ccol) == 0);
    CHECK(g.cols == 3 && g.rows == 1 && crow == 0 && ccol == 2);
    CHECK(grid_row(&g, 0)[2].cp == 'c');
    CHECK(clip(&g, 2, 0, &crow, &ccol) == -1 && g.cols == 3);
    vt_testing_fail_at = 1;
    CHECK(clip(&g, 2, 2, &crow, &ccol) == -1);
    vt_testing_fail_at = 0;
    CHECK(g.cols == 3);
    grid_free(&g);
    /* a cut through a wide glyph takes its head too */
    CHECK(grid_init(&g, 1, 4, 0) == 0);
    vt_cell *r = grid_row(&g, 0);
    r[0].cp = 'a';
    r[1].cp = 0x4E2D;
    r[1].flags = VT_CELL_WIDE;
    r[2].flags = VT_CELL_WIDE_TAIL;
    crow = 0;
    ccol = 0;
    CHECK(clip(&g, 1, 2, &crow, &ccol) == 0);
    CHECK(grid_row(&g, 0)[0].cp == 'a' && grid_row(&g, 0)[1].cp == 0);
    CHECK(grid_row(&g, 0)[1].flags == 0);
    grid_free(&g);
}

/* Keys and Ctrl chords the first tests leave out. */
static void test_more_keys(void) {
    vt *t = mk(2, 10);
    KEY_IS(t, VT_KEY_INSERT, 0, "\x1b[2~");
    KEY_IS(t, VT_KEY_PAGE_UP, VT_MOD_CTRL, "\x1b[5;5~");
    KEY_IS(t, VT_KEY_TAB, 0, "\t");
    KEY_IS(t, VT_KEY_TAB, VT_MOD_ALT, "\x1b\t");
    KEY_IS(t, 99, 0, "");
    w(t, "\x1b[20h");
    KEY_IS(t, VT_KEY_KP_ENTER, 0, "\r\n");
    TEXT_IS(t, '3', VT_MOD_CTRL, "\x1b");
    TEXT_IS(t, '4', VT_MOD_CTRL, "\x1c");
    TEXT_IS(t, '5', VT_MOD_CTRL, "\x1d");
    TEXT_IS(t, '6', VT_MOD_CTRL, "\x1e");
    TEXT_IS(t, '7', VT_MOD_CTRL, "\x1f");
    TEXT_IS(t, '8', VT_MOD_CTRL, "\x7f");
    TEXT_IS(t, '?', VT_MOD_CTRL, "\x7f");
    TEXT_IS(t, '/', VT_MOD_CTRL, "\x1f");
    TEXT_IS(t, '2', VT_MOD_CTRL, "\0");
    TEXT_IS(t, '@', VT_MOD_CTRL, "\0");
    TEXT_IS(t, '1', VT_MOD_CTRL, "1");
    TEXT_IS(t, 0xE9, VT_MOD_CTRL | VT_MOD_ALT, "\x1b\xc3\xa9");
    vt_free(t);
}

/* Mouse reports in the modes the first test leaves out: X10 drops the
   modifiers, urxvt, any-motion, Alt, and out-of-range input. */
static void test_more_mouse(void) {
    vt *t = mk(24, 80);
    w(t, "\x1b[?9h");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_LEFT, 0, 0, VT_MOD_SHIFT | VT_MOD_CTRL, "\x1b[M !!");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_WHEEL_RIGHT + 1, 0, 0, 0, "");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_LEFT, -1, 0, 0, "");
    MOUSE_IS(t, VT_MOUSE_PRESS, -1, 0, 0, 0, "");
    w(t, "\x1b[?1000h\x1b[?1015h");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_LEFT, 4, 9, 0, "\x1b[32;10;5M");
    MOUSE_IS(t, VT_MOUSE_RELEASE, VT_BUTTON_LEFT, 4, 9, 0, "\x1b[35;10;5M");
    w(t, "\x1b[?1006h\x1b[?1003h");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_LEFT, 0, 0, VT_MOD_ALT, "\x1b[<8;1;1M");
    MOUSE_IS(t, VT_MOUSE_MOTION, VT_BUTTON_NONE, 2, 3, 0, "\x1b[<35;4;3M");
    MOUSE_IS(t, VT_MOUSE_PRESS, VT_BUTTON_WHEEL_LEFT, 0, 0, 0, "\x1b[<66;1;1M");
    vt_free(t);
}

/* Every id taken and most of their cells gone with no history to keep
   them: a new link frees those ids instead of taking any from the screen. */
static void test_link_reclaim_frees(void) {
    vt *t = vt_new(2, 10, 0, NULL);
    char buf[64];
    for (int i = 0; i < 255; i++) {
        snprintf(buf, sizeof(buf), "\x1b]8;;u%d\x07x\x1b]8;;\x07\r\n", i);
        w(t, buf);
    }
    CHECK(link_is(t, 0, 0, "u254"));
    w(t, "\x1b]8;;new\x07y\x1b]8;;\x07");
    CHECK(link_is(t, 1, 0, "new") && link_is(t, 0, 0, "u254"));
    vt_free(t);
}

/* Queries out of range answer nothing rather than read past the tables. */
static void test_query_bounds(void) {
    vt *t = mk(2, 4);
    w(t, "ab");
    const uint32_t needle[5] = {'a', 'b', 'c', 'd', 'e'};
    int line = 0;
    int col = 0;
    int end = 0;
    CHECK(vt_find(t, needle, 0, 0, &line, &col, &end) == 0);
    CHECK(vt_find(t, needle, 5, 0, &line, &col, &end) == 0);
    CHECK(vt_link(t, 0) == NULL && vt_link(t, 256) == NULL && vt_link(t, 7) == NULL);
    CHECK(vt_prompt(t, 0, 0) == -1);
    vt_free(t);
}

int main(void) {
    test_repaint_keeps_moved_pads();
    test_text();
    test_deferred_wrap();
    test_wide();
    test_combining();
    test_sgr();
    test_erase_bce();
    test_region();
    test_history_cap();
    test_edit();
    test_alt_screen();
    test_charsets();
    test_tabs();
    test_replies();
    test_osc_colors();
    test_osc();
    test_clear_and_bell();
    test_utf8_edges();
    test_cancel_and_params();
    test_save_restore();
    test_reset();
    test_reflow();
    test_reflow_rows_only();
    test_resize_alt();
    test_keys();
    test_mouse();
    test_paste();
    test_cp437();
    test_copy();
    test_find();
    test_hyperlinks();
    test_prompt_marks();
    test_base_identity();
    test_base_keeps_history_on_line_edits();
    test_wide_edits();
    test_resize_keeps_pending_wrap();
    test_resize_keeps_tabs();
    test_saved_cursor_forgets_pending_on_width_change();
    test_resize_fails_whole();
    test_clone_and_repaint();
    test_cursor_moves();
    test_csi_save_restore();
    test_erase_modes();
    test_status_reports();
    test_private_modes();
    test_soft_reset();
    test_sgr_forms();
    test_repaint_bright_and_region();
    test_link_edges();
    test_color_specs();
    test_osc_edges();
    test_generation();
    test_new_and_clone_fail();
    test_parser_edges();
    test_scroll_counts();
    test_reflow_pads();
    test_grid_resize_into();
    test_more_keys();
    test_more_mouse();
    test_link_reclaim_frees();
    test_query_bounds();
    if (failures > 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
