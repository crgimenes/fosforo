#include "host.h"

#include <dirent.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond);                      \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

static char out[1 << 16];

static const char *take(froc *s) {
    size_t n = froc_output(s, (uint8_t *)out, sizeof(out) - 1);
    out[n] = '\0';
    return out;
}

static void type(froc *s, const char *text) {
    froc_input(s, (const uint8_t *)text, strlen(text));
    froc_tick(s, 50);
}

/* The app's commands come back as words and the line waits for them; the
   rest stays the shell's. */
static void test_app_commands(const char *root) {
    froc *s = froc_new(root, "teste", "box", "ssh key", 80, 24);
    CHECK(s != NULL);
    take(s);
    char cmd[256];
    CHECK(froc_command(s, cmd, sizeof(cmd)) == 0);
    type(s, "ssh -p 22 'a b'; echo after $?\r");
    size_t n = froc_command(s, cmd, sizeof(cmd));
    CHECK(n == sizeof("ssh\0-p\0"
                      "22\0a b"));
    CHECK(memcmp(cmd,
                 "ssh\0-p\0"
                 "22\0a b",
                 n) == 0);
    CHECK(froc_command(s, cmd, sizeof(cmd)) == 0); /* taken once */
    CHECK(strstr(take(s), "\nafter") == NULL);
    froc_done(s, 5);
    froc_tick(s, 50);
    CHECK(strstr(take(s), "after 5") != NULL);
    type(s, "mosh x\r");
    CHECK(froc_command(s, cmd, sizeof(cmd)) == 0);
    CHECK(strstr(take(s), "not found") != NULL);
    froc_free(s);
}

/* mv on the disk: a file the shell never wrote (put there by the Files
   app, iCloud) moves too, and so does a directory. */
static void test_mv_on_disk(const char *root) {
    char path[512];
    snprintf(path, sizeof(path), "%s/given.txt", root);
    FILE *f = fopen(path, "w");
    CHECK(f != NULL);
    if (f != NULL) {
        fputs("from outside\n", f);
        fclose(f);
    }
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    type(s, "mv given.txt kept.txt\r");
    CHECK(strstr(take(s), "Read-only") == NULL);
    snprintf(path, sizeof(path), "%s/kept.txt", root);
    CHECK(access(path, F_OK) == 0);
    type(s, "mkdir d\r");
    type(s, "mv kept.txt d/kept.txt\r");
    type(s, "echo new > d/made.txt\r"); /* into a directory only mkdir knew */
    type(s, "mv d e\r");
    CHECK(strstr(take(s), "error") == NULL);
    snprintf(path, sizeof(path), "%s/e/kept.txt", root);
    CHECK(access(path, F_OK) == 0);
    type(s, "cat e/kept.txt\r");
    CHECK(strstr(take(s), "from outside") != NULL);
    unlink(path);
    snprintf(path, sizeof(path), "%s/e/made.txt", root);
    CHECK(access(path, F_OK) == 0);
    unlink(path);
    snprintf(path, sizeof(path), "%s/e", root);
    rmdir(path);
    froc_free(s);
}

/* A second session remembers the first one's commands (Up brings them). */
static void test_history_kept(const char *root) {
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    type(s, "echo remembered-line\r");
    froc_free(s);
    s = froc_new(root, "teste", "box", NULL, 80, 24);
    take(s);
    type(s, "cat .history\r");
    const char *o = take(s);
    CHECK(strstr(o, "echo remembered-line\r\n") != NULL);
    froc_free(s);
    char path[512];
    snprintf(path, sizeof(path), "%s/.roc_history", root);
    CHECK(access(path, F_OK) == 0);
    unlink(path);
}

/* A session may open where another one is: in a directory of the tree,
   with the prompt saying so; anywhere else (gone, a file) it stays home. */
static void test_start_directory(const char *root) {
    char sub[512];
    snprintf(sub, sizeof(sub), "%s/docs", root);
    CHECK(mkdir(sub, 0700) == 0);
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    char cwd[256];
    CHECK(froc_cwd(s, cwd, sizeof(cwd)) > 0 && strcmp(cwd, "/home/teste") == 0);
    CHECK(!froc_chdir(s, "/home/teste/missing"));
    CHECK(!froc_chdir(s, "/home/teste/.roc_history"));
    CHECK(froc_cwd(s, cwd, sizeof(cwd)) > 0 && strcmp(cwd, "/home/teste") == 0);
    CHECK(froc_chdir(s, "/home/teste/docs"));
    CHECK(froc_cwd(s, cwd, sizeof(cwd)) == strlen("/home/teste/docs"));
    CHECK(strcmp(cwd, "/home/teste/docs") == 0);
    CHECK(froc_cwd(s, cwd, 4) == 0);
    CHECK(strstr(take(s), "~/docs") != NULL);
    type(s, "pwd\r");
    CHECK(strstr(take(s), "/home/teste/docs\r\n") != NULL);
    froc_free(s);
    CHECK(rmdir(sub) == 0);
}

/* mkdir and rmdir reach the disk, so an empty folder outlives the session
   and the Files app sees it; a parent that is not there is refused. */
static void test_directories_reach_the_disk(const char *root) {
    char sub[512];
    snprintf(sub, sizeof(sub), "%s/pasta", root);
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    type(s, "mkdir pasta\r");
    struct stat st;
    CHECK(stat(sub, &st) == 0 && S_ISDIR(st.st_mode));
    type(s, "mkdir pasta\r");
    CHECK(strstr(take(s), "File exists") != NULL);
    type(s, "mkdir sumida/filha\r");
    CHECK(strstr(take(s), "No such file or directory") != NULL);
    type(s, "rmdir pasta\r");
    CHECK(stat(sub, &st) != 0);
    CHECK(strstr(take(s), "rmdir:") == NULL);
    froc_free(s);
}

static uint8_t clip[64];
static size_t clip_len;
static const uint8_t *clip_get(void *ctx, size_t *len) {
    (void)ctx;
    *len = clip_len;
    return clip_len == 0 ? NULL : clip;
}
static bool clip_put(void *ctx, const uint8_t *data, size_t len) {
    (void)ctx;
    if (len > sizeof(clip)) {
        return false;
    }
    memcpy(clip, data, len);
    clip_len = len;
    return true;
}

/* pbcopy and pbpaste reach the app's clipboard once it is given; before
   that the shell says the host has none. */
static void test_clipboard(const char *root) {
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    type(s, "echo x | pbcopy\r");
    CHECK(strstr(take(s), "no clipboard") != NULL);
    froc_clipboard(s, clip_get, clip_put, NULL);
    clip_len = 0;
    type(s, "echo Hello World! | pbcopy; pbpaste | wc\r");
    const char *o = take(s);
    CHECK(clip_len == 13 && memcmp(clip, "Hello World!\n", 13) == 0);
    CHECK(strstr(o, "1 2 13\r\n") != NULL);
    froc_free(s);
}

static int fetches;
static bool ph_size(void *ctx, const char *path, long long *size) {
    (void)ctx;
    (void)path;
    *size = 1234;
    return true;
}
static bool ph_fetch(void *ctx, const char *path) {
    (void)ctx;
    fetches++;
    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        return false;
    }
    fputs("from the cloud\n", f);
    fclose(f);
    return true;
}

/* A .name.icloud placeholder is listed as name with the size the app
   says, and reading it brings the file to the disk first; without the
   hooks it stays a dot file. */
static void test_placeholders(const char *root) {
    char marker[512];
    char real[512];
    snprintf(marker, sizeof(marker), "%s/.nuvem.txt.icloud", root);
    snprintf(real, sizeof(real), "%s/nuvem.txt", root);
    FILE *f = fopen(marker, "wb");
    CHECK(f != NULL);
    fputs("bplist00", f);
    fclose(f);
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    type(s, "ls\r");
    CHECK(strstr(take(s), "nuvem.txt") == NULL);
    froc_free(s);
    froc_placeholders(ph_size, ph_fetch,
                      NULL); /* before the session: the index is built as it opens */
    s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    fetches = 0;
    type(s, "ls -l\r");
    const char *o = take(s);
    CHECK(strstr(o, " 1234 ") != NULL && strstr(o, "nuvem.txt") != NULL); /* the app's size, */
    CHECK(fetches == 0);                                                  /* and nothing brought */
    fetches = 0;
    type(s, "cat nuvem.txt\r");
    o = take(s);
    CHECK(fetches == 1 && strstr(o, "from the cloud") != NULL);
    struct stat st;
    CHECK(stat(real, &st) == 0);
    froc_free(s);
    froc_placeholders(NULL, NULL, NULL);
    CHECK(unlink(marker) == 0 && unlink(real) == 0);
}

static void put(const char *path, const char *text) {
    FILE *f = fopen(path, "wb");
    CHECK(f != NULL);
    if (f != NULL) {
        fputs(text, f);
        fclose(f);
    }
}

/* What the script at root/s.filo writes to ~/o: the first session's file. */
static const char *run_script(const char *root, froc *s, const char *src) {
    static char buf[1 << 16];
    char path[512];
    snprintf(path, sizeof(path), "%s/s.filo", root);
    put(path, src);
    take(s);
    type(s, "filo ~/s.filo > ~/o 2> ~/e\r");
    take(s);
    snprintf(path, sizeof(path), "%s/o", root);
    FILE *f = fopen(path, "rb");
    size_t n = 0;
    if (f != NULL) {
        n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
    }
    buf[n] = '\0';
    if (getenv("SHOW_SCRIPT") != NULL) {
        fprintf(stderr, "SCRIPT OUT<<%s>>\n", buf);
    }
    char err[512];
    snprintf(path, sizeof(path), "%s/e", root);
    f = fopen(path, "rb");
    if (f != NULL) {
        size_t k = fread(err, 1, sizeof(err) - 1, f);
        err[k] = '\0';
        fclose(f);
        if (k > 0) {
            fprintf(stderr, "script said: %s\n", err);
        }
    }
    return buf;
}

static const char stat_lib[] =
    "(def txt (fn (x) (cond ((= (type-of x) \"number\") (int-text x)) ((= (type-of x) "
    "\"string\") x) ((is-nil x) \"nil\") (else (string x)))))\n"
    "(def st (fn (p f) (let ((s (file-stat p f))) (out-write (if (is-nil s) \"nil\" (letv (k z "
    "t o) s (str-join \" \" (map txt (list k z t o))))) \"\\n\"))))\n"
    "(def kind (fn (p f) (let ((s (file-stat p f))) (out-write (if (is-nil s) \"nil\" (letv (k z "
    "t o) s k)) \"\\n\"))))\n"
    "(def listing (fn (d) (letv (es next) (dir-read d) (out-write (str-join \",\" (map (fn (e) "
    "(letv "
    "(nm kd) e (str-concat nm \":\" kd))) es)) \" \" (txt next) \"\\n\"))))\n";

static bool ph_twelve(void *ctx, const char *path, long long *size) {
    (void)ctx;
    (void)path;
    *size = 1234;
    return true;
}

/* Etapa 3 on the real disk: sizes and times as the disk has them, links as
   links unless followed (a dangling one or a loop is nothing there), what
   changed outside the shell after its index was made, 600 entries in
   pages, a directory that cannot be read, and iCloud's placeholders. */
static void test_live_files(const char *root) {
    char p[512];
    snprintf(p, sizeof(p), "%s/live", root);
    CHECK(mkdir(p, 0700) == 0);
    snprintf(p, sizeof(p), "%s/live/a.txt", root);
    put(p, "hello");
    struct timeval tv[2] = {{1700000000, 0}, {1700000000, 0}};
    CHECK(utimes(p, tv) == 0);
    snprintf(p, sizeof(p), "%s/live/sub", root);
    CHECK(mkdir(p, 0700) == 0);
    const char *links[][2] = {
        {"a.txt", "ln"}, {"nowhere", "dangle"}, {"loop2", "loop1"}, {"loop1", "loop2"}};
    for (size_t i = 0; i < 4; i++) {
        snprintf(p, sizeof(p), "%s/live/%s", root, links[i][1]);
        CHECK(symlink(links[i][0], p) == 0);
    }
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    char src[4096];
    snprintf(src, sizeof(src),
             "%s(st \"~/live/a.txt\" #f)(kind \"~/live/ln\" #f)(st \"~/live/ln\" #t)"
             "(kind \"~/live/dangle\" #f)(kind \"~/live/dangle\" #t)(kind \"~/live/loop1\" #t)"
             "(kind \"~/live/sub\" #f)(listing \"~/live\")",
             stat_lib);
    const char *o = run_script(root, s, src);
    CHECK(strcmp(o, "file 5 1700000000 home\nlink\nfile 5 1700000000 home\nlink\nnil\nnil\ndir\n"
                    "a.txt:file,dangle:link,ln:link,loop1:link,loop2:link,sub:dir nil\n") == 0);

    /* changed outside the shell, after the session indexed the home */
    snprintf(p, sizeof(p), "%s/live/a.txt", root);
    CHECK(unlink(p) == 0);
    snprintf(p, sizeof(p), "%s/live/new.txt", root);
    put(p, "fresh!");
    snprintf(src, sizeof(src),
             "%s(kind \"~/live/a.txt\" #f)(kind \"~/live/new.txt\" #f)(listing \"~/live\")",
             stat_lib);
    o = run_script(root, s, src);
    CHECK(
        strcmp(o,
               "nil\nfile\ndangle:link,ln:link,loop1:link,loop2:link,new.txt:file,sub:dir nil\n") ==
        0);

    /* the shell's own commands see it too: ls, a glob, cat */
    take(s);
    type(s, "ls -l ~/live\r");
    o = take(s);
    CHECK(strstr(o, "new.txt") != NULL && strstr(o, "a.txt") == NULL);
    const char *row = strstr(o, "-rw-r--r-- 1 teste  teste  ");
    CHECK(row != NULL && strstr(row, " 6 ") != NULL &&
          strstr(row, " 6 ") < strstr(row, "new.txt")); /* its size, not the index's */
    type(s, "echo ~/live/n*\r");
    CHECK(strstr(take(s), "/home/teste/live/new.txt\r\n") != NULL);
    type(s, "cat ~/live/new.txt\r");
    CHECK(strstr(take(s), "fresh!") != NULL);

    /* two windows: what one writes the other reads at once */
    froc *other = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(other != NULL);
    take(other);
    type(other, "echo from-the-other > ~/live/shared\r");
    take(other);
    type(s, "cat ~/live/shared\r");
    CHECK(strstr(take(s), "from-the-other") != NULL);
    type(other, "rm ~/live/shared\r");
    take(other);
    type(s, "cat ~/live/shared\r");
    CHECK(strstr(take(s), "No such file") != NULL);
    froc_free(other);

    /* 600 entries made on the disk meanwhile, read in pages of 250 */
    snprintf(p, sizeof(p), "%s/live/many", root);
    CHECK(mkdir(p, 0700) == 0);
    for (int i = 0; i < 600; i++) {
        snprintf(p, sizeof(p), "%s/live/many/f%03d", root, i);
        put(p, "");
    }
    o = run_script(
        root, s,
        "(out-write (nth (iterate (fn (st) (if (is-nil (nth st 0)) (list) (letv (es next) "
        "(dir-read \"~/live/many\" (nth st 0) 250) (list next (+ (nth st 1) (length es))))))"
        " (list 0 0)) 1))");
    CHECK(strcmp(o, "600") == 0);

    /* a directory the disk will not open is an error, not an empty one */
    snprintf(p, sizeof(p), "%s/live/locked", root);
    CHECK(mkdir(p, 0000) == 0);
    o = run_script(root, s, "(dir-read \"~/live/locked\") (out-write \"read\")");
    CHECK(strcmp(o, "") == 0);
    CHECK(chmod(p, 0700) == 0);

    /* iCloud's placeholder: the name, the size the app gives */
    snprintf(p, sizeof(p), "%s/live/sub/.cloud.txt.icloud", root);
    put(p, "bplist00");
    froc_placeholders(ph_twelve, NULL, NULL);
    snprintf(
        src, sizeof(src),
        "%s(listing \"~/live/sub\")(letv (k z t o) (file-stat \"~/live/sub/cloud.txt\") (out-write "
        "k \" \" z))",
        stat_lib);
    o = run_script(root, s, src);
    CHECK(strcmp(o, "cloud.txt:file nil\nfile 1234") == 0);
    froc_placeholders(NULL, NULL, NULL);
    froc_free(s);

    CHECK(unlink(p) == 0);
    for (int i = 0; i < 600; i++) {
        snprintf(p, sizeof(p), "%s/live/many/f%03d", root, i);
        CHECK(unlink(p) == 0);
    }
    const char *gone[] = {"live/many", "live/locked", "live/sub"};
    for (size_t i = 0; i < 3; i++) {
        snprintf(p, sizeof(p), "%s/%s", root, gone[i]);
        CHECK(rmdir(p) == 0);
    }
    const char *files[] = {"live/new.txt", "live/ln", "live/dangle", "live/loop1",
                           "live/loop2",   "s.filo",  "o",           "e"};
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        snprintf(p, sizeof(p), "%s/%s", root, files[i]);
        CHECK(unlink(p) == 0);
    }
    snprintf(p, sizeof(p), "%s/live", root);
    CHECK(rmdir(p) == 0);
}

static char *slurp(const char *path, char *buf, size_t cap);

/* Etapa 5 on the disk: a file larger than the script's whole memory (1
   MiB) written and read a piece at a time; a write that stops halfway
   leaves the old file whole; reasons, not crashes, for what cannot be. */
static void test_file_handles(const char *root) {
    char p[512];
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    /* 2 MiB in 4 KiB pieces, numbered lines, through one handle */
    const char *o = run_script(root, s,
                               "(def h (file-open \"~/big\" \"w\"))"
                               "(def line (fn (i) (str-concat (int-text (+ 100000 i)) \" "
                               "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcde"
                               "fghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ012345\\n\")))"
                               "(iterate (fn (i) (if (= i 16384) (list) (do (file-write h (line i) "
                               "(line (+ i 1))) (+ i 2)))) 0)"
                               "(out-write (string (file-close h)))");
    CHECK(strcmp(o, "#t") == 0);
    snprintf(p, sizeof(p), "%s/big", root);
    struct stat st;
    CHECK(stat(p, &st) == 0 && st.st_size == 16384 * 128);
    /* read back line by line: the count and the last line */
    o = run_script(
        root, s,
        "(def h (file-open \"~/big\"))"
        "(def r (iterate (fn (st) (let ((l (file-line h))) (if (is-nil l) (list) (list (+ "
        "(nth st 0) 1) l)))) (list 0 \"\")))"
        "(out-write (nth r 0) \" \" (byte-sub (nth r 1) 0 6))");
    CHECK(strcmp(o, "16384 116383") == 0);
    o = run_script(
        root, s,
        "(def h (file-open \"~/big\"))"
        "(def n (iterate (fn (k) (let ((b (file-read h 65536))) (if (is-nil b) (list) (+ k "
        "(byte-len b))))) 0))"
        "(file-seek h 128) (out-write n \" \" (byte-sub (file-read h 6) 0 6))");
    CHECK(strcmp(o, "2097152 100001") == 0);

    /* a write that fails halfway: the old file whole, nothing left beside it */
    snprintf(p, sizeof(p), "%s/keep.txt", root);
    put(p, "old\n");
    o = run_script(root, s,
                   "(def h (file-open \"~/keep.txt\" \"w\")) (file-write h \"new\") "
                   "(nth (list) 3)");
    char buf[64];
    CHECK(strcmp(slurp(p, buf, sizeof(buf)), "old\n") == 0);
    /* left open by a run that ended well: kept */
    o = run_script(root, s, "(file-write (file-open \"~/keep.txt\" \"w\") \"kept\\n\")");
    CHECK(strcmp(slurp(p, buf, sizeof(buf)), "kept\n") == 0);
    o = run_script(root, s,
                   "(def h (file-open \"~/keep.txt\" \"a\")) (file-write h \"more\\n\") "
                   "(out-write (string (file-close h)))");
    CHECK(strcmp(slurp(p, buf, sizeof(buf)), "kept\nmore\n") == 0);

    /* reasons for what cannot be */
    o = run_script(root, s, "(out-write (file-open \"~/no-such\"))");
    CHECK(strcmp(o, "No such file or directory") == 0);
    snprintf(p, sizeof(p), "%s/ro", root);
    CHECK(mkdir(p, 0500) == 0);
    o = run_script(root, s, "(out-write (file-open \"~/ro/x\" \"w\"))");
    CHECK(strcmp(o, "Permission denied") == 0);
    CHECK(chmod(p, 0700) == 0 && rmdir(p) == 0);
    o = run_script(root, s, "(out-write (file-open \"~/live-not-here/x\" \"w\"))");
    CHECK(strcmp(o, "No such file or directory") == 0);

    /* nothing written beside a name stays behind */
    char cmd[600];
    snprintf(cmd, sizeof(cmd), "ls -a %s | grep -c fosforo-tmp > /dev/null", root);
    CHECK(system(cmd) != 0);
    froc_free(s);
    const char *files[] = {"big", "keep.txt", "s.filo", "o", "e"};
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        snprintf(p, sizeof(p), "%s/%s", root, files[i]);
        CHECK(unlink(p) == 0);
    }
}

static char *slurp(const char *path, char *buf, size_t cap) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        buf[0] = '\0';
        return buf;
    }
    size_t n = fread(buf, 1, cap - 1, f);
    buf[n] = '\0';
    fclose(f);
    return buf;
}

/* find on the disk: files made outside the session, the times the disk
   keeps (-mtime, -newer), a link loop said under -L, mkdir -p reaching
   the disk. */
static void test_find_on_disk(const char *root) {
    char path[512];
    char buf[4096];
    snprintf(path, sizeof(path), "%s/tree", root);
    CHECK(mkdir(path, 0700) == 0);
    snprintf(path, sizeof(path), "%s/tree/old.txt", root);
    put(path, "old\n");
    struct timeval tv[2];
    gettimeofday(&tv[0], NULL);
    tv[0].tv_sec -= 10 * 86400;
    tv[1] = tv[0];
    CHECK(utimes(path, tv) == 0);
    snprintf(path, sizeof(path), "%s/tree/new.txt", root);
    put(path, "new\n");
    snprintf(path, sizeof(path), "%s/tree/loop", root);
    CHECK(symlink(".", path) == 0);
    char o[512];
    snprintf(o, sizeof(o), "%s/o", root);

    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    struct stat st;
    type(s, "find tree > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "tree\ntree/loop\ntree/new.txt\ntree/old.txt\n") == 0);
    type(s, "find tree -mtime +5 > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "tree/old.txt\n") == 0);
    type(s, "find tree -type f -mtime -1 > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "tree/new.txt\n") == 0);
    type(s, "find tree -newer tree/old.txt -type f > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "tree/new.txt\n") == 0);
    type(s, "find tree -type l > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "tree/loop\n") == 0);
    take(s);
    type(s, "find -L tree -type l > o; echo st=$?\r");
    const char *t = take(s);
    CHECK(strstr(t, "find: tree/loop: directory causes a cycle") != NULL);
    CHECK(strstr(t, "st=1") != NULL);
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "") == 0);
    /* touch on the disk: the time given, another file's, now */
    type(s, "touch -d 2026-01-02T15:30:45Z tree/new.txt tree/made.txt\r");
    snprintf(path, sizeof(path), "%s/tree/new.txt", root);
    CHECK(stat(path, &st) == 0 && st.st_mtime == 1767367845);
    snprintf(path, sizeof(path), "%s/tree/made.txt", root);
    CHECK(stat(path, &st) == 0 && st.st_size == 0 && st.st_mtime == 1767367845);
    type(s, "touch -r tree/old.txt tree/made.txt\r");
    CHECK(stat(path, &st) == 0 && st.st_mtime == tv[0].tv_sec);
    time_t before = time(NULL);
    type(s, "touch tree/made.txt\r");
    CHECK(stat(path, &st) == 0 && st.st_mtime >= before && st.st_mtime <= time(NULL) + 1);
    unlink(path);
    /* cp -R and rm -r on the disk: the link in the tree said, not followed */
    take(s);
    type(s, "cp -R -p tree copy; echo st=$?\r");
    const char *said = take(s);
    CHECK(strstr(said, "cp: copy/loop") == NULL &&
          strstr(said, "tree/loop: a link, not copied") != NULL);
    CHECK(strstr(said, "st=1") != NULL);
    snprintf(path, sizeof(path), "%s/copy/old.txt", root);
    CHECK(stat(path, &st) == 0 && st.st_mtime == tv[0].tv_sec);
    type(s, "rm -r copy\r");
    snprintf(path, sizeof(path), "%s/copy", root);
    CHECK(stat(path, &st) != 0);
    take(s);
    type(s, "home\r");
    CHECK(strstr(take(s), "Your home is this device's storage") != NULL);
    type(s, "mkdir -p p/q/r\r");
    snprintf(path, sizeof(path), "%s/p/q/r", root);
    CHECK(stat(path, &st) == 0 && S_ISDIR(st.st_mode));
    type(s, "rmdir -p p/q/r\r");
    snprintf(path, sizeof(path), "%s/p", root);
    CHECK(stat(path, &st) != 0);
    froc_free(s);

    unlink(o);
    snprintf(path, sizeof(path), "%s/tree/loop", root);
    unlink(path);
    snprintf(path, sizeof(path), "%s/tree/old.txt", root);
    unlink(path);
    snprintf(path, sizeof(path), "%s/tree/new.txt", root);
    unlink(path);
    snprintf(path, sizeof(path), "%s/tree", root);
    rmdir(path);
}

/* The utilities in Filo over a file named on the line, bigger than any
   pipe (1.1 MB): streamed a line at a time, its reading paying for the
   steps it takes. */
static void test_big_file(const char *root) {
    char path[512];
    char buf[256];
    snprintf(path, sizeof(path), "%s/big", root);
    FILE *f = fopen(path, "wb");
    CHECK(f != NULL);
    for (int i = 1; f != NULL && i <= 100000; i++) {
        fprintf(f, "line %d\n", i);
    }
    if (f != NULL) {
        fclose(f);
    }
    char o[512];
    snprintf(o, sizeof(o), "%s/o", root);
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    type(s, "wc -l big > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "100000 big\n") == 0);
    type(s, "grep -c 7 big > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "40951\n") == 0);
    type(s, "tail -n 1 big > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "line 100000\n") == 0);
    type(s, "head -n 2 big > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "line 1\nline 2\n") == 0);
    type(s, "cmp big big; echo $? > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "0\n") == 0);
    type(s, "uniq -d big > o; echo $? >> o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "0\n") == 0);
    /* a > bigger than the capture goes to the disk as it is written */
    type(s, "cut -c 6- big > o2; tail -n 1 o2 > o; wc -l o2 >> o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "100000\n100000 o2\n") == 0);
    type(s, "echo a > o; echo b >> o; cut -c 6- big >> o; head -n 3 o > o3\r");
    char o3[512];
    snprintf(o3, sizeof(o3), "%s/o3", root);
    CHECK(strcmp(slurp(o3, buf, sizeof(buf)), "a\nb\n1\n") == 0);
    unlink(o3);
    /* a | past the capture: spooled, read whole by the Filo utilities, cat
       passing it on, and a builtin that needs it in memory (read) says so */
    /* a line of 2 MB through the filters that go a match or a character at
       a time: the same bytes as tr makes of it */
    snprintf(path, sizeof(path), "%s/wide", root);
    f = fopen(path, "wb");
    CHECK(f != NULL);
    for (int i = 0; f != NULL && i < 200000; i++) {
        fputs("0123456789", f);
    }
    if (f != NULL) {
        fputs("\n", f);
        fclose(f);
    }
    type(s, "sed 's/0/x/g' wide | cksum > o; tr 0 x < wide | cksum >> o; fold -w 80 wide | wc -l "
            ">> o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "4081129291 2000001\n4081129291 2000001\n25000\n") ==
          0);
    /* wc goes by blocks: a line longer than the memory holds as a line */
    f = fopen(path, "wb");
    CHECK(f != NULL);
    for (int i = 0; f != NULL && i < 300000; i++) {
        fputs("0123456789", f);
    }
    if (f != NULL) {
        fclose(f);
    }
    type(s, "wc wide > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "0 1 3000000 wide\n") == 0);
    unlink(path);
    /* sort takes up to 20000 lines and 1 MB: the worst of both on two keys
       fits, and past the size it says so */
    f = fopen(path, "wb");
    CHECK(f != NULL);
    for (int i = 0; f != NULL && i < 20000; i++) {
        fprintf(f, "%07d w%05d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", (i * 7919) % 9999991,
                (i * 31) % 99999);
    }
    if (f != NULL) {
        fclose(f);
    }
    type(s, "sort -k 2 -k 1n wide | wc -l > o; tail -n 5000 big >> wide; sort wide 2>> o; echo $? "
            ">> o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)),
                 "20000\nsort: more than 1M: a database fits this better\n2\n") == 0);
    unlink(path);
    /* tail keeps n lines and a block, not the input as lines */
    type(s, "tail -n 100000 big | cksum > o; tail -n 100000 big > o2; cksum < o2 >> o; tail -n "
            "99999 big | wc -l >> o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "2734128645 1088895\n2734128645 1088895\n99999\n") ==
          0);
    type(s, "cat big | wc -l > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "100000\n") == 0);
    type(s, "cat big | grep -c 7 > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "40951\n") == 0);
    type(s, "cat big | cat | tail -n 1 > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "line 100000\n") == 0);
    type(s, "cat big | cut -c 6- | tail -n 20000 | sort -rn | head -n 1 > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "100000\n") == 0);
    type(s, "cat big | tee o2 o3 | wc -l > o; tail -n 1 o3 >> o; wc -l o2 >> o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "100000\nline 100000\n100000 o2\n") == 0);
    snprintf(o3, sizeof(o3), "%s/o3", root);
    unlink(o3);
    type(s, "cat big | sed -n '$p' > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "line 100000\n") == 0);
    take(s);
    type(s, "cat big | read x; echo st=$?\r");
    const char *said = take(s);
    CHECK(strstr(said, "Input too large to hold whole here") != NULL &&
          strstr(said, "st=1") != NULL);
    type(s, "x=$(cat big | wc -l); echo \"$x\" > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "100000\n") == 0);
    type(s, "for i in 1 2 3; do cat big; done > o2; wc -l o2 > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "300000 o2\n") == 0);
    snprintf(o3, sizeof(o3), "%s/o2", root);
    unlink(o3);
    froc_free(s);
    unlink(o);
    unlink(path);
}

typedef struct {
    froc *s;
    const char *line;
} typing;

static atomic_size_t busy_bytes; /* what came out while the script still ran */
static void busy_out(void *ctx, const uint8_t *data, size_t n) {
    (void)ctx;
    (void)data;
    atomic_fetch_add(&busy_bytes, n);
}

static void *type_thread(void *arg) {
    typing *t = arg;
    type(t->s, t->line);
    return NULL;
}

/* A Ctrl-C from another thread while a script loops: it stops at once, with
   130, and the session goes on. */
static void test_interrupt(const char *root) {
    char path[512];
    /* reading buys steps: a script that reads a file again and again only
       ends when it is stopped */
    char data[512];
    snprintf(data, sizeof(data), "%s/lines", root);
    FILE *f = fopen(data, "wb");
    CHECK(f != NULL);
    for (int i = 0; f != NULL && i < 20000; i++) {
        fprintf(f, "line %d\n", i);
    }
    if (f != NULL) {
        fclose(f);
    }
    snprintf(path, sizeof(path), "%s/loop.filo", root);
    put(path, "(iterate (fn (i) (let ((h (file-open \"lines\"))) (do (out-write \"pass\\n\") "
              "(iterate (fn (k) (if (is-nil (file-line h)) (list) k)) 0) (file-close h) (+ i 1)))) "
              "0)");
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    atomic_store(&busy_bytes, 0);
    froc_busy_output(s, busy_out, NULL);
    typing t = {s, "filo loop.filo; echo after\r"};
    pthread_t th;
    CHECK(pthread_create(&th, NULL, type_thread, &t) == 0);
    struct timespec nap = {0, 300 * 1000 * 1000};
    nanosleep(&nap, NULL);
    CHECK(atomic_load(&busy_bytes) > 0); /* out before the script ended */
    froc_interrupt(s);
    pthread_join(th, NULL);
    const char *o = take(s);
    CHECK(strstr(o, "Interrupted") != NULL && strstr(o, "\r\nafter") == NULL);
    type(s, "echo $?\r");
    CHECK(strstr(take(s), "130") != NULL);
    type(s, "echo fine\r");
    CHECK(strstr(take(s), "fine") != NULL);
    froc_free(s);
    unlink(path);
    unlink(data);
}

/* Two sessions over one home: each adds its lines to ~/.roc_history and
   none wipes the other's; a save the disk refused is made later. */
static void test_history_shared(const char *root) {
    froc *a = froc_new(root, "teste", "box", NULL, 80, 24);
    froc *b = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(a != NULL && b != NULL);
    take(a);
    take(b);
    type(a, "echo command-from-A\r");
    type(b, "echo command-from-B\r");
    type(a, "echo second-from-A\r");
    froc_free(a);
    froc_free(b);
    froc *c = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(c != NULL);
    take(c);
    type(c, "cat .history\r");
    const char *o = take(c);
    CHECK(strstr(o, "echo command-from-A\r\n") != NULL);
    CHECK(strstr(o, "echo command-from-B\r\n") != NULL);
    CHECK(strstr(o, "echo second-from-A\r\n") != NULL);
    CHECK(chmod(root, 0500) == 0); /* nothing can be written for a while */
    type(c, "echo while-locked\r");
    CHECK(chmod(root, 0700) == 0);
    type(c, "echo after-lock\r");
    froc_free(c);
    char path[512];
    snprintf(path, sizeof(path), "%s/.roc_history", root);
    static char file[1 << 16];
    slurp(path, file, sizeof(file));
    CHECK(strstr(file, "echo command-from-B\n") != NULL);
    CHECK(strstr(file, "echo while-locked\n") != NULL);
    CHECK(strstr(file, "echo after-lock\n") != NULL);
    CHECK(strstr(file, "while-locked\necho after-lock") != NULL); /* once each, in order */
    unlink(path);
}

/* Two sessions of one process typing at the same time: rocchetto keeps parser
   state in statics, so the host takes turns; each session sees only its
   own lines, and the shared history keeps both sessions' lines even when
   their saves race (the merge runs under the same turn). */
typedef struct {
    froc *s;
    char tag;
    int bad;
} worker;

static void *hammer(void *arg) {
    worker *w = arg;
    char buf[1 << 16];
    for (int i = 0; i < 150; i++) {
        char cmd[64];
        snprintf(cmd, sizeof(cmd), "echo %c-%d\r", w->tag, i);
        froc_input(w->s, (const uint8_t *)cmd, strlen(cmd));
        froc_tick(w->s, 50);
        size_t n = froc_output(w->s, (uint8_t *)buf, sizeof(buf) - 1);
        buf[n] = '\0';
        char other[8];
        snprintf(other, sizeof(other), "%c-", w->tag == 'A' ? 'B' : 'A');
        char want[16];
        snprintf(want, sizeof(want), "\n%c-%d\r\n", w->tag, i);
        if (strstr(buf, other) != NULL || strstr(buf, want) == NULL) {
            w->bad++;
        }
    }
    return NULL;
}

static void *tick_once(void *arg) {
    froc_tick(arg, 50);
    return NULL;
}

/* rocchetto wants a main thread's stack (the app gives it 8 MB too) */
static int start(pthread_t *t, void *(*fn)(void *), void *arg) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 << 20);
    int rc = pthread_create(t, &attr, fn, arg);
    pthread_attr_destroy(&attr);
    return rc;
}

static void test_sessions_at_once(const char *root) {
    worker a = {froc_new(root, "teste", "box", NULL, 80, 24), 'A', 0};
    worker b = {froc_new(root, "teste", "box", NULL, 80, 24), 'B', 0};
    CHECK(a.s != NULL && b.s != NULL);
    take(a.s);
    take(b.s);
    pthread_t ta;
    pthread_t tb;
    CHECK(start(&ta, hammer, &a) == 0);
    CHECK(start(&tb, hammer, &b) == 0);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    CHECK(a.bad == 0 && b.bad == 0);
    /* both saves pending, then written at the same moment: neither is lost */
    CHECK(chmod(root, 0500) == 0);
    type(a.s, "echo pending-A\r");
    type(b.s, "echo pending-B\r");
    CHECK(chmod(root, 0700) == 0);
    CHECK(start(&ta, tick_once, a.s) == 0);
    CHECK(start(&tb, tick_once, b.s) == 0);
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    froc_free(a.s);
    froc_free(b.s);
    froc *c = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(c != NULL);
    take(c);
    type(c, "cat .history\r");
    const char *o = take(c);
    CHECK(strstr(o, "echo pending-A\r\n") != NULL);
    CHECK(strstr(o, "echo pending-B\r\n") != NULL);
    froc_free(c);
    char path[512];
    snprintf(path, sizeof(path), "%s/.roc_history", root);
    unlink(path);
}

/* PATH on the disk: a program built here into ~/bin runs by its path and,
   once PATH has the directory, by its name; a source there does not. */
static void test_path_on_disk(const char *root) {
    char path[512];
    char buf[256];
    snprintf(path, sizeof(path), "%s/hello.filo", root);
    put(path, "(out-write \"hello \" (nth ARGS 0) \"\\n\")");
    char o[512];
    snprintf(o, sizeof(o), "%s/o", root);
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    type(s, "mkdir -p ~/bin; filo build -o ~/bin/hello hello.filo; cp hello.filo ~/bin/src\r");
    type(s, "./bin/hello um > o; PATH=~/bin:/bin; hello dois >> o; src 2>> o; type hello >> o\r");
    CHECK(strstr(slurp(o, buf, sizeof(buf)), "hello um\nhello dois\n") != NULL);
    CHECK(strstr(buf, "src: command not found") != NULL);
    CHECK(strstr(buf, "hello is /home/teste/bin/hello") != NULL);
    /* a shell script by its #!, the user's over the shell's own cat */
    snprintf(path, sizeof(path), "%s/bin/cat", root);
    put(path, "#!/bin/sh\necho my cat $1\n");
    type(s, "cat x > o; type cat >> o; PATH=/bin; cat hello.filo >> o\r");
    CHECK(strstr(slurp(o, buf, sizeof(buf)), "my cat x\ncat is /home/teste/bin/cat\n(out-write") !=
          NULL);
    snprintf(path, sizeof(path), "%s/hello.filo", root);
    froc_free(s);
    unlink(path);
    unlink(o);
    snprintf(path, sizeof(path), "rm -rf %s/bin", root);
    CHECK(system(path) == 0);
}

/* ~/.profile on the disk runs as the shell opens. */
static void test_profile_on_disk(const char *root) {
    char path[512];
    char buf[256];
    snprintf(path, sizeof(path), "%s/.profile", root);
    put(path, "PATH=~/bin:$PATH\nprof=yes\n");
    char o[512];
    snprintf(o, sizeof(o), "%s/o", root);
    froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
    CHECK(s != NULL);
    take(s);
    type(s, "echo $prof $PATH > o\r");
    CHECK(strcmp(slurp(o, buf, sizeof(buf)), "yes /home/teste/bin:/bin\n") == 0);
    froc_free(s);
    unlink(path);
    unlink(o);
}

/* The rocchetto's test/fixtures/utilities.txt on the disk: each case in an empty
   ~/fx, by /bin and by the sources (the site's /pub/filo/examples) in ~/src (see
   oracle.mjs there). */
static size_t unescape(const char *e, char *dst, size_t cap) {
    size_t n = 0;
    for (; *e != '\0' && n < cap; e++) {
        if (*e != '\\') {
            dst[n++] = *e;
        } else if (e[1] == 'n' || e[1] == 't') {
            dst[n++] = e[1] == 'n' ? '\n' : '\t';
            e++;
        } else if (e[1] == 'x' && e[2] != '\0' && e[3] != '\0') {
            char hex[3] = {e[2], e[3], '\0'};
            dst[n++] = (char)strtol(hex, NULL, 16);
            e += 3;
        } else if (e[1] != '\0') {
            dst[n++] = e[1];
            e++;
        }
    }
    return n;
}

static size_t file_bytes(const char *path, char *buf, size_t cap, bool *there) {
    FILE *f = fopen(path, "rb");
    *there = f != NULL;
    if (f == NULL) {
        return 0;
    }
    size_t n = fread(buf, 1, cap, f);
    fclose(f);
    return n;
}

static void test_fixtures(const char *root) {
    FILE *f = fopen(ROC_FIXTURES, "rb");
    CHECK(f != NULL);
    if (f == NULL) {
        return;
    }
    static char raw[4096];
    static char want[2048];
    static char got[4096];
    char path[512];
    int cases = 0;
    for (int source = 0; source < 2; source++) {
        rewind(f);
        froc *s = froc_new(root, "teste", "box", NULL, 80, 24);
        CHECK(s != NULL);
        take(s);
        if (source == 1) { /* the site's /pub/filo/examples, put in ~/src */
            snprintf(path, sizeof(path), "mkdir -p %s/src && cp %s/*.filo %s/src/", root,
                     ROC_COMMANDS, root);
            CHECK(system(path) == 0);
            DIR *d = opendir(ROC_COMMANDS);
            CHECK(d != NULL);
            const struct dirent *e = NULL;
            while (d != NULL && (e = readdir(d)) != NULL) {
                size_t len = strlen(e->d_name);
                if (len > 5 && strcmp(e->d_name + len - 5, ".filo") == 0) {
                    char alias[160];
                    snprintf(alias, sizeof(alias), "alias %.*s='filo ~/src/%s'\r", (int)(len - 5),
                             e->d_name, e->d_name);
                    type(s, alias);
                }
            }
            if (d != NULL) {
                closedir(d);
            }
            take(s);
        }
        int failed = 0;
        while (fgets(raw, sizeof(raw), f) != NULL) {
            raw[strcspn(raw, "\n")] = '\0';
            if (raw[0] == '\0' || raw[0] == '#') {
                continue;
            }
            char *field[4] = {raw, NULL, NULL, NULL};
            for (int i = 1; i < 4 && field[i - 1] != NULL; i++) {
                char *tab = strchr(field[i - 1], '\t');
                if (tab != NULL) {
                    *tab = '\0';
                    field[i] = tab + 1;
                }
            }
            CHECK(field[3] != NULL);
            if (field[3] == NULL) {
                continue;
            }
            const char *line = field[0][0] == '!' ? field[0] + 1 : field[0];
            size_t want_len = unescape(field[3], want, sizeof(want));
            type(s, "cd; rm -rf ~/fx; mkdir ~/fx; cd ~/fx\r");
            char cmd[512];
            snprintf(cmd, sizeof(cmd), "{ %s; } > ~/.fx.out 2> ~/.fx.err; echo $? > ~/.fx.st\r",
                     line);
            type(s, cmd);
            take(s);
            bool there = false;
            snprintf(path, sizeof(path), "%s/.fx.st", root);
            size_t n = file_bytes(path, got, sizeof(got) - 1, &there);
            got[n] = '\0';
            int status = there ? atoi(got) : -1;
            snprintf(path, sizeof(path), "%s/.fx.err", root);
            size_t errs = file_bytes(path, got, sizeof(got), &there);
            snprintf(path, sizeof(path), "%s/.fx.out", root);
            n = file_bytes(path, got, sizeof(got), &there);
            bool ok_status = strcmp(field[1], "+") == 0 ? status > 0 : status == atoi(field[1]);
            bool ok_err = (errs > 0) == (strcmp(field[2], "+") == 0);
            bool ok_out = there && n == want_len && memcmp(got, want, n) == 0;
            if (!ok_status || !ok_err || !ok_out) {
                fprintf(stderr, "fixture (%s): %s\tstatus %d\tstderr %zu\tout %.*s\n",
                        source == 1 ? "source" : "bytecode", line, status, errs, (int)n, got);
                failed++;
            }
            cases++;
        }
        CHECK(failed == 0);
        froc_free(s);
    }
    fclose(f);
    CHECK(cases > 200);
    snprintf(path, sizeof(path), "rm -rf %s/fx %s/.fx.out %s/.fx.err %s/.fx.st", root, root, root,
             root);
    CHECK(system(path) == 0);
}

int main(void) {
    char root[] = "/tmp/fosforo-rochost-XXXXXX";
    if (mkdtemp(root) == NULL) {
        perror("mkdtemp");
        return 1;
    }
    test_app_commands(root);
    test_mv_on_disk(root);
    test_history_kept(root);
    test_start_directory(root);
    test_directories_reach_the_disk(root);
    test_clipboard(root);
    test_placeholders(root);
    test_live_files(root);
    test_file_handles(root);
    test_find_on_disk(root);
    test_big_file(root);
    test_fixtures(root);
    test_path_on_disk(root);
    test_profile_on_disk(root);
    test_interrupt(root);
    test_history_shared(root);
    test_sessions_at_once(root);
    rmdir(root);
    if (failures > 0) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("rochost: all tests passed\n");
    return 0;
}
