#ifndef FOSFORO_CFG_H
#define FOSFORO_CFG_H

/* Runs a Filo configuration script against a fixed set of globals. The host
   declares each key with its default; the globals are sealed, so a typo in
   the script is an error instead of a silent new variable. Values of the
   wrong kind are errors too. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    CFG_NUM = 0,
    CFG_BOOL = 1,
    CFG_STR = 2,
    CFG_STR_MAX = 256,
};

typedef struct {
    const char *name;
    int kind;
    double num;
    bool b;
    char str[CFG_STR_MAX];
} cfg_var;

/* Returns 0 with vars updated, or -1 with a message ("line 3: ...") in err
   and vars left at their defaults. themes: the directory (theme "name")
   reads name.filo from; NULL where there is none. */
int cfg_run(const uint8_t *src, size_t len, const char *themes, cfg_var *vars, size_t n, char *err,
            size_t errcap);

/* Hooks: the script may set a function on a global named after an event,
   (set on-bell (fn (arg) ...)), and the host calls it when the event
   happens. cfg_open runs the script as cfg_run does and keeps the
   interpreter for that; the events are open, close, bell, title, prompt,
   focus, blur and notify. A handler gets one string argument, may (set)
   the config, pick a (theme "name") and ask for a (notify "text"); it runs
   under a small step budget. */
typedef struct cfg_session cfg_session;

cfg_session *cfg_open(const uint8_t *src, size_t len, const char *themes, cfg_var *vars, size_t n,
                      char *err, size_t errcap);

/* Whether a handler is set for the event: the cheap gate before cfg_fire. */
bool cfg_has(const cfg_session *s, const char *event);

/* Calls the handler with arg (NULL for none). vars (the same declarations
   as at cfg_open) get what the handler set, and the theme it picked;
   notify gets what it asked to show, "" for nothing. -1 with err when the
   handler failed, or there is none. */
int cfg_fire(cfg_session *s, const char *event, const char *arg, cfg_var *vars, size_t n,
             char *notify, size_t notifycap, char *err, size_t errcap);

void cfg_close(cfg_session *s);

#endif
