#include "cfg.h"

#include "filo.h"
#include "filo_libc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    ARENA = 1048576,
    STEP_LIMIT = 1000000,
    EVENT_STEPS = 200000, /* a handler is a reflex, not a program */
    THEME_NAME_MAX = 64,
    THEME_FILE_MAX = 65536,
    EVENTS = 8,
    THEMES_KEPT = 8,
    ARG_MAX = 256,
};

static const char *const events[EVENTS] = {
    "open", "close", "bell", "title", "prompt", "focus", "blur", "notify",
};

typedef struct {
    const char *dir;
    char name[THEME_NAME_MAX];
    bool loaded; /* the second pass: (theme) was answered already */
    bool live;   /* a handler is running: (theme) and (notify) act when it returns */
    char arg[ARG_MAX];
    char notify[CFG_STR_MAX];
} theme_state;

/* (getEnv "NAME" "fallback") */
static int get_env(filo_ctx *ctx, const filo_value *args, uint32_t n, filo_value *out) {
    filo_str name;
    filo_str fallback;
    if (n != 2 || filo_arg_str(ctx, &args[0], &name) != FILO_OK ||
        filo_arg_str(ctx, &args[1], &fallback) != FILO_OK) {
        return filo_fail(ctx, "getEnv wants (getEnv \"NAME\" \"fallback\")");
    }
    char key[256];
    if (name.len >= sizeof(key)) {
        return filo_fail(ctx, "getEnv: name too long");
    }
    memcpy(key, name.ptr, name.len);
    key[name.len] = '\0';
    const char *v = getenv(key);
    if (v == NULL) {
        *out = args[1];
        return FILO_OK;
    }
    size_t len = strlen(v);
    uint8_t *copy = filo_alloc(ctx, len + 1);
    if (copy == NULL) {
        return filo_fail(ctx, "getEnv: out of memory");
    }
    memcpy(copy, v, len + 1);
    *out = filo_string(copy, (uint32_t)len);
    return FILO_OK;
}

/* (theme "name"): themes/name.filo is run first, init.filo over it; from a
   handler, the theme is switched to. */
static int theme(filo_ctx *ctx, const filo_value *args, uint32_t n, filo_value *out) {
    theme_state *t = ctx->host.user;
    filo_str name;
    if (n != 1 || filo_arg_str(ctx, &args[0], &name) != FILO_OK) {
        return filo_fail(ctx, "theme wants (theme \"name\")");
    }
    if (name.len == 0 || name.len >= THEME_NAME_MAX || name.ptr[0] == '.' ||
        memchr(name.ptr, '/', name.len) != NULL) {
        return filo_fail(ctx, "theme: the name of a file in themes/, without .filo");
    }
    if (t->dir == NULL) {
        return filo_fail(ctx, "theme: there is no themes directory here");
    }
    if (!t->loaded || t->live) {
        memcpy(t->name, name.ptr, name.len);
        t->name[name.len] = '\0';
    }
    *out = args[0];
    return FILO_OK;
}

/* (notify "text"), from a handler: the app shows it once the handler returns. */
static int notify_builtin(filo_ctx *ctx, const filo_value *args, uint32_t n, filo_value *out) {
    theme_state *t = ctx->host.user;
    filo_str s;
    if (n != 1 || filo_arg_str(ctx, &args[0], &s) != FILO_OK) {
        return filo_fail(ctx, "notify wants (notify \"text\")");
    }
    size_t len = s.len < sizeof(t->notify) - 1 ? s.len : sizeof(t->notify) - 1;
    memcpy(t->notify, s.ptr, len);
    t->notify[len] = '\0';
    *out = args[0];
    return FILO_OK;
}

/* (event-arg): what the event brought (a title, a notice), "" otherwise. */
static int event_arg(filo_ctx *ctx, const filo_value *args, uint32_t n, filo_value *out) {
    const theme_state *t = ctx->host.user;
    (void)args;
    if (n != 0) {
        return filo_fail(ctx, "event-arg takes nothing");
    }
    *out = filo_cstring(t->arg);
    return FILO_OK;
}

static void failf(char *err, size_t cap, const filo_ctx *ctx, const char *what) {
    uint32_t line = 0;
    uint32_t col = 0;
    if (filo_error_at(ctx, &line, &col)) {
        snprintf(err, cap, "line %u: %s", (unsigned)line, what);
        return;
    }
    snprintf(err, cap, "%s", what);
}

static filo_value initial(const cfg_var *v) {
    if (v->kind == CFG_NUM) {
        return filo_num(v->num);
    }
    if (v->kind == CFG_BOOL) {
        return filo_bool(v->b);
    }
    return filo_cstring(v->str);
}

static int read_back(const filo_ctx *ctx, const cfg_var *v, cfg_var *out, char *err, size_t cap) {
    filo_value got;
    *out = *v;
    if (!filo_get_global(ctx, v->name, &got)) {
        return 0;
    }
    static const uint8_t want[] = {FILO_NUMBER, FILO_BOOL, FILO_STRING};
    if (got.kind != want[v->kind]) {
        snprintf(err, cap, "%s must be a %s, not a %s", v->name, filo_kind_name(want[v->kind]),
                 filo_kind_name(got.kind));
        return -1;
    }
    if (v->kind == CFG_NUM) {
        out->num = got.u.num;
    } else if (v->kind == CFG_BOOL) {
        out->b = got.u.b;
    } else {
        if (got.u.str.len >= CFG_STR_MAX) {
            snprintf(err, cap, "%s is longer than %d bytes", v->name, CFG_STR_MAX - 1);
            return -1;
        }
        memcpy(out->str, got.u.str.ptr, got.u.str.len);
        out->str[got.u.str.len] = '\0';
    }
    return 0;
}

/* A fresh interpreter holding the host's globals at `vars` and the on-*
   handlers (as #f, for a script to set), sealed. */
static filo_ctx *setup(theme_state *t, const cfg_var *vars, size_t n, uint8_t **mem, char *err,
                       size_t errcap) {
    filo_ctx *ctx = calloc(1, sizeof(*ctx));
    mem[0] = malloc(ARENA);
    mem[1] = malloc(ARENA);
    if (ctx == NULL || mem[0] == NULL || mem[1] == NULL) {
        snprintf(err, errcap, "out of memory");
        goto fail;
    }
    filo_libc_install();
    filo_host host = filo_libc_host;
    host.user = t;
    if (filo_init(ctx, &host, mem[0], ARENA, mem[1], ARENA) != FILO_OK ||
        filo_math_register(ctx, &filo_libc_math) != FILO_OK ||
        filo_strings_register(ctx, &filo_libc_strings) != FILO_OK ||
        filo_register_builtin(ctx, "getEnv", get_env) != FILO_OK ||
        filo_register_builtin(ctx, "theme", theme) != FILO_OK ||
        filo_register_builtin(ctx, "notify", notify_builtin) != FILO_OK ||
        filo_register_builtin(ctx, "event-arg", event_arg) != FILO_OK) {
        snprintf(err, errcap, "filo: %s", filo_error(ctx));
        goto fail;
    }
    for (size_t i = 0; i < n; i++) {
        if (filo_set_global(ctx, vars[i].name, initial(&vars[i])) != FILO_OK) {
            snprintf(err, errcap, "filo: %s", filo_error(ctx));
            goto fail;
        }
    }
    for (int i = 0; i < EVENTS; i++) {
        char name[32];
        snprintf(name, sizeof(name), "on-%s", events[i]);
        if (filo_set_global(ctx, name, filo_bool(false)) != FILO_OK) {
            snprintf(err, errcap, "filo: %s", filo_error(ctx));
            goto fail;
        }
    }
    filo_seal_globals(ctx);
    return ctx;
fail:
    free(ctx);
    free(mem[0]);
    free(mem[1]);
    mem[0] = NULL;
    mem[1] = NULL;
    return NULL;
}

/* Compiles and runs src. Filo rejects an empty script, and a config that
   only has comments (the default file) is empty to it: a closing
   expression makes it a program without moving any line number. */
static int run_source(filo_ctx *ctx, const uint8_t *src, size_t len, uint32_t steps, char *err,
                      size_t errcap) {
    uint8_t *program = malloc(len + 3);
    if (program == NULL) {
        snprintf(err, errcap, "out of memory");
        return -1;
    }
    memcpy(program, src, len);
    memcpy(program + len, "\n#t", 3);
    filo_prog prog;
    filo_limits limits = {steps, FILO_RECURSION_LIMIT_DEFAULT};
    int ok = filo_compile(ctx, program, len + 3, &prog) == FILO_OK &&
             filo_run(ctx, &prog, &limits, NULL) == FILO_OK;
    free(program);
    if (!ok) {
        failf(err, errcap, ctx, filo_error(ctx));
        return -1;
    }
    return 0;
}

static int run_once(const uint8_t *src, size_t len, cfg_var *vars, size_t n, theme_state *t,
                    char *err, size_t errcap) {
    uint8_t *mem[2] = {NULL, NULL};
    cfg_var *out = calloc(n, sizeof(*out));
    int rc = -1;
    if (out == NULL) {
        snprintf(err, errcap, "out of memory");
        return -1;
    }
    filo_ctx *ctx = setup(t, vars, n, mem, err, errcap);
    if (ctx == NULL || run_source(ctx, src, len, STEP_LIMIT, err, errcap) != 0) {
        goto done;
    }
    for (size_t i = 0; i < n; i++) {
        if (read_back(ctx, &vars[i], &out[i], err, errcap) != 0) {
            goto done;
        }
    }
    memcpy(vars, out, n * sizeof(*out));
    rc = 0;
done:
    free(out);
    free(mem[1]);
    free(mem[0]);
    free(ctx);
    return rc;
}

static uint8_t *read_theme(const theme_state *t, size_t *len, char *err, size_t errcap) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.filo", t->dir, t->name);
    FILE *f = fopen(path, "rb");
    uint8_t *buf = malloc(THEME_FILE_MAX + 1);
    if (f == NULL || buf == NULL) {
        snprintf(err, errcap, "theme \"%s\": no %s", t->name, path);
        free(buf);
        if (f != NULL) {
            fclose(f);
        }
        return NULL;
    }
    *len = fread(buf, 1, THEME_FILE_MAX + 1, f); /* one more: a file too large shows */
    fclose(f);
    if (*len > THEME_FILE_MAX) {
        snprintf(err, errcap, "theme \"%s\": larger than %d bytes", t->name, THEME_FILE_MAX);
        free(buf);
        return NULL;
    }
    return buf;
}

/* Twice when a theme is asked for: once to learn which, then the theme
   over the defaults and init.filo over the theme, so what init.filo sets
   wins wherever (theme) stands in it. */
int cfg_run(const uint8_t *src, size_t len, const char *themes, cfg_var *vars, size_t n, char *err,
            size_t errcap) {
    theme_state t;
    memset(&t, 0, sizeof(t));
    t.dir = themes;
    cfg_var *work = malloc(n * sizeof(*work));
    if (work == NULL) {
        snprintf(err, errcap, "out of memory");
        return -1;
    }
    memcpy(work, vars, n * sizeof(*work));
    int rc = run_once(src, len, work, n, &t, err, errcap);
    if (rc == 0 && t.name[0] != '\0') {
        t.loaded = true;
        size_t tlen = 0;
        uint8_t *tsrc = read_theme(&t, &tlen, err, errcap);
        memcpy(work, vars, n * sizeof(*work));
        rc = -1;
        if (tsrc != NULL) {
            char why[256];
            rc = run_once(tsrc, tlen, work, n, &t, why, sizeof(why));
            if (rc != 0) {
                snprintf(err, errcap, "themes/%s.filo: %s", t.name, why);
            }
            free(tsrc);
        }
        if (rc == 0) {
            rc = run_once(src, len, work, n, &t, err, errcap);
        }
    }
    if (rc == 0) {
        memcpy(vars, work, n * sizeof(*work));
    }
    free(work);
    return rc;
}

/* ---- hooks: the interpreter kept alive after the config ran ---- */

struct cfg_session {
    theme_state t; /* first: the builtins reach it through host.user */
    char *dir;     /* our copy of the themes path: the caller's may be gone by the first event */
    filo_ctx *ctx;
    uint8_t *mem[2];
    cfg_var *vars; /* the host's declarations, for reading back */
    size_t n;
    filo_prog fire[EVENTS]; /* "(on-bell (event-arg))", compiled once */
    uint8_t *fire_src[EVENTS];
    struct {
        char name[THEME_NAME_MAX];
        filo_prog prog;
        uint8_t *src;
    } themes[THEMES_KEPT]; /* compiled once each: the arena never grows per event */
    int nthemes;
};

static int event_index(const char *event) {
    for (int i = 0; event != NULL && i < EVENTS; i++) {
        if (strcmp(events[i], event) == 0) {
            return i;
        }
    }
    return -1;
}

void cfg_close(cfg_session *s) {
    if (s == NULL) {
        return;
    }
    for (int i = 0; i < EVENTS; i++) {
        free(s->fire_src[i]);
    }
    for (int i = 0; i < s->nthemes; i++) {
        free(s->themes[i].src);
    }
    free(s->mem[0]);
    free(s->mem[1]);
    free(s->ctx);
    free(s->vars);
    free(s->dir);
    free(s);
}

cfg_session *cfg_open(const uint8_t *src, size_t len, const char *themes, cfg_var *vars, size_t n,
                      char *err, size_t errcap) {
    if (cfg_run(src, len, themes, vars, n, err, errcap) != 0) {
        return NULL;
    }
    cfg_session *s = calloc(1, sizeof(*s));
    cfg_var *copy = malloc(n * sizeof(*vars));
    if (s == NULL || copy == NULL) {
        snprintf(err, errcap, "out of memory");
        free(s);
        free(copy);
        return NULL;
    }
    memcpy(copy, vars, n * sizeof(*vars));
    s->vars = copy;
    s->n = n;
    if (themes != NULL) {
        size_t m = strlen(themes) + 1;
        s->dir = malloc(m);
        if (s->dir == NULL) {
            snprintf(err, errcap, "out of memory");
            cfg_close(s);
            return NULL;
        }
        memcpy(s->dir, themes, m);
    }
    s->t.dir = s->dir;
    s->t.loaded = true; /* the theme is in vars already: (theme) in this pass is a no-op */
    s->ctx = setup(&s->t, vars, n, s->mem, err, errcap);
    if (s->ctx == NULL || run_source(s->ctx, src, len, STEP_LIMIT, err, errcap) != 0) {
        cfg_close(s);
        return NULL;
    }
    for (int i = 0; i < EVENTS; i++) {
        char call[64];
        int m = snprintf(call, sizeof(call), "(on-%s (event-arg))", events[i]);
        s->fire_src[i] = malloc((size_t)m + 1);
        if (s->fire_src[i] == NULL) {
            snprintf(err, errcap, "out of memory");
            cfg_close(s);
            return NULL;
        }
        memcpy(s->fire_src[i], call, (size_t)m + 1);
        if (filo_compile(s->ctx, s->fire_src[i], (size_t)m, &s->fire[i]) != FILO_OK) {
            snprintf(err, errcap, "filo: %s", filo_error(s->ctx));
            cfg_close(s);
            return NULL;
        }
    }
    return s;
}

bool cfg_has(const cfg_session *s, const char *event) {
    if (s == NULL || event_index(event) < 0) {
        return false;
    }
    char name[32];
    snprintf(name, sizeof(name), "on-%s", event);
    filo_value v;
    if (!filo_get_global(s->ctx, name, &v)) {
        return false;
    }
    if (v.kind != FILO_FUNC) {
        return false;
    }
    return true;
}

/* (theme "name") from a handler: the theme file, compiled the first time
   and run over the live globals. */
static int switch_theme(cfg_session *s, char *err, size_t errcap) {
    filo_limits limits = {STEP_LIMIT, FILO_RECURSION_LIMIT_DEFAULT};
    for (int i = 0; i < s->nthemes; i++) {
        if (strcmp(s->themes[i].name, s->t.name) == 0) {
            if (filo_run(s->ctx, &s->themes[i].prog, &limits, NULL) != FILO_OK) {
                failf(err, errcap, s->ctx, filo_error(s->ctx));
                return -1;
            }
            return 0;
        }
    }
    if (s->nthemes == THEMES_KEPT) {
        snprintf(err, errcap, "theme: more than %d themes switched to", THEMES_KEPT); /* yagni */
        return -1;
    }
    size_t tlen = 0;
    uint8_t *tsrc = read_theme(&s->t, &tlen, err, errcap);
    if (tsrc == NULL) {
        return -1;
    }
    uint8_t *program = realloc(tsrc, tlen + 3);
    if (program == NULL) {
        free(tsrc);
        snprintf(err, errcap, "out of memory");
        return -1;
    }
    memcpy(program + tlen, "\n#t", 3);
    filo_prog prog;
    if (filo_compile(s->ctx, program, tlen + 3, &prog) != FILO_OK ||
        filo_run(s->ctx, &prog, &limits, NULL) != FILO_OK) {
        char why[256];
        failf(why, sizeof(why), s->ctx, filo_error(s->ctx));
        snprintf(err, errcap, "themes/%s.filo: %s", s->t.name, why);
        free(program);
        return -1;
    }
    snprintf(s->themes[s->nthemes].name, THEME_NAME_MAX, "%s", s->t.name);
    s->themes[s->nthemes].prog = prog;
    s->themes[s->nthemes].src = program;
    s->nthemes++;
    return 0;
}

int cfg_fire(cfg_session *s, const char *event, const char *arg, cfg_var *vars, size_t n,
             char *notify, size_t notifycap, char *err, size_t errcap) {
    int i = event_index(event);
    if (notifycap > 0) {
        notify[0] = '\0';
    }
    if (!cfg_has(s, event) || n != s->n) {
        snprintf(err, errcap, "no handler for %s", event == NULL ? "?" : event);
        return -1;
    }
    snprintf(s->t.arg, sizeof(s->t.arg), "%s", arg == NULL ? "" : arg);
    s->t.notify[0] = '\0';
    s->t.name[0] = '\0';
    s->t.live = true;
    filo_limits limits = {EVENT_STEPS, FILO_RECURSION_LIMIT_DEFAULT};
    int rc = 0;
    if (filo_run(s->ctx, &s->fire[i], &limits, NULL) != FILO_OK) {
        snprintf(err, errcap, "on-%s: %s", event, filo_error(s->ctx));
        rc = -1;
    } else if (s->t.name[0] != '\0') {
        rc = switch_theme(s, err, errcap);
    }
    s->t.live = false;
    for (size_t k = 0; rc == 0 && k < n; k++) {
        rc = read_back(s->ctx, &s->vars[k], &vars[k], err, errcap);
    }
    snprintf(notify, notifycap, "%s", s->t.notify);
    return rc;
}
