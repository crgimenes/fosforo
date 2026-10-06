#ifndef FOSFORO_VT_H
#define FOSFORO_VT_H

/* Terminal emulation core: bytes from the host go in, a grid of cells comes
   out. No I/O, no global state, no threads: the caller serializes access
   (one lock around vt_write and vt_copy_screen is enough). */

#include <stddef.h>
#include <stdint.h>

typedef struct vt vt;

/* Colors: the top byte is the kind, the low 24 bits the value. */
enum {
    VT_COLOR_KIND_DEFAULT = 0,
    VT_COLOR_KIND_INDEX = 1,
    VT_COLOR_KIND_RGB = 2,
};
#define VT_COLOR_DEFAULT 0U
#define VT_COLOR_INDEX(i) ((1U << 24U) | ((uint32_t)(i) & 0xFFU))
#define VT_COLOR_RGB(r, g, b)                                                                      \
    ((2U << 24U) | (((uint32_t)(r) & 0xFFU) << 16U) | (((uint32_t)(g) & 0xFFU) << 8U) |            \
     ((uint32_t)(b) & 0xFFU))
#define VT_COLOR_KIND(c) ((c) >> 24U)

#define VT_ATTR_BOLD (1U << 0U)
#define VT_ATTR_DIM (1U << 1U)
#define VT_ATTR_ITALIC (1U << 2U)
#define VT_ATTR_BLINK (1U << 3U)
#define VT_ATTR_INVERSE (1U << 4U)
#define VT_ATTR_INVISIBLE (1U << 5U)
#define VT_ATTR_STRIKE (1U << 6U)
#define VT_ATTR_OVERLINE (1U << 7U)
#define VT_ATTR_UL_SHIFT 8U
#define VT_ATTR_UL_MASK (7U << 8U)

enum {
    VT_UL_NONE = 0,
    VT_UL_SINGLE = 1,
    VT_UL_DOUBLE = 2,
    VT_UL_CURLY = 3,
    VT_UL_DOTTED = 4,
    VT_UL_DASHED = 5,
};

#define VT_CELL_WIDE (1U << 0U)      /* glyph spans this cell and the next */
#define VT_CELL_WIDE_TAIL (1U << 1U) /* second half of a wide glyph, draws nothing */
#define VT_CELL_PAD (1U << 2U)       /* left empty because a wide glyph wrapped early */
#define VT_CELL_PROMPT (1U << 3U)    /* a shell prompt starts here (OSC 133;A) */

typedef struct {
    uint32_t cp; /* 0 = empty */
    uint32_t fg;
    uint32_t bg;
    uint16_t attr;
    uint8_t flags;
    uint8_t link; /* OSC 8 hyperlink: 0 none, else an id for vt_link */
} vt_cell;

#define VT_MODE_CURSOR_KEYS (1U << 0U) /* DECCKM: application cursor keys */
#define VT_MODE_KEYPAD (1U << 1U)      /* DECKPAM: application keypad */
#define VT_MODE_ORIGIN (1U << 2U)      /* DECOM */
#define VT_MODE_AUTOWRAP (1U << 3U)    /* DECAWM */
#define VT_MODE_CURSOR_VISIBLE (1U << 4U)
#define VT_MODE_CURSOR_BLINK (1U << 5U)
#define VT_MODE_INSERT (1U << 6U)  /* IRM */
#define VT_MODE_NEWLINE (1U << 7U) /* LNM */
#define VT_MODE_REVERSE (1U << 8U) /* DECSCNM */
#define VT_MODE_ALT_SCREEN (1U << 9U)
#define VT_MODE_MOUSE_X10 (1U << 10U)
#define VT_MODE_MOUSE_BUTTON (1U << 11U)
#define VT_MODE_MOUSE_DRAG (1U << 12U)
#define VT_MODE_MOUSE_ANY (1U << 13U)
#define VT_MODE_MOUSE_SGR (1U << 14U)
#define VT_MODE_MOUSE_UTF8 (1U << 15U)
#define VT_MODE_MOUSE_URXVT (1U << 16U)
#define VT_MODE_FOCUS (1U << 17U)
#define VT_MODE_BRACKETED_PASTE (1U << 18U)
#define VT_MODE_SYNC_OUTPUT (1U << 19U) /* 2026: renderer holds the last frame */

/* Color slots for vt_config_color / vt_color: 0..255 are the palette. */
enum {
    VT_SLOT_FG = 256,
    VT_SLOT_BG = 257,
    VT_SLOT_CURSOR = 258,
    VT_SLOT_COUNT = 259,
};

typedef struct {
    int row;
    int col;
    int visible;
    int style; /* DECSCUSR: 0/1 blinking block, 2 block, 3/4 underline, 5/6 bar */
} vt_cursor;

typedef struct {
    void *user;
    /* OSC sequences the core does not handle itself (52 clipboard, 8 links,
       133 prompt marks, 1337 images...). data is the payload after "id;". */
    void (*osc)(void *user, uint32_t id, const uint8_t *data, size_t len);
    void (*bell)(void *user); /* BEL: the host flashes or beeps */
} vt_host;

enum {
    VT_MAX_ROWS = 1000,
    VT_MAX_COLS = 4096,
    VT_MAX_HISTORY = 1000000,
};

/* Returns NULL on invalid size or allocation failure. host may be NULL. */
vt *vt_new(int rows, int cols, int history, const vt_host *host);
void vt_free(vt *t);

void vt_write(vt *t, const uint8_t *buf, size_t len);

/* An independent copy (Mosh keeps the states the server may diff from).
   The host callbacks are shared. NULL on allocation failure. */
vt *vt_clone(const vt *t);

/* Bytes that bring a terminal of the same size to this state: modes,
   scroll region, every cell, title, cursor and pen. Returns the length the
   whole repaint takes; only cap bytes are written, so a caller with a
   short buffer calls again with that length. */
size_t vt_repaint(const vt *t, uint8_t *out, size_t cap);

/* Reflows the primary screen; the alternate screen is clipped. Returns 0, or
   -1 (invalid size or allocation failure) leaving the terminal unchanged. */
int vt_resize(vt *t, int rows, int cols);

/* Clears the screen and the history, keeping the cursor's line at the top
   (the prompt stays): the terminal's own Cmd+K. */
void vt_clear(vt *t);

/* Drains bytes the terminal must send back to the host (DA, DSR, color
   queries...). Returns how many were copied. */
size_t vt_reply(vt *t, uint8_t *out, size_t cap);

void vt_size(const vt *t, int *rows, int *cols);

/* Lines above the visible screen; always 0 on the alternate screen. */
int vt_history(const vt *t);

/* Copies rows*cols cells of the screen as seen scrolled back `back` lines
   (0 = live screen; clamped to vt_history). */
void vt_copy_screen(const vt *t, int back, vt_cell *dst);

/* Lines addressable by selection: history plus screen. Line
   lines - rows is the top of the live screen. */
int vt_lines(const vt *t);

/* What line 0 was called when the terminal began: grows by one for every
   line the history drops (or vt_clear discards), so an address kept from
   before follows its text as address - (base now - base then). A reflow, a
   switch to or from the alternate screen and a reset renumber everything
   and move base past every old address. */
uint64_t vt_base(const vt *t);

/* Text of the cells from (l0, c0) to (l1, c1), both inclusive, as UTF-8.
   Rows joined by autowrap stay one line; other rows end in \n with trailing
   blanks dropped. Returns the bytes written (at most cap). */
size_t vt_copy_text(const vt *t, int l0, int c0, int l1, int c1, uint8_t *out, size_t cap);

/* Finds needle (code points; ASCII and Latin-1 letters match either case)
   in history and screen, the addresses of vt_lines. Starts at (*line,
   *col), exclusive: backwards when back is nonzero, forwards otherwise; a
   line past the end or before 0 searches the whole text. On a hit returns
   1 with *line, *col and *end (its last cell). Matches stay on one row. */
int vt_find(const vt *t, const uint32_t *needle, int n, int back, int *line, int *col, int *end);

vt_cursor vt_get_cursor(const vt *t);
uint32_t vt_modes(const vt *t);
const char *vt_title(const vt *t);
const char *vt_cwd(const vt *t); /* OSC 7 payload, as sent */

/* Bumped on every change that can alter what is drawn: a renderer that sees
   the same value skips the frame. */
uint64_t vt_generation(const vt *t);

/* The URI of a cell's hyperlink (OSC 8), NULL when the id is not in use.
   Only the URI: the id= parameter serves to group cells, nothing else. */
const char *vt_link(const vt *t, int id);

/* Nonzero when line continues on the next: autowrap joined them, so a copy
   gives them as one line and a triple click takes both. */
int vt_wrapped(const vt *t, int line);

/* The nearest line holding a prompt mark (OSC 133;A from the shell)
   before line when back is nonzero, after it otherwise; -1 if none. Lines
   are addressed as in vt_lines. */
int vt_prompt(const vt *t, int line, int back);

/* Cells a code point takes: 0 (combining), 1 or 2 (wide, emoji). */
int vt_width(uint32_t cp);

/* Sets a color both now and as the value OSC 104/110/111/112 and RIS return
   to. rgb is 0xRRGGBB. */
void vt_config_color(vt *t, int slot, uint32_t rgb);
uint32_t vt_color(const vt *t, int slot);

enum {
    VT_ENCODING_UTF8 = 0,
    VT_ENCODING_CP437 = 1, /* bytes >= 0x80 are IBM PC glyphs (BBS ANSI art) */
};
void vt_set_encoding(vt *t, int encoding);

/* ---- input: what a key, click or paste sends to the host ----
   Every encoder writes into out (at least VT_INPUT_MAX bytes for keys and
   mouse) and returns the byte count; 0 means send nothing. */

enum { VT_INPUT_MAX = 32 };

#define VT_MOD_SHIFT 1U
#define VT_MOD_ALT 2U /* Option as Meta: sent as an ESC prefix */
#define VT_MOD_CTRL 4U

enum {
    VT_KEY_UP = 1,
    VT_KEY_DOWN = 2,
    VT_KEY_RIGHT = 3,
    VT_KEY_LEFT = 4,
    VT_KEY_HOME = 5,
    VT_KEY_END = 6,
    VT_KEY_INSERT = 7,
    VT_KEY_DELETE = 8,
    VT_KEY_PAGE_UP = 9,
    VT_KEY_PAGE_DOWN = 10,
    VT_KEY_ENTER = 11,
    VT_KEY_KP_ENTER = 12,
    VT_KEY_TAB = 13,
    VT_KEY_BACKSPACE = 14,
    VT_KEY_ESCAPE = 15,
    VT_KEY_F1 = 16,
    VT_KEY_F2 = 17,
    VT_KEY_F3 = 18,
    VT_KEY_F4 = 19,
    VT_KEY_F5 = 20,
    VT_KEY_F6 = 21,
    VT_KEY_F7 = 22,
    VT_KEY_F8 = 23,
    VT_KEY_F9 = 24,
    VT_KEY_F10 = 25,
    VT_KEY_F11 = 26,
    VT_KEY_F12 = 27,
};

size_t vt_key(const vt *t, int key, uint32_t mods, uint8_t *out);

/* A character typed on the keyboard, already resolved by the layout. */
size_t vt_text(const vt *t, uint32_t cp, uint32_t mods, uint8_t *out);

enum {
    VT_MOUSE_PRESS = 0,
    VT_MOUSE_RELEASE = 1,
    VT_MOUSE_MOTION = 2,
};
enum {
    VT_BUTTON_LEFT = 0,
    VT_BUTTON_MIDDLE = 1,
    VT_BUTTON_RIGHT = 2,
    VT_BUTTON_NONE = 3, /* motion with no button down */
    VT_BUTTON_WHEEL_UP = 4,
    VT_BUTTON_WHEEL_DOWN = 5,
    VT_BUTTON_WHEEL_LEFT = 6,
    VT_BUTTON_WHEEL_RIGHT = 7,
};

/* row/col are 0-based cells. Honors the tracking and encoding modes the
   application asked for; 0 when it asked for none. */
size_t vt_mouse(const vt *t, int event, int button, int row, int col, uint32_t mods, uint8_t *out);

size_t vt_focus(const vt *t, int focused, uint8_t *out);

/* Newlines become CR; under bracketed paste the text is wrapped in the
   markers and ESC bytes are dropped, so pasted text cannot close the bracket
   and inject commands. out needs len + 12 bytes. */
size_t vt_paste(const vt *t, const uint8_t *text, size_t len, uint8_t *out);

#endif
