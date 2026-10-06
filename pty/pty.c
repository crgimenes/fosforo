#include "pty.h"

#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#include <utmp.h>
#endif

static void set_size(struct winsize *ws, int rows, int cols) {
    memset(ws, 0, sizeof(*ws));
    ws->ws_row = (unsigned short)rows;
    ws->ws_col = (unsigned short)cols;
}

/* Runs in the child between fork and exec: async-signal-safe calls only. */
static void child(int slave, const char *path, char *const argv[], char *const envp[],
                  const char *dir) {
    if (login_tty(slave) != 0) {
        _exit(126);
    }
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    static const int sigs[] = {
        SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGPIPE, SIGHUP, SIGTERM, SIGWINCH,
    };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &dfl, NULL);
    }
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    /* the app's own descriptors (window server, Metal, XPC) must not leak
       into the shell */
    long max = sysconf(_SC_OPEN_MAX);
    if (max < 0 || max > 65536) {
        max = 65536;
    }
    for (int fd = 3; fd < (int)max; fd++) {
        close(fd);
    }
    if (dir != NULL && chdir(dir) != 0) {
        (void)chdir("/");
    }
    execve(path, argv, envp);
    _exit(127);
}

int pty_spawn(const char *path, char *const argv[], char *const envp[], const char *dir, int rows,
              int cols, pid_t *pid) {
    int master = -1;
    int slave = -1;
    struct winsize ws;
    set_size(&ws, rows, cols);
    if (openpty(&master, &slave, NULL, NULL, &ws) != 0) {
        return -1;
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    pid_t p = fork();
    if (p < 0) {
        close(master);
        close(slave);
        return -1;
    }
    if (p == 0) {
        close(master);
        child(slave, path, argv, envp, dir);
    }
    close(slave);
    *pid = p;
    return master;
}

int pty_resize(int fd, int rows, int cols) {
    struct winsize ws;
    set_size(&ws, rows, cols);
    return ioctl(fd, TIOCSWINSZ, &ws);
}
