#ifndef FOSFORO_PTY_H
#define FOSFORO_PTY_H

/* Child process on a pseudo-terminal. The fork-to-exec path lives in C
   because only async-signal-safe calls are allowed there, and a Swift closure
   can allocate. */

#include <sys/types.h>

/* Starts path with argv/envp as the session leader of a new pty of the given
   size, in directory dir (NULL keeps the current one). Returns the master fd
   (close-on-exec) and stores the pid, or -1 with errno set. */
int pty_spawn(const char *path, char *const argv[], char *const envp[], const char *dir, int rows,
              int cols, pid_t *pid);

int pty_resize(int fd, int rows, int cols);

#endif
