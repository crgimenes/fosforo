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
    CHECK(run("(set FontSize (len (map (fn (x) x) (range 1048576))))", v, err) != 0);

    setenv("FOSFORO_CFG_TEST", "Monaco", 1);
    CHECK(run("(set FontName (getEnv \"FOSFORO_CFG_TEST\" \"x\"))", v, err) == 0);
    CHECK(strcmp(v[2].str, "Monaco") == 0);
    CHECK(run("(set FontName (getEnv \"FOSFORO_CFG_UNSET\" \"fallback\"))", v, err) == 0);
    CHECK(strcmp(v[2].str, "fallback") == 0);

    test_themes(v, err);
    test_hooks(v, err);
    test_hook_values_do_not_fill_the_arena(v, err);
    char path[512];
    snprintf(path, sizeof(path), "%s/big.filo", dir);
    unlink(path);
    snprintf(path, sizeof(path), "%s/broken.filo", dir);
    unlink(path);
    rmdir(dir);

    if (failures > 0) {
        fprintf(stderr, "%d check(s) failed (last err: %s)\n", failures, err);
        return 1;
    }
    printf("ok\n");
    return 0;
}
