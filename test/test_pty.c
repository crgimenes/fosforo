#include "pty.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond);                      \
            failures++;                                                                            \
        }                                                                                          \
    } while (0)

/* Reads until EOF/EIO (child gone) or 5 s pass. */
static size_t drain(int fd, char *buf, size_t cap) {
    size_t n = 0;
    for (;;) {
        struct pollfd p = {fd, POLLIN, 0};
        if (poll(&p, 1, 5000) <= 0) {
            break;
        }
        ssize_t r = read(fd, buf + n, cap - 1 - n);
        if (r <= 0) {
            break;
        }
        n += (size_t)r;
        if (n == cap - 1) {
            break;
        }
    }
    buf[n] = '\0';
    return n;
}

/* Reads until want shows up, EOF, or 5 s pass. */
static int wait_for(int fd, const char *want) {
    char buf[1024];
    size_t n = 0;
    while (n < sizeof(buf) - 1) {
        struct pollfd p = {fd, POLLIN, 0};
        if (poll(&p, 1, 5000) <= 0) {
            break;
        }
        ssize_t r = read(fd, buf + n, sizeof(buf) - 1 - n);
        if (r <= 0) {
            break;
        }
        n += (size_t)r;
        buf[n] = '\0';
        if (strstr(buf, want) != NULL) {
            return 1;
        }
    }
    return 0;
}

/* What cannot run comes back as the child's exit status 127; a directory
   that cannot be entered leaves the child in /. */
static void test_child_failures(char *envp[]) {
    char out[4096];
    int status = 0;
    pid_t pid = 0;
    char *dir[] = {"/tmp", NULL};
    int fd = pty_spawn("/tmp", dir, envp, NULL, 24, 80, &pid);
    CHECK(fd >= 0);
    drain(fd, out, sizeof(out));
    CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 127);
    close(fd);

    char *pwd[] = {"/bin/sh", "-c", "pwd", NULL};
    fd = pty_spawn("/bin/sh", pwd, envp, "/nonexistent-fosforo-dir", 24, 80, &pid);
    CHECK(fd >= 0);
    drain(fd, out, sizeof(out));
    CHECK(strcmp(out, "/\r\n") == 0);
    CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(fd);
}

/* A descriptor the app left open without close-on-exec does not reach
   the child. */
static void test_no_descriptor_leak(char *envp[]) {
    int devnull = open("/dev/null", O_WRONLY);
    CHECK(devnull >= 0 && dup2(devnull, 9) == 9);
    char *argv[] = {"/bin/sh", "-c",
                    "if (: >&9) 2>/dev/null; then echo leaked; else echo closed; fi", NULL};
    pid_t pid = 0;
    int fd = pty_spawn("/bin/sh", argv, envp, NULL, 24, 80, &pid);
    CHECK(fd >= 0);
    char out[256];
    drain(fd, out, sizeof(out));
    CHECK(strcmp(out, "closed\r\n") == 0);
    int status = 0;
    waitpid(pid, &status, 0);
    close(fd);
    close(9);
    close(devnull);
}

/* The app may ignore SIGINT and block SIGTERM; the child starts with
   neither, so Ctrl-C and a kill reach the shell. */
static void test_child_signals(char *envp[]) {
    struct sigaction ign;
    struct sigaction old_int;
    memset(&ign, 0, sizeof(ign));
    ign.sa_handler = SIG_IGN;
    sigemptyset(&ign.sa_mask);
    CHECK(sigaction(SIGINT, &ign, &old_int) == 0);
    sigset_t term;
    sigset_t old_mask;
    sigemptyset(&term);
    sigaddset(&term, SIGTERM);
    CHECK(sigprocmask(SIG_BLOCK, &term, &old_mask) == 0);
    static const int sigs[] = {SIGINT, SIGTERM};
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        char *argv[] = {"/bin/sh", "-c", "echo ready; exec sleep 5", NULL};
        pid_t pid = 0;
        int fd = pty_spawn("/bin/sh", argv, envp, NULL, 24, 80, &pid);
        CHECK(fd >= 0 && wait_for(fd, "ready"));
        CHECK(kill(pid, sigs[i]) == 0);
        int status = 0;
        CHECK(waitpid(pid, &status, 0) == pid);
        CHECK(WIFSIGNALED(status) && WTERMSIG(status) == sigs[i]);
        close(fd);
    }
    sigprocmask(SIG_SETMASK, &old_mask, NULL);
    sigaction(SIGINT, &old_int, NULL);
}

/* No descriptor left for the pty, no process left for the fork: -1 with
   errno, and nothing open behind. */
static void test_spawn_fails(char *envp[]) {
    char *argv[] = {"/bin/sh", "-c", "exit 0", NULL};
    pid_t pid = 0;
    int probe = open("/dev/null", O_RDONLY);
    CHECK(probe >= 0);
    close(probe);
    struct rlimit old;
    CHECK(getrlimit(RLIMIT_NOFILE, &old) == 0);
    struct rlimit low = old;
    low.rlim_cur = (rlim_t)probe;
    CHECK(setrlimit(RLIMIT_NOFILE, &low) == 0);
    errno = 0;
    int fd = pty_spawn("/bin/sh", argv, envp, NULL, 24, 80, &pid);
    int err = errno;
    CHECK(setrlimit(RLIMIT_NOFILE, &old) == 0);
    CHECK(fd == -1 && err == EMFILE);

    CHECK(getrlimit(RLIMIT_NPROC, &old) == 0);
    low = old;
    low.rlim_cur = 1;
    CHECK(setrlimit(RLIMIT_NPROC, &low) == 0);
    errno = 0;
    fd = pty_spawn("/bin/sh", argv, envp, NULL, 24, 80, &pid);
    err = errno;
    /* macOS lowered the hard limit to kern.maxprocperuid on the way down */
    CHECK(getrlimit(RLIMIT_NPROC, &low) == 0);
    low.rlim_cur = old.rlim_cur < low.rlim_max ? old.rlim_cur : low.rlim_max;
    CHECK(setrlimit(RLIMIT_NPROC, &low) == 0);
    if (fd >= 0) { /* root: the limit does not hold, nothing failed */
        int status = 0;
        waitpid(pid, &status, 0);
        close(fd);
    } else {
        CHECK(err == EAGAIN);
    }
    int again = open("/dev/null", O_RDONLY);
    CHECK(again == probe); /* the pty's two ends were closed */
    close(again);
    CHECK(pty_resize(-1, 24, 80) == -1 && errno == EBADF);
}

int main(void) {
    char *argv[] = {"/bin/sh", "-c", "stty size; tty; echo \"$FOSFORO_TEST\"; pwd; exit 3", NULL};
    char *envp[] = {"FOSFORO_TEST=hello", "PATH=/bin:/usr/bin", NULL};
    pid_t pid = 0;
    int fd = pty_spawn("/bin/sh", argv, envp, "/tmp", 7, 33, &pid);
    CHECK(fd >= 0);
    CHECK(pid > 0);
    char out[4096];
    drain(fd, out, sizeof(out));
    CHECK(strstr(out, "7 33") != NULL);
    CHECK(strstr(out, "/dev/ttys") != NULL || strstr(out, "/dev/pts/") != NULL);
    CHECK(strstr(out, "hello") != NULL);
    CHECK(strstr(out, "/tmp") != NULL || strstr(out, "/private/tmp") != NULL);
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 3);
    close(fd);

    char *argv2[] = {"/bin/sh", "-c", "read x; stty size", NULL};
    fd = pty_spawn("/bin/sh", argv2, envp, NULL, 24, 80, &pid);
    CHECK(pty_resize(fd, 40, 120) == 0);
    CHECK(write(fd, "go\n", 3) == 3);
    drain(fd, out, sizeof(out));
    CHECK(strstr(out, "40 120") != NULL);
    waitpid(pid, &status, 0);
    close(fd);

    char *argv3[] = {"/nonexistent", NULL};
    fd = pty_spawn("/nonexistent", argv3, envp, NULL, 24, 80, &pid);
    CHECK(fd >= 0);
    drain(fd, out, sizeof(out));
    CHECK(waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 127);
    close(fd);

    test_child_failures(envp);
    test_no_descriptor_leak(envp);
    test_child_signals(envp);
    test_spawn_fails(envp);

    if (failures > 0) {
        fprintf(stderr, "%d check(s) failed\n%s\n", failures, out);
        return 1;
    }
    printf("ok\n");
    return 0;
}
