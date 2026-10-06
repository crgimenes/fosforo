#include "pty.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
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

    if (failures > 0) {
        fprintf(stderr, "%d check(s) failed\n%s\n", failures, out);
        return 1;
    }
    printf("ok\n");
    return 0;
}
