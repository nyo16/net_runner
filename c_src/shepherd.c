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
#include <sys/ioctl.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* PTY headers — platform-specific */
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

#include "protocol.h"
#include "utils.h"

/* Self-pipe for signal handling */
static int signal_pipe[2] = {-1, -1};

/*
 * Async-signal-safe post-fork failure path. Between fork() and exec*(),
 * POSIX allows only async-signal-safe functions, so we cannot call
 * fprintf / strerror / malloc. This helper uses write(2) on a stack
 * buffer only.
 */
static void child_fail(const char *tag, const char *detail) {
    if (tag) {
        size_t i = 0;
        while (i < 64 && tag[i] != '\0') i++;
        (void)!write(STDERR_FILENO, tag, i);
        (void)!write(STDERR_FILENO, ": ", 2);
    }
    if (detail) {
        size_t i = 0;
        while (i < 256 && detail[i] != '\0') i++;
        (void)!write(STDERR_FILENO, detail, i);
    }
    (void)!write(STDERR_FILENO, "\n", 1);
    _exit(127);
}

static void sigchld_handler(int sig) {
    (void)sig;
    int saved_errno = errno;
    /* Write a single byte to wake up poll() — ignore failure in signal handler */
    if (write(signal_pipe[1], "C", 1) < 0) { /* nothing to do */ }
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

/* Milliseconds on a monotonic clock, or -1 if the clock is unavailable. */
static int64_t monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Bound on how long any single shepherd->BEAM frame may wait for socket
 * buffer space before being dropped. */
#define UDS_WRITE_TIMEOUT_MS 5000

/*
 * Write all of buf to the non-blocking UDS, polling POLLOUT for up to
 * timeout_ms before giving up. Returns 0 on success, -1 on error/timeout.
 *
 * The UDS is deliberately non-blocking for writes: a BEAM that stops
 * draining the socket must not park the shepherd in write(2) forever.
 * The critical case is send_child_exited after the child was reaped — a
 * shepherd wedged there never runs cgroup_cleanup(), leaking the cgroup
 * and any processes still in it. On persistent EAGAIN we drop the frame
 * instead: the peer is wedged or gone, it will observe the UDS close
 * when we exit, and a lost frame is recoverable where a wedged shepherd
 * is not.
 */
static int write_fully(int fd, const uint8_t *buf, size_t len,
                       int timeout_ms) {
    int64_t now = monotonic_ms();
    int64_t deadline = (now < 0) ? -1 : now + timeout_ms;
    size_t written = 0;

    while (written < len) {
        ssize_t n = write(fd, buf + written, len - written);
        if (n > 0) {
            written += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            int wait_ms = timeout_ms;
            if (deadline >= 0) {
                now = monotonic_ms();
                if (now < 0 || now >= deadline) return -1;
                wait_ms = (int)(deadline - now);
            }
            struct pollfd pfd = {.fd = fd, .events = POLLOUT, .revents = 0};
            int pret = poll(&pfd, 1, wait_ms);
            if (pret < 0 && errno != EINTR) return -1;
            if (pret == 0) return -1; /* peer not draining: drop the frame */
            continue;
        }
        return -1;
    }
    return 0;
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
    if (!cmsg_buf) {
        ERROR_LOG("send_fds: calloc(%zu) failed", cmsg_space);
        return -1;
    }

    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = cmsg_space;

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (!cmsg) {
        ERROR_LOG("send_fds: CMSG_FIRSTHDR returned NULL");
        free(cmsg_buf);
        return -1;
    }
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN((size_t)nfds * sizeof(int));
    memcpy(CMSG_DATA(cmsg), fds, (size_t)nfds * sizeof(int));

    /* Retry on EINTR; wait (bounded) for buffer space on EAGAIN — the UDS
     * is non-blocking. Anything else, or a partial send, is an error. */
    for (;;) {
        ssize_t ret = sendmsg(uds_fd, &msg, 0);
        if (ret == 1) {
            free(cmsg_buf);
            return 0;
        }
        if (ret < 0 && errno == EINTR) continue;
        if (ret < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pfd = {.fd = uds_fd, .events = POLLOUT,
                                 .revents = 0};
            int pret = poll(&pfd, 1, UDS_WRITE_TIMEOUT_MS);
            if (pret > 0 || (pret < 0 && errno == EINTR)) continue;
            ERROR_LOG("sendmsg: no buffer space after %d ms",
                      UDS_WRITE_TIMEOUT_MS);
            free(cmsg_buf);
            return -1;
        }
        ERROR_LOG("sendmsg failed: ret=%zd errno=%s", ret, strerror(errno));
        free(cmsg_buf);
        return -1;
    }
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

    return write_fully(uds_fd, buf, 1 + payload_len, UDS_WRITE_TIMEOUT_MS);
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

    return write_fully(uds_fd, buf, 3 + len, UDS_WRITE_TIMEOUT_MS);
}

/* Configurable kill escalation timeout (set from CLI arg) */
static int kill_timeout_ms = DEFAULT_KILL_TIMEOUT_MS;

/* PTY mode: master FD kept for WINSIZE ioctls */
static int pty_mode = MODE_PIPE;
static int pty_master_fd = -1;

/* cgroup v2 support (Linux only) */
static char cgroup_path[CGROUP_PATH_MAX] = {0};

/* Human-readable reason for the most recent cgroup_setup() failure. The
 * spawn paths send it to the BEAM as MSG_ERROR so the caller learns WHY
 * isolation could not be established. Only ever written on Linux; the
 * default covers the (unreachable) failure of the non-Linux stub. */
static char cgroup_errmsg[256] = "cgroup setup failed";

#ifdef __linux__
/* Set only when this shepherd created the cgroup directory itself. A
 * pre-existing directory belongs to someone else: attach the child to it,
 * but never cgroup.kill it or rmdir it on teardown. */
static int cgroup_owned = 0;
#endif

#ifdef __linux__
#include <dirent.h>

static int cgroup_setup(pid_t child_pid) {
    if (cgroup_path[0] == '\0') return 0;

    char full_path[512];
    char procs_path[576];

    int n = snprintf(full_path, sizeof(full_path), "/sys/fs/cgroup/%s",
                     cgroup_path);
    if (n < 0 || (size_t)n >= sizeof(full_path)) {
        ERROR_LOG("cgroup path too long");
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: path too long");
        return -1;
    }
    /* 0700 — the cgroup directory has no reason to be group/world
     * readable. A pre-existing directory is fatal: we cannot know who
     * owns it, cgroup_cleanup() would refuse to tear it down
     * (cgroup_owned stays 0), and silently degrading containment the
     * caller explicitly requested is worse than failing the spawn. */
    if (mkdir(full_path, 0700) == 0) {
        cgroup_owned = 1;
    } else if (errno == EEXIST) {
        ERROR_LOG("cgroup %s already exists; refusing to adopt it",
                  full_path);
        /* %.180s caps the interpolated path: cgroup_path may be up to 255
         * bytes, and 14 + 180 + 44 + NUL must fit the 256-byte errmsg
         * (gcc -Wformat-truncation under -Werror on glibc). */
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: %.180s already exists; teardown would not be owned",
                 cgroup_path);
        return -1;
    } else {
        int err = errno;
        ERROR_LOG("mkdir(%s) failed: %s", full_path, strerror(err));
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: mkdir failed: %s", strerror(err));
        return -1;
    }

    n = snprintf(procs_path, sizeof(procs_path), "%s/cgroup.procs", full_path);
    if (n < 0 || (size_t)n >= sizeof(procs_path)) {
        ERROR_LOG("cgroup procs path too long");
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: procs path too long");
        return -1;
    }
    FILE *f = fopen(procs_path, "w");
    if (!f) {
        int err = errno;
        ERROR_LOG("failed to open %s: %s", procs_path, strerror(err));
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: open cgroup.procs failed: %s", strerror(err));
        return -1;
    }
    if (fprintf(f, "%d\n", child_pid) < 0) {
        int err = errno;
        ERROR_LOG("write to %s failed: %s", procs_path, strerror(err));
        fclose(f);
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: write to cgroup.procs failed: %s",
                 strerror(err));
        return -1;
    }
    /* The pid migration happens at write/flush time behind stdio
     * buffering, so the real failures (EPERM without delegation, EBUSY on
     * an inner node, ENOENT for a vanished cgroup) surface at fclose. An
     * unchecked fclose here made isolation fail open. */
    if (fclose(f) != 0) {
        int err = errno;
        ERROR_LOG("flush to %s failed: %s", procs_path, strerror(err));
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: write to cgroup.procs failed: %s",
                 strerror(err));
        return -1;
    }
    return 0;
}

static void cgroup_cleanup(void) {
    if (cgroup_path[0] == '\0' || !cgroup_owned) return;

    char full_path[512];
    char kill_path[576];

    int n = snprintf(full_path, sizeof(full_path), "/sys/fs/cgroup/%s",
                     cgroup_path);
    if (n < 0 || (size_t)n >= sizeof(full_path)) return;

    /* Kill all processes in the cgroup via cgroup.kill (cgroup v2) */
    n = snprintf(kill_path, sizeof(kill_path), "%s/cgroup.kill", full_path);
    if (n < 0 || (size_t)n >= sizeof(kill_path)) return;
    FILE *f = fopen(kill_path, "w");
    if (f) {
        fprintf(f, "1\n");
        fclose(f);
    }

    /* Poll for rmdir success rather than a fixed sleep — the kernel needs
     * a moment to reap the killed processes. Bail after ~1s (10 * 100ms). */
    for (int i = 0; i < 10; i++) {
        if (rmdir(full_path) == 0) return;
        if (errno != EBUSY && errno != ENOTEMPTY) return; /* real error */
        usleep(100000);
    }
}
#else
static int cgroup_setup(pid_t child_pid) {
    (void)child_pid;
    return 0;
}
static void cgroup_cleanup(void) {}
#endif

/*
 * Wait up to timeout_ms for child_pid to be reaped. Returns 1 if it was reaped
 * (or was already gone), 0 on timeout.
 *
 * Blocks in poll() on the SIGCHLD self-pipe rather than sleeping in fixed
 * slices: a child that died 1 ms after SIGTERM used to cost a full 100 ms
 * usleep tick, twice over. The deadline comes from a monotonic clock so that
 * EINTR (SIGCHLD itself interrupts poll) and wakeups for some other child
 * cannot extend it; if the clock is unavailable the loop collapses to a single
 * bounded poll, which is still bounded.
 */
static int wait_for_child(pid_t child_pid, int timeout_ms) {
    int64_t now = monotonic_ms();
    int64_t deadline = (now < 0) ? -1 : now + timeout_ms;
    int wait_ms = timeout_ms;

    for (;;) {
        pid_t ret = waitpid(child_pid, NULL, WNOHANG);
        if (ret > 0 || (ret < 0 && errno == ECHILD)) return 1;
        if (wait_ms <= 0) return 0;

        struct pollfd pfd;
        pfd.fd = signal_pipe[0];
        pfd.events = POLLIN;
        pfd.revents = 0;
        int pret = poll(&pfd, 1, wait_ms);
        if (pret < 0 && errno != EINTR) {
            /* poll is broken — give up rather than spin on it. */
            return 0;
        }
        if (pret > 0 && (pfd.revents & POLLIN)) {
            /* Drain the self-pipe. It is non-blocking and the event loop may
             * have drained it already, so EAGAIN here is expected. */
            char drain[64];
            while (read(signal_pipe[0], drain, sizeof(drain)) > 0) {}
        }

        if (deadline < 0) {
            wait_ms = 0; /* No clock: one poll, then a final waitpid. */
        } else {
            now = monotonic_ms();
            wait_ms = (now < 0) ? 0 : (int)(deadline - now);
        }
    }
}

/*
 * Kill child process group, with escalation from SIGTERM to SIGKILL.
 * The child called setpgid(0,0) so its pgid == child_pid.
 * Using kill(-pgid, sig) catches grandchildren too.
 */
static void kill_child(pid_t child_pid) {
    if (child_pid <= 0) return;

    /* First try SIGTERM to the whole process group */
    if (kill(-child_pid, SIGTERM) != 0) {
        /* Process group may not exist; try direct kill */
        if (kill(child_pid, SIGTERM) != 0 && errno == ESRCH)
            return; /* Already dead */
    }

    /* Wait for graceful exit (configurable, default 5s) */
    if (!wait_for_child(child_pid, kill_timeout_ms)) {
        /* Escalate to SIGKILL the whole process group */
        kill(-child_pid, SIGKILL);

        /* Bounded — a child wedged in uninterruptible kernel sleep (D-state)
         * never reaps, and we must not hang the shepherd on it. cgroup
         * cleanup and the kernel take over from there. */
        (void)wait_for_child(child_pid, 3000);
    }

    /* Cleanup cgroup (kills any remaining processes, removes dir) */
    cgroup_cleanup();
}

/*
 * Length of a single framed command given its opcode. Returns 0 if the
 * opcode is unknown (in which case the parser will skip one byte).
 */
static size_t command_length(uint8_t opcode) {
    switch (opcode) {
    case CMD_KILL:         return 2;
    case CMD_CLOSE_STDIN:  return 1;
    case CMD_SET_WINSIZE:  return 5;
    default:               return 0;
    }
}

/*
 * Handle a single command frame.
 */
static void handle_command(int uds_fd, pid_t child_pid, int stdin_w,
                           uint8_t *buf, size_t len) {
    (void)uds_fd;
    if (len < 1) return;

    switch (buf[0]) {
    case CMD_KILL:
        if (len >= 2 && child_pid > 0) {
            int sig = buf[1];
            /* Validate signal is in POSIX range */
            if (sig < 1 || sig > 31) break;
            /* Kill the process group (catches grandchildren).
             * Fall back to direct kill if group doesn't exist. */
            if (kill(-child_pid, sig) != 0) {
                kill(child_pid, sig);
            }
        }
        break;

    case CMD_CLOSE_STDIN:
        if (stdin_w >= 0) {
            close(stdin_w);
        }
        break;

    case CMD_SET_WINSIZE:
        if (len >= 5 && pty_master_fd >= 0) {
            struct winsize ws;
            memset(&ws, 0, sizeof(ws));
            ws.ws_row = (unsigned short)((buf[1] << 8) | buf[2]);
            ws.ws_col = (unsigned short)((buf[3] << 8) | buf[4]);
            ioctl(pty_master_fd, TIOCSWINSZ, &ws);
        }
        break;

    default:
        DEBUG_LOG("unknown command: 0x%02x", buf[0]);
        break;
    }
}

/*
 * Parse and dispatch all framed commands present in buf. Returns the number
 * of bytes consumed (may be less than len if a tail command is truncated).
 */
static size_t handle_commands(int uds_fd, pid_t child_pid, int *stdin_w,
                              uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        size_t clen = command_length(buf[off]);
        if (clen == 0) {
            /* Unknown opcode: skip one byte to make progress rather than
             * stalling the parser on bad input. */
            DEBUG_LOG("unknown command opcode 0x%02x, skipping", buf[off]);
            off += 1;
            continue;
        }
        if (off + clen > len) {
            /* Partial tail — caller must carry this over to the next read. */
            break;
        }
        uint8_t op = buf[off];
        handle_command(uds_fd, child_pid, *stdin_w, &buf[off], clen);
        if (op == CMD_CLOSE_STDIN) {
            *stdin_w = -1;
        }
        off += clen;
    }
    return off;
}

/*
 * Main event loop using poll().
 *
 * Watches:
 *   - UDS socket for BEAM commands and POLLHUP (BEAM death)
 *   - Signal pipe for SIGCHLD (child death)
 */
static int event_loop(int uds_fd, pid_t child_pid, int *stdin_w) {
    struct pollfd fds[2];
    int child_status = -1;
    int child_exited = 0;

    /* Carry-over buffer for partially-framed commands across reads. Max
     * incoming frame is CMD_SET_WINSIZE (5 bytes); keep a little slack. */
    uint8_t cbuf[64];
    size_t cbuf_used = 0;

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
            ssize_t n = read(uds_fd, cbuf + cbuf_used, sizeof(cbuf) - cbuf_used);
            if (n > 0) {
                cbuf_used += (size_t)n;
                size_t consumed = handle_commands(uds_fd, child_pid, stdin_w,
                                                  cbuf, cbuf_used);
                if (consumed > 0 && consumed < cbuf_used) {
                    memmove(cbuf, cbuf + consumed, cbuf_used - consumed);
                }
                cbuf_used -= consumed;
            } else if (n == 0) {
                /* BEAM closed the socket */
                DEBUG_LOG("BEAM closed UDS, killing child %d", child_pid);
                kill_child(child_pid);
                return -1;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK &&
                       errno != EINTR) {
                ERROR_LOG("read(uds) failed: %s", strerror(errno));
                kill_child(child_pid);
                return -1;
            }
        }

        /* Check signal pipe for SIGCHLD */
        if (fds[1].revents & POLLIN) {
            /* Drain the signal pipe */
            char drain[64];
            while (read(signal_pipe[0], drain, sizeof(drain)) > 0) {}

            /* Reap any and all children that have exited. SIGCHLD is
             * coalesced by the kernel — multiple pending exits can deliver
             * as a single SIGCHLD. Loop until no more reapable children
             * remain. We only flip child_exited when the managed child is
             * reaped; other reapees (should be none today, future-proof)
             * are still cleaned up. */
            int status;
            pid_t ret_pid;
            while ((ret_pid = waitpid(-1, &status, WNOHANG)) > 0) {
                if (ret_pid != child_pid) continue;
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

    /* Notify BEAM of the child exit FIRST. cgroup_cleanup() retries rmdir up
     * to ten times with usleep(100000) between, so doing it first parks the
     * caller's await_exit for up to a full second on a status we already hold
     * in child_status. Nothing in cgroup_cleanup() can change child_status or
     * uds_fd, so the order is free to swap. (kill_child's ordering at :352 is
     * deliberately the other way round — there the cleanup is the point.) */
    send_child_exited(uds_fd, child_status);

    /* Cleanup cgroup on normal exit too */
    cgroup_cleanup();
    return child_status;
}

/*
 * Usage: shepherd <uds_path> [--kill-timeout <ms>] [--token-fd] <cmd> [args...]
 *
 *   uds_path:       Path to the UDS listener socket created by the BEAM
 *   --kill-timeout:  SIGTERM->SIGKILL escalation timeout in ms (default 5000)
 *   --token-fd:     read the 32-char hex handshake token from fd 3 (the
 *                   BEAM port channel) and send it verbatim as the first
 *                   frame after connect so the BEAM can authenticate us
 *   cmd:            Command to execute
 *   args:           Arguments for the command
 */
int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr,
                "usage: shepherd <uds_path> [--kill-timeout <ms>] [--token-fd] <cmd> [args...]\n");
        return 1;
    }

    const char *uds_path = argv[1];
    int cmd_idx = 2;
    int token_from_fd = 0;
    char token[TOKEN_HEX_LEN + 1] = {0};

    /* Parse optional flags */
    while (cmd_idx < argc && argv[cmd_idx][0] == '-') {
        if (strcmp(argv[cmd_idx], "--kill-timeout") == 0 && cmd_idx + 1 < argc) {
            char *endptr;
            long val = strtol(argv[cmd_idx + 1], &endptr, 10);
            if (*endptr != '\0' || endptr == argv[cmd_idx + 1] || val <= 0 || val > 60000) {
                fprintf(stderr, "error: --kill-timeout must be 1-60000 ms\n");
                return 1;
            }
            kill_timeout_ms = (int)val;
            cmd_idx += 2;
        } else if (strcmp(argv[cmd_idx], "--pty") == 0) {
            pty_mode = MODE_PTY;
            cmd_idx += 1;
        } else if (strcmp(argv[cmd_idx], "--token-fd") == 0) {
            /* The token is read from fd 3 (the :nouse_stdio port channel),
             * NEVER argv: /proc/<pid>/cmdline is world-readable on Linux and
             * same-uid readable on macOS, so an argv token would be visible
             * to exactly the same-uid attacker it exists to stop. */
            token_from_fd = 1;
            cmd_idx += 1;
        } else if (strcmp(argv[cmd_idx], "--cgroup-path") == 0 && cmd_idx + 1 < argc) {
            const char *path = argv[cmd_idx + 1];
            /* Reject path traversal: no ".." components, no leading "/" */
            if (path[0] == '/' || strstr(path, "..") != NULL) {
                fprintf(stderr, "error: invalid cgroup path (must be relative, no '..')\n");
                return 1;
            }
            /* Reject rather than silently truncate: a truncated path would
             * attach the child to (and later kill) a different cgroup than
             * the one the caller validated. */
            if (strlen(path) >= CGROUP_PATH_MAX) {
                fprintf(stderr, "error: cgroup path too long (max %d bytes)\n",
                        CGROUP_PATH_MAX - 1);
                return 1;
            }
            memcpy(cgroup_path, path, strlen(path) + 1);
            cmd_idx += 2;
        } else {
            break; /* Unknown flag — treat as command */
        }
    }

    if (cmd_idx >= argc) {
        fprintf(stderr, "error: no command specified\n");
        return 1;
    }

    /* FDs 3/4 are the BEAM port's :nouse_stdio channel to this shepherd.
     * Mark them close-on-exec so the child cannot inherit a handle to the
     * BEAM. (The UDS and pipe fds get their own CLOEXEC below.) */
    set_cloexec(3);
    set_cloexec(4);

    /* Read the handshake token from the BEAM before touching the UDS. The
     * port channel is private to the BEAM and this process. */
    if (token_from_fd) {
        size_t got = 0;
        while (got < TOKEN_HEX_LEN) {
            ssize_t n = read(3, token + got, TOKEN_HEX_LEN - got);
            if (n < 0) {
                if (errno == EINTR) continue;
                perror("token read");
                return 1;
            }
            if (n == 0) {
                fprintf(stderr, "error: BEAM closed before sending token\n");
                return 1;
            }
            got += (size_t)n;
        }
    }

    char *cmd = argv[cmd_idx];
    char **cmd_args = &argv[cmd_idx]; /* cmd + args, NULL-terminated by OS */

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
    if (sigaction(SIGCHLD, &sa, NULL) != 0) {
        perror("sigaction");
        return 1;
    }

    /* Ignore SIGPIPE: a write to a BEAM that has already gone away must fail
     * with EPIPE — every write loop here checks for a negative return — rather
     * than killing the shepherd outright and orphaning the child. */
    struct sigaction sa_pipe;
    memset(&sa_pipe, 0, sizeof(sa_pipe));
    sa_pipe.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &sa_pipe, NULL) != 0) {
        perror("sigaction(SIGPIPE)");
        return 1;
    }

    /* Connect to BEAM's UDS listener */
    int uds_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (uds_fd < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(uds_path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "error: uds_path too long (max %zu bytes)\n",
                sizeof(addr.sun_path) - 1);
        close(uds_fd);
        return 1;
    }
    strncpy(addr.sun_path, uds_path, sizeof(addr.sun_path) - 1);

    if (connect(uds_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("connect");
        close(uds_fd);
        return 1;
    }

    set_cloexec(uds_fd);

    /* Writes to the UDS are non-blocking + bounded (see write_fully). The
     * event-loop reads already tolerate EAGAIN. */
    if (set_nonblocking(uds_fd) != 0) {
        perror("fcntl(uds, O_NONBLOCK)");
        close(uds_fd);
        return 1;
    }

    /* Authenticate: the BEAM handed us a per-spawn random token over fd 3
     * and accepts FDs only from the peer that echoes it back as the very
     * first frame. Without this, any same-uid process that wins the accept
     * race would receive the child's pipe FDs via SCM_RIGHTS. */
    if (token_from_fd) {
        if (write_fully(uds_fd, (const uint8_t *)token, TOKEN_HEX_LEN,
                        UDS_WRITE_TIMEOUT_MS) != 0) {
            fprintf(stderr, "error: token write failed\n");
            close(uds_fd);
            return 1;
        }
    }

    pid_t child_pid;
    int shepherd_stdin_w = -1;

    if (pty_mode == MODE_PTY) {
        /* === PTY mode: single bidirectional master FD === */
        int master_fd, slave_fd;
        if (openpty(&master_fd, &slave_fd, NULL, NULL, NULL) != 0) {
            send_error(uds_fd, "openpty failed");
            close(uds_fd);
            return 1;
        }

        /* cgroup/exec ordering gate (used by the shepherd side below).
         * Created only when a cgroup was requested, so non-cgroup spawns
         * are byte-for-byte unchanged. */
        int sync_pipe[2] = {-1, -1};
        if (cgroup_path[0] != '\0' && pipe(sync_pipe) != 0) {
            send_error(uds_fd, "failed to create cgroup sync pipe");
            close(master_fd);
            close(slave_fd);
            close(uds_fd);
            return 1;
        }

        child_pid = fork();
        if (child_pid < 0) {
            send_error(uds_fd, "fork failed");
            close(master_fd);
            close(slave_fd);
            close(uds_fd);
            return 1;
        }

        if (child_pid == 0) {
            /* === Child process (PTY) === */
            close(uds_fd);
            close(signal_pipe[0]);
            close(signal_pipe[1]);
            close(master_fd);

            /* Wait for the shepherd to place us in the requested cgroup
             * before doing anything that can create more pids (execvp,
             * and everything the exec'd program forks). cgroup.procs
             * migration moves only the written pid, so a grandchild
             * forked before migration would escape the cgroup's limits
             * and its cgroup.kill teardown. Only async-signal-safe calls
             * here (read/write/close/_exit). EOF or a non-'G' byte means
             * the shepherd could not establish isolation: die without
             * exec. */
            if (sync_pipe[0] >= 0) {
                close(sync_pipe[1]);
                char go = 0;
                ssize_t r;
                do {
                    r = read(sync_pipe[0], &go, 1);
                } while (r < 0 && errno == EINTR);
                close(sync_pipe[0]);
                if (r != 1 || go != 'G') _exit(127);
            }

            /* Create new session (required before acquiring controlling tty) */
            if (setsid() == (pid_t)-1) child_fail("setsid", NULL);
            if (ioctl(slave_fd, TIOCSCTTY, 0) != 0) child_fail("TIOCSCTTY", NULL);

            if (dup2(slave_fd, STDIN_FILENO)  != STDIN_FILENO ||
                dup2(slave_fd, STDOUT_FILENO) != STDOUT_FILENO ||
                dup2(slave_fd, STDERR_FILENO) != STDERR_FILENO) {
                child_fail("dup2", NULL);
            }
            if (slave_fd > STDERR_FILENO) close(slave_fd);

            /* SIG_IGN survives exec, so restore the default SIGPIPE
             * disposition the child would have had under a shell. */
            signal(SIGPIPE, SIG_DFL);

            setpgid(0, 0);
            execvp(cmd, cmd_args);
            child_fail("execvp", cmd);
        }

        /* === Shepherd (PTY) === */
        close(slave_fd);
        pty_master_fd = master_fd;
        set_cloexec(master_fd);

        /* Move child to cgroup (Linux only, no-op elsewhere). The child
         * is parked on the sync pipe until the outcome is known, so
         * nothing can exec — or fork grandchildren — outside the cgroup.
         * If the user requested a cgroup path and setup failed, isolation
         * is not available — treat as fatal. */
        if (cgroup_setup(child_pid) != 0) {
            if (sync_pipe[0] >= 0) {
                /* EOF on the gate: the child _exit(127)s without exec. */
                close(sync_pipe[0]);
                close(sync_pipe[1]);
            }
            send_error(uds_fd, cgroup_errmsg);
            kill_child(child_pid);
            close(master_fd);
            close(uds_fd);
            return 1;
        }
        if (sync_pipe[0] >= 0) {
            close(sync_pipe[0]);
            char go = 'G';
            ssize_t w;
            do {
                w = write(sync_pipe[1], &go, 1);
            } while (w < 0 && errno == EINTR);
            close(sync_pipe[1]);
            if (w != 1) {
                /* The child cannot exec without the go byte; treat as a
                 * failed spawn rather than leave it parked forever. */
                send_error(uds_fd, "cgroup sync pipe write failed");
                kill_child(child_pid);
                close(master_fd);
                close(uds_fd);
                return 1;
            }
        }

        /* Send single master FD to BEAM (used for both read and write) */
        int fds_to_send[1] = {master_fd};
        if (send_fds(uds_fd, fds_to_send, 1) != 0) {
            send_error(uds_fd, "failed to send PTY FD");
            kill_child(child_pid);
            close(master_fd);
            close(uds_fd);
            return 1;
        }

        if (send_child_started(uds_fd, child_pid) != 0) {
            kill_child(child_pid);
            close(master_fd);
            close(uds_fd);
            return 1;
        }

        /* No stdin_w to keep — master FD is bidirectional */
        shepherd_stdin_w = -1;

    } else {
        /* === Pipe mode (default) === */
        int stdin_pipe[2] = {-1, -1};
        int stdout_pipe[2] = {-1, -1};
        int stderr_pipe[2] = {-1, -1};

#ifdef __linux__
        /* Use pipe2 with O_CLOEXEC to atomically set close-on-exec */
        if (pipe2(stdin_pipe, O_CLOEXEC) != 0) {
#else
        if (pipe(stdin_pipe) != 0) {
#endif
            send_error(uds_fd, "failed to create pipes");
            close(uds_fd);
            return 1;
        }
#ifdef __linux__
        if (pipe2(stdout_pipe, O_CLOEXEC) != 0) {
#else
        if (pipe(stdout_pipe) != 0) {
#endif
            send_error(uds_fd, "failed to create pipes");
            close(stdin_pipe[0]); close(stdin_pipe[1]);
            close(uds_fd);
            return 1;
        }
#ifdef __linux__
        if (pipe2(stderr_pipe, O_CLOEXEC) != 0) {
#else
        if (pipe(stderr_pipe) != 0) {
#endif
            send_error(uds_fd, "failed to create pipes");
            close(stdin_pipe[0]); close(stdin_pipe[1]);
            close(stdout_pipe[0]); close(stdout_pipe[1]);
            close(uds_fd);
            return 1;
        }
#ifndef __linux__
        /* On macOS, set close-on-exec manually */
        set_cloexec(stdin_pipe[0]);  set_cloexec(stdin_pipe[1]);
        set_cloexec(stdout_pipe[0]); set_cloexec(stdout_pipe[1]);
        set_cloexec(stderr_pipe[0]); set_cloexec(stderr_pipe[1]);
#endif

#ifdef __linux__
        /* Grow the pipe buffers from the default 64 KiB to 1 MiB. Each
         * buffer-sized chunk costs the BEAM a full read -> EAGAIN ->
         * enif_select -> message round trip, so a 16x bigger buffer cuts the
         * round trips per MiB by ~16x. Best effort: the kernel caps the size
         * via /proc/sys/fs/pipe-max-size and an unprivileged process may not
         * be permitted to grow it at all, in which case the default stands.
         * macOS has no equivalent knob. */
        (void)fcntl(stdout_pipe[0], F_SETPIPE_SZ, 1 << 20);
        (void)fcntl(stderr_pipe[0], F_SETPIPE_SZ, 1 << 20);
        (void)fcntl(stdin_pipe[1], F_SETPIPE_SZ, 1 << 20);
#endif

        /* cgroup/exec ordering gate — see the PTY path for rationale. */
        int sync_pipe[2] = {-1, -1};
        if (cgroup_path[0] != '\0' && pipe(sync_pipe) != 0) {
            send_error(uds_fd, "failed to create cgroup sync pipe");
            close(stdin_pipe[0]);  close(stdin_pipe[1]);
            close(stdout_pipe[0]); close(stdout_pipe[1]);
            close(stderr_pipe[0]); close(stderr_pipe[1]);
            close(uds_fd);
            return 1;
        }

        child_pid = fork();
        if (child_pid < 0) {
            send_error(uds_fd, "fork failed");
            close(stdin_pipe[0]);  close(stdin_pipe[1]);
            close(stdout_pipe[0]); close(stdout_pipe[1]);
            close(stderr_pipe[0]); close(stderr_pipe[1]);
            close(uds_fd);
            return 1;
        }

        if (child_pid == 0) {
            /* === Child process (pipe) === */
            close(uds_fd);
            close(signal_pipe[0]);
            close(signal_pipe[1]);
            close(stdin_pipe[1]);
            close(stdout_pipe[0]);
            close(stderr_pipe[0]);

            /* Gate exec on cgroup placement — see the PTY child above.
             * Only async-signal-safe calls (read/write/close/_exit). */
            if (sync_pipe[0] >= 0) {
                close(sync_pipe[1]);
                char go = 0;
                ssize_t r;
                do {
                    r = read(sync_pipe[0], &go, 1);
                } while (r < 0 && errno == EINTR);
                close(sync_pipe[0]);
                if (r != 1 || go != 'G') _exit(127);
            }

            if (dup2(stdin_pipe[0],  STDIN_FILENO)  != STDIN_FILENO ||
                dup2(stdout_pipe[1], STDOUT_FILENO) != STDOUT_FILENO ||
                dup2(stderr_pipe[1], STDERR_FILENO) != STDERR_FILENO) {
                child_fail("dup2", NULL);
            }

            close(stdin_pipe[0]);
            close(stdout_pipe[1]);
            close(stderr_pipe[1]);

            /* SIG_IGN survives exec, so restore the default SIGPIPE
             * disposition the child would have had under a shell. */
            signal(SIGPIPE, SIG_DFL);

            setpgid(0, 0);
            execvp(cmd, cmd_args);
            child_fail("execvp", cmd);
        }

        /* === Shepherd (pipe) === */
        close(stdin_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        /* Move child to cgroup (Linux only, no-op elsewhere). The child
         * is parked on the sync pipe until the outcome is known, so
         * nothing can exec — or fork grandchildren — outside the cgroup.
         * If the user requested a cgroup path and setup failed, isolation
         * is not available — treat as fatal. */
        if (cgroup_setup(child_pid) != 0) {
            if (sync_pipe[0] >= 0) {
                /* EOF on the gate: the child _exit(127)s without exec. */
                close(sync_pipe[0]);
                close(sync_pipe[1]);
            }
            send_error(uds_fd, cgroup_errmsg);
            kill_child(child_pid);
            close(stdin_pipe[1]);
            close(stdout_pipe[0]);
            close(stderr_pipe[0]);
            close(uds_fd);
            return 1;
        }
        if (sync_pipe[0] >= 0) {
            close(sync_pipe[0]);
            char go = 'G';
            ssize_t w;
            do {
                w = write(sync_pipe[1], &go, 1);
            } while (w < 0 && errno == EINTR);
            close(sync_pipe[1]);
            if (w != 1) {
                /* The child cannot exec without the go byte; treat as a
                 * failed spawn rather than leave it parked forever. */
                send_error(uds_fd, "cgroup sync pipe write failed");
                kill_child(child_pid);
                close(stdin_pipe[1]);
                close(stdout_pipe[0]);
                close(stderr_pipe[0]);
                close(uds_fd);
                return 1;
            }
        }

        int fds_to_send[3] = {stdin_pipe[1], stdout_pipe[0], stderr_pipe[0]};
        if (send_fds(uds_fd, fds_to_send, 3) != 0) {
            send_error(uds_fd, "failed to send FDs");
            kill_child(child_pid);
            close(stdin_pipe[1]);
            close(stdout_pipe[0]);
            close(stderr_pipe[0]);
            close(uds_fd);
            return 1;
        }

        if (send_child_started(uds_fd, child_pid) != 0) {
            kill_child(child_pid);
            close(stdin_pipe[1]);
            close(stdout_pipe[0]);
            close(stderr_pipe[0]);
            close(uds_fd);
            return 1;
        }

        shepherd_stdin_w = stdin_pipe[1];
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
    }

    /* Enter event loop. stdin_w is passed by pointer so a CMD_CLOSE_STDIN
     * handled inside the loop is visible here — otherwise the fd would be
     * closed a second time below, racing whatever recycled the number. */
    int result = event_loop(uds_fd, child_pid, &shepherd_stdin_w);

    /* Cleanup */
    if (shepherd_stdin_w >= 0) close(shepherd_stdin_w);
    close(uds_fd);

    return result >= 0 ? 0 : 1;
}
