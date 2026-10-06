#ifndef FOSFORO_GRID_H
#define FOSFORO_GRID_H

#include "vt.h"

/* Lines live in a ring of slots, each slot naming a storage row. Scrolling
   the whole screen advances `start`; scrolling a region rotates slot entries.
   Cells never move. */
typedef struct {
    vt_cell *cells;   /* cap * cols */
    uint8_t *wrapped; /* per storage row: the line continues on the next row */
    uint32_t *ring;   /* per slot: storage row */
    int cols;
    int rows;
    int cap;   /* rows + history capacity */
    int start; /* slot of the oldest line */
    int count; /* lines in use, rows <= count <= cap */
    /* Lines that left the ring so far: line 0 today was line `lost` when the
       grid began, so a holder of line addresses (a selection) can follow. A
       reflow renumbers every line and counts them all as lost. */
    uint64_t lost;
} vt_grid;

int grid_init(vt_grid *g, int rows, int cols, int history);
void grid_free(vt_grid *g);
int grid_copy(vt_grid *dst, const vt_grid *src);

/* line: 0 = oldest history line, count-1 = bottom of the screen */
uint32_t grid_storage(const vt_grid *g, int line);
vt_cell *grid_line(const vt_grid *g, int line);
vt_cell *grid_row(const vt_grid *g, int row); /* visible row */
uint8_t *grid_wrapped(const vt_grid *g, int row);

void grid_fill(vt_cell *cells, int n, vt_cell blank);
void grid_clear(vt_grid *g, vt_cell blank);
void grid_clear_history(vt_grid *g);

/* Scrolls rows [top, bot) by n. With history set (full screen only), lines
   leaving the top enter the history instead of being discarded. */
void grid_scroll_up(vt_grid *g, int top, int bot, int n, vt_cell blank, int history);
void grid_scroll_down(vt_grid *g, int top, int bot, int n, vt_cell blank);

/* Rewraps every line to the new width keeping the cursor on the character it
   was on; ccol in as cols means the insertion point past the last column (a
   wrap pending), and comes back as cols when it still is. Returns -1 on
   allocation failure, grid untouched. */
int grid_reflow(vt_grid *g, int rows, int cols, int *crow, int *ccol);

/* Resize without reflow (alternate screen): keeps the top-left corner. */
int grid_clip(vt_grid *g, int rows, int cols, int *crow, int *ccol);

/* The same, as a new grid in *out with g untouched: a caller resizing two
   grids installs both or neither (grid_free the one it does not). */
int grid_reflow_into(const vt_grid *g, int rows, int cols, int *crow, int *ccol, vt_grid *out);
int grid_clip_into(const vt_grid *g, int rows, int cols, int *crow, int *ccol, vt_grid *out);

static inline int clampi(int v, int lo, int hi) {
    if (v < lo) {
        return lo;
    }
    if (v > hi) {
        return hi;
    }
    return v;
}

#endif
