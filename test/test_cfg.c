#include "cfg.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond);                      \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

static void defaults(cfg_var *v) {
    memset(v, 0, 3 * sizeof(*v));
    v[0].name = "FontSize";
    v[0].kind = CFG_NUM;
    v[0].num = 25;
    v[1].name = "BrightBold";
    v[1].kind = CFG_BOOL;
    v[1].b = true;
    v[2].name = "FontName";
    v[2].kind = CFG_STR;
    strcpy(v[2].str, "3270-Regular");
}

static const char *themes; /* a temp directory, made in main */

static int run(const char *src, cfg_var *v, char *err) {
    defaults(v);
    return cfg_run((const uint8_t *)src, strlen(src), themes, v, 3, err, 256);
}

static void write_theme(const char *name, const char *src) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s.filo", themes, name);
    FILE *f = fopen(path, "w");
    if (f != NULL) {
        fputs(src, f);
        fclose(f);
    }
}

/* A theme lays its settings down first; init.filo wins over it wherever
   (theme) stands, and a script may pick the theme. */
static void test_themes(cfg_var *v, char *err) {
    write_theme("big", "(set FontSize 40)\n(set FontName \"Big\")");
    write_theme("broken", "\n(set Nope 1)");
    CHECK(run("(theme \"big\")", v, err) == 0 && v[0].num == 40 && strcmp(v[2].str, "Big") == 0);
    CHECK(run("(set FontSize 12)\n(theme \"big\")", v, err) == 0 && v[0].num == 12);
    CHECK(strcmp(v[2].str, "Big") == 0);
    CHECK(run("(theme (if (> 2 1) \"big\" \"small\"))", v, err) == 0 && v[0].num == 40);
    CHECK(run("(theme \"missing\")", v, err) != 0 && strstr(err, "missing") != NULL);
    CHECK(v[0].num == 25);
    CHECK(run("(theme \"../big\")", v, err) != 0);
    CHECK(run("(theme \"broken\")", v, err) != 0);
    CHECK(strstr(err, "themes/broken.filo: line 2") != NULL);
}

/* Hooks: handlers set in the script run on events, with what they set
   read back, the theme they pick switched to, their notice handed over. */
static void test_hooks(cfg_var *v, char *err) {
    defaults(v);
    const char *src = "(set on-bell (fn (a) (set FontSize 30) (notify a)))\n"
                      "(set on-focus (fn (a) (theme \"big\")))\n"
                      "(set on-blur (fn (a) (set FontSize \"no\")))";
    /* the themes path is the caller's only during cfg_open (Swift passes a temporary) */
    char *gone = strdup(themes);
    CHECK(gone != NULL);
    if (gone == NULL) {
        return;
    }
    cfg_session *s = cfg_open((const uint8_t *)src, strlen(src), gone, v, 3, err, 256);
    memset(gone, 'x', strlen(gone));
    free(gone);
    CHECK(s != NULL);
    if (s == NULL) {
        return;
    }
    CHECK(cfg_has(s, "bell") && cfg_has(s, "focus") && !cfg_has(s, "title") && !cfg_has(s, "x"));
    char note[256] = "x";
    CHECK(cfg_fire(s, "bell", "ding", v, 3, note, sizeof(note), err, 256) == 0);
    CHECK(v[0].num == 30 && strcmp(note, "ding") == 0);
    CHECK(cfg_fire(s, "focus", NULL, v, 3, note, sizeof(note), err, 256) == 0);
    CHECK(v[0].num == 40 && strcmp(v[2].str, "Big") == 0 && note[0] == '\0');
    CHECK(cfg_fire(s, "focus", NULL, v, 3, note, sizeof(note), err, 256) == 0); /* cached */
    CHECK(cfg_fire(s, "blur", NULL, v, 3, note, sizeof(note), err, 256) != 0);
    CHECK(strstr(err, "FontSize") != NULL);
    CHECK(cfg_fire(s, "title", "t", v, 3, note, sizeof(note), err, 256) != 0);
    cfg_close(s);
    CHECK(cfg_open((const uint8_t *)"(set on-bell 1", 14, themes, v, 3, err, 256) == NULL);
    cfg_close(NULL);
}

/* A handler that keeps the event's text in a setting, fired 20000 times
   with 255 bytes each: the Filo arena (1 MB) takes back what every run
   left behind, so the hook stays usable. */
static void test_hook_values_do_not_fill_the_arena(cfg_var *v, char *err) {
    defaults(v);
    const char *src = "(set on-title (fn (a) (set FontName a)))";
    cfg_session *s = cfg_open((const uint8_t *)src, strlen(src), themes, v, 3, err, 256);
    CHECK(s != NULL);
    if (s == NULL) {
        return;
    }
    char arg[256];
    char note[256];
    int fired = 0;
    for (int i = 0; i < 20000; i++) {
        memset(arg, i % 2 == 0 ? 'a' : 'b', 255);
        arg[255] = '\0';
        if (cfg_fire(s, "title", arg, v, 3, note, sizeof(note), err, 256) != 0) {
            break;
        }
        fired++;
    }
    CHECK(fired == 20000);
    if (fired < 20000) {
        fprintf(stderr, "event %d: %s\n", fired, err);
    }
    CHECK(strcmp(v[2].str, arg) == 0);
    cfg_close(s);
}

/* Builtins called the wrong way, a value over the cap, no themes
   directory, a theme file over the cap: each refused with what it was. */
static void test_errors(cfg_var *v, char *err) {
    CHECK(run("(set FontName (getEnv 1 2))", v, err) != 0 && strstr(err, "getEnv wants") != NULL);
    char src[512];
    char name[301];
    memset(name, 'N', 300);
    name[300] = '\0';
    snprintf(src, sizeof(src), "(set FontName (getEnv \"%s\" \"x\"))", name);
    CHECK(run(src, v, err) != 0 && strstr(err, "name too long") != NULL);
    CHECK(run("(theme 1)", v, err) != 0 && strstr(err, "theme wants") != NULL);
    CHECK(run("(notify 1)", v, err) != 0 && strstr(err, "notify wants") != NULL);
    CHECK(run("(event-arg 1)", v, err) != 0 && strstr(err, "takes nothing") != NULL);
    char text[CFG_STR_MAX + 1];
    memset(text, 's', CFG_STR_MAX - 1);
    text[CFG_STR_MAX - 1] = '\0';
    snprintf(src, sizeof(src), "(set FontName \"%s\")", text);
    CHECK(run(src, v, err) == 0 && strlen(v[2].str) == CFG_STR_MAX - 1);
    text[CFG_STR_MAX - 1] = 's';
    text[CFG_STR_MAX] = '\0';
    snprintf(src, sizeof(src), "(set FontName \"%s\")", text);
    CHECK(run(src, v, err) != 0 && strstr(err, "longer than 255") != NULL);
    CHECK(strcmp(v[2].str, "3270-Regular") == 0);

    defaults(v);
    const char *pick = "(theme \"big\")";
    CHECK(cfg_run((const uint8_t *)pick, strlen(pick), NULL, v, 3, err, 256) != 0);
    CHECK(strstr(err, "no themes directory") != NULL);

    enum { HUGE_THEME = 70000 };
    char *huge = malloc(HUGE_THEME + 1);
    CHECK(huge != NULL);
    if (huge == NULL) {
        return;
    }
    memset(huge, ';', HUGE_THEME);
    huge[HUGE_THEME] = '\0';
    write_theme("huge", huge);
    free(huge);
    CHECK(run("(theme \"huge\")", v, err) != 0 && strstr(err, "larger than 65536") != NULL);
}

/* Handlers that fail: a theme that is not there, one that does not run
   (at once, or the second time), past the themes kept, a handler that
   errors itself; the session stays usable after each. */
static void test_hook_errors(cfg_var *v, char *err) {
    write_theme("grow", "(set FontSize (if (> FontSize 100) (error \"boom\") 200))");
    char name[16];
    char body[64];
    for (int i = 0; i < 8; i++) {
        snprintf(name, sizeof(name), "t%d", i);
        snprintf(body, sizeof(body), "(set FontSize %d)", 50 + i);
        write_theme(name, body);
    }
    defaults(v);
    const char *src = "(set on-title (fn (a) (theme a)))\n"
                      "(set on-bell (fn (a) (theme \"grow\")))\n"
                      "(set on-close (fn (a) (error \"boom\")))\n"
                      "(set on-prompt (fn (a) (notify 1)))";
    cfg_session *s = cfg_open((const uint8_t *)src, strlen(src), themes, v, 3, err, 256);
    CHECK(s != NULL);
    if (s == NULL) {
        return;
    }
    char note[64];
    CHECK(cfg_fire(s, "title", "missing", v, 3, note, sizeof(note), err, 256) != 0);
    CHECK(strstr(err, "theme \"missing\": no ") != NULL);
    CHECK(cfg_fire(s, "title", "broken", v, 3, note, sizeof(note), err, 256) != 0);
    CHECK(strstr(err, "themes/broken.filo: line 2") != NULL);
    CHECK(cfg_fire(s, "bell", NULL, v, 3, note, sizeof(note), err, 256) == 0 && v[0].num == 200);
    err[0] = '\0';
    CHECK(cfg_fire(s, "bell", NULL, v, 3, note, sizeof(note), err, 256) != 0 && err[0] != '\0');
    for (int i = 0; i < 7; i++) { /* grow and seven more fill the eight kept */
        snprintf(name, sizeof(name), "t%d", i);
        CHECK(cfg_fire(s, "title", name, v, 3, note, sizeof(note), err, 256) == 0);
        CHECK(v[0].num == 50 + i);
    }
    CHECK(cfg_fire(s, "title", "t7", v, 3, note, sizeof(note), err, 256) != 0);
    CHECK(strstr(err, "more than 8 themes") != NULL);
    CHECK(cfg_fire(s, "title", "t0", v, 3, note, sizeof(note), err, 256) == 0 && v[0].num == 50);
    CHECK(cfg_fire(s, "close", NULL, v, 3, note, sizeof(note), err, 256) != 0);
    CHECK(strncmp(err, "on-close: ", 10) == 0);
    CHECK(cfg_fire(s, "prompt", NULL, v, 3, note, sizeof(note), err, 256) != 0);
    CHECK(strstr(err, "notify wants") != NULL);
    CHECK(cfg_fire(s, "title", "t1", v, 2, note, sizeof(note), err, 256) != 0);
    CHECK(strstr(err, "no handler for title") != NULL);
    CHECK(cfg_fire(s, NULL, NULL, v, 3, note, sizeof(note), err, 256) != 0);
    CHECK(strstr(err, "no handler for ?") != NULL);
    CHECK(!cfg_has(NULL, "bell") && !cfg_has(s, NULL));
    CHECK(cfg_fire(s, "title", "t1", v, 3, note, sizeof(note), err, 256) == 0 && v[0].num == 51);
    cfg_close(s);

    /* no themes directory: (theme) from a handler is the handler's error */
    defaults(v);
    src = "(set on-focus (fn (a) (theme \"t0\")))";
    s = cfg_open((const uint8_t *)src, strlen(src), NULL, v, 3, err, 256);
    CHECK(s != NULL);
    if (s == NULL) {
        return;
    }
    CHECK(cfg_fire(s, "focus", NULL, v, 3, note, sizeof(note), err, 256) != 0);
    CHECK(strstr(err, "on-focus: ") != NULL && strstr(err, "no themes directory") != NULL);
    cfg_close(s);
    src = "\n(set on-bell (fn (a) a))\n(set Nope 1)";
    CHECK(cfg_open((const uint8_t *)src, strlen(src), themes, v, 3, err, 256) == NULL);
    CHECK(strncmp(err, "line 3", 6) == 0);
}

int main(void) {
    cfg_var v[3];
    char err[256] = "";
    char dir[] = "/tmp/fosforo-cfg-XXXXXX";
    themes = mkdtemp(dir);
    CHECK(themes != NULL);
    CHECK(run("", v, err) == 0);
    CHECK(v[0].num == 25 && v[1].b && strcmp(v[2].str, "3270-Regular") == 0);

    CHECK(run(";; comment\n(set FontSize 18)\n(set BrightBold #f)\n(set FontName \"Menlo\")", v,
              err) == 0);
    CHECK(v[0].num == 18 && !v[1].b && strcmp(v[2].str, "Menlo") == 0);

    CHECK(run("(set FontSize (+ 10 4))", v, err) == 0 && v[0].num == 14);

    CHECK(run("(set FontSize \"big\")", v, err) != 0);
    CHECK(strstr(err, "FontSize") != NULL);
    CHECK(v[0].num == 25);

    CHECK(run("\n\n(set FontSiz 18)", v, err) != 0);
    CHECK(strncmp(err, "line 3", 6) == 0);

    CHECK(run("(set FontSize", v, err) != 0);

    CHECK(run(";; only comments\n", v, err) == 0);
    CHECK(run("(def helper 1)", v, err) != 0);
    CHECK(run("(set FontSize (length (map (fn (x) x) (range 1048576))))", v, err) != 0);
    CHECK(strstr(err, "arena") != NULL); /* the arena fills, not a name Filo lacks */

    setenv("FOSFORO_CFG_TEST", "Monaco", 1);
    CHECK(run("(set FontName (getEnv \"FOSFORO_CFG_TEST\" \"x\"))", v, err) == 0);
    CHECK(strcmp(v[2].str, "Monaco") == 0);
    CHECK(run("(set FontName (getEnv \"FOSFORO_CFG_UNSET\" \"fallback\"))", v, err) == 0);
    CHECK(strcmp(v[2].str, "fallback") == 0);

    test_themes(v, err);
    test_hooks(v, err);
    test_hook_values_do_not_fill_the_arena(v, err);
    test_errors(v, err);
    test_hook_errors(v, err);
    static const char *const made[] = {"big", "broken", "huge", "grow", "t0", "t1",
                                       "t2",  "t3",     "t4",   "t5",   "t6", "t7"};
    char path[512];
    for (size_t i = 0; i < sizeof(made) / sizeof(made[0]); i++) {
        snprintf(path, sizeof(path), "%s/%s.filo", dir, made[i]);
        unlink(path);
    }
    rmdir(dir);

    if (failures > 0) {
        fprintf(stderr, "%d check(s) failed (last err: %s)\n", failures, err);
        return 1;
    }
    printf("ok\n");
    return 0;
}
