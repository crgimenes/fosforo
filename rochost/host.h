#ifndef FOSFORO_ROC_HOST_H
#define FOSFORO_ROC_HOST_H

/* One rocchetto session over a real directory: the app feeds it keys and time and
   takes its terminal output. Not thread-safe; one thread drives a session.
   Several sessions may live at once. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct froc froc;

/* root: the directory that is the user's home; user and host: the prompt's
   user@host; commands: the app's own (ssh, mosh...), space-separated, which
   the shell hands back through froc_command; NULL for none. The session
   opens at its prompt (no board) and ends with exit. NULL when root is not
   a directory or memory is short. */
froc *froc_new(const char *root, const char *user, const char *host, const char *commands,
               uint16_t cols, uint16_t rows);
void froc_free(froc *s);

/* The shell's working directory as a path of its own tree (/home/<user>/...,
   what froc_cwd gives): a new session opens where another one is. False,
   nothing changed, when it is not a directory there; before any input the
   prompt is drawn again where it is. */
bool froc_chdir(froc *s, const char *path);
/* The working directory into out (cap bytes); returns its length, 0 when
   it does not fit. */
size_t froc_cwd(const froc *s, char *out, size_t cap);

void froc_input(froc *s, const uint8_t *data, size_t n);
/* A Ctrl-C typed while the session is busy: from any thread, at once (a
   script running stops); the 0x03 itself still goes in with the keys. */
void froc_interrupt(froc *s);
/* What a script writes while it runs long, handed out on the session's
   thread as it goes (every 50 ms at most), not only when froc_input
   returns; cb must not call back into the session. */
typedef void (*froc_busy_out)(void *ctx, const uint8_t *data, size_t n);
void froc_busy_output(froc *s, froc_busy_out cb, void *ctx);
/* Time passing: effects, blinking, timeouts. Call it every few tens of ms. */
void froc_tick(froc *s, uint32_t ms);
void froc_resize(froc *s, uint16_t cols, uint16_t rows);
/* Takes up to cap bytes of what the shell wrote; returns how many. */
size_t froc_output(froc *s, uint8_t *out, size_t cap);
bool froc_exited(const froc *s);
/* One of the app's commands the shell is waiting on: its words, each ended
   by a NUL, in out; returns their length, 0 when there is none (or it does
   not fit in cap). Taken once; the shell waits until froc_done. */
size_t froc_command(froc *s, char *out, size_t cap);
void froc_done(froc *s, int status);

/* The machine's clipboard for pbcopy and pbpaste: get returns bytes valid
   until the next call (NULL: nothing there), put stores them. Called on
   the session's thread. Until set, the commands say the host has none. */
typedef const uint8_t *(*froc_clipboard_get)(void *ctx, size_t *len);
typedef bool (*froc_clipboard_put)(void *ctx, const uint8_t *data, size_t len);
void froc_clipboard(froc *s, froc_clipboard_get get, froc_clipboard_put put, void *ctx);

/* Files kept elsewhere until opened, which the disk shows as .name.icloud
   placeholders (iCloud Drive): the app gives the size the file has, and
   brings it to the disk when asked, blocking until it is there (or not:
   false). With these set the shell lists and reads such files by their
   names; without them the placeholders stay dot files. The paths are the
   file's own, on the disk, as the app's FileManager takes them. Process-
   wide, set before the sessions: the index is built when one opens. */
typedef bool (*froc_placeholder_size)(void *ctx, const char *path, long long *size);
typedef bool (*froc_placeholder_fetch)(void *ctx, const char *path);
void froc_placeholders(froc_placeholder_size size, froc_placeholder_fetch fetch, void *ctx);

#endif
