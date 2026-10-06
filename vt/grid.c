#include "grid.h"

#include <stdlib.h>
#include <string.h>

#ifdef VT_TESTING
/* Tests inject allocation failures: the n-th allocation from now fails.
   The one piece of global state in the core, and only in test builds. */
int vt_testing_fail_at = 0;
static int fail_now(void) {
    if (vt_testing_fail_at > 0 && --vt_testing_fail_at == 0) {
        return 1;
    }
    return 0;
}
#define GRID_CALLOC(n, s) (fail_now() ? NULL : calloc((n), (s)))
#define GRID_MALLOC(n) (fail_now() ? NULL : malloc(n))
#define GRID_REALLOC(p, n) (fail_now() ? NULL : realloc((p), (n)))
#else
#define GRID_CALLOC(n, s) calloc((n), (s))
#define GRID_MALLOC(n) malloc(n)
#define GRID_REALLOC(p, n) realloc((p), (n))
#endif

static int alloc_storage(vt_grid *g, int rows, int cols, int cap) {
    vt_cell *cells = GRID_CALLOC((size_t)cap * (size_t)cols, sizeof(vt_cell));
    uint8_t *wrapped = GRID_CALLOC((size_t)cap, 1);
    uint32_t *ring = GRID_MALLOC((size_t)cap * sizeof(uint32_t));
    if (cells == NULL || wrapped == NULL || ring == NULL) {
        free(cells);
        free(wrapped);
        free(ring);
        return -1;
    }
    for (int i = 0; i < cap; i++) {
        ring[i] = (uint32_t)i;
    }
    g->cells = cells;
    g->wrapped = wrapped;
    g->ring = ring;
    g->rows = rows;
    g->cols = cols;
    g->cap = cap;
    g->start = 0;
    g->count = rows;
    return 0;
}

int grid_init(vt_grid *g, int rows, int cols, int history) {
    memset(g, 0, sizeof(*g));
    return alloc_storage(g, rows, cols, rows + history);
}

void grid_free(vt_grid *g) {
    free(g->cells);
    free(g->wrapped);
    free(g->ring);
    memset(g, 0, sizeof(*g));
}

int grid_copy(vt_grid *dst, const vt_grid *src) {
    vt_grid g;
    memset(&g, 0, sizeof(g));
    if (alloc_storage(&g, src->rows, src->cols, src->cap) != 0) {
        return -1;
    }
    memcpy(g.cells, src->cells, (size_t)src->cap * (size_t)src->cols * sizeof(vt_cell));
    memcpy(g.wrapped, src->wrapped, (size_t)src->cap);
    memcpy(g.ring, src->ring, (size_t)src->cap * sizeof(uint32_t));
    g.start = src->start;
    g.count = src->count;
    g.lost = src->lost;
    *dst = g;
    return 0;
}

static int slot_of(const vt_grid *g, int line) {
    return (g->start + line) % g->cap;
}

uint32_t grid_storage(const vt_grid *g, int line) {
    return g->ring[slot_of(g, line)];
}

vt_cell *grid_line(const vt_grid *g, int line) {
    return g->cells + ((size_t)grid_storage(g, line) * (size_t)g->cols);
}

vt_cell *grid_row(const vt_grid *g, int row) {
    return grid_line(g, g->count - g->rows + row);
}

uint8_t *grid_wrapped(const vt_grid *g, int row) {
    return g->wrapped + grid_storage(g, g->count - g->rows + row);
}

void grid_fill(vt_cell *cells, int n, vt_cell blank) {
    for (int i = 0; i < n; i++) {
        cells[i] = blank;
    }
}

/* Mutates the grid's cells; a const grid here would cascade into grid_clear's
   public signature and read as "does not modify". */
// cppcheck-suppress constParameterPointer
static void clear_row(vt_grid *g, int row, vt_cell blank) {
    grid_fill(grid_row(g, row), g->cols, blank);
    *grid_wrapped(g, row) = 0;
}

void grid_clear(vt_grid *g, vt_cell blank) {
    for (int r = 0; r < g->rows; r++) {
        clear_row(g, r, blank);
    }
}

void grid_clear_history(vt_grid *g) {
    g->start = slot_of(g, g->count - g->rows);
    g->lost += (uint64_t)(g->count - g->rows);
    g->count = g->rows;
}

static void swap_rows(vt_grid *g, int a, int b) {
    int base = g->count - g->rows;
    int sa = slot_of(g, base + a);
    int sb = slot_of(g, base + b);
    uint32_t tmp = g->ring[sa];
    g->ring[sa] = g->ring[sb];
    g->ring[sb] = tmp;
}

static void reverse_rows(vt_grid *g, int lo, int hi) {
    while (lo < hi) {
        swap_rows(g, lo, hi);
        lo++;
        hi--;
    }
}

/* Rotation by three reversals: O(bot - top) slot swaps for any n. */
static void rotate_up(vt_grid *g, int top, int bot, int n) {
    reverse_rows(g, top, top + n - 1);
    reverse_rows(g, top + n, bot - 1);
    reverse_rows(g, top, bot - 1);
}

void grid_scroll_up(vt_grid *g, int top, int bot, int n, vt_cell blank, int history) {
    if (n <= 0 || top >= bot) {
        return;
    }
    if (history) {
        if (n > g->cap) {
            n = g->cap;
        }
        for (int k = 0; k < n; k++) {
            if (g->count < g->cap) {
                g->count++;
            } else {
                g->start = (g->start + 1) % g->cap;
                g->lost++;
            }
            clear_row(g, g->rows - 1, blank);
        }
        return;
    }
    if (n > bot - top) {
        n = bot - top;
    }
    if (top == 0 && bot == g->rows && g->count == g->rows) {
        g->lost += (uint64_t)n; /* nothing above: the lines that left were the first addressed */
    }
    rotate_up(g, top, bot, n);
    for (int r = bot - n; r < bot; r++) {
        clear_row(g, r, blank);
    }
}

void grid_scroll_down(vt_grid *g, int top, int bot, int n, vt_cell blank) {
    if (n <= 0 || top >= bot) {
        return;
    }
    if (n > bot - top) {
        n = bot - top;
    }
    if (n < bot - top) {
        rotate_up(g, top, bot, bot - top - n);
    }
    for (int r = top; r < top + n; r++) {
        clear_row(g, r, blank);
    }
}

static int cell_blank(const vt_cell *c) {
    return c->cp == 0 && c->bg == VT_COLOR_DEFAULT && c->attr == 0 &&
           (c->flags & (VT_CELL_WIDE | VT_CELL_WIDE_TAIL)) == 0;
}

typedef struct {
    vt_cell *cells;
    uint8_t *wrapped;
    int cols;
    int n;
    int cap;
} lines;

static vt_cell *lines_add(lines *l) {
    if (l->n == l->cap) {
        int ncap = l->cap == 0 ? 256 : l->cap * 2;
        vt_cell *c = GRID_REALLOC(l->cells, (size_t)ncap * (size_t)l->cols * sizeof(vt_cell));
        if (c == NULL) {
            return NULL;
        }
        l->cells = c;
        uint8_t *w = GRID_REALLOC(l->wrapped, (size_t)ncap);
        if (w == NULL) {
            return NULL;
        }
        l->wrapped = w;
        l->cap = ncap;
    }
    vt_cell *line = l->cells + ((size_t)l->n * (size_t)l->cols);
    memset(line, 0, (size_t)l->cols * sizeof(vt_cell));
    l->wrapped[l->n] = 0;
    l->n++;
    return line;
}

typedef struct {
    vt_cell *cells;
    int n;
    int cap;
} cellbuf;

static int cellbuf_push(cellbuf *b, vt_cell c) {
    if (b->n == b->cap) {
        int ncap = b->cap == 0 ? 1024 : b->cap * 2;
        vt_cell *p = GRID_REALLOC(b->cells, (size_t)ncap * sizeof(vt_cell));
        if (p == NULL) {
            return -1;
        }
        b->cells = p;
        b->cap = ncap;
    }
    b->cells[b->n] = c;
    b->n++;
    return 0;
}

/* Joins one logical line (rows chained by the wrapped flag) starting at
   *line into para. Trailing blanks of the last row are dropped, except up to
   the cursor. Returns the cursor offset inside para, -1 if not here, -2 on
   allocation failure. */
static int gather(const vt_grid *g, int *line, int cur_line, int ccol, cellbuf *para) {
    int cursor = -1;
    para->n = 0;
    for (;;) {
        const vt_cell *src = grid_line(g, *line);
        int wrapped = g->wrapped[grid_storage(g, *line)];
        int n = g->cols;
        if (!wrapped) {
            while (n > 0 && cell_blank(&src[n - 1])) {
                n--;
            }
        }
        int here = *line == cur_line;
        /* ccol == cols: the insertion point after the last column (a wrap
           pending): the cursor goes after this row's cells */
        int past = here && ccol >= g->cols;
        if (here && !past && n < ccol + 1) {
            n = ccol + 1;
        }
        for (int i = 0; i < n; i++) {
            if (here && i == ccol) {
                cursor = para->n;
            }
            if ((src[i].flags & VT_CELL_PAD) != 0 && !(here && i == ccol)) {
                continue;
            }
            vt_cell c = src[i];
            c.flags = (uint8_t)(c.flags & ~VT_CELL_PAD);
            if (cellbuf_push(para, c) != 0) {
                return -2;
            }
        }
        if (past) {
            cursor = para->n;
        }
        (*line)++;
        if (!wrapped || *line >= g->count) {
            return cursor;
        }
    }
}

/* Lays para out over lines of l->cols cells. */
static int emit(lines *l, const cellbuf *para, int cursor, int *cline, int *ccol) {
    int cols = l->cols;
    vt_cell *out = lines_add(l);
    if (out == NULL) {
        return -1;
    }
    int col = 0;
    for (int k = 0; k < para->n; k++) {
        vt_cell c = para->cells[k];
        if ((c.flags & VT_CELL_WIDE_TAIL) != 0) {
            if (k == cursor) {
                *cline = l->n - 1;
                *ccol = col > 0 ? col - 1 : 0;
            }
            continue;
        }
        /* the width comes from the rune, not from the flags: a glyph that a
           one-column grid had to keep in one cell is wide again when the
           grid can hold it, and the tail is remade below */
        int width = vt_width(c.cp) == 2 ? 2 : 1;
        c.flags = (uint8_t)(c.flags & ~VT_CELL_WIDE);
        if (width == 2 && cols < 2) {
            width = 1;
        } else if (width == 2) {
            c.flags |= VT_CELL_WIDE;
        }
        if (col + width > cols) {
            if (col < cols) {
                out[col].flags = VT_CELL_PAD;
            }
            l->wrapped[l->n - 1] = 1;
            out = lines_add(l);
            if (out == NULL) {
                return -1;
            }
            col = 0;
        }
        if (k == cursor) {
            *cline = l->n - 1;
            *ccol = col;
        }
        out[col] = c;
        if (width == 2) {
            vt_cell tail = c;
            tail.cp = 0;
            tail.flags = VT_CELL_WIDE_TAIL;
            out[col + 1] = tail;
        }
        col += width;
    }
    if (cursor == para->n) { /* after the last cell: the next column, or past the edge */
        *cline = l->n - 1;
        *ccol = col;
    }
    return 0;
}

static int line_blank(const lines *l, int i) {
    const vt_cell *c = l->cells + ((size_t)i * (size_t)l->cols);
    for (int k = 0; k < l->cols; k++) {
        if (!cell_blank(&c[k])) {
            return 0;
        }
    }
    return !l->wrapped[i];
}

/* The new grid, built from lines l, into *out: g is left as it was, so a
   caller that resizes two grids can publish both or neither. */
static int build(const vt_grid *g, const lines *l, int first, int nlines, int rows, int cols,
                 int cap, vt_grid *out) {
    vt_grid ng;
    memset(&ng, 0, sizeof(ng));
    if (alloc_storage(&ng, rows, cols, cap) != 0) {
        return -1;
    }
    ng.count = nlines > rows ? nlines : rows;
    ng.lost = g->lost + (uint64_t)g->count; /* renumbered: no old address survives */
    for (int i = 0; l->cells != NULL && i < nlines && first + i < l->n; i++) {
        vt_cell *to = ng.cells + ((size_t)i * (size_t)cols);
        const vt_cell *from = l->cells + ((size_t)(first + i) * (size_t)cols);
        memcpy(to, from, (size_t)cols * sizeof(vt_cell));
        /* NOLINTNEXTLINE(clang-analyzer-security.ArrayBound) -- loop bounds i < cap, < l->n */
        ng.wrapped[i] = l->wrapped[first + i];
    }
    *out = ng;
    return 0;
}

int grid_reflow(vt_grid *g, int rows, int cols, int *crow, int *ccol) {
    vt_grid out;
    if (grid_reflow_into(g, rows, cols, crow, ccol, &out) != 0) {
        return -1;
    }
    grid_free(g);
    *g = out;
    return 0;
}

int grid_clip(vt_grid *g, int rows, int cols, int *crow, int *ccol) {
    vt_grid out;
    if (grid_clip_into(g, rows, cols, crow, ccol, &out) != 0) {
        return -1;
    }
    grid_free(g);
    *g = out;
    return 0;
}

int grid_reflow_into(const vt_grid *g, int rows, int cols, int *crow, int *ccol, vt_grid *out) {
    if (rows < 1 || cols < 1) {
        return -1;
    }
    int history = g->cap - g->rows;
    lines l = {NULL, NULL, cols, 0, 0};
    cellbuf para = {NULL, 0, 0};
    int cur_line = g->count - g->rows + clampi(*crow, 0, g->rows - 1);
    int ccl = clampi(*ccol, 0, g->cols); /* cols: past the edge, a wrap pending */
    int new_line = -1;
    int new_col = 0;
    int line = 0;
    int rc = -1;
    while (line < g->count) {
        int cursor = gather(g, &line, cur_line, ccl, &para);
        if (cursor == -2 || emit(&l, &para, cursor, &new_line, &new_col) != 0) {
            goto done;
        }
    }
    while (l.n > 1 && l.n - 1 > new_line && line_blank(&l, l.n - 1)) {
        l.n--;
    }
    int win = l.n > rows ? l.n - rows : 0;
    if (new_line >= 0 && new_line < win) {
        win = new_line;
    }
    int drop = win > history ? win - history : 0;
    int nlines = l.n - drop;
    if (nlines > win - drop + rows) {
        nlines = win - drop + rows;
    }
    if (build(g, &l, drop, nlines, rows, cols, rows + history, out) != 0) {
        goto done;
    }
    *crow = clampi(new_line - win, 0, rows - 1);
    *ccol = clampi(new_col, 0, cols); /* cols: past the last column, a wrap pending */
    rc = 0;
done:
    free(l.cells);
    free(l.wrapped);
    free(para.cells);
    return rc;
}

int grid_clip_into(const vt_grid *g, int rows, int cols, int *crow, int *ccol, vt_grid *out) {
    if (rows < 1 || cols < 1) {
        return -1;
    }
    lines l = {NULL, NULL, cols, 0, 0};
    int keep = rows < g->rows ? rows : g->rows;
    int w = cols < g->cols ? cols : g->cols;
    int rc = -1;
    for (int r = 0; r < keep; r++) {
        vt_cell *line = lines_add(&l);
        if (line == NULL) {
            goto done;
        }
        memcpy(line, grid_row(g, r), (size_t)w * sizeof(vt_cell));
        if ((line[w - 1].flags & VT_CELL_WIDE) != 0 && w == cols && w < g->cols) {
            memset(&line[w - 1], 0, sizeof(vt_cell));
        }
    }
    if (build(g, &l, 0, keep, rows, cols, rows + (g->cap - g->rows), out) != 0) {
        goto done;
    }
    *crow = clampi(*crow, 0, rows - 1);
    *ccol = clampi(*ccol, 0, cols - 1);
    rc = 0;
done:
    free(l.cells);
    free(l.wrapped);
    return rc;
}
