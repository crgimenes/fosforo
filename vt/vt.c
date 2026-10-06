#include "vt.h"

#include "compose_table.h"
#include "cp437_table.h"
#include "grid.h"
#include "utf8.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    MAX_PARAMS = 32,
    MAX_INTER = 2,
    PARAM_MAX = 65535,
    OSC_CAP = 65536, /* yagni: OSC 1337 images need streaming to the host */
    REPLY_CAP = 4096,
    TITLE_CAP = 1024,
    LINK_MAX = 255, /* ids in vt_cell.link */
    URI_CAP = 4096,
    TAB_WIDTH = 8,
};

typedef enum {
    ST_GROUND,
    ST_ESCAPE,
    ST_ESCAPE_INTER,
    ST_CSI_ENTRY,
    ST_CSI_PARAM,
    ST_CSI_INTER,
    ST_CSI_IGNORE,
    ST_OSC,
    ST_STRING_IGNORE, /* DCS, SOS, PM, APC: consumed until ST */
} parse_state;

typedef struct {
    uint32_t fg;
    uint32_t bg;
    uint16_t attr;
} pen;

typedef struct {
    int row;
    int col;
    int pending;
    int origin;
    pen pen;
    uint8_t charset[4];
    uint8_t gl;
} saved_cursor;

struct vt {
    vt_grid grid[2];
    int alt;
    /* vt_base = base_shift + the shown grid's lost: a screen switch or a
       reset sets it so every address of before falls behind the new base */
    int64_t base_shift;
    int rows;
    int cols;

    int row;
    int col;
    int pending; /* deferred wrap: last column written, wrap on next print */
    pen pen;
    uint8_t charset[4];
    uint8_t gl;
    saved_cursor saved[2];
    int top; /* scroll region [top, bot) */
    int bot;
    uint8_t *tabs;
    uint32_t modes;
    int cursor_style;
    uint32_t last_cp;

    parse_state state;
    int encoding;
    utf8_dec utf;
    uint32_t params[MAX_PARAMS];
    uint32_t colon; /* bit i: params[i] was introduced by ':' */
    int nparams;
    uint8_t prefix;
    uint8_t inter[MAX_INTER];
    int ninter;
    uint8_t *osc;
    size_t osc_len;
    int osc_overflow;

    uint8_t reply[REPLY_CAP];
    size_t reply_len;
    char title[TITLE_CAP];
    char cwd[TITLE_CAP];
    uint32_t colors[VT_SLOT_COUNT];
    uint32_t default_colors[VT_SLOT_COUNT];
    uint64_t gen;
    vt_host host;

    /* OSC 8: key is "params\x1furi"; the id cells carry is the index. Kept
       out of the pen: SGR 0 does not end a hyperlink. */
    char *links[LINK_MAX + 1];
    uint8_t link;      /* for the next cells printed */
    uint8_t prompt;    /* OSC 133;A seen: the next cell printed is marked */
    uint8_t link_next; /* the slot recycled when all are taken */
};

static const uint32_t xterm16[16] = {
    0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
    0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
};

static void default_palette(uint32_t *c) {
    for (int i = 0; i < 16; i++) {
        c[i] = xterm16[i];
    }
    static const uint32_t level[6] = {0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF};
    for (int i = 0; i < 216; i++) {
        c[16 + i] = (level[i / 36] << 16U) | (level[(i / 6) % 6] << 8U) | level[i % 6];
    }
    for (int i = 0; i < 24; i++) {
        uint32_t v = (uint32_t)(8 + (i * 10));
        c[232 + i] = (v << 16U) | (v << 8U) | v;
    }
    c[VT_SLOT_FG] = 0xE5E5E5;
    c[VT_SLOT_BG] = 0x000000;
    c[VT_SLOT_CURSOR] = 0xE5E5E5;
}

static vt_grid *screen(vt *t) {
    return &t->grid[t->alt];
}

static vt_cell blank_cell(const vt *t) {
    vt_cell c;
    memset(&c, 0, sizeof(c));
    c.bg = t->pen.bg;
    return c;
}

static void reset_tabs(vt *t) {
    for (int i = 0; i < t->cols; i++) {
        t->tabs[i] = (uint8_t)(i % TAB_WIDTH == 0 && i > 0);
    }
}

static void reset_state(vt *t) {
    t->row = 0;
    t->col = 0;
    t->pending = 0;
    memset(&t->pen, 0, sizeof(t->pen));
    t->link = 0;
    t->prompt = 0;
    memset(t->charset, 'B', sizeof(t->charset));
    t->gl = 0;
    memset(t->saved, 0, sizeof(t->saved));
    for (int i = 0; i < 2; i++) {
        memset(t->saved[i].charset, 'B', sizeof(t->saved[i].charset));
    }
    t->top = 0;
    t->bot = t->rows;
    t->modes = VT_MODE_AUTOWRAP | VT_MODE_CURSOR_VISIBLE;
    t->cursor_style = 0;
    t->last_cp = 0;
    reset_tabs(t);
}

vt *vt_new(int rows, int cols, int history, const vt_host *host) {
    if (rows < 1 || cols < 1 || rows > VT_MAX_ROWS || cols > VT_MAX_COLS || history < 0 ||
        history > VT_MAX_HISTORY) {
        return NULL;
    }
    vt *t = calloc(1, sizeof(*t));
    if (t == NULL) {
        return NULL;
    }
    t->osc = malloc(OSC_CAP);
    t->tabs = calloc((size_t)cols, 1);
    if (t->osc == NULL || t->tabs == NULL || grid_init(&t->grid[0], rows, cols, history) != 0 ||
        grid_init(&t->grid[1], rows, cols, 0) != 0) {
        vt_free(t);
        return NULL;
    }
    if (host != NULL) {
        t->host = *host;
    }
    t->rows = rows;
    t->cols = cols;
    default_palette(t->default_colors);
    memcpy(t->colors, t->default_colors, sizeof(t->colors));
    utf8_dec_init(&t->utf);
    reset_state(t);
    return t;
}

vt *vt_clone(const vt *t) {
    vt *c = malloc(sizeof(*c));
    if (c == NULL) {
        return NULL;
    }
    memcpy(c, t, sizeof(*c));
    memset(c->grid, 0, sizeof(c->grid));
    memset((void *)c->links, 0, sizeof(c->links));
    c->osc = malloc(OSC_CAP);
    c->tabs = malloc((size_t)t->cols);
    if (c->osc == NULL || c->tabs == NULL || grid_copy(&c->grid[0], &t->grid[0]) != 0 ||
        grid_copy(&c->grid[1], &t->grid[1]) != 0) {
        vt_free(c);
        return NULL;
    }
    memcpy(c->osc, t->osc, t->osc_len);
    memcpy(c->tabs, t->tabs, (size_t)t->cols);
    for (int i = 0; i <= LINK_MAX; i++) {
        if (t->links[i] != NULL) {
            size_t n = strlen(t->links[i]) + 1;
            c->links[i] = malloc(n);
            if (c->links[i] == NULL) {
                vt_free(c);
                return NULL;
            }
            memcpy(c->links[i], t->links[i], n);
        }
    }
    return c;
}

void vt_free(vt *t) {
    if (t == NULL) {
        return;
    }
    grid_free(&t->grid[0]);
    grid_free(&t->grid[1]);
    free(t->osc);
    free(t->tabs);
    for (int i = 0; i <= LINK_MAX; i++) {
        free(t->links[i]);
    }
    free(t);
}

static void put_reply(vt *t, const char *s, size_t n) {
    if (n > REPLY_CAP - t->reply_len) {
        return;
    }
    memcpy(t->reply + t->reply_len, s, n);
    t->reply_len += n;
}

__attribute__((format(printf, 2, 3))) static void replyf(vt *t, const char *fmt, ...) {
    char buf[64];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        put_reply(t, buf, (size_t)n);
    }
}

size_t vt_reply(vt *t, uint8_t *out, size_t cap) {
    size_t n = t->reply_len < cap ? t->reply_len : cap;
    memcpy(out, t->reply, n);
    memmove(t->reply, t->reply + n, t->reply_len - n);
    t->reply_len -= n;
    return n;
}

/* ---- cursor and scrolling ---- */

static void scroll_up(vt *t, int top, int bot, int n) {
    int history = !t->alt && top == 0 && bot == t->rows;
    grid_scroll_up(screen(t), top, bot, n, blank_cell(t), history);
}

static void scroll_down(vt *t, int top, int bot, int n) {
    grid_scroll_down(screen(t), top, bot, n, blank_cell(t));
}

static void index_down(vt *t) {
    t->pending = 0;
    if (t->row == t->bot - 1) {
        scroll_up(t, t->top, t->bot, 1);
        return;
    }
    if (t->row < t->rows - 1) {
        t->row++;
    }
}

static void reverse_index(vt *t) {
    t->pending = 0;
    if (t->row == t->top) {
        scroll_down(t, t->top, t->bot, 1);
        return;
    }
    if (t->row > 0) {
        t->row--;
    }
}

static void move_to(vt *t, int row, int col) {
    int lo = 0;
    int hi = t->rows - 1;
    if ((t->modes & VT_MODE_ORIGIN) != 0) {
        lo = t->top;
        hi = t->bot - 1;
    }
    t->row = clampi(row, lo, hi);
    t->col = clampi(col, 0, t->cols - 1);
    t->pending = 0;
}

static int origin_row(const vt *t) {
    return (t->modes & VT_MODE_ORIGIN) != 0 ? t->top : 0;
}

static void tab_forward(vt *t, int n) {
    while (n > 0 && t->col < t->cols - 1) {
        t->col++;
        if (t->tabs[t->col]) {
            n--;
        }
    }
    t->pending = 0;
}

static void tab_back(vt *t, int n) {
    while (n > 0 && t->col > 0) {
        t->col--;
        if (t->tabs[t->col]) {
            n--;
        }
    }
    t->pending = 0;
}

/* ---- printing ---- */

static const uint32_t dec_special[32] = {
    0x0020, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B,
    0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C,
    0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
};

static uint32_t map_charset(const vt *t, uint32_t cp) {
    uint8_t set = t->charset[t->gl];
    if (set == '0' && cp >= 0x5F && cp <= 0x7E) {
        return dec_special[cp - 0x5F];
    }
    if (set == 'A' && cp == '#') {
        return 0x00A3;
    }
    return cp;
}

static uint32_t compose(uint32_t base, uint32_t mark) {
    size_t lo = 0;
    size_t hi = sizeof(compose_table) / sizeof(compose_table[0]);
    while (lo < hi) {
        size_t mid = lo + ((hi - lo) / 2);
        uint64_t key = ((uint64_t)compose_table[mid].base << 32U) | compose_table[mid].mark;
        uint64_t want = ((uint64_t)base << 32U) | mark;
        if (key == want) {
            return compose_table[mid].composed;
        }
        if (key < want) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return 0;
}

/* yagni: one composition step per mark; emoji ZWJ sequences and marks with no
   precomposed form are dropped. Full grapheme clusters need a side table. */
static void combine(vt *t, uint32_t mark) {
    int col = t->pending ? t->col : t->col - 1;
    if (col < 0) {
        return;
    }
    vt_cell *row = grid_row(screen(t), t->row);
    if ((row[col].flags & VT_CELL_WIDE_TAIL) != 0 && col > 0) {
        col--;
    }
    uint32_t c = compose(row[col].cp, mark);
    if (c != 0) {
        row[col].cp = c;
    }
}

static void blank_at(const vt *t, vt_cell *row, int col) {
    row[col] = blank_cell(t);
}

/* Writing over half of a wide glyph erases the other half. */
static void split_wide(const vt *t, vt_cell *row, int col, int width) {
    if ((row[col].flags & VT_CELL_WIDE_TAIL) != 0 && col > 0) {
        blank_at(t, row, col - 1);
    }
    int last = col + width - 1;
    if ((row[last].flags & VT_CELL_WIDE) != 0 && last + 1 < t->cols) {
        blank_at(t, row, last + 1);
    }
}

static void insert_blanks(vt *t, int n) {
    vt_cell *row = grid_row(screen(t), t->row);
    /* a wide glyph straddling the insertion point loses both halves: its
       tail would move away from its head */
    if ((row[t->col].flags & VT_CELL_WIDE_TAIL) != 0) {
        split_wide(t, row, t->col, 1);
        blank_at(t, row, t->col);
    }
    int move = t->cols - t->col - n;
    if (move > 0) {
        memmove(&row[t->col + n], &row[t->col], (size_t)move * sizeof(vt_cell));
    }
    int end = t->col + n < t->cols ? t->col + n : t->cols;
    for (int i = t->col; i < end; i++) {
        blank_at(t, row, i);
    }
    if ((row[t->cols - 1].flags & VT_CELL_WIDE) != 0) {
        blank_at(t, row, t->cols - 1); /* its tail fell off the edge */
    }
}

static void wrap_line(vt *t) {
    *grid_wrapped(screen(t), t->row) = 1;
    index_down(t);
    t->col = 0;
}

static void print(vt *t, uint32_t cp) {
    if (cp < 0x80) {
        cp = map_charset(t, cp);
    }
    int width = vt_width(cp);
    if (width == 0) {
        combine(t, cp);
        return;
    }
    int autowrap = (t->modes & VT_MODE_AUTOWRAP) != 0;
    if (t->pending && autowrap) {
        wrap_line(t);
    }
    t->pending = 0;
    if (width == 2 && t->col == t->cols - 1) {
        if (!autowrap || t->cols < 2) {
            return;
        }
        vt_cell *row = grid_row(screen(t), t->row);
        split_wide(t, row, t->col, 1);
        blank_at(t, row, t->col);
        row[t->col].flags = VT_CELL_PAD;
        wrap_line(t);
    }
    if ((t->modes & VT_MODE_INSERT) != 0) {
        insert_blanks(t, width);
    }
    vt_cell *row = grid_row(screen(t), t->row);
    split_wide(t, row, t->col, width);
    vt_cell *c = &row[t->col];
    c->cp = cp;
    c->fg = t->pen.fg;
    c->bg = t->pen.bg;
    c->attr = t->pen.attr;
    c->flags = (uint8_t)((width == 2 ? VT_CELL_WIDE : 0) | (t->prompt ? VT_CELL_PROMPT : 0));
    t->prompt = 0;
    c->link = t->link;
    if (width == 2) {
        vt_cell *tail = &row[t->col + 1];
        *tail = *c;
        tail->cp = 0;
        tail->flags = VT_CELL_WIDE_TAIL;
    }
    t->last_cp = cp;
    if (t->col + width >= t->cols) {
        t->col = t->cols - 1;
        t->pending = autowrap;
        return;
    }
    t->col += width;
}

/* Fast path for runs of printable ASCII in the common modes: one row pointer
   per stretch instead of one full print per byte. */
static void print_ascii(vt *t, const uint8_t *s, size_t n) {
    if (t->charset[t->gl] != 'B' ||
        (t->modes & (VT_MODE_INSERT | VT_MODE_AUTOWRAP)) != VT_MODE_AUTOWRAP) {
        for (size_t i = 0; i < n; i++) {
            print(t, s[i]);
        }
        return;
    }
    size_t i = 0;
    while (i < n) {
        if (t->pending) {
            wrap_line(t);
            t->pending = 0;
        }
        vt_cell *row = grid_row(screen(t), t->row);
        size_t room = (size_t)(t->cols - t->col);
        size_t k = n - i < room ? n - i : room;
        split_wide(t, row, t->col, 1);
        split_wide(t, row, t->col + (int)k - 1, 1);
        vt_cell c;
        c.fg = t->pen.fg;
        c.bg = t->pen.bg;
        c.attr = t->pen.attr;
        c.flags = 0;
        c.link = t->link;
        for (size_t j = 0; j < k; j++) {
            c.cp = s[i + j];
            row[t->col + (int)j] = c;
        }
        if (t->prompt) {
            row[t->col].flags |= VT_CELL_PROMPT;
            t->prompt = 0;
        }
        t->last_cp = s[i + k - 1];
        i += k;
        if (t->col + (int)k >= t->cols) {
            t->col = t->cols - 1;
            t->pending = 1;
            continue;
        }
        t->col += (int)k;
    }
}

/* ---- C0 controls ---- */

static void execute(vt *t, uint8_t b) {
    switch (b) {
    case 0x07:
        if (t->host.bell != NULL) {
            t->host.bell(t->host.user);
        }
        break;
    case 0x08:
        if (t->col > 0) {
            t->col--;
        }
        t->pending = 0;
        break;
    case 0x09:
        tab_forward(t, 1);
        break;
    case 0x0A:
    case 0x0B:
    case 0x0C:
        index_down(t);
        if ((t->modes & VT_MODE_NEWLINE) != 0) {
            t->col = 0;
        }
        break;
    case 0x0D:
        t->col = 0;
        t->pending = 0;
        break;
    case 0x0E:
        t->gl = 1;
        break;
    case 0x0F:
        t->gl = 0;
        break;
    default:
        break;
    }
}

/* ---- saved cursor, screens, reset ---- */

static void save_cursor(vt *t) {
    saved_cursor *s = &t->saved[t->alt];
    s->row = t->row;
    s->col = t->col;
    s->pending = t->pending;
    s->origin = (t->modes & VT_MODE_ORIGIN) != 0;
    s->pen = t->pen;
    memcpy(s->charset, t->charset, sizeof(s->charset));
    s->gl = t->gl;
}

static void restore_cursor(vt *t) {
    const saved_cursor *s = &t->saved[t->alt];
    t->row = clampi(s->row, 0, t->rows - 1);
    t->col = clampi(s->col, 0, t->cols - 1);
    t->pending = s->pending;
    t->modes &= ~(uint32_t)VT_MODE_ORIGIN;
    if (s->origin) {
        t->modes |= VT_MODE_ORIGIN;
    }
    t->pen = s->pen;
    memcpy(t->charset, s->charset, sizeof(t->charset));
    t->gl = s->gl;
}

/* Shows grid `alt` from now on (or the same one again, on a reset): no line
   address kept from before survives, so the base moves past them all. */
static void show_grid(vt *t, int alt) {
    uint64_t before = vt_base(t);
    int old = t->grid[t->alt].count;
    t->alt = alt;
    t->base_shift = (int64_t)(before + (uint64_t)old) - (int64_t)t->grid[alt].lost;
}

static void enter_alt(vt *t, int mode) {
    if (t->alt) {
        return;
    }
    if (mode == 1049) {
        save_cursor(t);
    }
    show_grid(t, 1);
    if (mode == 1049) {
        grid_clear(&t->grid[1], blank_cell(t));
    }
    t->modes |= VT_MODE_ALT_SCREEN;
}

static void leave_alt(vt *t, int mode) {
    if (!t->alt) {
        return;
    }
    if (mode == 1047 || mode == 1049) {
        grid_clear(&t->grid[1], blank_cell(t));
    }
    show_grid(t, 0);
    t->modes &= ~(uint32_t)VT_MODE_ALT_SCREEN;
    if (mode == 1049) {
        restore_cursor(t);
    }
}

static void full_reset(vt *t) {
    show_grid(t, 0); /* everything on both screens goes: so do the addresses */
    reset_state(t);
    vt_cell blank = blank_cell(t);
    grid_clear(&t->grid[0], blank);
    grid_clear_history(&t->grid[0]);
    grid_clear(&t->grid[1], blank);
    memcpy(t->colors, t->default_colors, sizeof(t->colors));
    t->title[0] = '\0';
}

/* ---- ESC dispatch ---- */

static void esc_dispatch(vt *t, uint8_t final) {
    if (t->ninter == 1) {
        uint8_t i = t->inter[0];
        if (i >= '(' && i <= '+') {
            t->charset[i - '('] = final;
            return;
        }
        if (i == '#' && final == '8') {
            const vt_grid *g = screen(t);
            vt_cell e;
            memset(&e, 0, sizeof(e));
            e.cp = 'E';
            for (int r = 0; r < t->rows; r++) {
                grid_fill(grid_row(g, r), t->cols, e);
            }
            t->top = 0;
            t->bot = t->rows;
            move_to(t, 0, 0);
        }
        return;
    }
    if (t->ninter != 0) {
        return;
    }
    switch (final) {
    case '7':
        save_cursor(t);
        break;
    case '8':
        restore_cursor(t);
        break;
    case 'D':
        index_down(t);
        break;
    case 'E':
        index_down(t);
        t->col = 0;
        break;
    case 'H':
        t->tabs[t->col] = 1;
        break;
    case 'M':
        reverse_index(t);
        break;
    case 'c':
        full_reset(t);
        break;
    case '=':
        t->modes |= VT_MODE_KEYPAD;
        break;
    case '>':
        t->modes &= ~(uint32_t)VT_MODE_KEYPAD;
        break;
    default:
        break;
    }
}

/* ---- CSI dispatch ---- */

static int param(const vt *t, int i, int def) {
    if (i >= t->nparams || t->params[i] == 0) {
        return def;
    }
    return (int)t->params[i];
}

static int param0(const vt *t, int i) {
    if (i >= t->nparams) {
        return 0;
    }
    return (int)t->params[i];
}

static int is_sub(const vt *t, int i) {
    return i < t->nparams && (t->colon & (1U << (uint32_t)i)) != 0;
}

static uint8_t byte_of(uint32_t v) {
    return (uint8_t)(v > 255 ? 255 : v);
}

/* 38/48/58 color, both the ;-separated and the :-separated (ITU T.416) forms.
   Returns the index of the last parameter consumed. */
static int ext_color(const vt *t, int i, uint32_t *out) {
    if (is_sub(t, i + 1)) {
        int j = i + 1;
        while (is_sub(t, j + 1)) {
            j++;
        }
        int k = j - i;
        uint32_t sel = t->params[i + 1];
        if (sel == 5 && k >= 2) {
            *out = VT_COLOR_INDEX(byte_of(t->params[i + 2]));
        }
        if (sel == 2 && k >= 5) {
            *out = VT_COLOR_RGB(byte_of(t->params[i + 3]), byte_of(t->params[i + 4]),
                                byte_of(t->params[i + 5]));
        }
        if (sel == 2 && k == 4) {
            *out = VT_COLOR_RGB(byte_of(t->params[i + 2]), byte_of(t->params[i + 3]),
                                byte_of(t->params[i + 4]));
        }
        return j;
    }
    if (i + 1 >= t->nparams) {
        return i;
    }
    uint32_t sel = t->params[i + 1];
    if (sel == 5 && i + 2 < t->nparams) {
        *out = VT_COLOR_INDEX(byte_of(t->params[i + 2]));
        return i + 2;
    }
    if (sel == 2 && i + 4 < t->nparams) {
        *out = VT_COLOR_RGB(byte_of(t->params[i + 2]), byte_of(t->params[i + 3]),
                            byte_of(t->params[i + 4]));
        return i + 4;
    }
    return t->nparams;
}

static void set_underline(pen *p, uint32_t style) {
    if (style > VT_UL_DASHED) {
        style = VT_UL_SINGLE;
    }
    p->attr = (uint16_t)(((uint32_t)p->attr & ~VT_ATTR_UL_MASK) | (style << VT_ATTR_UL_SHIFT));
}

static void set_attr(pen *p, uint16_t on, uint16_t off) {
    p->attr = (uint16_t)(((uint32_t)p->attr & ~(uint32_t)off) | (uint32_t)on);
}

static void sgr(vt *t) {
    pen *p = &t->pen;
    if (t->nparams == 0) {
        memset(p, 0, sizeof(*p));
        return;
    }
    for (int i = 0; i < t->nparams; i++) {
        uint32_t v = t->params[i];
        uint32_t discard = 0;
        switch (v) {
        case 0:
            memset(p, 0, sizeof(*p));
            break;
        case 1:
            set_attr(p, VT_ATTR_BOLD, 0);
            break;
        case 2:
            set_attr(p, VT_ATTR_DIM, 0);
            break;
        case 3:
            set_attr(p, VT_ATTR_ITALIC, 0);
            break;
        case 4:
            if (is_sub(t, i + 1)) {
                set_underline(p, t->params[i + 1]);
                i++;
                break;
            }
            set_underline(p, VT_UL_SINGLE);
            break;
        case 5:
        case 6:
            set_attr(p, VT_ATTR_BLINK, 0);
            break;
        case 7:
            set_attr(p, VT_ATTR_INVERSE, 0);
            break;
        case 8:
            set_attr(p, VT_ATTR_INVISIBLE, 0);
            break;
        case 9:
            set_attr(p, VT_ATTR_STRIKE, 0);
            break;
        case 21:
            set_underline(p, VT_UL_DOUBLE);
            break;
        case 22:
            set_attr(p, 0, VT_ATTR_BOLD | VT_ATTR_DIM);
            break;
        case 23:
            set_attr(p, 0, VT_ATTR_ITALIC);
            break;
        case 24:
            set_underline(p, VT_UL_NONE);
            break;
        case 25:
            set_attr(p, 0, VT_ATTR_BLINK);
            break;
        case 27:
            set_attr(p, 0, VT_ATTR_INVERSE);
            break;
        case 28:
            set_attr(p, 0, VT_ATTR_INVISIBLE);
            break;
        case 29:
            set_attr(p, 0, VT_ATTR_STRIKE);
            break;
        case 38:
            i = ext_color(t, i, &p->fg);
            break;
        case 39:
            p->fg = VT_COLOR_DEFAULT;
            break;
        case 48:
            i = ext_color(t, i, &p->bg);
            break;
        case 49:
            p->bg = VT_COLOR_DEFAULT;
            break;
        case 53:
            set_attr(p, VT_ATTR_OVERLINE, 0);
            break;
        case 55:
            set_attr(p, 0, VT_ATTR_OVERLINE);
            break;
        case 58: /* yagni: underline color parsed and dropped until a cell field exists */
            i = ext_color(t, i, &discard);
            break;
        default:
            if (v >= 30 && v <= 37) {
                p->fg = VT_COLOR_INDEX(v - 30);
            } else if (v >= 40 && v <= 47) {
                p->bg = VT_COLOR_INDEX(v - 40);
            } else if (v >= 90 && v <= 97) {
                p->fg = VT_COLOR_INDEX(v - 90 + 8);
            } else if (v >= 100 && v <= 107) {
                p->bg = VT_COLOR_INDEX(v - 100 + 8);
            }
            break;
        }
        while (is_sub(t, i + 1)) {
            i++;
        }
    }
}

static void erase_cells(vt *t, int row, int from, int to) {
    vt_cell *r = grid_row(screen(t), row);
    from = clampi(from, 0, t->cols);
    to = clampi(to, 0, t->cols);
    if (from >= to) {
        return;
    }
    if ((r[from].flags & VT_CELL_WIDE_TAIL) != 0 && from > 0) {
        blank_at(t, r, from - 1);
    }
    if ((r[to - 1].flags & VT_CELL_WIDE) != 0 && to < t->cols) {
        blank_at(t, r, to);
    }
    grid_fill(r + from, to - from, blank_cell(t));
}

static void erase_display(vt *t, int mode) {
    switch (mode) {
    case 0:
        erase_cells(t, t->row, t->col, t->cols);
        *grid_wrapped(screen(t), t->row) = 0;
        for (int r = t->row + 1; r < t->rows; r++) {
            erase_cells(t, r, 0, t->cols);
            *grid_wrapped(screen(t), r) = 0;
        }
        break;
    case 1:
        for (int r = 0; r < t->row; r++) {
            erase_cells(t, r, 0, t->cols);
            *grid_wrapped(screen(t), r) = 0;
        }
        erase_cells(t, t->row, 0, t->col + 1);
        break;
    case 2:
        grid_clear(screen(t), blank_cell(t));
        break;
    case 3:
        if (!t->alt) {
            grid_clear_history(&t->grid[0]);
        }
        break;
    default:
        break;
    }
}

static void erase_line(vt *t, int mode) {
    switch (mode) {
    case 0:
        erase_cells(t, t->row, t->col, t->cols);
        *grid_wrapped(screen(t), t->row) = 0;
        break;
    case 1:
        erase_cells(t, t->row, 0, t->col + 1);
        break;
    case 2:
        erase_cells(t, t->row, 0, t->cols);
        *grid_wrapped(screen(t), t->row) = 0;
        break;
    default:
        break;
    }
}

static void delete_chars(vt *t, int n) {
    vt_cell *row = grid_row(screen(t), t->row);
    n = clampi(n, 1, t->cols - t->col);
    split_wide(t, row, t->col, n); /* a tail at the start, a head at the end: both halves go */
    int move = t->cols - t->col - n;
    if (move > 0) {
        memmove(&row[t->col], &row[t->col + n], (size_t)move * sizeof(vt_cell));
    }
    grid_fill(row + t->cols - n, n, blank_cell(t));
    t->pending = 0;
}

static void insert_lines(vt *t, int n) {
    if (t->row < t->top || t->row >= t->bot) {
        return;
    }
    scroll_down(t, t->row, t->bot, n);
    t->col = 0;
    t->pending = 0;
}

static void delete_lines(vt *t, int n) {
    if (t->row < t->top || t->row >= t->bot) {
        return;
    }
    grid_scroll_up(screen(t), t->row, t->bot, n, blank_cell(t), 0);
    t->col = 0;
    t->pending = 0;
}

static uint32_t private_mode_bit(int mode) {
    switch (mode) {
    case 1:
        return VT_MODE_CURSOR_KEYS;
    case 5:
        return VT_MODE_REVERSE;
    case 6:
        return VT_MODE_ORIGIN;
    case 7:
        return VT_MODE_AUTOWRAP;
    case 9:
        return VT_MODE_MOUSE_X10;
    case 12:
        return VT_MODE_CURSOR_BLINK;
    case 25:
        return VT_MODE_CURSOR_VISIBLE;
    case 47:
    case 1047:
    case 1049:
        return VT_MODE_ALT_SCREEN;
    case 66:
        return VT_MODE_KEYPAD;
    case 1000:
        return VT_MODE_MOUSE_BUTTON;
    case 1002:
        return VT_MODE_MOUSE_DRAG;
    case 1003:
        return VT_MODE_MOUSE_ANY;
    case 1004:
        return VT_MODE_FOCUS;
    case 1005:
        return VT_MODE_MOUSE_UTF8;
    case 1006:
        return VT_MODE_MOUSE_SGR;
    case 1015:
        return VT_MODE_MOUSE_URXVT;
    case 2004:
        return VT_MODE_BRACKETED_PASTE;
    case 2026:
        return VT_MODE_SYNC_OUTPUT;
    default:
        return 0;
    }
}

static const uint32_t mouse_tracking =
    VT_MODE_MOUSE_X10 | VT_MODE_MOUSE_BUTTON | VT_MODE_MOUSE_DRAG | VT_MODE_MOUSE_ANY;
static const uint32_t mouse_encoding = VT_MODE_MOUSE_SGR | VT_MODE_MOUSE_UTF8 | VT_MODE_MOUSE_URXVT;

static void set_private_mode(vt *t, int mode, int on) {
    switch (mode) {
    case 47:
    case 1047:
    case 1049:
        if (on) {
            enter_alt(t, mode);
        } else {
            leave_alt(t, mode);
        }
        return;
    case 1048:
        if (on) {
            save_cursor(t);
        } else {
            restore_cursor(t);
        }
        return;
    default:
        break;
    }
    uint32_t bit = private_mode_bit(mode);
    if (bit == 0) {
        return;
    }
    if (on && (bit & mouse_tracking) != 0) {
        t->modes &= ~mouse_tracking;
    }
    if (on && (bit & mouse_encoding) != 0) {
        t->modes &= ~mouse_encoding;
    }
    if (on) {
        t->modes |= bit;
    } else {
        t->modes &= ~bit;
    }
    if (mode == 6) {
        move_to(t, origin_row(t), 0);
    }
}

static void set_modes(vt *t, int on) {
    for (int i = 0; i < t->nparams; i++) {
        int m = (int)t->params[i];
        if (t->prefix == '?') {
            set_private_mode(t, m, on);
            continue;
        }
        uint32_t bit = 0;
        if (m == 4) {
            bit = VT_MODE_INSERT;
        }
        if (m == 20) {
            bit = VT_MODE_NEWLINE;
        }
        if (on) {
            t->modes |= bit;
        } else {
            t->modes &= ~bit;
        }
    }
}

static void report_mode(vt *t) {
    int m = param0(t, 0);
    uint32_t bit = 0;
    if (t->prefix == '?') {
        bit = private_mode_bit(m);
    } else if (m == 4) {
        bit = VT_MODE_INSERT;
    } else if (m == 20) {
        bit = VT_MODE_NEWLINE;
    }
    int state = 0;
    if (bit != 0) {
        state = (t->modes & bit) != 0 ? 1 : 2;
    }
    if (t->prefix == '?') {
        replyf(t, "\x1b[?%d;%d$y", m, state);
        return;
    }
    replyf(t, "\x1b[%d;%d$y", m, state);
}

static void set_region(vt *t) {
    int top = param(t, 0, 1);
    int bot = param(t, 1, t->rows);
    if (bot > t->rows) {
        bot = t->rows;
    }
    if (top >= bot) {
        return;
    }
    t->top = top - 1;
    t->bot = bot;
    move_to(t, origin_row(t), 0);
}

static void device_status(vt *t) {
    int n = param0(t, 0);
    if (n == 5) {
        put_reply(t, "\x1b[0n", 4);
        return;
    }
    if (n != 6) {
        return;
    }
    int row = t->row - origin_row(t) + 1;
    if (t->prefix == '?') {
        replyf(t, "\x1b[?%d;%dR", row, t->col + 1);
        return;
    }
    replyf(t, "\x1b[%d;%dR", row, t->col + 1);
}

static void csi_prefixed(vt *t, uint8_t final) {
    switch (final) {
    case 'c':
        if (t->prefix == '>') {
            put_reply(t, "\x1b[>1;10;0c", 10);
        }
        break;
    case 'h':
        set_modes(t, 1);
        break;
    case 'l':
        set_modes(t, 0);
        break;
    case 'n':
        device_status(t);
        break;
    case 'p':
        if (t->ninter == 1 && t->inter[0] == '$') {
            report_mode(t);
        }
        break;
    case 'q':
        if (t->prefix == '>') {
            const char v[] = "\x1bP>|fosforo 0.0\x1b\\";
            put_reply(t, v, sizeof(v) - 1);
        }
        break;
    case 'J':
        erase_display(t, param0(t, 0));
        break;
    case 'K':
        erase_line(t, param0(t, 0));
        break;
    default:
        break;
    }
}

static void csi_with_inter(vt *t, uint8_t final) {
    uint8_t i = t->inter[0];
    if (i == ' ' && final == 'q') {
        t->cursor_style = clampi(param0(t, 0), 0, 6);
        return;
    }
    if (i == '!' && final == 'p') {
        /* DECSTR: autowrap stays on, unlike the VT510 table — `tput reset`
           sends this and a shell without autowrap is unusable. */
        uint32_t keep = t->modes & (VT_MODE_ALT_SCREEN | mouse_tracking | mouse_encoding |
                                    VT_MODE_FOCUS | VT_MODE_BRACKETED_PASTE);
        t->modes = keep | VT_MODE_AUTOWRAP | VT_MODE_CURSOR_VISIBLE;
        memset(&t->pen, 0, sizeof(t->pen));
        memset(t->charset, 'B', sizeof(t->charset));
        t->gl = 0;
        t->top = 0;
        t->bot = t->rows;
        memset(&t->saved[t->alt], 0, sizeof(t->saved[t->alt]));
        memset(t->saved[t->alt].charset, 'B', sizeof(t->saved[t->alt].charset));
        t->pending = 0;
        return;
    }
    if (i == '$' && final == 'p') {
        report_mode(t);
    }
}

static void csi_dispatch(vt *t, uint8_t final) {
    if (t->ninter > 0) {
        csi_with_inter(t, final);
        return;
    }
    if (t->prefix != 0) {
        csi_prefixed(t, final);
        return;
    }
    switch (final) {
    case '@':
        insert_blanks(t, clampi(param(t, 0, 1), 1, t->cols));
        t->pending = 0;
        break;
    case 'A':
        t->row = clampi(t->row - param(t, 0, 1), t->row >= t->top ? t->top : 0, t->rows - 1);
        t->pending = 0;
        break;
    case 'B':
    case 'e':
        t->row = clampi(t->row + param(t, 0, 1), 0, t->row < t->bot ? t->bot - 1 : t->rows - 1);
        t->pending = 0;
        break;
    case 'C':
    case 'a':
        t->col = clampi(t->col + param(t, 0, 1), 0, t->cols - 1);
        t->pending = 0;
        break;
    case 'D':
        t->col = clampi(t->col - param(t, 0, 1), 0, t->cols - 1);
        t->pending = 0;
        break;
    case 'E':
        t->row = clampi(t->row + param(t, 0, 1), 0, t->row < t->bot ? t->bot - 1 : t->rows - 1);
        t->col = 0;
        t->pending = 0;
        break;
    case 'F':
        t->row = clampi(t->row - param(t, 0, 1), t->row >= t->top ? t->top : 0, t->rows - 1);
        t->col = 0;
        t->pending = 0;
        break;
    case 'G':
    case '`':
        t->col = clampi(param(t, 0, 1) - 1, 0, t->cols - 1);
        t->pending = 0;
        break;
    case 'H':
    case 'f':
        move_to(t, origin_row(t) + param(t, 0, 1) - 1, param(t, 1, 1) - 1);
        break;
    case 'I':
        tab_forward(t, param(t, 0, 1));
        break;
    case 'J':
        erase_display(t, param0(t, 0));
        break;
    case 'K':
        erase_line(t, param0(t, 0));
        break;
    case 'L':
        insert_lines(t, param(t, 0, 1));
        break;
    case 'M':
        delete_lines(t, param(t, 0, 1));
        break;
    case 'P':
        delete_chars(t, param(t, 0, 1));
        break;
    case 'S':
        scroll_up(t, t->top, t->bot, param(t, 0, 1));
        break;
    case 'T':
        scroll_down(t, t->top, t->bot, param(t, 0, 1));
        break;
    case 'X':
        erase_cells(t, t->row, t->col, t->col + param(t, 0, 1));
        t->pending = 0;
        break;
    case 'Z':
        tab_back(t, param(t, 0, 1));
        break;
    case 'b': {
        int n = clampi(param(t, 0, 1), 1, t->rows * t->cols);
        for (int i = 0; i < n && t->last_cp != 0; i++) {
            print(t, t->last_cp);
        }
        break;
    }
    case 'c':
        if (param0(t, 0) == 0) {
            put_reply(t, "\x1b[?62;22c", 9);
        }
        break;
    case 'd':
        move_to(t, origin_row(t) + param(t, 0, 1) - 1, t->col);
        break;
    case 'g':
        if (param0(t, 0) == 0) {
            t->tabs[t->col] = 0;
        }
        if (param0(t, 0) == 3) {
            memset(t->tabs, 0, (size_t)t->cols);
        }
        break;
    case 'h':
        set_modes(t, 1);
        break;
    case 'l':
        set_modes(t, 0);
        break;
    case 'm':
        sgr(t);
        break;
    case 'n':
        device_status(t);
        break;
    case 'r':
        set_region(t);
        break;
    case 's':
        save_cursor(t);
        break;
    case 't':
        if (param0(t, 0) == 18) {
            replyf(t, "\x1b[8;%d;%dt", t->rows, t->cols);
        }
        break;
    case 'u':
        restore_cursor(t);
        break;
    default:
        break;
    }
}

/* ---- OSC ---- */

static int hexval(uint8_t c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

/* One component of 1..4 hex digits, scaled to 8 bits. */
static int hex_component(const uint8_t *s, size_t n, uint32_t *out) {
    if (n < 1 || n > 4) {
        return -1;
    }
    uint32_t v = 0;
    for (size_t i = 0; i < n; i++) {
        int h = hexval(s[i]);
        if (h < 0) {
            return -1;
        }
        v = (v << 4U) | (uint32_t)h;
    }
    uint32_t max = (1U << (4 * n)) - 1;
    *out = ((v * 255) + (max / 2)) / max;
    return 0;
}

/* "rgb:r/g/b" (1..4 hex digits each) or "#rrggbb". */
static int parse_color(const uint8_t *s, size_t n, uint32_t *rgb) {
    uint32_t c[3];
    if (n == 7 && s[0] == '#') {
        for (int i = 0; i < 3; i++) {
            if (hex_component(s + 1 + (2 * (size_t)i), 2, &c[i]) != 0) {
                return -1;
            }
        }
        *rgb = (c[0] << 16U) | (c[1] << 8U) | c[2];
        return 0;
    }
    if (n < 4 || memcmp(s, "rgb:", 4) != 0) {
        return -1;
    }
    size_t pos = 4;
    for (int i = 0; i < 3; i++) {
        size_t end = pos;
        while (end < n && s[end] != '/') {
            end++;
        }
        if (hex_component(s + pos, end - pos, &c[i]) != 0) {
            return -1;
        }
        if (i < 2 && end >= n) {
            return -1;
        }
        pos = end + 1;
    }
    *rgb = (c[0] << 16U) | (c[1] << 8U) | c[2];
    return 0;
}

static void reply_color(vt *t, const char *prefix, int slot) {
    uint32_t c = t->colors[slot];
    unsigned r = (c >> 16U) & 0xFFU;
    unsigned g = (c >> 8U) & 0xFFU;
    unsigned b = c & 0xFFU;
    char buf[80];
    int n = snprintf(buf, sizeof(buf), "\x1b]%s;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\", prefix, r, r,
                     g, g, b, b);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        put_reply(t, buf, (size_t)n);
    }
}

/* Splits data at ';' into successive fields. */
static int next_field(const uint8_t *data, size_t len, size_t *pos, const uint8_t **f,
                      size_t *flen) {
    if (*pos > len) {
        return 0;
    }
    size_t end = *pos;
    while (end < len && data[end] != ';') {
        end++;
    }
    *f = data + *pos;
    *flen = end - *pos;
    *pos = end + 1;
    return 1;
}

static int field_int(const uint8_t *f, size_t n) {
    if (n == 0 || n > 5) {
        return -1;
    }
    int v = 0;
    for (size_t i = 0; i < n; i++) {
        if (f[i] < '0' || f[i] > '9') {
            return -1;
        }
        v = (v * 10) + (f[i] - '0');
    }
    return v;
}

static void osc_palette(vt *t, const uint8_t *data, size_t len) {
    size_t pos = 0;
    const uint8_t *f;
    size_t flen;
    while (next_field(data, len, &pos, &f, &flen)) {
        int idx = field_int(f, flen);
        const uint8_t *spec;
        size_t slen;
        if (!next_field(data, len, &pos, &spec, &slen) || idx < 0 || idx > 255) {
            return;
        }
        if (slen == 1 && spec[0] == '?') {
            char prefix[16];
            snprintf(prefix, sizeof(prefix), "4;%d", idx);
            reply_color(t, prefix, idx);
            continue;
        }
        uint32_t rgb;
        if (parse_color(spec, slen, &rgb) == 0) {
            t->colors[idx] = rgb;
        }
    }
}

static void osc_dynamic(vt *t, int id, const uint8_t *data, size_t len) {
    size_t pos = 0;
    const uint8_t *f;
    size_t flen;
    int slot = VT_SLOT_FG + (id - 10);
    while (slot <= VT_SLOT_CURSOR && next_field(data, len, &pos, &f, &flen)) {
        if (flen == 1 && f[0] == '?') {
            char prefix[8];
            snprintf(prefix, sizeof(prefix), "%d", slot - VT_SLOT_FG + 10);
            reply_color(t, prefix, slot);
        } else {
            uint32_t rgb;
            if (parse_color(f, flen, &rgb) == 0) {
                t->colors[slot] = rgb;
            }
        }
        slot++;
    }
}

static void osc_reset_palette(vt *t, const uint8_t *data, size_t len) {
    if (len == 0) {
        memcpy(t->colors, t->default_colors, 256 * sizeof(uint32_t));
        return;
    }
    size_t pos = 0;
    const uint8_t *f;
    size_t flen;
    while (next_field(data, len, &pos, &f, &flen)) {
        int idx = field_int(f, flen);
        if (idx >= 0 && idx <= 255) {
            t->colors[idx] = t->default_colors[idx];
        }
    }
}

static void copy_text(char *dst, const uint8_t *src, size_t n) {
    if (n > TITLE_CAP - 1) {
        n = TITLE_CAP - 1;
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* Every cell whose link is marked in drop loses it; returns which ids are
   still on some cell. */
static void sweep_links(vt *t, const uint8_t *drop, uint8_t *used) {
    memset(used, 0, LINK_MAX + 1);
    for (int k = 0; k < 2; k++) {
        const vt_grid *g = &t->grid[k];
        for (int l = 0; l < g->count; l++) {
            vt_cell *row = grid_line(g, l);
            for (int c = 0; c < g->cols; c++) {
                if (drop[row[c].link]) {
                    row[c].link = 0;
                }
                used[row[c].link] = 1;
            }
        }
    }
}

/* All ids taken: free the ones no cell has any more (scrolled out of the
   history); if that leaves few, take a batch away from their cells too, so
   a reused id never makes an old link open a new URI. At most two passes
   per LINK_RECLAIM_MIN new links. */
static void reclaim_links(vt *t) {
    enum { LINK_RECLAIM_MIN = 32, LINK_EVICT = 128 };
    uint8_t drop[LINK_MAX + 1] = {0};
    uint8_t used[LINK_MAX + 1];
    sweep_links(t, drop, used);
    int freed = 0;
    for (int i = 1; i <= LINK_MAX; i++) {
        if (!used[i] && i != t->link) {
            free(t->links[i]);
            t->links[i] = NULL;
            freed++;
        }
    }
    if (freed >= LINK_RECLAIM_MIN) {
        return;
    }
    for (int n = 0; n < LINK_EVICT; n++) {
        t->link_next = (uint8_t)((t->link_next % LINK_MAX) + 1);
        if (t->link_next != t->link) {
            drop[t->link_next] = 1;
        }
    }
    sweep_links(t, drop, used);
    for (int i = 1; i <= LINK_MAX; i++) {
        if (drop[i]) {
            free(t->links[i]);
            t->links[i] = NULL;
        }
    }
}

/* OSC 8 ; params ; URI: cells printed from here on link to URI; an empty
   URI ends the link. Only printable ASCII is taken (RFC 3986 escapes the
   rest), which also keeps control bytes out of what the app opens. */
static void osc_link(vt *t, const uint8_t *data, size_t len) {
    size_t semi = 0;
    while (semi < len && data[semi] != ';') {
        semi++;
    }
    if (semi == len) {
        return;
    }
    size_t ulen = len - semi - 1;
    if (ulen == 0) {
        t->link = 0;
        return;
    }
    if (len + 1 > URI_CAP) {
        t->link = 0;
        return;
    }
    char key[URI_CAP];
    for (size_t i = 0; i < len; i++) {
        if (data[i] < 0x20 || data[i] > 0x7E) {
            t->link = 0;
            return;
        }
        key[i] = i == semi ? '\x1f' : (char)data[i];
    }
    key[len] = 0;
    int free_slot = 0;
    for (int i = 1; i <= LINK_MAX; i++) {
        if (t->links[i] == NULL) {
            if (free_slot == 0) {
                free_slot = i;
            }
            continue;
        }
        if (strcmp(t->links[i], key) == 0) {
            t->link = (uint8_t)i;
            return;
        }
    }
    int slot = free_slot;
    if (slot == 0) {
        reclaim_links(t);
        for (slot = 1; slot <= LINK_MAX && t->links[slot] != NULL; slot++) {
        }
        if (slot > LINK_MAX) {
            t->link = 0;
            return;
        }
    }
    t->links[slot] = malloc(len + 1);
    if (t->links[slot] == NULL) {
        t->link = 0;
        return;
    }
    memcpy(t->links[slot], key, len + 1);
    t->link = (uint8_t)slot;
}

static void osc_dispatch(vt *t) {
    if (t->osc_overflow) {
        return;
    }
    const uint8_t *s = t->osc;
    size_t n = t->osc_len;
    size_t i = 0;
    uint32_t id = 0;
    while (i < n && s[i] >= '0' && s[i] <= '9' && id < 100000) {
        id = (id * 10) + (uint32_t)(s[i] - '0');
        i++;
    }
    if (i == 0 || (i < n && s[i] != ';')) {
        return;
    }
    const uint8_t *data = i < n ? s + i + 1 : s + n;
    size_t len = i < n ? n - i - 1 : 0;
    switch (id) {
    case 0:
    case 2:
        copy_text(t->title, data, len);
        break;
    case 1:
        break;
    case 4:
        osc_palette(t, data, len);
        break;
    case 7:
        copy_text(t->cwd, data, len);
        break;
    case 8:
        osc_link(t, data, len);
        break;
    case 133: /* shell integration: the prompt start is a mark here, and the host's event */
        if (len > 0 && data[0] == 'A') {
            t->prompt = 1;
        }
        if (t->host.osc != NULL) {
            t->host.osc(t->host.user, id, data, len);
        }
        break;
    case 10:
    case 11:
    case 12:
        osc_dynamic(t, (int)id, data, len);
        break;
    case 104:
        osc_reset_palette(t, data, len);
        break;
    case 110:
    case 111:
    case 112:
        t->colors[VT_SLOT_FG + (int)(id - 110)] = t->default_colors[VT_SLOT_FG + (int)(id - 110)];
        break;
    default:
        if (t->host.osc != NULL) {
            t->host.osc(t->host.user, id, data, len);
        }
        break;
    }
}

static void osc_put(vt *t, uint8_t b) {
    if (t->osc_len == OSC_CAP) {
        t->osc_overflow = 1;
        return;
    }
    t->osc[t->osc_len] = b;
    t->osc_len++;
}

/* ---- parser (Paul Williams' VT500 state machine) ---- */

static void clear_seq(vt *t) {
    t->nparams = 0;
    t->colon = 0;
    t->prefix = 0;
    t->ninter = 0;
}

static void collect(vt *t, uint8_t b) {
    if (t->ninter >= 0 && t->ninter < MAX_INTER) {
        t->inter[t->ninter] = b;
    }
    t->ninter++;
}

static void param_byte(vt *t, uint8_t b) {
    if (t->nparams == 0) {
        t->params[0] = 0;
        t->nparams = 1;
    }
    if (b >= '0' && b <= '9') {
        uint32_t *p = &t->params[t->nparams - 1];
        *p = (*p * 10) + (uint32_t)(b - '0');
        if (*p > PARAM_MAX) {
            *p = PARAM_MAX;
        }
        return;
    }
    if (t->nparams == MAX_PARAMS) {
        return;
    }
    t->params[t->nparams] = 0;
    if (b == ':') {
        t->colon |= 1U << (uint32_t)t->nparams;
    }
    t->nparams++;
}

static void enter(vt *t, parse_state s) {
    t->state = s;
    if (s == ST_ESCAPE || s == ST_CSI_ENTRY) {
        clear_seq(t);
    }
    if (s == ST_OSC) {
        t->osc_len = 0;
        t->osc_overflow = 0;
    }
}

static void csi_final(vt *t, uint8_t b) {
    if (t->ninter <= MAX_INTER) {
        csi_dispatch(t, b);
    }
    t->state = ST_GROUND;
}

static void step_escape(vt *t, uint8_t b) {
    if (b >= 0x20 && b <= 0x2F) {
        collect(t, b);
        t->state = ST_ESCAPE_INTER;
        return;
    }
    switch (b) {
    case '[':
        enter(t, ST_CSI_ENTRY);
        return;
    case ']':
        enter(t, ST_OSC);
        return;
    case 'P':
    case 'X':
    case '^':
    case '_':
        t->state = ST_STRING_IGNORE;
        return;
    default:
        break;
    }
    if (b >= 0x30 && b <= 0x7E) {
        esc_dispatch(t, b);
        t->state = ST_GROUND;
    }
}

static void step_csi(vt *t, uint8_t b) {
    int digitish = (b >= '0' && b <= '9') || b == ';' || b == ':';
    if (b >= 0x40 && b <= 0x7E) {
        if (t->state == ST_CSI_IGNORE) {
            t->state = ST_GROUND;
            return;
        }
        csi_final(t, b);
        return;
    }
    if (t->state == ST_CSI_IGNORE) {
        return;
    }
    if (b >= 0x20 && b <= 0x2F) {
        collect(t, b);
        t->state = ST_CSI_INTER;
        return;
    }
    if (t->state == ST_CSI_INTER) {
        t->state = ST_CSI_IGNORE;
        return;
    }
    if (digitish) {
        param_byte(t, b);
        t->state = ST_CSI_PARAM;
        return;
    }
    if (b >= 0x3C && b <= 0x3F && t->state == ST_CSI_ENTRY) {
        t->prefix = b;
        t->state = ST_CSI_PARAM;
        return;
    }
    t->state = ST_CSI_IGNORE;
}

static void step(vt *t, uint8_t b) {
    if (t->state == ST_GROUND && t->utf.need > 0) {
        if ((b & 0xC0U) == 0x80U) {
            uint32_t cp = 0;
            int resync = 0;
            utf8_result r = utf8_dec_feed(&t->utf, b, &cp, &resync);
            if (r == UTF8_RUNE) {
                print(t, cp);
            }
            if (r == UTF8_ERROR) {
                print(t, UTF8_REPLACEMENT);
            }
            return;
        }
        utf8_dec_init(&t->utf);
        print(t, UTF8_REPLACEMENT);
    }
    if (b == 0x18 || b == 0x1A) {
        t->state = ST_GROUND;
        return;
    }
    if (b == 0x1B) {
        if (t->state == ST_OSC) {
            osc_dispatch(t);
        }
        enter(t, ST_ESCAPE);
        return;
    }
    switch (t->state) {
    case ST_GROUND:
        if (b < 0x20) {
            execute(t, b);
            return;
        }
        if (b == 0x7F) {
            return;
        }
        if (b < 0x80) {
            print(t, b);
            return;
        }
        if (t->encoding == VT_ENCODING_CP437) {
            print(t, cp437_high[b - 0x80]);
            return;
        }
        {
            uint32_t cp = 0;
            int resync = 0;
            utf8_result r = utf8_dec_feed(&t->utf, b, &cp, &resync);
            if (r == UTF8_ERROR) {
                print(t, UTF8_REPLACEMENT);
            }
        }
        return;
    case ST_OSC:
        if (b == 0x07) {
            osc_dispatch(t);
            t->state = ST_GROUND;
            return;
        }
        if (b >= 0x20) {
            osc_put(t, b);
        }
        return;
    case ST_STRING_IGNORE:
        return;
    default:
        break;
    }
    if (b < 0x20) {
        execute(t, b);
        return;
    }
    if (b >= 0x7F) {
        return;
    }
    switch (t->state) {
    case ST_ESCAPE:
        step_escape(t, b);
        return;
    case ST_ESCAPE_INTER:
        if (b >= 0x20 && b <= 0x2F) {
            collect(t, b);
            return;
        }
        if (t->ninter <= MAX_INTER) {
            esc_dispatch(t, b);
        }
        t->state = ST_GROUND;
        return;
    default:
        step_csi(t, b);
        return;
    }
}

void vt_write(vt *t, const uint8_t *buf, size_t len) {
    size_t i = 0;
    while (i < len) {
        if (t->state == ST_GROUND && t->utf.need == 0) {
            size_t j = i;
            while (j < len && buf[j] >= 0x20 && buf[j] < 0x7F) {
                j++;
            }
            if (j > i) {
                print_ascii(t, buf + i, j - i);
                i = j;
                continue;
            }
        }
        step(t, buf[i]);
        i++;
    }
    t->gen++;
}

/* ---- resize and queries ---- */

int vt_resize(vt *t, int rows, int cols) {
    if (rows < 1 || cols < 1 || rows > VT_MAX_ROWS || cols > VT_MAX_COLS) {
        return -1;
    }
    if (rows == t->rows && cols == t->cols) {
        return 0;
    }
    uint8_t *tabs = calloc((size_t)cols, 1);
    if (tabs == NULL) {
        return -1;
    }
    int prow = t->alt ? t->saved[0].row : t->row;
    int pcol = t->alt ? t->saved[0].col : t->col;
    int ppending = t->alt ? t->saved[0].pending : t->pending;
    if (ppending) {
        pcol++; /* the insertion point is after the last column, not on it */
    }
    int arow = t->alt ? t->row : 0;
    int acol = t->alt ? t->col : 0;
    /* both grids first, in temporaries: a failure leaves everything as it was */
    vt_grid primary;
    vt_grid alternate;
    if (grid_reflow_into(&t->grid[0], rows, cols, &prow, &pcol, &primary) != 0) {
        free(tabs);
        return -1;
    }
    if (grid_clip_into(&t->grid[1], rows, cols, &arow, &acol, &alternate) != 0) {
        grid_free(&primary);
        free(tabs);
        return -1;
    }
    grid_free(&t->grid[0]);
    grid_free(&t->grid[1]);
    t->grid[0] = primary;
    t->grid[1] = alternate;
    ppending = pcol >= cols; /* still past the edge: the wrap stays pending */
    if (ppending) {
        pcol = cols - 1;
    }
    int apending = t->pending && cols == t->cols; /* clipped, the column stands */
    if (t->alt) {
        t->saved[0].row = prow;
        t->saved[0].col = pcol;
        t->saved[0].pending = ppending;
        t->row = arow;
        t->col = acol;
        t->pending = apending;
    } else {
        t->row = prow;
        t->col = pcol;
        t->pending = ppending;
    }
    for (int i = 0; i < 2; i++) {
        t->saved[i].row = clampi(t->saved[i].row, 0, rows - 1);
        t->saved[i].col = clampi(t->saved[i].col, 0, cols - 1);
        if (cols != t->cols && !(t->alt && i == 0) && t->saved[i].pending) {
            /* a saved wrap (DECSC in the last column) belongs to the old
               width: the insertion point is after that character */
            if (t->saved[i].col + 1 < cols) {
                t->saved[i].col++;
            }
            t->saved[i].pending = 0;
        }
    }
    /* the tab stops stay: the ones set (HTS) up to the old width, the
       default every TAB_WIDTH beyond it */
    int kept = clampi(t->cols, 0, cols);
    memcpy(tabs, t->tabs, (size_t)kept);
    for (int i = kept; i < cols; i++) {
        tabs[i] = (uint8_t)(i % TAB_WIDTH == 0 && i > 0);
    }
    free(t->tabs);
    t->tabs = tabs;
    t->rows = rows;
    t->cols = cols;
    t->top = 0;
    t->bot = rows;
    t->gen++;
    return 0;
}

void vt_clear(vt *t) {
    vt_grid *g = screen(t);
    if (!t->alt) {
        grid_clear_history(&t->grid[0]); /* first: the scroll below then counts its lines as lost */
    }
    if (t->row > 0) {
        grid_scroll_up(g, 0, t->rows, t->row, blank_cell(t), 0);
        t->row = 0;
    }
    for (int r = 1; r < t->rows; r++) {
        erase_cells(t, r, 0, t->cols);
        *grid_wrapped(g, r) = 0;
    }
    t->gen++;
}

void vt_size(const vt *t, int *rows, int *cols) {
    *rows = t->rows;
    *cols = t->cols;
}

int vt_history(const vt *t) {
    if (t->alt) {
        return 0;
    }
    return t->grid[0].count - t->grid[0].rows;
}

void vt_copy_screen(const vt *t, int back, vt_cell *dst) {
    const vt_grid *g = &t->grid[t->alt];
    back = clampi(back, 0, vt_history(t));
    int first = g->count - g->rows - back;
    for (int r = 0; r < g->rows; r++) {
        memcpy(dst + ((size_t)r * (size_t)g->cols), grid_line(g, first + r),
               (size_t)g->cols * sizeof(vt_cell));
    }
}

typedef struct {
    uint8_t *out;
    size_t cap;
    size_t n; /* what the whole output takes, written or not */
} sink;

static void emit(sink *k, const char *s, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (k->n + i < k->cap) {
            k->out[k->n + i] = (uint8_t)s[i];
        }
    }
    k->n += len;
}

static void emits(sink *k, const char *s) {
    emit(k, s, strlen(s));
}

__attribute__((format(printf, 2, 3))) static void emitf(sink *k, const char *fmt, ...) {
    char buf[48];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0 && (size_t)n < sizeof(buf)) {
        emit(k, buf, (size_t)n);
    }
}

static void emit_color(sink *k, uint32_t c, int base, int bright, int ext) {
    uint32_t kind = VT_COLOR_KIND(c);
    uint32_t v = c & 0xFFFFFFU;
    if (kind == VT_COLOR_KIND_INDEX && v < 8) {
        emitf(k, ";%d", base + (int)v);
    } else if (kind == VT_COLOR_KIND_INDEX && v < 16) {
        emitf(k, ";%d", bright + (int)v - 8);
    } else if (kind == VT_COLOR_KIND_INDEX) {
        emitf(k, ";%d;5;%d", ext, (int)v);
    } else if (kind == VT_COLOR_KIND_RGB) {
        emitf(k, ";%d;2;%d", ext, (int)(v >> 16U));
        emitf(k, ";%d;%d", (int)((v >> 8U) & 0xFFU), (int)(v & 0xFFU));
    }
}

static void emit_sgr(sink *k, uint32_t fg, uint32_t bg, uint16_t attr) {
    static const struct {
        uint16_t bit;
        const char *code;
    } flags[] = {
        {VT_ATTR_BOLD, ";1"},   {VT_ATTR_DIM, ";2"},       {VT_ATTR_ITALIC, ";3"},
        {VT_ATTR_BLINK, ";5"},  {VT_ATTR_INVERSE, ";7"},   {VT_ATTR_INVISIBLE, ";8"},
        {VT_ATTR_STRIKE, ";9"}, {VT_ATTR_OVERLINE, ";53"},
    };
    emits(k, "\x1b[0");
    for (size_t i = 0; i < sizeof(flags) / sizeof(flags[0]); i++) {
        if ((attr & flags[i].bit) != 0) {
            emits(k, flags[i].code);
        }
    }
    uint32_t ul = ((uint32_t)attr & VT_ATTR_UL_MASK) >> VT_ATTR_UL_SHIFT;
    if (ul != 0) {
        emitf(k, ";4:%d", (int)ul);
    }
    emit_color(k, fg, 30, 90, 38);
    emit_color(k, bg, 40, 100, 48);
    emits(k, "m");
}

static void emit_mode(sink *k, const vt *t, int mode, uint32_t bit) {
    emitf(k, (t->modes & bit) != 0 ? "\x1b[?%dh" : "\x1b[?%dl", mode);
}

size_t vt_repaint(const vt *t, uint8_t *out, size_t cap) {
    sink k = {out, cap, 0};
    static const struct {
        int mode;
        uint32_t bit;
    } modes[] = {
        {1, VT_MODE_CURSOR_KEYS},        {5, VT_MODE_REVERSE},       {7, VT_MODE_AUTOWRAP},
        {9, VT_MODE_MOUSE_X10},          {12, VT_MODE_CURSOR_BLINK}, {1000, VT_MODE_MOUSE_BUTTON},
        {1002, VT_MODE_MOUSE_DRAG},      {1003, VT_MODE_MOUSE_ANY},  {1004, VT_MODE_FOCUS},
        {1005, VT_MODE_MOUSE_UTF8},      {1006, VT_MODE_MOUSE_SGR},  {1015, VT_MODE_MOUSE_URXVT},
        {2004, VT_MODE_BRACKETED_PASTE},
    };
    emits(&k, "\x1b[?25l\x1b[0m\x1b[r\x1b[H\x1b[2J");
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        emit_mode(&k, t, modes[i].mode, modes[i].bit);
    }
    emits(&k, (t->modes & VT_MODE_KEYPAD) != 0 ? "\x1b=" : "\x1b>");
    /* the screen is written in a known state (ASCII in GL, autowrap on,
       insert off) so every glyph lands as it is; the terminal's own
       charsets and modes come after it */
    emits(&k, "\x1b(B\x0f\x1b[?7h\x1b[4l\x1b[?6l");
    const vt_grid *g = &t->grid[t->alt];
    vt_cell pen;
    memset(&pen, 0, sizeof(pen));
    int after_wrap = 0; /* the row before was written whole and continues here */
    int after_pad = 0;  /* ...and ended in a pad: a wide glyph was written to make it */
    /* a pad on the last row cannot be made in turn: the wrap would scroll.
       Before the body, the row is kept out of the scroll region while the
       wide glyph makes it: the wrap goes nowhere, the glyph lands at the
       row's start, and the row's text written in turn covers it (DECSTBM
       homes the cursor, which the body's own CUP undoes). Too small a
       screen (the glyph would cover the pad itself) keeps a blank, which
       copies the same */
    {
        const vt_cell *last = grid_row(g, t->rows - 1);
        if (*grid_wrapped(g, t->rows - 1) != 0 && t->rows >= 3 && t->cols >= 3 &&
            (last[t->cols - 1].flags & VT_CELL_PAD) != 0) {
            emitf(&k, "\x1b[1;%dr\x1b[%d;%dH\xe4\xb8\xad\x1b[r", t->rows - 1, t->rows, t->cols);
        }
    }
    for (int r = 0; r < t->rows; r++) {
        const vt_cell *row = grid_row(g, r);
        int wrapped = *grid_wrapped(g, r) != 0;
        int padded = wrapped && t->cols >= 2 && (row[t->cols - 1].flags & VT_CELL_PAD) != 0;
        int end = t->cols;
        /* a soft-wrapped row is written whole, so the next row's first
           glyph wraps onto it the way the original did; others are trimmed */
        while (!wrapped && end > 0 && row[end - 1].cp == 0 && row[end - 1].bg == VT_COLOR_DEFAULT &&
               row[end - 1].attr == 0) {
            end--;
        }
        if (padded && r == t->rows - 1) {
            padded = 0; /* made before the body, or left blank: see above the loop */
        }
        if (end == 0) {
            if (after_pad) {
                emitf(&k, "\x1b[%d;1H\x1b[2X", r + 1); /* the glyph that made the pad */
            } else if (after_wrap) {
                /* an empty continuation: something has to wrap to mark the
                   row before as wrapped; a blank written, then erased */
                emits(&k, " \x1b[D\x1b[X");
            }
            after_wrap = 0;
            after_pad = 0;
            if (padded) {
                emitf(&k, "\x1b[%d;%dH\xe4\xb8\xad", r + 1, t->cols);
                after_wrap = 1;
                after_pad = 1;
            }
            continue;
        }
        if (!after_wrap || after_pad) {
            emitf(&k, "\x1b[%d;1H", r + 1);
        }
        for (int c = 0; c < end; c++) {
            const vt_cell *cell = &row[c];
            if ((cell->flags & (VT_CELL_WIDE_TAIL | VT_CELL_PAD)) != 0) {
                continue; /* a pad is made again by the wide glyph that wraps after it */
            }
            if (cell->fg != pen.fg || cell->bg != pen.bg || cell->attr != pen.attr) {
                emit_sgr(&k, cell->fg, cell->bg, cell->attr);
                pen = *cell;
            }
            uint8_t b[UTF8_MAX_BYTES];
            size_t len = utf8_encode(b, cell->cp == 0 ? ' ' : cell->cp);
            emit(&k, (const char *)b, len);
        }
        if (padded) {
            /* only a wide glyph that does not fit makes a pad: one is
               written here and wraps; the next row writes over it */
            emits(&k, "\xe4\xb8\xad");
        }
        after_wrap = wrapped;
        after_pad = padded;
    }
    if (t->top != 0 || t->bot != t->rows) {
        emitf(&k, "\x1b[%d;%dr", t->top + 1, t->bot);
    }
    if (t->title[0] != '\0') {
        emits(&k, "\x1b]2;");
        emits(&k, t->title);
        emits(&k, "\x07");
    }
    emit_mode(&k, t, 6, VT_MODE_ORIGIN);
    emitf(&k, "\x1b[%d;%dH", t->row - ((t->modes & VT_MODE_ORIGIN) != 0 ? t->top : 0) + 1,
          t->col + 1);
    const vt_cell *row = grid_row(g, t->row);
    if (t->pending && (t->modes & VT_MODE_AUTOWRAP) != 0 &&
        (row[t->col].flags & VT_CELL_PAD) == 0) {
        /* the wrap pending: the cursor sits on the last column it wrote;
           writing that glyph once more leaves the destination the same way.
           A pad under it (a scroll moved the rows) no stream can rewrite:
           the text wins, the pending bit goes */
        int head = (row[t->col].flags & VT_CELL_WIDE_TAIL) != 0 && t->col > 0 ? t->col - 1 : t->col;
        emitf(&k, "\x1b[%d;%dH", t->row - ((t->modes & VT_MODE_ORIGIN) != 0 ? t->top : 0) + 1,
              head + 1);
        emit_sgr(&k, row[head].fg, row[head].bg, row[head].attr);
        uint8_t b[UTF8_MAX_BYTES];
        size_t len = utf8_encode(b, row[head].cp == 0 ? ' ' : row[head].cp);
        emit(&k, (const char *)b, len);
    }
    for (int i = 0; i < 4; i++) {
        emitf(&k, "\x1b%c%c", "()*+"[i], t->charset[i] != 0 ? t->charset[i] : 'B');
    }
    static const char *const shifts[] = {"\x0f", "\x0e", "\x1bn", "\x1bo"};
    emits(&k, shifts[clampi(t->gl, 0, 3)]);
    emit_mode(&k, t, 7, VT_MODE_AUTOWRAP);
    emits(&k, (t->modes & VT_MODE_INSERT) != 0 ? "\x1b[4h" : "\x1b[4l");
    emits(&k, (t->modes & VT_MODE_NEWLINE) != 0 ? "\x1b[20h" : "\x1b[20l");
    emitf(&k, "\x1b[%d q", t->cursor_style);
    emit_sgr(&k, t->pen.fg, t->pen.bg, t->pen.attr);
    if ((t->modes & VT_MODE_CURSOR_VISIBLE) != 0) {
        emits(&k, "\x1b[?25h");
    }
    return k.n;
}

int vt_lines(const vt *t) {
    return t->grid[t->alt].count;
}

uint64_t vt_base(const vt *t) {
    return (uint64_t)(t->base_shift + (int64_t)t->grid[t->alt].lost);
}

static size_t put_rune(uint8_t *out, size_t n, size_t cap, uint32_t cp) {
    uint8_t b[UTF8_MAX_BYTES];
    size_t k = utf8_encode(b, cp);
    if (n + k > cap) {
        return n;
    }
    memcpy(out + n, b, k);
    return n + k;
}

size_t vt_copy_text(const vt *t, int l0, int c0, int l1, int c1, uint8_t *out, size_t cap) {
    const vt_grid *g = &t->grid[t->alt];
    if (l1 < l0 || (l1 == l0 && c1 < c0)) {
        int tl = l0;
        int tc = c0;
        l0 = l1;
        c0 = c1;
        l1 = tl;
        c1 = tc;
    }
    l0 = clampi(l0, 0, g->count - 1);
    l1 = clampi(l1, 0, g->count - 1);
    c0 = clampi(c0, 0, g->cols - 1);
    c1 = clampi(c1, 0, g->cols - 1);
    size_t n = 0;
    for (int line = l0; line <= l1; line++) {
        const vt_cell *row = grid_line(g, line);
        int wrapped = g->wrapped[grid_storage(g, line)] && line != l1;
        int from = line == l0 ? c0 : 0;
        int end = line == l1 ? c1 + 1 : g->cols;
        if (!wrapped) {
            while (end > from && (row[end - 1].cp == 0 || row[end - 1].cp == ' ')) {
                end--;
            }
        }
        for (int i = from; i < end; i++) {
            if ((row[i].flags & (VT_CELL_WIDE_TAIL | VT_CELL_PAD)) != 0) {
                continue;
            }
            n = put_rune(out, n, cap, row[i].cp == 0 ? ' ' : row[i].cp);
        }
        if (line != l1 && !wrapped) {
            n = put_rune(out, n, cap, '\n');
        }
    }
    return n;
}

static uint32_t fold(uint32_t cp) {
    if ((cp >= 'A' && cp <= 'Z') || (cp >= 0xC0 && cp <= 0xDE && cp != 0xD7)) {
        return cp + 32;
    }
    return cp == 0 ? ' ' : cp;
}

/* Where needle starts in row (ignoring case, cells of wide glyphs as one),
   first match after col going forward, last before col going back; -1 if
   none. *end gets the last cell of the match. */
/* The row's runes folded once, each with its cell (wide tails and pads
   skipped), then the needle (folded by the caller) against them: the
   search is a loop over whole lines, so this is where its time goes. */
static int find_in_row(const vt_cell *row, int cols, const uint32_t *needle, int n, int back,
                       int col, int *end, uint32_t *vals, int *pos) {
    int m = 0;
    for (int c = 0; c < cols; c++) {
        if ((row[c].flags & (VT_CELL_WIDE_TAIL | VT_CELL_PAD)) == 0) {
            vals[m] = fold(row[c].cp);
            pos[m] = c;
            m++;
        }
    }
    int found = -1;
    for (int i = 0; i + n <= m; i++) {
        if (back ? pos[i] >= col : pos[i] <= col) {
            if (back) {
                break;
            }
            continue;
        }
        if (vals[i] != needle[0]) {
            continue;
        }
        int k = 1;
        while (k < n && vals[i + k] == needle[k]) {
            k++;
        }
        if (k == n) {
            found = pos[i];
            *end = pos[i + n - 1];
            if (!back) {
                break;
            }
        }
    }
    return found;
}

int vt_find(const vt *t, const uint32_t *needle, int n, int back, int *line, int *col, int *end) {
    const vt_grid *g = &t->grid[t->alt];
    if (n <= 0 || n > g->cols) {
        return 0;
    }
    uint32_t folded[VT_MAX_COLS]; /* 48 KB of stack: the core keeps no state of its own */
    uint32_t vals[VT_MAX_COLS];
    int pos[VT_MAX_COLS];
    for (int k = 0; k < n; k++) {
        folded[k] = fold(needle[k]);
    }
    int l = clampi(*line, 0, g->count - 1);
    int c = *line >= g->count ? g->cols : *col;
    if (*line < 0) {
        c = -1;
    }
    for (; back ? l >= 0 : l < g->count; l += back ? -1 : 1) {
        int e = 0;
        int at = find_in_row(grid_line(g, l), g->cols, folded, n, back, c, &e, vals, pos);
        if (at >= 0) {
            *line = l;
            *col = at;
            *end = e;
            return 1;
        }
        c = back ? g->cols : -1;
    }
    return 0;
}

vt_cursor vt_get_cursor(const vt *t) {
    vt_cursor c;
    c.row = t->row;
    c.col = t->col;
    c.visible = (t->modes & VT_MODE_CURSOR_VISIBLE) != 0;
    c.style = t->cursor_style;
    return c;
}

uint32_t vt_modes(const vt *t) {
    return t->modes;
}

const char *vt_title(const vt *t) {
    return t->title;
}

const char *vt_cwd(const vt *t) {
    return t->cwd;
}

int vt_width(uint32_t cp) {
    return cp < 0x300 ? 1 : utf8_width(cp);
}

int vt_wrapped(const vt *t, int line) {
    const vt_grid *g = &t->grid[t->alt];
    if (line < 0 || line >= g->count - 1) {
        return 0;
    }
    return g->wrapped[grid_storage(g, line)];
}

int vt_prompt(const vt *t, int line, int back) {
    const vt_grid *g = &t->grid[t->alt];
    int dir = back ? -1 : 1;
    for (int l = line + dir; l >= 0 && l < g->count; l += dir) {
        const vt_cell *row = grid_line(g, l);
        for (int c = 0; c < g->cols; c++) {
            if ((row[c].flags & VT_CELL_PROMPT) != 0) {
                return l;
            }
        }
    }
    return -1;
}

const char *vt_link(const vt *t, int id) {
    if (id <= 0 || id > LINK_MAX || t->links[id] == NULL) {
        return NULL;
    }
    return strchr(t->links[id], '\x1f') + 1;
}

uint64_t vt_generation(const vt *t) {
    return t->gen;
}

void vt_set_encoding(vt *t, int encoding) {
    t->encoding = encoding == VT_ENCODING_CP437 ? VT_ENCODING_CP437 : VT_ENCODING_UTF8;
    utf8_dec_init(&t->utf);
}

void vt_config_color(vt *t, int slot, uint32_t rgb) {
    if (slot < 0 || slot >= VT_SLOT_COUNT) {
        return;
    }
    t->colors[slot] = rgb & 0xFFFFFFU;
    t->default_colors[slot] = rgb & 0xFFFFFFU;
    t->gen++;
}

uint32_t vt_color(const vt *t, int slot) {
    if (slot < 0 || slot >= VT_SLOT_COUNT) {
        return 0;
    }
    return t->colors[slot];
}
