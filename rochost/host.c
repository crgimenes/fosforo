/* fosforo's rocchetto host: the BBS shell with a real directory as the user's
   home, as a session the app drives (froc_*). The directory appears at
   /home/<user> - the only place rocchetto lets a user write; the rest of the tree
   is the shell's own, read-only. The Mac runs it in a process on a pty
   (main.c); iOS, where there are no processes to start, in-process. */

#include "host.h"

#include "roc.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

enum {
    FILE_MAX = 16 << 20, /* larger files are not the shell's business */
    SCRATCH_MAX = 64 << 20,
    INDEX_MAX = 1 << 20, /* the index the core accepts is bounded too */
    ENTRIES_MAX = 10000, /* a runaway tree must not stall the boot */
    DEPTH_MAX = 16,
};

struct froc {
    roc m; /* ~10 MB (most of it the scripts' memory): always on the heap */
    char root[1024];
    char mount[ROC_USER_MAX + 8]; /* /home/<user>, where root appears */
    uint32_t req_id;
    char path[VFS_PATH_MAX];
    int pending;
    uint8_t *file; /* file_get's bytes: valid until the next call */
    char *index;
    size_t index_len;
    size_t entries;
    uint8_t *out; /* the shell's output, kept until the host takes it */
    size_t out_len;
    size_t out_cap;
    void *scratch; /* reserved on first use, paged in only as touched */
    char user[ROC_USER_MAX];
    char host[64];
    char commands[256];
    size_t hist_n; /* the history as last saved: a new line changes these */
    size_t hist_next;
    char cmd[4096]; /* the app's command waiting, NUL-separated words */
    size_t cmd_len;
    froc_clipboard_get clip_get;
    froc_clipboard_put clip_put;
    void *clip_ctx;
    atomic_bool interrupt;  /* a Ctrl-C typed while the session ran (any thread) */
    froc_busy_out busy_out; /* what a long script writes, handed out as it runs */
    void *busy_ctx;
    struct timespec busy_last;
};

/* iCloud placeholders, for every session (see froc_placeholders). */
static froc_placeholder_size ph_size;
static froc_placeholder_fetch ph_fetch;
static void *ph_ctx;

typedef struct froc host_state;

static int safe(const char *path) {
    return path[0] == '/' && strstr(path, "..") == NULL;
}

/* Only paths under the mount reach the disk. */
static int full_path(const host_state *h, const char *path, char *out, size_t cap) {
    size_t m = strlen(h->mount);
    if (!safe(path) || strncmp(path, h->mount, m) != 0 || (path[m] != '/' && path[m] != '\0')) {
        return 0;
    }
    int n = snprintf(out, cap, "%s%s", h->root, path + m);
    return n > 0 && (size_t)n < cap;
}

/* The name rocchetto itself will settle on (set_user in roc.c): the same rules,
   or the home would be mounted where the shell does not look. */
static void mount_for(const char *user, char *out, size_t cap) {
    size_t n = user != NULL ? strlen(user) : 0;
    for (size_t i = 0; i < n; i++) {
        if ((unsigned char)user[i] < 0x20 || user[i] == ' ' || user[i] == 0x7F) {
            n = 0;
            break;
        }
    }
    if (n == 0 || n >= ROC_USER_MAX) {
        user = "guest";
    }
    snprintf(out, cap, "/home/%s", user);
}

static void index_add(host_state *h, const char *line) {
    size_t n = strlen(line);
    if (h->index_len + n > INDEX_MAX || h->entries >= ENTRIES_MAX) {
        return;
    }
    char *p = realloc(h->index, h->index_len + n);
    if (p == NULL) {
        return;
    }
    h->index = p;
    memcpy(h->index + h->index_len, line, n);
    h->index_len += n;
    h->entries++;
}

static void when(time_t t, char *out, size_t cap) {
    struct tm tm;
    if (localtime_r(&t, &tm) == NULL || strftime(out, cap, "%Y-%m-%d %H:%M", &tm) == 0) {
        out[0] = '\0';
    }
}

/* The index TSV of mkindex.sh (path, size, date, title; directories end in
   /), for every file under the root, not only .md/.txt: here the files are
   the user's, not a site's. Dot files are in: ls hides them, ls -a shows
   them, as on a computer (~/.ssh among them). */
/* ".name.icloud" into "name", when the app resolves placeholders and the
   real file is not on the disk yet. */
static int placeholder(const host_state *h, const char *dir, const char *name, char *out,
                       size_t cap) {
    size_t n = strlen(name);
    const char *suffix = ".icloud";
    size_t k = strlen(suffix);
    (void)h;
    if (ph_size == NULL || name[0] != '.' || n <= k + 1 || strcmp(name + n - k, suffix) != 0) {
        return 0;
    }
    if (n - k - 1 >= cap) {
        return 0;
    }
    memcpy(out, name + 1, n - k - 1);
    out[n - k - 1] = '\0';
    char full[2048];
    struct stat st;
    snprintf(full, sizeof(full), "%s/%s", dir, out);
    return stat(full, &st) != 0; /* downloaded already: the real entry lists it */
}

static void walk(host_state *h, const char *rel, int depth) {
    char dir[2048];
    snprintf(dir, sizeof(dir), "%s%s", h->root, rel);
    DIR *d = opendir(dir);
    if (d == NULL || depth > DEPTH_MAX) {
        if (d != NULL) {
            closedir(d);
        }
        return;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
            continue;
        }
        char sub[VFS_PATH_MAX];
        int n = snprintf(sub, sizeof(sub), "%s/%s", rel, e->d_name);
        if (n <= 0 || (size_t)n >= sizeof(sub)) {
            continue;
        }
        char full[2048];
        struct stat st;
        snprintf(full, sizeof(full), "%s%s", h->root, sub);
        if (stat(full, &st) != 0) {
            continue;
        }
        char date[32];
        char line[VFS_PATH_MAX + ROC_USER_MAX + 72];
        when(st.st_mtime, date, sizeof(date));
        char real[256];
        if (placeholder(h, dir, e->d_name, real, sizeof(real))) {
            long long size = 0;
            snprintf(full, sizeof(full), "%s%s/%s", h->root, rel, real);
            if (!ph_size(ph_ctx, full, &size)) {
                continue;
            }
            snprintf(line, sizeof(line), "%s%s/%s\t%lld\t%s\t\n", h->mount, rel, real, size, date);
            index_add(h, line);
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            snprintf(line, sizeof(line), "%s%s/\t0\t%s\t\n", h->mount, sub, date);
            index_add(h, line);
            walk(h, sub, depth + 1);
            continue;
        }
        if (S_ISREG(st.st_mode)) {
            snprintf(line, sizeof(line), "%s%s\t%lld\t%s\t\n", h->mount, sub, (long long)st.st_size,
                     date);
            index_add(h, line);
        }
    }
    closedir(d);
}

/* Not on the disk, but its placeholder is: the app brings it, blocking. */
static int fetched(const char *full) {
    if (ph_fetch == NULL) {
        return 0;
    }
    const char *slash = strrchr(full, '/');
    if (slash == NULL) {
        return 0;
    }
    char marker[2100];
    snprintf(marker, sizeof(marker), "%.*s/.%s.icloud", (int)(slash - full), full, slash + 1);
    struct stat st;
    return stat(marker, &st) == 0 && ph_fetch(ph_ctx, full);
}

static const uint8_t *file_get(void *ctx, const char *path, size_t *len) {
    host_state *h = ctx;
    char full[2048];
    if (!full_path(h, path, full, sizeof(full))) {
        return NULL;
    }
    FILE *f = fopen(full, "rb");
    if (f == NULL && fetched(full)) {
        f = fopen(full, "rb");
    }
    if (f == NULL) {
        return NULL;
    }
    struct stat st;
    if (fstat(fileno(f), &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > FILE_MAX) {
        fclose(f);
        return NULL;
    }
    uint8_t *buf = realloc(h->file, (size_t)st.st_size + 1);
    if (buf == NULL) {
        fclose(f);
        return NULL;
    }
    h->file = buf;
    *len = fread(buf, 1, (size_t)st.st_size, f);
    fclose(f);
    return buf;
}

/* Written beside and renamed over: a crash mid-write leaves the old file,
   never half of the new one — this is where the user's config lives. */
/* The directories above full, under root, made as needed: rocchetto's mkdir
   lives in its index, the disk learns of it when a file goes in. */
static bool parents(const host_state *h, const char *full) {
    char dir[2048];
    snprintf(dir, sizeof(dir), "%s", full);
    size_t from = strlen(h->root) + 1;
    for (size_t i = from; dir[i] != '\0'; i++) {
        if (dir[i] != '/') {
            continue;
        }
        dir[i] = '\0';
        if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
            return false;
        }
        dir[i] = '/';
    }
    return true;
}

static bool file_put(void *ctx, const char *path, const uint8_t *data, size_t len) {
    const host_state *h = ctx;
    char full[2048];
    char tmp[2100];
    if (!full_path(h, path, full, sizeof(full)) || !parents(h, full)) {
        return false;
    }
    /* this process and session's own: two sessions may write the same file */
    snprintf(tmp, sizeof(tmp), "%s.%d-%lx.fosforo-tmp", full, (int)getpid(),
             (unsigned long)(uintptr_t)h);
    FILE *f = fopen(tmp, "wb");
    if (f == NULL) {
        return false;
    }
    size_t w = fwrite(data, 1, len, f);
    int ok = w == len && fflush(f) == 0 && fsync(fileno(f)) == 0;
    ok = fclose(f) == 0 && ok;
    if (!ok || rename(tmp, full) != 0) {
        unlink(tmp);
        return false;
    }
    return true;
}

static bool file_del(void *ctx, const char *path) {
    const host_state *h = ctx;
    char full[2048];
    return full_path(h, path, full, sizeof(full)) && unlink(full) == 0;
}

static bool file_move(void *ctx, const char *from, const char *to) {
    const host_state *h = ctx;
    char a[2048];
    char b[2048];
    return full_path(h, from, a, sizeof(a)) && full_path(h, to, b, sizeof(b)) && parents(h, b) &&
           rename(a, b) == 0;
}

static bool dir_make(void *ctx, const char *path) {
    const host_state *h = ctx;
    char full[2048];
    return full_path(h, path, full, sizeof(full)) && parents(h, full) &&
           (mkdir(full, 0755) == 0 || errno == EEXIST);
}

/* A directory made before this hook existed is only in the index: gone
   from the disk counts as removed. */
static bool dir_del(void *ctx, const char *path) {
    const host_state *h = ctx;
    char full[2048];
    return full_path(h, path, full, sizeof(full)) && (rmdir(full) == 0 || errno == ENOENT);
}

static const uint8_t *clipboard_get(void *ctx, size_t *len) {
    const host_state *h = ctx;
    return h->clip_get(h->clip_ctx, len);
}

static bool clipboard_put(void *ctx, const uint8_t *data, size_t len) {
    const host_state *h = ctx;
    return h->clip_put(h->clip_ctx, data, len);
}

static void stat_into(const struct stat *st, roc_stat *out) {
    out->dir = S_ISDIR(st->st_mode);
    out->link = S_ISLNK(st->st_mode);
    out->has_size = S_ISREG(st->st_mode);
    out->size = (uint64_t)st->st_size;
    out->has_mtime = true;
    out->mtime = (int64_t)st->st_mtime;
    out->has_id = true;
    out->dev = (uint64_t)st->st_dev;
    out->ino = (uint64_t)st->st_ino;
}

/* A file written beside its name and renamed over it: not one to show. */
static bool in_flight(const char *name) {
    size_t n = strlen(name);
    size_t k = strlen(".fosforo-tmp");
    return n > k && strcmp(name + n - k, ".fosforo-tmp") == 0;
}

/* What a path of the home is on the disk now; a file iCloud keeps away is
   its name, with the size the app says, and its placeholder's time. */
static int file_stat(void *ctx, const char *path, bool follow, roc_stat *out) {
    const host_state *h = ctx;
    char full[2048];
    if (!full_path(h, path, full, sizeof(full))) {
        return ROC_HOST_NOT_MINE;
    }
    struct stat st;
    if ((follow ? stat(full, &st) : lstat(full, &st)) == 0) {
        stat_into(&st, out);
        return ROC_HOST_YES;
    }
    const char *slash = strrchr(full, '/');
    long long size = 0;
    char marker[2100];
    if (ph_size != NULL && slash != NULL &&
        snprintf(marker, sizeof(marker), "%.*s/.%s.icloud", (int)(slash - full), full, slash + 1) >
            0 &&
        lstat(marker, &st) == 0 && ph_size(ph_ctx, full, &size)) {
        stat_into(&st, out);
        out->size = (uint64_t)size;
        out->away = true;
        return ROC_HOST_YES;
    }
    return ROC_HOST_NO;
}

/* A | too large for the shell: a file in the app's temporary directory,
   unlinked at once, so it is in none of the person's folders and goes
   when its descriptor closes. */
typedef struct {
    int fd;
    uint64_t len;
} spool;

static void *spool_new(void *ctx) {
    (void)ctx;
    const char *dir = getenv("TMPDIR");
    char name[1024];
    if (snprintf(name, sizeof(name), "%s/fosforo-pipe-XXXXXX", dir != NULL ? dir : "/tmp") >=
        (int)sizeof(name)) {
        return NULL;
    }
    int fd = mkstemp(name);
    if (fd < 0) {
        return NULL;
    }
    (void)unlink(name);
    spool *sp = calloc(1, sizeof(*sp));
    if (sp == NULL) {
        close(fd);
        return NULL;
    }
    sp->fd = fd;
    return sp;
}

static bool spool_write(void *ctx, void *s, const uint8_t *data, size_t n) {
    (void)ctx;
    spool *sp = s;
    while (n > 0) {
        ssize_t k = pwrite(sp->fd, data, n, (off_t)sp->len);
        if (k < 0 && errno == EINTR) {
            continue;
        }
        if (k <= 0) {
            return false;
        }
        data += k;
        n -= (size_t)k;
        sp->len += (uint64_t)k;
    }
    return true;
}

static long long spool_read(void *ctx, void *s, uint64_t off, uint8_t *buf, size_t n) {
    (void)ctx;
    const spool *sp = s;
    for (;;) {
        ssize_t k = pread(sp->fd, buf, n, (off_t)off);
        if (k < 0 && errno == EINTR) {
            continue;
        }
        return (long long)k;
    }
}

static void spool_free(void *ctx, void *s) {
    (void)ctx;
    spool *sp = s;
    close(sp->fd);
    free(sp);
}

static bool interrupted(void *ctx);

/* touch's time on the disk: written and read both set to it, as touch
   without -a or -m does. */
static int set_mtime(void *ctx, const char *path, int64_t mtime) {
    const host_state *h = ctx;
    char full[2048];
    if (!full_path(h, path, full, sizeof(full))) {
        return ROC_HOST_NOT_MINE;
    }
    struct timeval tv[2] = {{.tv_sec = (time_t)mtime}, {.tv_sec = (time_t)mtime}};
    return utimes(full, tv) == 0 ? ROC_HOST_YES : ROC_HOST_NO;
}

/* The entries of a directory of the home as the disk has them now: what
   changed outside the shell since its index was made is here too. Links are
   given as links, never walked into. */
static int dir_list(void *ctx, const char *dir, roc_dir_each each, void *user) {
    const host_state *h = ctx;
    char full[2048];
    if (!full_path(h, dir, full, sizeof(full))) {
        return ROC_HOST_NOT_MINE;
    }
    DIR *d = opendir(full);
    if (d == NULL) {
        return ROC_HOST_NO;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0 || in_flight(e->d_name)) {
            continue;
        }
        char real[256];
        if (placeholder(h, full, e->d_name, real, sizeof(real))) {
            each(user, real, false, false);
            continue;
        }
        char sub[2400];
        struct stat st;
        if (snprintf(sub, sizeof(sub), "%s/%s", full, e->d_name) <= 0 || lstat(sub, &st) != 0) {
            continue; /* gone since readdir saw it */
        }
        each(user, e->d_name, S_ISDIR(st.st_mode), S_ISLNK(st.st_mode));
    }
    closedir(d);
    return ROC_HOST_YES;
}

/* A file the shell reads or writes a piece at a time. A write goes to a
   file beside its name and is renamed over it at the close, so a script
   that stops halfway leaves the old file whole; an append goes straight
   to the end. */
typedef struct {
    int fd;
    int mode;
    char full[2048];
    char tmp[2100];
} host_file;

static int fh_open(void *ctx, const char *path, int mode, void **h, uint64_t *size) {
    const host_state *hs = ctx;
    char full[2048];
    if (!full_path(hs, path, full, sizeof(full))) {
        return ROC_HOST_NOT_MINE;
    }
    host_file *f = calloc(1, sizeof(*f));
    if (f == NULL) {
        return ROC_HOST_NO;
    }
    f->mode = mode;
    snprintf(f->full, sizeof(f->full), "%s", full);
    struct stat st;
    if (mode == ROC_FH_READ) {
        f->fd = open(full, O_RDONLY);
        if (f->fd < 0 && fetched(full)) {
            f->fd = open(full, O_RDONLY);
        }
    } else if (!parents(hs, full)) {
        f->fd = -1;
    } else if (mode == ROC_FH_WRITE) {
        snprintf(f->tmp, sizeof(f->tmp), "%s.%d-%lx.fosforo-tmp", full, (int)getpid(),
                 (unsigned long)(uintptr_t)f);
        f->fd = open(f->tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    } else {
        f->fd = open(full, O_WRONLY | O_APPEND | O_CREAT, 0644);
    }
    if (f->fd < 0 || fstat(f->fd, &st) != 0 || S_ISDIR(st.st_mode)) {
        if (f->fd >= 0) {
            close(f->fd);
        }
        if (f->tmp[0] != '\0') {
            unlink(f->tmp);
        }
        free(f);
        return ROC_HOST_NO;
    }
    *size = (uint64_t)st.st_size;
    *h = f;
    return ROC_HOST_YES;
}

static long long fh_read(void *ctx, void *h, uint64_t off, uint8_t *buf, size_t n) {
    (void)ctx;
    const host_file *f = h;
    ssize_t k = 0;
    do {
        k = pread(f->fd, buf, n, (off_t)off);
    } while (k < 0 && errno == EINTR);
    return k < 0 ? -1 : (long long)k;
}

static bool fh_write(void *ctx, void *h, const uint8_t *data, size_t n) {
    (void)ctx;
    const host_file *f = h;
    size_t done = 0;
    while (done < n) {
        ssize_t k = write(f->fd, data + done, n - done);
        if (k < 0 && errno == EINTR) {
            continue;
        }
        if (k <= 0) {
            return false;
        }
        done += (size_t)k;
    }
    return true;
}

static bool fh_close(void *ctx, void *h, bool commit) {
    (void)ctx;
    host_file *f = h;
    bool ok = close(f->fd) == 0;
    if (f->mode == ROC_FH_WRITE) {
        ok = ok && commit && rename(f->tmp, f->full) == 0;
        if (!ok) {
            unlink(f->tmp); /* dropped, or not kept: the old file as it was */
        }
    }
    free(f);
    return ok;
}

static void on_request(void *ctx, uint32_t req_id, const char *path) {
    host_state *h = ctx;
    h->req_id = req_id;
    snprintf(h->path, sizeof(h->path), "%s", path);
    h->pending = 1;
}

/* The shell's terminal output into out, which grows: the host takes it when
   it can (froc_output), and the core needs draining between feeds. */
static void drain(host_state *h) {
    uint8_t buf[TERM_OUT_CAP];
    size_t n = term_out_read(&h->m.t, buf, sizeof(buf));
    if (n == 0) {
        return;
    }
    if (h->out_len + n > h->out_cap) {
        size_t cap = h->out_cap == 0 ? 65536 : h->out_cap * 2;
        while (cap < h->out_len + n) {
            cap *= 2;
        }
        uint8_t *p = realloc(h->out, cap);
        if (p == NULL) {
            return; /* dropped: a terminal falls behind before it crashes */
        }
        h->out = p;
        h->out_cap = cap;
    }
    memcpy(h->out + h->out_len, buf, n);
    h->out_len += n;
}

static void feed_bytes(host_state *h, uint32_t id, const uint8_t *data, size_t len) {
    size_t off = 0;
    while (off < len) {
        size_t n = len - off < ROC_FEED_MAX ? len - off : ROC_FEED_MAX;
        roc_feed(&h->m, id, data + off, n);
        drain(h); /* the core's overflow guard depends on draining between feeds */
        off += n;
    }
    roc_feed_eof(&h->m, id);
    drain(h);
}

static void serve(host_state *h) {
    h->pending = 0;
    if (strcmp(h->path, ROC_INDEX_PATH) == 0) {
        free(h->index);
        h->index = NULL;
        h->index_len = 0;
        h->entries = 0;
        walk(h, "", 0);
        feed_bytes(h, h->req_id, (const uint8_t *)h->index, h->index_len);
        return;
    }
    size_t len = 0;
    const uint8_t *data = file_get(h, h->path, &len);
    if (data == NULL) {
        roc_feed_fail(&h->m, h->req_id);
        drain(h);
        return;
    }
    feed_bytes(h, h->req_id, data, len);
}

static bool clock_now(void *ctx, int64_t *secs, int32_t *tz_minutes) {
    (void)ctx;
    time_t now = time(NULL);
    struct tm local;
    if (localtime_r(&now, &local) == NULL) {
        return false;
    }
    *secs = (int64_t)now;
    *tz_minutes = (int32_t)(local.tm_gmtoff / 60);
    return true;
}

/* A reservation the system pages in only as a tool touches it, one per
   session: two shells running tools at once must not share it. */
static void *scratch(void *ctx, size_t need) {
    host_state *h = ctx;
    if (need > SCRATCH_MAX) {
        return NULL;
    }
    if (h->scratch == NULL) {
        void *p = mmap(NULL, SCRATCH_MAX, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) {
            return NULL;
        }
        h->scratch = p;
    }
    return h->scratch;
}

static bool is_app_command(const host_state *h, const char *name) {
    size_t n = strlen(name);
    for (const char *p = h->commands; *p != '\0';) {
        const char *end = strchr(p, ' ');
        size_t len = end != NULL ? (size_t)(end - p) : strlen(p);
        if (len == n && n > 0 && memcmp(p, name, n) == 0) {
            return true;
        }
        p += len;
        while (*p == ' ') {
            p++;
        }
    }
    return false;
}

static bool run(void *ctx, int argc, char *const argv[]) {
    host_state *h = ctx;
    if (argc < 1 || !is_app_command(h, argv[0])) {
        return false;
    }
    size_t len = 0;
    for (int i = 0; i < argc; i++) {
        size_t n = strlen(argv[i]) + 1;
        if (len + n > sizeof(h->cmd)) {
            return false;
        }
        memcpy(h->cmd + len, argv[i], n);
        len += n;
    }
    h->cmd_len = len;
    return true;
}

/* A file request the core made is answered before anything else runs. */
static void settle(host_state *h) {
    while (h->pending) {
        serve(h);
    }
}

/* ~/.roc_history, as ~/.bash_history: the lines of earlier sessions come
   back, and each new one is written. Several sessions: the last to write
   keeps its lines, as bash does. */
static void history_path(const host_state *h, char *out, size_t cap) {
    snprintf(out, cap, "%s/.roc_history", h->mount);
}

static void history_load(host_state *h) {
    char path[VFS_PATH_MAX];
    size_t len = 0;
    history_path(h, path, sizeof(path));
    const uint8_t *p = file_get(h, path, &len);
    size_t start = 0;
    for (size_t i = 0; p != NULL && i <= len; i++) {
        if (i == len || p[i] == '\n') {
            roc_history_add(&h->m, p + start, i - start);
            start = i + 1;
        }
    }
    h->hist_n = h->m.hist_n;
    h->hist_next = h->m.hist_next;
}

/* The lines typed since the last save go after what is on disk now, which
   other sessions add to as well; the newest ROC_HIST_MAX stay. A save that
   fails leaves the lines marked unsaved, for the next try. */
static void history_save(host_state *h) {
    size_t n = h->m.hist_n;
    size_t next = h->m.hist_next;
    if (n == h->hist_n && next == h->hist_next) {
        return;
    }
    size_t fresh; /* how many of the ring's newest entries are new here */
    if (n < ROC_HIST_MAX) {
        fresh = n - h->hist_n; /* not wrapped yet: next == n */
    } else if (h->hist_n < ROC_HIST_MAX) {
        fresh = ROC_HIST_MAX - h->hist_n + next; /* wrapped since: filled up, then next more */
    } else {
        fresh = (next + ROC_HIST_MAX - h->hist_next) % ROC_HIST_MAX;
    }
    if (fresh == 0 || fresh > ROC_HIST_MAX) {
        fresh = ROC_HIST_MAX; /* a whole ring or more went by */
    }
    if (fresh > n) {
        fresh = n;
    }
    size_t cap = (size_t)ROC_HIST_MAX * (ROC_LINE_MAX + 1);
    uint8_t *buf = malloc(cap);
    if (buf == NULL) {
        return;
    }
    size_t fresh_bytes = 0;
    for (size_t i = n - fresh; i < n; i++) {
        size_t elen = 0;
        (void)roc_history_at(&h->m, i, &elen);
        fresh_bytes += elen + 1;
    }
    char path[VFS_PATH_MAX];
    history_path(h, path, sizeof(path));
    size_t len = 0;
    const uint8_t *old = file_get(h, path, &len);
    if (old == NULL) {
        len = 0;
    }
    size_t lines = 0;
    for (size_t i = 0; i < len; i++) {
        lines += old[i] == '\n';
    }
    if (len > 0 && old[len - 1] != '\n') {
        lines++;
    }
    size_t skip = lines + fresh > ROC_HIST_MAX ? lines + fresh - ROC_HIST_MAX : 0;
    size_t start = 0; /* the oldest lines go, a whole one at a time, until it all fits */
    while (start < len && (skip > 0 || len - start + fresh_bytes + 1 > cap)) {
        while (start < len && old[start] != '\n') {
            start++;
        }
        if (start < len) {
            start++;
        }
        if (skip > 0) {
            skip--;
        }
    }
    size_t out = len - start;
    memcpy(buf, old + start, out);
    if (out > 0 && buf[out - 1] != '\n') {
        buf[out++] = '\n';
    }
    for (size_t i = n - fresh; i < n; i++) {
        size_t elen = 0;
        const uint8_t *e = roc_history_at(&h->m, i, &elen);
        memcpy(buf + out, e, elen);
        out += elen;
        buf[out++] = '\n';
    }
    if (file_put(h, path, buf, out)) {
        h->hist_n = n;
        h->hist_next = next;
    }
    free(buf);
}

static froc *do_fmsh_new(const char *root, const char *user, const char *host_name,
                         const char *commands, uint16_t cols, uint16_t rows) {
    char *real = realpath(root, NULL);
    if (real == NULL) {
        return NULL;
    }
    host_state *h = calloc(1, sizeof(*h));
    if (h == NULL || strlen(real) >= sizeof(h->root)) {
        free(real);
        free(h);
        return NULL;
    }
    snprintf(h->root, sizeof(h->root), "%s", strcmp(real, "/") == 0 ? "" : real);
    free(real);
    snprintf(h->user, sizeof(h->user), "%s", user != NULL ? user : "");
    snprintf(h->host, sizeof(h->host), "%s", host_name != NULL ? host_name : "");
    snprintf(h->commands, sizeof(h->commands), "%s", commands != NULL ? commands : "");
    mount_for(h->user, h->mount, sizeof(h->mount));
    roc_host host = {
        .ctx = h,
        .request = on_request,
        .user = h->user,
        .host_name = h->host,
        .file_get = file_get,
        .file_put = file_put,
        .file_del = file_del,
        .file_move = file_move,
        .dir_make = dir_make,
        .dir_del = dir_del,
        .file_stat = file_stat,
        .dir_list = dir_list,
        .fh_open = fh_open,
        .fh_read = fh_read,
        .fh_write = fh_write,
        .fh_close = fh_close,
        .set_mtime = set_mtime,
        .spool_new = spool_new,
        .spool_write = spool_write,
        .spool_read = spool_read,
        .spool_free = spool_free,
        .interrupted = interrupted,
        .clock = clock_now,
        .scratch = scratch,
        .run = run,
        .commands = h->commands,
    };
    roc_init(&h->m, &host, cols, rows, ROC_F_PROMPT);
    drain(h);
    settle(h); /* the boot, index and all, before the lines are given back */
    drain(h);
    history_load(h);
    return h;
}

static void do_fmsh_free(froc *h) {
    if (h == NULL) {
        return;
    }
    if (h->scratch != NULL) {
        munmap(h->scratch, SCRATCH_MAX);
    }
    free(h->file);
    free(h->index);
    free(h->out);
    free(h);
}

static bool do_fmsh_chdir(froc *h, const char *path) {
    const vfs_node *node = vfs_lookup(&h->m.fs, path);
    size_t n = strlen(path);
    if (node == NULL || !node->dir || n >= sizeof(h->m.cwd)) {
        return false;
    }
    memcpy(h->m.cwd, path, n + 1);
    term_puts(&h->m.t, "\r\x1b[2K"); /* the prompt drawn at boot said the home */
    roc_line_repaint(&h->m);
    drain(h);
    return true;
}

static size_t do_fmsh_cwd(const froc *h, char *out, size_t cap) {
    size_t n = strlen(h->m.cwd);
    if (n + 1 > cap) {
        return 0;
    }
    memcpy(out, h->m.cwd, n + 1);
    return n;
}

static void do_fmsh_input(froc *h, const uint8_t *data, size_t n) {
    settle(h);
    roc_input(&h->m, data, n);
    drain(h);
    settle(h);
    history_save(h);
}

static void do_fmsh_tick(froc *h, uint32_t ms) {
    settle(h);
    roc_tick(&h->m, ms);
    drain(h);
    settle(h);
    history_save(h); /* keys may become a line here, in the tick */
}

static void do_fmsh_resize(froc *h, uint16_t cols, uint16_t rows) {
    roc_resize(&h->m, cols, rows);
    drain(h);
}

static size_t do_fmsh_output(froc *h, uint8_t *out, size_t cap) {
    size_t n = h->out_len < cap ? h->out_len : cap;
    memcpy(out, h->out, n);
    memmove(h->out, h->out + n, h->out_len - n);
    h->out_len -= n;
    return n;
}

static bool do_fmsh_exited(const froc *h) {
    return roc_exited(&h->m);
}

static size_t do_fmsh_command(froc *h, char *out, size_t cap) {
    size_t n = h->cmd_len;
    if (n == 0 || n > cap) {
        return 0;
    }
    memcpy(out, h->cmd, n);
    h->cmd_len = 0;
    return n;
}

static void do_fmsh_done(froc *h, int status) {
    settle(h);
    roc_run_done(&h->m, status);
    drain(h);
    settle(h);
}

/* rocchetto keeps parser state in statics (cmds.c: the list being run, word
   buffers, the globber), so two sessions in one process must take turns:
   every entry below holds one mutex for the call. Nothing here waits on
   I/O or calls back out while holding it. */
static pthread_mutex_t entry = PTHREAD_MUTEX_INITIALIZER;

froc *froc_new(const char *root, const char *user, const char *host_name, const char *commands,
               uint16_t cols, uint16_t rows) {
    pthread_mutex_lock(&entry);
    froc *h = do_fmsh_new(root, user, host_name, commands, cols, rows);
    pthread_mutex_unlock(&entry);
    return h;
}

void froc_free(froc *h) {
    pthread_mutex_lock(&entry);
    do_fmsh_free(h);
    pthread_mutex_unlock(&entry);
}

bool froc_chdir(froc *h, const char *path) {
    pthread_mutex_lock(&entry);
    bool ok = do_fmsh_chdir(h, path);
    pthread_mutex_unlock(&entry);
    return ok;
}

size_t froc_cwd(const froc *h, char *out, size_t cap) {
    pthread_mutex_lock(&entry);
    size_t n = do_fmsh_cwd(h, out, cap);
    pthread_mutex_unlock(&entry);
    return n;
}

/* No lock: it is called while the session runs, from the thread the keys
   come on, and the running script asks for it (interrupted). */
void froc_interrupt(froc *h) {
    atomic_store(&h->interrupt, true);
}

/* Asked now and then while a script runs (on the session's thread, the
   entry lock held): a Ctrl-C from the keys' thread, and, every 50 ms at
   most, what the script wrote so far out to the terminal. */
static bool interrupted(void *ctx) {
    froc *h = ctx;
    if (h->busy_out != NULL) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long long ms = ((long long)(now.tv_sec - h->busy_last.tv_sec) * 1000) +
                       ((now.tv_nsec - h->busy_last.tv_nsec) / 1000000);
        if (ms >= 50) {
            h->busy_last = now;
            drain(h);
            if (h->out_len > 0) {
                h->busy_out(h->busy_ctx, h->out, h->out_len);
                h->out_len = 0;
            }
        }
    }
    return atomic_exchange(&h->interrupt, false);
}

void froc_busy_output(froc *h, froc_busy_out cb, void *ctx) {
    pthread_mutex_lock(&entry);
    h->busy_out = cb;
    h->busy_ctx = ctx;
    pthread_mutex_unlock(&entry);
}

void froc_input(froc *h, const uint8_t *data, size_t n) {
    pthread_mutex_lock(&entry);
    atomic_store(&h->interrupt, false); /* the Ctrl-C in these keys is theirs now */
    do_fmsh_input(h, data, n);
    pthread_mutex_unlock(&entry);
}

void froc_tick(froc *h, uint32_t ms) {
    pthread_mutex_lock(&entry);
    do_fmsh_tick(h, ms);
    pthread_mutex_unlock(&entry);
}

void froc_resize(froc *h, uint16_t cols, uint16_t rows) {
    pthread_mutex_lock(&entry);
    do_fmsh_resize(h, cols, rows);
    pthread_mutex_unlock(&entry);
}

size_t froc_output(froc *h, uint8_t *out, size_t cap) {
    pthread_mutex_lock(&entry);
    size_t n = do_fmsh_output(h, out, cap);
    pthread_mutex_unlock(&entry);
    return n;
}

bool froc_exited(const froc *h) {
    pthread_mutex_lock(&entry);
    bool gone = do_fmsh_exited(h);
    pthread_mutex_unlock(&entry);
    return gone;
}

size_t froc_command(froc *h, char *out, size_t cap) {
    pthread_mutex_lock(&entry);
    size_t n = do_fmsh_command(h, out, cap);
    pthread_mutex_unlock(&entry);
    return n;
}

void froc_done(froc *h, int status) {
    pthread_mutex_lock(&entry);
    do_fmsh_done(h, status);
    pthread_mutex_unlock(&entry);
}

void froc_placeholders(froc_placeholder_size size, froc_placeholder_fetch fetch, void *ctx) {
    pthread_mutex_lock(&entry);
    ph_size = size;
    ph_fetch = fetch;
    ph_ctx = ctx;
    pthread_mutex_unlock(&entry);
}

void froc_clipboard(froc *h, froc_clipboard_get get, froc_clipboard_put put, void *ctx) {
    pthread_mutex_lock(&entry);
    h->clip_get = get;
    h->clip_put = put;
    h->clip_ctx = ctx;
    h->m.host.clipboard_get = get != NULL ? clipboard_get : NULL;
    h->m.host.clipboard_put = put != NULL ? clipboard_put : NULL;
    pthread_mutex_unlock(&entry);
}
