/* fosforo-roc: the rocchetto session of host.c on the terminal this process was
   started on (a pty the Mac app opened). */

#include "host.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

enum { POLL_MS = 50 };

static volatile sig_atomic_t winch;

static void on_winch(int sig) {
    (void)sig;
    winch = 1;
}

static void size_of(uint16_t *cols, uint16_t *rows) {
    struct winsize ws;
    *cols = 80;
    *rows = 24;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
        *cols = ws.ws_col;
        *rows = ws.ws_row;
    }
}

static void flush(froc *s) {
    uint8_t buf[65536];
    size_t n;
    while ((n = froc_output(s, buf, sizeof(buf))) > 0) {
        size_t off = 0;
        while (off < n) {
            ssize_t w = write(STDOUT_FILENO, buf + off, n - off);
            if (w < 0 && errno == EINTR) {
                continue;
            }
            if (w <= 0) {
                return;
            }
            off += (size_t)w;
        }
    }
}

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        printf("usage: fosforo-roc <dir>\n"
               "The rocchetto shell with <dir> as the user's home (/home/$USER): its\n"
               "files are the shell's, and what the shell writes there lands in\n"
               "<dir>. Runs on the terminal it is started in; exit ends it.\n"
               "example: fosforo-roc \"$HOME/Library/Application Support/fosforo\"\n");
        return argc == 2 ? 0 : 2;
    }
    struct termios raw;
    if (tcgetattr(STDIN_FILENO, &raw) == 0) {
        cfmakeraw(&raw);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_winch;
    sigaction(SIGWINCH, &sa, NULL);

    uint16_t cols;
    uint16_t rows;
    size_of(&cols, &rows);
    char host[64] = "";
    gethostname(host, sizeof(host) - 1);
    host[strcspn(host, ".")] = '\0'; /* "box", not "box.local" */
    froc *s = froc_new(argv[1], getenv("USER"), host, NULL, cols, rows);
    if (s == NULL) {
        fprintf(stderr, "fosforo-roc: %s: %s\n", argv[1], strerror(errno));
        return 1;
    }
    flush(s);
    while (!froc_exited(s)) {
        if (winch) {
            winch = 0;
            size_of(&cols, &rows);
            froc_resize(s, cols, rows);
            flush(s);
        }
        struct pollfd pfd = {.fd = STDIN_FILENO, .events = POLLIN};
        int pr = poll(&pfd, 1, POLL_MS);
        if (pr <= 0) {
            froc_tick(s, POLL_MS);
            flush(s);
            continue;
        }
        uint8_t buf[1024];
        ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            break;
        }
        froc_input(s, buf, (size_t)n);
        flush(s);
    }
    flush(s);
    froc_free(s);
    return 0;
}
