#include "vt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* First two bytes pick the size. Markers in the stream: 0xFF resizes to the
   next two bytes, 0xFD clears (Cmd+K), 0xFE is a checkpoint. At every
   checkpoint, and at the end, the properties the app relies on are checked
   against the state before: anything the grid lied about is as bad as a
   crash. */
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

enum { MAX_ROWS = 40, MAX_COLS = 120, MAX_HISTORY = 50 };
enum { LINE_CAP = MAX_COLS * 4 + 2 };

typedef struct {
    uint64_t base;
    uint64_t gen;
    int rows;
    int cols;
    int history;
    vt_cursor cursor;
    uint32_t modes;
    vt_cell cells[MAX_ROWS * MAX_COLS];
    uint8_t text[MAX_HISTORY * LINE_CAP]; /* each history line, NUL-terminated */
} shot;

static void fail(const char *what) {
    fprintf(stderr, "%s\n", what);
    abort();
}

static size_t line_text(const vt *t, int line, int cols, uint8_t *out) {
    size_t n = vt_copy_text(t, line, 0, line, cols - 1, out, LINE_CAP - 1);
    out[n] = 0;
    return n;
}

static void take(const vt *t, shot *s) {
    s->base = vt_base(t);
    s->gen = vt_generation(t);
    vt_size(t, &s->rows, &s->cols);
    s->history = vt_history(t);
    s->cursor = vt_get_cursor(t);
    s->modes = vt_modes(t);
    vt_copy_screen(t, 0, s->cells);
    for (int l = 0; l < s->history; l++) {
        line_text(t, l, s->cols, s->text + (size_t)l * LINE_CAP);
    }
}

/* A history line never changes: its address, moved by what the base lost,
   still names the same text, or the line is gone. A size change renumbers
   everything, so the base must have passed every old address. */
static void check_addresses(const vt *t, const shot *before) {
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    uint64_t base = vt_base(t);
    if (base < before->base) {
        fail("base went backwards");
    }
    uint64_t delta = base - before->base;
    if ((rows != before->rows || cols != before->cols) &&
        delta < (uint64_t)(before->history + before->rows)) {
        fail("resize kept old line addresses alive");
    }
    int history = vt_history(t);
    uint8_t now[LINE_CAP];
    for (int l = 0; l < before->history; l++) {
        if ((uint64_t)l < delta) {
            continue;
        }
        int at = (int)((uint64_t)l - delta);
        if (at >= history) {
            fail("a history line came back to the screen");
        }
        line_text(t, at, cols, now);
        if (strcmp((const char *)now, (const char *)before->text + (size_t)l * LINE_CAP) != 0) {
            fprintf(stderr, "history line %d (now %d) changed: '%s' -> '%s'\n", l, at,
                    before->text + (size_t)l * LINE_CAP, now);
            abort();
        }
    }
}

/* The renderer skips a frame when the generation did not move: it must
   move whenever anything it draws did. */
static void check_generation(const vt *t, const shot *before) {
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    vt_cursor cursor = vt_get_cursor(t);
    uint32_t modes = vt_modes(t);
    vt_cell *cells = malloc((size_t)rows * (size_t)cols * sizeof(vt_cell));
    if (cells == NULL) {
        return;
    }
    vt_copy_screen(t, 0, cells);
    int same = rows == before->rows && cols == before->cols &&
               memcmp(&cursor, &before->cursor, sizeof(vt_cursor)) == 0 &&
               ((modes ^ before->modes) & (VT_MODE_REVERSE | VT_MODE_CURSOR_VISIBLE)) == 0 &&
               memcmp(cells, before->cells, (size_t)rows * (size_t)cols * sizeof(vt_cell)) == 0;
    free(cells);
    if (!same && vt_generation(t) == before->gen) {
        fail("the picture changed and the generation did not");
    }
}

static void check_cursor(const vt *t) {
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    vt_cursor c = vt_get_cursor(t);
    if (c.row < 0 || c.row >= rows || c.col < 0 || c.col >= cols) {
        fprintf(stderr, "cursor %d,%d outside %dx%d\n", c.row, c.col, rows, cols);
        abort();
    }
}

/* Every head has its tail right after it and every tail its head before. */
static void check_wide(const vt_cell *cells, int rows, int cols) {
    for (int r = 0; r < rows; r++) {
        const vt_cell *row = cells + (size_t)r * (size_t)cols;
        for (int c = 0; c < cols; c++) {
            if ((row[c].flags & VT_CELL_WIDE) != 0 &&
                (c + 1 >= cols || (row[c + 1].flags & VT_CELL_WIDE_TAIL) == 0)) {
                fprintf(stderr, "wide head without tail at %d,%d\n", r, c);
                abort();
            }
            if ((row[c].flags & VT_CELL_WIDE_TAIL) != 0 &&
                (c == 0 || (row[c - 1].flags & VT_CELL_WIDE) == 0)) {
                fprintf(stderr, "wide tail without head at %d,%d\n", r, c);
                abort();
            }
        }
    }
}

static uint32_t fold(uint32_t cp) {
    return cp >= 'A' && cp <= 'Z' ? cp + 32 : cp;
}

/* The search finds what is on the screen, every hit reads back as the
   needle, the hits come in order, and backwards walks the same hits. */
static void check_search(const vt *t, const shot *s, unsigned seed) {
    if (s->cols < 1 || s->rows < 1) {
        return;
    }
    int r = (int)(seed % (unsigned)s->rows);
    const vt_cell *row = s->cells + (size_t)r * (size_t)s->cols;
    int start = -1;
    int run = 0;
    for (int c = 0; c < s->cols; c++) {
        int plain = row[c].cp > ' ' && row[c].cp < 0x7F && (row[c].flags & ~VT_CELL_PROMPT) == 0;
        if (plain && start < 0) {
            start = c;
        }
        if (plain) {
            run++;
        } else if (start >= 0) {
            break;
        }
    }
    if (start < 0) {
        return;
    }
    int n = 1 + (int)((seed / 7U) % 6U);
    if (n > run) {
        n = run;
    }
    uint32_t needle[8];
    for (int k = 0; k < n; k++) {
        needle[k] = row[start + k].cp;
    }
    int total = vt_lines(t) * s->cols + 1;
    int (*hits)[2] = malloc((size_t)total * sizeof(*hits));
    if (hits == NULL) {
        return;
    }
    int count = 0;
    int line = -1;
    int col = -1;
    int end = 0;
    uint8_t text[LINE_CAP];
    while (vt_find(t, needle, n, 0, &line, &col, &end)) {
        if (count >= total) {
            fail("the forward search never ends");
        }
        if (count > 0 && (line < hits[count - 1][0] ||
                          (line == hits[count - 1][0] && col <= hits[count - 1][1]))) {
            fail("the forward search went backwards");
        }
        size_t len = vt_copy_text(t, line, col, line, end, text, sizeof(text) - 1);
        if (len != (size_t)n) {
            fprintf(stderr, "hit at %d,%d..%d reads %zu bytes for a needle of %d\n", line, col, end,
                    len, n);
            abort();
        }
        for (int k = 0; k < n; k++) {
            if (fold(text[k]) != fold(needle[k])) {
                fail("a hit does not read back as the needle");
            }
        }
        hits[count][0] = line;
        hits[count][1] = col;
        count++;
    }
    int screen_line = vt_lines(t) - s->rows + r;
    int seen = 0;
    for (int i = 0; i < count; i++) {
        if (hits[i][0] == screen_line && hits[i][1] == start) {
            seen = 1;
        }
    }
    if (!seen) {
        fprintf(stderr, "the needle at %d,%d was not found (%d hits)\n", screen_line, start, count);
        abort();
    }
    line = vt_lines(t);
    col = s->cols;
    int i = count;
    while (vt_find(t, needle, n, 1, &line, &col, &end)) {
        i--;
        if (i < 0 || hits[i][0] != line || hits[i][1] != col) {
            fprintf(stderr, "backward search disagrees at hit %d: %d,%d\n", i, line, col);
            abort();
        }
    }
    if (i != 0) {
        fail("the backward search stopped early");
    }
    free(hits);
}

/* Every line's cells, history first: vt_copy_screen a screenful at a time. */
static vt_cell *all_cells(const vt *t, int rows, int cols, int lines) {
    int history = vt_history(t);
    vt_cell *all = malloc((size_t)lines * (size_t)cols * sizeof(vt_cell));
    vt_cell *page = malloc((size_t)rows * (size_t)cols * sizeof(vt_cell));
    if (all == NULL || page == NULL) {
        free(all);
        free(page);
        return NULL;
    }
    for (int top = 0; top < lines; top += rows) {
        int back = history - top;
        if (back < 0) {
            back = 0;
            top = history;
        }
        vt_copy_screen(t, back, page);
        for (int r = 0; r < rows && top + r < lines; r++) {
            memcpy(all + ((size_t)(top + r) * (size_t)cols), page + ((size_t)r * (size_t)cols),
                   (size_t)cols * sizeof(vt_cell));
        }
        if (back == 0) {
            break;
        }
    }
    free(page);
    return all;
}

static size_t put_cp(uint8_t *out, size_t n, size_t cap, uint32_t cp) {
    uint8_t b[4];
    size_t k;
    if (cp < 0x80) {
        b[0] = (uint8_t)cp;
        k = 1;
    } else if (cp < 0x800) {
        b[0] = (uint8_t)(0xC0 | (cp >> 6));
        b[1] = (uint8_t)(0x80 | (cp & 0x3F));
        k = 2;
    } else if (cp < 0x10000) {
        b[0] = (uint8_t)(0xE0 | (cp >> 12));
        b[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (uint8_t)(0x80 | (cp & 0x3F));
        k = 3;
    } else {
        b[0] = (uint8_t)(0xF0 | (cp >> 18));
        b[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        b[3] = (uint8_t)(0x80 | (cp & 0x3F));
        k = 4;
    }
    if (n + k > cap) {
        return cap + 1;
    }
    memcpy(out + n, b, k);
    return n + k;
}

/* What the copy of (l0,c0)..(l1,c1) must read, from the cells alone: rows
   autowrap joined stay one line, others end in a newline with trailing
   blanks dropped, wide tails and pads take no character. */
static size_t expected_copy(const vt *t, const vt_cell *all, int cols, int l0, int c0, int l1,
                            int c1, uint8_t *out, size_t cap) {
    size_t n = 0;
    for (int line = l0; line <= l1; line++) {
        const vt_cell *row = all + ((size_t)line * (size_t)cols);
        int wrapped = vt_wrapped(t, line) && line != l1;
        int from = line == l0 ? c0 : 0;
        int end = line == l1 ? c1 + 1 : cols;
        if (!wrapped) {
            while (end > from && (row[end - 1].cp == 0 || row[end - 1].cp == ' ')) {
                end--;
            }
        }
        for (int i = from; i < end; i++) {
            if ((row[i].flags & (VT_CELL_WIDE_TAIL | VT_CELL_PAD)) != 0) {
                continue;
            }
            n = put_cp(out, n, cap, row[i].cp == 0 ? ' ' : row[i].cp);
        }
        if (line != l1 && !wrapped) {
            n = put_cp(out, n, cap, '\n');
        }
        if (n > cap) {
            return n;
        }
    }
    return n;
}

/* The copy reads what the cells say, for the whole text and for ranges
   picked from the stream, both ends given in either order. */
static void check_copy(const vt *t, unsigned seed) {
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    int lines = vt_lines(t);
    vt_cell *all = all_cells(t, rows, cols, lines);
    if (all == NULL) {
        return;
    }
    size_t cap = (size_t)lines * ((size_t)cols * 4 + 1) + 1;
    uint8_t *want = malloc(cap * 2);
    if (want == NULL) {
        free(all);
        return;
    }
    uint8_t *got = want + cap;
    int ranges[3][4] = {{0, 0, lines - 1, cols - 1}, {0, 0, 0, 0}, {0, 0, 0, 0}};
    for (int i = 1; i < 3; i++) {
        unsigned x = seed * 2654435761U + (unsigned)i * 40503U;
        ranges[i][0] = (int)(x % (unsigned)lines);
        ranges[i][1] = (int)((x >> 8) % (unsigned)cols);
        ranges[i][2] = (int)((x >> 16) % (unsigned)lines);
        ranges[i][3] = (int)((x >> 24) % (unsigned)cols);
    }
    for (int i = 0; i < 3; i++) {
        int l0 = ranges[i][0];
        int c0 = ranges[i][1];
        int l1 = ranges[i][2];
        int c1 = ranges[i][3];
        size_t ng = vt_copy_text(t, l0, c0, l1, c1, got, cap);
        if (l1 < l0 || (l1 == l0 && c1 < c0)) {
            int tl = l0;
            int tc = c0;
            l0 = l1;
            c0 = c1;
            l1 = tl;
            c1 = tc;
        }
        size_t nw = expected_copy(t, all, cols, l0, c0, l1, c1, want, cap);
        if (nw != ng || memcmp(want, got, nw) != 0) {
            fprintf(stderr, "copy of %d,%d..%d,%d reads %zu bytes, the cells say %zu\n", l0, c0, l1,
                    c1, ng, nw);
            abort();
        }
    }
    free(want);
    free(all);
}

/* vt_prompt walks exactly the lines holding a prompt mark, both ways. */
static void check_prompts(const vt *t) {
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    int lines = vt_lines(t);
    int history = vt_history(t);
    uint8_t *marked = calloc((size_t)lines, 1);
    vt_cell *cells = malloc((size_t)rows * (size_t)cols * sizeof(vt_cell));
    if (marked == NULL || cells == NULL) {
        free(marked);
        free(cells);
        return;
    }
    for (int top = 0; top < lines; top += rows) {
        int back = history - top;
        if (back < 0) {
            back = 0;
            top = history;
        }
        vt_copy_screen(t, back, cells);
        for (int r = 0; r < rows && top + r < lines; r++) {
            for (int c = 0; c < cols; c++) {
                if ((cells[(size_t)r * (size_t)cols + (size_t)c].flags & VT_CELL_PROMPT) != 0) {
                    marked[top + r] = 1;
                }
            }
        }
        if (back == 0) {
            break;
        }
    }
    int at = -1;
    for (int l = 0; l < lines; l++) {
        if (!marked[l]) {
            continue;
        }
        int next = vt_prompt(t, at, 0);
        if (next != l) {
            fprintf(stderr, "prompt after %d: got %d, marked %d\n", at, next, l);
            abort();
        }
        at = l;
    }
    if (vt_prompt(t, at, 0) != -1) {
        fail("a prompt after the last one");
    }
    at = lines;
    for (int l = lines - 1; l >= 0; l--) {
        if (!marked[l]) {
            continue;
        }
        int prev = vt_prompt(t, at, 1);
        if (prev != l) {
            fprintf(stderr, "prompt before %d: got %d, marked %d\n", at, prev, l);
            abort();
        }
        at = l;
    }
    if (vt_prompt(t, at, 1) != -1) {
        fail("a prompt before the first one");
    }
    free(marked);
    free(cells);
}

/* Repainting a screen onto itself changes nothing the copy can see: the
   text, its soft wraps, where the next glyph goes; anything else and the
   repaint lies to the Mosh side. */
static void check_repaint(vt *t) {
    /* an unfinished UTF-8 sequence in the decoder would flush on the
       repaint's first ESC: settle it before the clone (ESC \ is nothing) */
    vt_write(t, (const uint8_t *)"\x1b\\", 2);
    vt *copy = vt_clone(t);
    if (copy == NULL) {
        return;
    }
    size_t need = vt_repaint(copy, NULL, 0);
    uint8_t *paint = malloc(need);
    if (paint == NULL) {
        vt_free(copy);
        return;
    }
    vt_repaint(copy, paint, need);
    int rows;
    int cols;
    vt_size(t, &rows, &cols);
    size_t cap = (size_t)rows * (size_t)cols * 4 + (size_t)rows + 8;
    /* one column cannot take a wide glyph by writing (a reflow to it keeps
       one in a single cell): the property holds from two up */
    uint8_t *before = cols >= 2 ? malloc(cap * 2) : NULL;
    if (before == NULL) {
        vt_write(t, paint, need);
    } else {
        uint8_t *after = before + cap;
        int first = vt_lines(t) - rows;
        size_t nb = vt_copy_text(t, first, 0, first + rows - 1, cols - 1, before, cap);
        vt_write(t, paint, need);
        size_t na = vt_copy_text(t, first, 0, first + rows - 1, cols - 1, after, cap);
        /* a row ending in a pad (a wide glyph that did not fit) followed by
           a narrow glyph cannot be rewrapped by writing: the lines may
           regroup, the text may not */
        while (nb > 0 && before[nb - 1] == '\n') {
            nb--;
        }
        while (na > 0 && after[na - 1] == '\n') {
            na--;
        }
        if (na != nb || memcmp(before, after, na) != 0) {
            fprintf(stderr, "repaint changed the copy: %zu -> %zu bytes\n", nb, na);
            abort();
        }
        free(before);
    }
    free(paint);
    vt_free(copy);
}

static void checkpoint(vt *t, shot *s, unsigned seed, int deep) {
    check_addresses(t, s);
    check_generation(t, s);
    check_cursor(t);
    take(t, s);
    check_wide(s->cells, s->rows, s->cols);
    if (deep) {
        check_search(t, s, seed);
        check_prompts(t);
        check_copy(t, seed);
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 2) {
        return 0;
    }
    int rows = 1 + data[0] % MAX_ROWS;
    int cols = 1 + data[1] % MAX_COLS;
    vt *t = vt_new(rows, cols, data[0] % MAX_HISTORY, NULL);
    if (t == NULL) {
        return 0;
    }
    shot *s = malloc(sizeof(*s));
    if (s == NULL) {
        vt_free(t);
        return 0;
    }
    take(t, s);
    size_t start = 2;
    for (size_t i = 2; i < size; i++) {
        if (data[i] < 0xFD) {
            continue;
        }
        if (data[i] == 0xFF && i + 2 >= size) {
            continue;
        }
        vt_write(t, data + start, i - start);
        if (data[i] == 0xFF) {
            rows = 1 + data[i + 1] % MAX_ROWS;
            cols = 1 + data[i + 2] % MAX_COLS;
            vt_resize(t, rows, cols);
            checkpoint(t, s, (unsigned)i, 1);
            i += 2;
        } else if (data[i] == 0xFD) {
            vt_clear(t);
            checkpoint(t, s, (unsigned)i, 0);
        } else {
            checkpoint(t, s, (unsigned)i, 0);
        }
        start = i + 1;
    }
    if (start < size) {
        vt_write(t, data + start, size - start);
    }
    uint8_t reply[512];
    while (vt_reply(t, reply, sizeof(reply)) > 0) {
    }
    uint8_t in[VT_INPUT_MAX];
    for (size_t i = 0; i + 3 < size && i < 64; i += 4) {
        vt_key(t, data[i] % 32, data[i + 1] % 8U, in);
        vt_text(t, (uint32_t)data[i + 2] << (data[i + 3] % 12U), data[i + 1] % 8U, in);
        vt_mouse(t, data[i] % 3, data[i + 1] % 8, data[i + 2], (int)data[i + 3] * 9, data[i] % 8U,
                 in);
    }
    checkpoint(t, s, (unsigned)size, 1);
    check_repaint(t);
    uint8_t paste[4096 + 12];
    vt_paste(t, data, size < 4096 ? size : 4096, paste);
    free(s);
    vt_free(t);
    return 0;
}
