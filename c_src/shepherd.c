/*
 * shepherd.c - Persistent child process shepherd for NetRunner
 *
 * Lifecycle:
 *   1. BEAM opens this binary via Port.open with :nouse_stdio
 *   2. Shepherd connects to BEAM's UDS listener (path passed as argv[1])
 *   3. Shepherd forks child, execvp's the command
 *   4. Sends child's pipe FDs to BEAM via SCM_RIGHTS over UDS
 *   5. Sends MSG_CHILD_STARTED with child PID
 *   6. Enters poll() loop watching:
 *      - UDS for commands from BEAM (KILL, CLOSE_STDIN)
 *      - Signal pipe for SIGCHLD (child death)
 *   7. On BEAM death (UDS POLLHUP): SIGTERM child, wait, SIGKILL if needed
 *   8. On child death: send MSG_CHILD_EXITED, exit
 *
 * The shepherd NEVER calls execvp on itself - it stays alive as a watchdog.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#include "protocol.h"
#include "utils.h"

/* Self-pipe for signal handling */
static int signal_pipe[2] = {-1, -1};

static void sigchld_handler(int sig) {
    (void)sig;
    int saved_errno = errno;
    /* Write a single byte to wake up poll() */
    (void)write(signal_pipe[1], "C", 1);
    errno = saved_errno;
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags == -1) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

/*
 * Send file descriptors over UDS using SCM_RIGHTS.
 * Sends stdin_w, stdout_r, stderr_r to the BEAM.
 */
static int send_fds(int uds_fd, int *fds, int nfds) {
    char buf[1] = {0};
    struct iovec iov = {.iov_base = buf, .iov_len = 1};

    size_t cmsg_space = CMSG_SPACE((size_t)nfds * sizeof(int));
    char *cmsg_buf = calloc(1, cmsg_space);
    if (!cmsg_buf) return -1;

    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = cmsg_space;

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN((size_t)nfds * sizeof(int));
    memcpy(CMSG_DATA(cmsg), fds, (size_t)nfds * sizeof(int));

    ssize_t ret = sendmsg(uds_fd, &msg, 0);
    free(cmsg_buf);
    return ret > 0 ? 0 : -1;
}

/*
 * Send a protocol message to BEAM over UDS.
 */
static int send_message(int uds_fd, uint8_t type, const void *payload,
                        size_t payload_len) {
    uint8_t buf[256];
    if (1 + payload_len > sizeof(buf)) return -1;

    buf[0] = type;
    if (payload_len > 0) {
        memcpy(buf + 1, payload, payload_len);
    }

    ssize_t written = 0;
    ssize_t total = (ssize_t)(1 + payload_len);
    while (written < total) {
        ssize_t n = write(uds_fd, buf + written, (size_t)(total - written));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        written += n;
    }
    return 0;
}

static int send_child_started(int uds_fd, pid_t pid) {
    uint32_t pid_be = htonl((uint32_t)pid);
    return send_message(uds_fd, MSG_CHILD_STARTED, &pid_be, sizeof(pid_be));
}

static int send_child_exited(int uds_fd, int status) {
    uint32_t status_be = htonl((uint32_t)status);
    return send_message(uds_fd, MSG_CHILD_EXITED, &status_be, sizeof(status_be));
}

static int send_error(int uds_fd, const char *msg) {
    size_t len = strlen(msg);
    if (len > 255) len = 255;
    uint8_t buf[258];
    buf[0] = MSG_ERROR;
    buf[1] = (uint8_t)((len >> 8) & 0xFF);
    buf[2] = (uint8_t)(len & 0xFF);
    memcpy(buf + 3, msg, len);

    ssize_t total = (ssize_t)(3 + len);
    ssize_t written = 0;
    while (written < total) {
        ssize_t n = write(uds_fd, buf + written, (size_t)(total - written));
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        written += n;
    }
    return 0;
}

/*
 * Kill child process, with escalation from SIGTERM to SIGKILL.
 */
static void kill_child(pid_t child_pid) {
    if (child_pid <= 0) return;

    /* First try SIGTERM */
    if (kill(child_pid, SIGTERM) != 0) {
        if (errno == ESRCH) return; /* Already dead */
    }

    /* Wait up to 5 seconds for graceful exit */
    for (int i = 0; i < 50; i++) {
        int status;
        pid_t ret = waitpid(child_pid, &status, WNOHANG);
        if (ret > 0 || (ret < 0 && errno == ECHILD)) return;
        usleep(100000); /* 100ms */
    }

    /* Escalate to SIGKILL */
    kill(child_pid, SIGKILL);
    waitpid(child_pid, NULL, 0);
}

/*
 * Handle a command received from BEAM over UDS.
 */
static void handle_command(int uds_fd, pid_t child_pid, int stdin_w,
                           uint8_t *buf, ssize_t len) {
    (void)uds_fd;
    if (len < 1) return;

    switch (buf[0]) {
    case CMD_KILL:
        if (len >= 2 && child_pid > 0) {
            int sig = buf[1];
            kill(child_pid, sig);
        }
        break;

    case CMD_CLOSE_STDIN:
        if (stdin_w >= 0) {
            close(stdin_w);
            /* Caller should track that stdin is closed */
        }
        break;

    default:
        DEBUG_LOG("unknown command: 0x%02x", buf[0]);
        break;
    }
}

/*
 * Main event loop using poll().
 *
 * Watches:
 *   - UDS socket for BEAM commands and POLLHUP (BEAM death)
 *   - Signal pipe for SIGCHLD (child death)
 */
static int event_loop(int uds_fd, pid_t child_pid, int stdin_w) {
    struct pollfd fds[2];
    int child_status = -1;
    int child_exited = 0;

    fds[0].fd = uds_fd;
    fds[0].events = POLLIN;
    fds[1].fd = signal_pipe[0];
    fds[1].events = POLLIN;

    while (!child_exited) {
        int ret = poll(fds, 2, -1);
        if (ret < 0) {
            if (errno == EINTR) continue;
            ERROR_LOG("poll failed: %s", strerror(errno));
            kill_child(child_pid);
            return -1;
        }

        /* Check UDS for BEAM death or commands */
        if (fds[0].revents & (POLLHUP | POLLERR)) {
            /* BEAM died - kill child and exit */
            DEBUG_LOG("BEAM connection lost (POLLHUP), killing child %d",
                      child_pid);
            kill_child(child_pid);
            return -1;
        }

        if (fds[0].revents & POLLIN) {
            uint8_t buf[16];
            ssize_t n = read(uds_fd, buf, sizeof(buf));
            if (n > 0) {
                handle_command(uds_fd, child_pid, stdin_w, buf, n);
                /* If CMD_CLOSE_STDIN was handled, mark stdin as closed */
                if (buf[0] == CMD_CLOSE_STDIN) {
                    stdin_w = -1;
                }
            } else if (n == 0) {
                /* BEAM closed the socket */
                DEBUG_LOG("BEAM closed UDS, killing child %d", child_pid);
                kill_child(child_pid);
                return -1;
            }
        }

        /* Check signal pipe for SIGCHLD */
        if (fds[1].revents & POLLIN) {
            /* Drain the signal pipe */
            char drain[64];
            while (read(signal_pipe[0], drain, sizeof(drain)) > 0) {}

            /* Reap child */
            int status;
            pid_t ret_pid = waitpid(child_pid, &status, WNOHANG);
            if (ret_pid > 0) {
                child_exited = 1;
                if (WIFEXITED(status)) {
                    child_status = WEXITSTATUS(status);
                } else if (WIFSIGNALED(status)) {
                    /* Encode signal death as 128 + signal */
                    child_status = 128 + WTERMSIG(status);
                } else {
                    child_status = -1;
                }
            }
        }
    }

    /* Notify BEAM of child exit */
    send_child_exited(uds_fd, child_status);
    return child_status;
}

/*
 * Usage: shepherd <uds_path> <cmd> [args...]
 *
 *   uds_path: Path to the UDS listener socket created by the BEAM
 *   cmd:      Command to execute
 *   args:     Arguments for the command
 */
int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: shepherd <uds_path> <cmd> [args...]\n");
        return 1;
    }

    const char *uds_path = argv[1];
    char *cmd = argv[2];
    char **cmd_args = &argv[2]; /* cmd + args, NULL-terminated by OS */

    /* Set up self-pipe for signal handling */
    if (pipe(signal_pipe) != 0) {
        perror("pipe");
        return 1;
    }
    set_nonblocking(signal_pipe[0]);
    set_nonblocking(signal_pipe[1]);
    set_cloexec(signal_pipe[0]);
    set_cloexec(signal_pipe[1]);

    /* Install SIGCHLD handler */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigchld_handler;
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigaction(SIGCHLD, &sa, NULL);

    /* Connect to BEAM's UDS listener */
    int uds_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (uds_fd < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, uds_path, sizeof(addr.sun_path) - 1);

    if (connect(uds_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("connect");
        close(uds_fd);
        return 1;
    }

    set_cloexec(uds_fd);

    /* Create pipes for child stdin/stdout/stderr */
    int stdin_pipe[2];   /* [0]=read (child), [1]=write (beam) */
    int stdout_pipe[2];  /* [0]=read (beam), [1]=write (child) */
    int stderr_pipe[2];  /* [0]=read (beam), [1]=write (child) */

    if (pipe(stdin_pipe) != 0 || pipe(stdout_pipe) != 0 ||
        pipe(stderr_pipe) != 0) {
        send_error(uds_fd, "failed to create pipes");
        close(uds_fd);
        return 1;
    }

    /* Fork child process */
    pid_t child_pid = fork();
    if (child_pid < 0) {
        send_error(uds_fd, "fork failed");
        close(uds_fd);
        return 1;
    }

    if (child_pid == 0) {
        /* === Child process === */

        /* Close shepherd-side FDs */
        close(uds_fd);
        close(signal_pipe[0]);
        close(signal_pipe[1]);
        close(stdin_pipe[1]);  /* Close write end of stdin */
        close(stdout_pipe[0]); /* Close read end of stdout */
        close(stderr_pipe[0]); /* Close read end of stderr */

        /* Redirect stdio */
        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);

        /* Close original pipe FDs after dup */
        close(stdin_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        /* Create new process group */
        setpgid(0, 0);

        /* Execute command */
        execvp(cmd, cmd_args);

        /* If execvp returns, it failed */
        fprintf(stderr, "execvp failed: %s: %s\n", cmd, strerror(errno));
        _exit(127);
    }

    /* === Shepherd process === */

    /* Close child-side FDs */
    close(stdin_pipe[0]);  /* Close read end of stdin */
    close(stdout_pipe[1]); /* Close write end of stdout */
    close(stderr_pipe[1]); /* Close write end of stderr */

    /* Send pipe FDs to BEAM via SCM_RIGHTS: stdin_w, stdout_r, stderr_r */
    int fds_to_send[3] = {stdin_pipe[1], stdout_pipe[0], stderr_pipe[0]};
    if (send_fds(uds_fd, fds_to_send, 3) != 0) {
        send_error(uds_fd, "failed to send FDs");
        kill_child(child_pid);
        close(uds_fd);
        return 1;
    }

    /* Notify BEAM that child has started */
    if (send_child_started(uds_fd, child_pid) != 0) {
        kill_child(child_pid);
        close(uds_fd);
        return 1;
    }

    /* Keep a copy of stdin_w for CMD_CLOSE_STDIN.
     * Also close our copy of the FDs that BEAM now owns,
     * EXCEPT stdin_w which we keep for close-stdin support. */
    int shepherd_stdin_w = stdin_pipe[1];
    close(stdout_pipe[0]);
    close(stderr_pipe[0]);

    /* Enter event loop */
    int result = event_loop(uds_fd, child_pid, shepherd_stdin_w);

    /* Cleanup */
    if (shepherd_stdin_w >= 0) close(shepherd_stdin_w);
    close(uds_fd);

    return result >= 0 ? 0 : 1;
}
