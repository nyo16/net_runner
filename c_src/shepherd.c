/*
 * shepherd.c - Persistent child process shepherd for NetRunner
 *
 * Lifecycle:
 *   1. BEAM opens this binary via Port.open with :nouse_stdio
 *   2. Shepherd reads the handshake token from fd 3, connects to the BEAM's
 *      UDS listener (path passed as argv[1]) and echoes the token
 *   3. Shepherd forks the child. The child takes its own process group (pipe
 *      mode) or session (PTY mode), resets its signal state and parks on the
 *      exec gate
 *   4. Shepherd places the child in its cgroup (if requested), sends the
 *      child's FDs (plus a pidfd on Linux) via SCM_RIGHTS, sends
 *      MSG_CHILD_STARTED, and only then releases the gate: the command never
 *      runs before the BEAM holds its FDs
 *   5. Enters a poll() loop watching:
 *      - UDS for commands from BEAM (KILL, CLOSE_STDIN, SET_WINSIZE)
 *      - Signal pipe for SIGCHLD (child death) and termination signals
 *   6. On child death: sweep the child's process group, reap, clean up the
 *      cgroup, send MSG_CHILD_EXITED, exit
 *   7. On BEAM death (UDS hangup) or a termination signal: SIGTERM the
 *      group, wait up to kill_timeout, SIGKILL the group, reap, clean up
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

#ifdef __linux__
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif

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

/* Last termination signal (SIGTERM/INT/HUP/QUIT) received, 0 if none. The
 * byte the handler writes to the self-pipe only wakes poll(); this flag is
 * what the shepherd acts on. */
static volatile sig_atomic_t term_signal = 0;

/* How long the PTY parent waits for the child to report that it leads its
 * session, and how long any post-SIGKILL reap may take. */
#define CHILD_READY_TIMEOUT_MS 5000
#define REAP_TIMEOUT_MS 3000

/* ---- Post-fork helpers (async-signal-safe only) ---- */

static size_t bounded_strlen(const char *s, size_t cap) {
    size_t i = 0;
    while (i < cap && s[i] != '\0') i++;
    return i;
}

static void write_str(const char *s, size_t cap) {
    (void)!write(STDERR_FILENO, s, bounded_strlen(s, cap));
}

/* Fixed texts for the errnos an exec or child setup typically fails with:
 * strerror() is not async-signal-safe. They match glibc/musl/macOS wording,
 * so callers can match them regardless of platform. */
static const char *child_errno_text(int err) {
    switch (err) {
    case ENOENT:  return "No such file or directory";
    case EACCES:  return "Permission denied";
    case ENOEXEC: return "Exec format error";
    case ENOTDIR: return "Not a directory";
    case E2BIG:   return "Argument list too long";
    case ENOMEM:  return "Cannot allocate memory";
    case ELOOP:   return "Too many levels of symbolic links";
    case ETXTBSY: return "Text file busy";
    case EPERM:   return "Operation not permitted";
    case EINVAL:  return "Invalid argument";
    case EISDIR:  return "Is a directory";
    case EMFILE:  return "Too many open files";
    default:      return "error";
    }
}

/*
 * Async-signal-safe post-fork failure path. Between fork() and exec*(),
 * POSIX allows only async-signal-safe functions, so we cannot call
 * fprintf / strerror / malloc. This helper uses write(2) on a stack
 * buffer only. Writes "tag[: detail][: reason][ (errno N)]\n" and exits
 * with code. reason NULL and err != 0 uses the errno's fixed text.
 */
__attribute__((noreturn))
static void child_fail(const char *tag, const char *detail, const char *reason,
                       int err, int code) {
    write_str(tag, 64);
    if (detail) {
        (void)!write(STDERR_FILENO, ": ", 2);
        write_str(detail, 256);
    }
    if (reason == NULL && err != 0) reason = child_errno_text(err);
    if (reason) {
        (void)!write(STDERR_FILENO, ": ", 2);
        write_str(reason, 128);
    }
    if (err > 0) {
        char num[16];
        size_t pos = sizeof(num);
        num[--pos] = ')';
        unsigned int v = (unsigned int)err;
        do {
            num[--pos] = (char)('0' + v % 10);
            v /= 10;
        } while (v != 0 && pos > 0);
        (void)!write(STDERR_FILENO, " (errno ", 8);
        (void)!write(STDERR_FILENO, num + pos, sizeof(num) - pos);
    }
    (void)!write(STDERR_FILENO, "\n", 1);
    _exit(code);
}

/* Child side, right after fork(): if the shepherd dies (SIGKILL, OOM, crash)
 * before reaping us, have the kernel SIGKILL us instead of leaving an
 * unsupervised orphan that nothing will ever kill. The getppid() check closes
 * the window where the shepherd died between fork() and prctl(). The setting
 * survives execve (except into set-id binaries), so it covers the exec'd
 * command; it does not reach grandchildren, which the BEAM's process-group
 * kill and cgroup.kill cover. Two raw syscalls: async-signal-safe. Linux
 * only; elsewhere the BEAM's group kill is the only layer. */
static void die_with_shepherd(pid_t shepherd_pid) {
#ifdef __linux__
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != shepherd_pid) {
        _exit(127);
    }
#else
    (void)shepherd_pid;
#endif
}

/* libc refuses to touch its reserved real-time signals (glibc 32-33, musl
 * 32-34), yet an inherited SIG_IGN on them survives exec like any other.
 * Reset them with the raw syscall: an all-zero kernel sigaction is SIG_DFL
 * with no flags and an empty mask whatever the architecture's field order.
 * The kernel sigset is 8 bytes on most architectures, 16 on MIPS. */
static void reset_reserved_signal(int sig) {
#if defined(__linux__) && defined(SYS_rt_sigaction)
    unsigned long zero[8] = {0};
    if (syscall(SYS_rt_sigaction, sig, zero, NULL, (size_t)8) != 0 && errno == EINVAL)
        (void)syscall(SYS_rt_sigaction, sig, zero, NULL, (size_t)16);
#else
    (void)sig;
#endif
}

/* Give the child the signal state a shell would: every disposition back to
 * SIG_DFL (inherited SIG_IGNs such as erts' SIGFPE or nohup's SIGHUP survive
 * exec otherwise; our own handlers would run in the child until exec) and an
 * empty mask (the parent blocked everything across fork()). */
static void child_reset_signals(void) {
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    for (int s = 1; s < NSIG; s++) {
        if (s == SIGKILL || s == SIGSTOP) continue;
        if (sigaction(s, &dfl, NULL) != 0) reset_reserved_signal(s);
    }
    sigset_t none;
    sigemptyset(&none);
    (void)sigprocmask(SIG_SETMASK, &none, NULL);
}

/* exec, or fail with the shell's codes: 127 when the command was not found,
 * 126 when it was found but could not be executed. */
__attribute__((noreturn))
static void exec_child(char *cmd, char **args, int allow_execvp) {
    if (!allow_execvp) {
        child_fail("execvp", cmd,
                   "PATH is not set in the replacement environment", 0, 127);
    }
    execvp(cmd, args);
    int err = errno;
    child_fail("execvp", cmd, NULL, err, err == ENOENT ? 127 : 126);
}

extern char **environ;

static char **kept_environment_names = NULL;
static size_t kept_environment_name_count = 0;

static int keep_environment_entry(const char *entry) {
    const char *equals = strchr(entry, '=');
    if (equals == NULL) return 0;

    size_t name_len = (size_t)(equals - entry);
    for (size_t i = 0; i < kept_environment_name_count; i++) {
        const char *kept = kept_environment_names[i];
        if (strlen(kept) == name_len && memcmp(entry, kept, name_len) == 0) {
            return 1;
        }
    }
    return 0;
}

static void restrict_environment(void) {
    if (kept_environment_names == NULL) return;

    char **write = environ;
    for (char **read = environ; *read != NULL; read++) {
        if (keep_environment_entry(*read)) *write++ = *read;
    }
    *write = NULL;
}

/* Wake poll() — ignore failure in a signal handler (pipe full = already
 * awake). errno is preserved for the interrupted code. */
static void wake_event_loop(char byte) {
    int saved_errno = errno;
    if (write(signal_pipe[1], &byte, 1) < 0) { /* nothing to do */ }
    errno = saved_errno;
}

static void sigchld_handler(int sig) {
    (void)sig;
    wake_event_loop('C');
}

static void term_handler(int sig) {
    term_signal = sig;
    wake_event_loop('T');
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

/* Create a CLOEXEC pipe (atomically where the platform allows). */
static int cloexec_pipe(int fds[2]) {
#ifdef __linux__
    return pipe2(fds, O_CLOEXEC);
#else
    if (pipe(fds) != 0) return -1;
    set_cloexec(fds[0]);
    set_cloexec(fds[1]);
    return 0;
#endif
}

/* Milliseconds on a monotonic clock, or -1 if the clock is unavailable. */
static int64_t monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Remaining milliseconds until deadline (from monotonic_ms() + budget, or
 * -1 when the clock is unavailable, in which case the full budget is
 * returned once and 0 afterwards via *spent). */
static int remaining_ms(int64_t deadline, int budget_ms, int *spent) {
    if (deadline < 0) {
        if (*spent) return 0;
        *spent = 1;
        return budget_ms;
    }
    int64_t now = monotonic_ms();
    if (now < 0 || now >= deadline) return 0;
    return (int)(deadline - now);
}

/* Bound on how long any single shepherd->BEAM frame may wait for socket
 * buffer space before being dropped. */
#define UDS_WRITE_TIMEOUT_MS 5000

/* Upper bound on waiting for the handshake token on fd 3; matches the BEAM's
 * accept deadline, after which the spawn is abandoned anyway. */
#define TOKEN_READ_TIMEOUT_MS 10000

/*
 * Absolute deadline for one bounded POLLOUT wait, initialised lazily so a
 * write that succeeds on the first attempt never reads the clock.
 *   at == -2  unset
 *   at == -1  monotonic clock unavailable; `polls` caps the wait instead
 *   at >=  0  monotonic_ms() value to stop at
 */
struct write_deadline {
    int64_t at;
    int polls;
};
#define WRITE_DEADLINE_INIT {-2, 0}

/* Without a clock each poll() is a full timeout_ms, so this caps the total
 * wait at NOCLOCK_MAX_POLLS * timeout_ms regardless of how often the peer
 * frees a byte or a signal interrupts us. */
#define NOCLOCK_MAX_POLLS 4

/*
 * Wait until fd is writable or the deadline passes. Returns 0 when
 * writable, -1 on timeout or error. Every EAGAIN/EINTR wakeup re-derives
 * the remaining budget from the same deadline, so a peer that frees one
 * byte per timeout cannot extend the wait indefinitely.
 */
static int wait_pollout(int fd, struct write_deadline *dl, int timeout_ms) {
    if (dl->at == -2) {
        int64_t now = monotonic_ms();
        dl->at = (now < 0) ? -1 : now + timeout_ms;
    }
    for (;;) {
        int wait_ms = timeout_ms;
        if (dl->at >= 0) {
            int64_t now = monotonic_ms();
            if (now < 0 || now >= dl->at) return -1;
            wait_ms = (int)(dl->at - now);
        } else if (dl->polls++ >= NOCLOCK_MAX_POLLS) {
            return -1;
        }
        struct pollfd pfd = {.fd = fd, .events = POLLOUT, .revents = 0};
        int pret = poll(&pfd, 1, wait_ms);
        if (pret > 0) return 0;
        if (pret < 0 && errno == EINTR) continue;
        return -1; /* timeout, or poll error */
    }
}

/*
 * Write all of buf to the non-blocking UDS, polling POLLOUT for up to
 * timeout_ms before giving up. Returns 0 on success, -1 on error/timeout.
 *
 * The UDS is deliberately non-blocking for writes: a BEAM that stops
 * draining the socket must not park the shepherd in write(2) forever.
 * On persistent EAGAIN we drop the frame instead: the peer is wedged or
 * gone, it will observe the UDS close when we exit, and a lost frame is
 * recoverable where a wedged shepherd is not.
 */
static int write_fully(int fd, const uint8_t *buf, size_t len,
                       int timeout_ms) {
    struct write_deadline dl = WRITE_DEADLINE_INIT;
    size_t written = 0;

    while (written < len) {
        ssize_t n = write(fd, buf + written, len - written);
        if (n > 0) {
            written += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            /* peer not draining within the deadline: drop the frame */
            if (wait_pollout(fd, &dl, timeout_ms) < 0) return -1;
            continue;
        }
        return -1;
    }
    return 0;
}

/*
 * Send file descriptors over UDS using SCM_RIGHTS: [stdin_w, stdout_r,
 * stderr_r] in pipe mode or [master] in PTY mode, each followed by the
 * child's pidfd when one could be opened (Linux).
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

    /* Retry on EINTR; wait (bounded by one shared deadline) for buffer
     * space on EAGAIN — the UDS is non-blocking. Anything else, or a
     * partial send, is an error. */
    struct write_deadline dl = WRITE_DEADLINE_INIT;
    for (;;) {
        ssize_t ret = sendmsg(uds_fd, &msg, 0);
        if (ret == 1) {
            free(cmsg_buf);
            return 0;
        }
        if (ret < 0 && errno == EINTR) continue;
        if (ret < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_pollout(uds_fd, &dl, UDS_WRITE_TIMEOUT_MS) == 0) continue;
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

/* status is always 0..255 (see encode_wait_status). */
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
#include <dirent.h>

/* Set only when this shepherd created the cgroup directory itself. A
 * pre-existing directory belongs to someone else: attach the child to it,
 * but never cgroup.kill it or rmdir it on teardown. Cleared once the
 * directory is removed, so cleanup is idempotent. */
static int cgroup_owned = 0;

#define CGROUP_ROOT "/sys/fs/cgroup/"

/* Create every ancestor of the leaf (the shared net_runner/ parent and any
 * intermediate components) on demand. EEXIST is success: concurrent spawns
 * into sibling leaves race on the same mkdir, and an ancestor created by an
 * admin or another shepherd is equally usable. Ancestors are shared, so
 * they are never cgroup.kill'ed or removed; adopting a pre-existing one does
 * not weaken the ownership guard, which stays on the leaf. 0755 so a
 * delegated user other than the creator can still traverse it. Failure gets
 * its own message so "no permission for cgroups at all" (EACCES on a
 * non-delegated root) is distinguishable from a leaf collision. */
static int cgroup_create_ancestors(char *full_path) {
    char *rel = full_path + strlen(CGROUP_ROOT);
    for (char *p = strchr(rel, '/'); p != NULL && p[1] != '\0';
         p = strchr(p + 1, '/')) {
        *p = '\0';
        int rc = mkdir(full_path, 0755);
        int err = errno;
        *p = '/';
        if (rc != 0 && err != EEXIST) {
            int rel_len = (int)(p - rel);
            ERROR_LOG("mkdir(%.*s) failed: %s", (int)(p - full_path), full_path,
                      strerror(err));
            snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                     "cgroup_setup: cannot create parent cgroup %.*s: %s",
                     rel_len > 160 ? 160 : rel_len, rel, strerror(err));
            return -1;
        }
    }
    return 0;
}

static int cgroup_setup(pid_t child_pid) {
    if (cgroup_path[0] == '\0') return 0;

    char full_path[512];
    char procs_path[576];

    int n = snprintf(full_path, sizeof(full_path), CGROUP_ROOT "%s",
                     cgroup_path);
    if (n < 0 || (size_t)n >= sizeof(full_path)) {
        ERROR_LOG("cgroup path too long");
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: path too long");
        return -1;
    }
    if (cgroup_create_ancestors(full_path) != 0) return -1;

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

    /* Teardown relies on cgroup.kill (Linux >= 5.14) to reach descendants
     * that left the child's process group (setsid/setpgid daemonisers).
     * Without it the only kill vector is kill(-pgid), so the containment
     * the caller asked for would be partial — fail closed instead. The
     * directory we just made is removed so a retry does not hit EEXIST. */
    char kill_path[576];
    n = snprintf(kill_path, sizeof(kill_path), "%s/cgroup.kill", full_path);
    if (n < 0 || (size_t)n >= sizeof(kill_path)) {
        ERROR_LOG("cgroup kill path too long");
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: kill path too long");
        return -1;
    }
    if (access(kill_path, W_OK) != 0) {
        int err = errno;
        ERROR_LOG("%s unavailable: %s", kill_path, strerror(err));
        snprintf(cgroup_errmsg, sizeof(cgroup_errmsg),
                 "cgroup_setup: cgroup.kill unavailable (%s); teardown could "
                 "not reach escaped descendants",
                 strerror(err));
        if (rmdir(full_path) == 0) cgroup_owned = 0;
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

/* Depth-first rmdir of path and every sub-cgroup below it (the child may
 * have created some). path is modified in place but restored; cap bounds
 * both the path and, with it, the recursion depth. cgroupfs has no
 * symlinks. Returns rmdir(path)'s result. */
static int cgroup_rmdir_tree(char *path, size_t cap) {
    DIR *d = opendir(path);
    if (d != NULL) {
        size_t len = strlen(path);
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (e->d_type != DT_DIR && e->d_type != DT_UNKNOWN) continue;
            if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
                continue;
            size_t name_len = strlen(e->d_name);
            if (len + 1 + name_len + 1 > cap) continue;
            path[len] = '/';
            memcpy(path + len + 1, e->d_name, name_len + 1);
            (void)cgroup_rmdir_tree(path, cap);
            path[len] = '\0';
        }
        closedir(d);
    }
    return rmdir(path);
}

static void cgroup_cleanup(void) {
    if (cgroup_path[0] == '\0' || !cgroup_owned) return;

    char full_path[512];
    char kill_path[576];

    int n = snprintf(full_path, sizeof(full_path), CGROUP_ROOT "%s",
                     cgroup_path);
    if (n < 0 || (size_t)n >= sizeof(full_path)) return;

    /* Kill all processes in the cgroup — recursively, sub-cgroups
     * included — via cgroup.kill (cgroup v2). cgroup_setup() verified the
     * file was writable, so a failure here is worth a log line: it means
     * descendants may outlive the teardown. */
    n = snprintf(kill_path, sizeof(kill_path), "%s/cgroup.kill", full_path);
    if (n < 0 || (size_t)n >= sizeof(kill_path)) return;
    FILE *f = fopen(kill_path, "w");
    if (!f) {
        ERROR_LOG("cgroup_cleanup: open %s failed: %s", kill_path,
                  strerror(errno));
    } else if (fprintf(f, "1\n") < 0 || fclose(f) != 0) {
        ERROR_LOG("cgroup_cleanup: write to %s failed: %s", kill_path,
                  strerror(errno));
    }

    /* Poll for removal rather than a fixed sleep — the kernel needs a
     * moment to reap the killed processes. Bail after ~1s (10 * 100ms). */
    int err = 0;
    for (int i = 0; i < 10; i++) {
        if (cgroup_rmdir_tree(full_path, sizeof(full_path)) == 0 ||
            errno == ENOENT) {
            cgroup_owned = 0;
            return;
        }
        err = errno;
        if (err != EBUSY && err != ENOTEMPTY) break; /* real error */
        usleep(100000);
    }
    ERROR_LOG("cgroup_cleanup: %s not removed: %s", full_path, strerror(err));
}
#else
static int cgroup_setup(pid_t child_pid) {
    (void)child_pid;
    return 0;
}
static void cgroup_cleanup(void) {}
#endif

/* ---- Child exit observation and teardown ---- */

/* Drain the non-blocking self-pipe. EAGAIN when already empty is expected. */
static void drain_signal_pipe(void) {
    char drain[64];
    while (read(signal_pipe[0], drain, sizeof(drain)) > 0) {}
}

/* 1 if child_pid has exited, WITHOUT reaping it: the zombie keeps its pid
 * and process-group id pinned, so the group can still be signalled with no
 * pid-reuse risk. ECHILD (nothing to wait for) also counts as exited. */
static int child_has_exited(pid_t child_pid) {
    for (;;) {
        siginfo_t si;
        memset(&si, 0, sizeof(si));
        int r = waitid(P_PID, (id_t)child_pid, &si,
                       WEXITED | WNOHANG | WNOWAIT);
        /* si_code guard: macOS waitid() can report a *stopped* child even
         * with only WEXITED requested (golang/go#19314). */
        if (r == 0) {
            return si.si_pid == child_pid &&
                   (si.si_code == CLD_EXITED || si.si_code == CLD_KILLED ||
                    si.si_code == CLD_DUMPED);
        }
        if (errno == EINTR) continue;
        return errno == ECHILD;
    }
}

/*
 * Wait up to timeout_ms for child_pid to exit, without reaping it. Returns 1
 * if it exited, 0 on timeout.
 *
 * Blocks in poll() on the SIGCHLD self-pipe rather than sleeping in fixed
 * slices. The deadline comes from a monotonic clock so that EINTR and
 * wakeups for other signals cannot extend it; if the clock is unavailable
 * the loop collapses to a single bounded poll, which is still bounded.
 */
static int wait_for_exit(pid_t child_pid, int timeout_ms) {
    int64_t now = monotonic_ms();
    int64_t deadline = (now < 0) ? -1 : now + timeout_ms;
    int spent = 0;

    for (;;) {
        if (child_has_exited(child_pid)) return 1;
        int wait_ms = remaining_ms(deadline, timeout_ms, &spent);
        if (wait_ms <= 0) return 0;

        struct pollfd pfd = {.fd = signal_pipe[0], .events = POLLIN, .revents = 0};
        int pret = poll(&pfd, 1, wait_ms);
        if (pret < 0 && errno != EINTR) {
            /* poll is broken — give up rather than spin on it. */
            return child_has_exited(child_pid);
        }
        if (pret > 0 && (pfd.revents & POLLIN)) drain_signal_pipe();
    }
}

/* Map a waitpid status to the 0..255 value MSG_CHILD_EXITED carries:
 * exit code, 128 + signal, or EXIT_STATUS_UNKNOWN for anything else. */
static int encode_wait_status(int status) {
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return EXIT_STATUS_UNKNOWN;
}

/* Signal the child's process group, falling back to the child itself when
 * the group does not exist (yet). */
static void signal_group(pid_t child_pid, int sig) {
    if (kill(-child_pid, sig) != 0) (void)kill(child_pid, sig);
}

/* Reap child_pid after it was sent SIGKILL. Bounded — a child wedged in
 * uninterruptible kernel sleep (D-state) never exits, and we must not hang
 * the shepherd on it; the kernel completes the SIGKILL later, so that case
 * reports 128 + SIGKILL. */
static int reap_killed_child(pid_t child_pid) {
    (void)wait_for_exit(child_pid, REAP_TIMEOUT_MS);
    int status;
    pid_t r;
    do {
        r = waitpid(child_pid, &status, WNOHANG);
    } while (r < 0 && errno == EINTR);
    if (r == child_pid) return encode_wait_status(status);
    return 128 + SIGKILL;
}

/*
 * Teardown ladder: SIGTERM the group, wait up to kill_timeout for the leader
 * to exit (without reaping), then ALWAYS SIGKILL the group — members that
 * ignore SIGTERM must not outlive a leader that obeyed it — reap, and clean
 * up the cgroup. Returns the leader's status for MSG_CHILD_EXITED.
 */
static int kill_child(pid_t child_pid) {
    int status = EXIT_STATUS_UNKNOWN;
    if (child_pid > 0) {
        signal_group(child_pid, SIGTERM);
        (void)wait_for_exit(child_pid, kill_timeout_ms);
        signal_group(child_pid, SIGKILL);
        status = reap_killed_child(child_pid);
    }
    cgroup_cleanup();
    return status;
}

/* ---- BEAM commands ---- */

/*
 * Length of a single framed command given its opcode. Returns 0 if the
 * opcode is unknown.
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
 * Handle a single, complete command frame.
 */
static void handle_command(pid_t child_pid, int *stdin_w, const uint8_t *buf) {
    switch (buf[0]) {
    case CMD_KILL: {
        int sig = buf[1];
        /* Validate signal is in POSIX range */
        if (child_pid > 0 && sig >= 1 && sig <= 31) signal_group(child_pid, sig);
        break;
    }

    case CMD_CLOSE_STDIN:
        if (*stdin_w >= 0) {
            close(*stdin_w);
            *stdin_w = -1;
        }
        break;

    case CMD_SET_WINSIZE:
        if (pty_master_fd >= 0) {
            struct winsize ws;
            memset(&ws, 0, sizeof(ws));
            ws.ws_row = (unsigned short)((buf[1] << 8) | buf[2]);
            ws.ws_col = (unsigned short)((buf[3] << 8) | buf[4]);
            ioctl(pty_master_fd, TIOCSWINSZ, &ws);
        }
        break;

    default:
        break;
    }
}

/*
 * Parse and dispatch all framed commands present in buf. Returns the number
 * of bytes consumed (may be less than len if a tail command is truncated).
 *
 * An unknown opcode is a protocol error: from then on ALL input is
 * discarded (sticky, across reads) rather than resynchronised, which could
 * execute payload bytes of a frame from a newer protocol (e.g. 0x01 0x09) as
 * commands, also when that frame is split across reads. Logged once so a
 * misbehaving peer cannot flood the node's stderr. BEAM death (POLLHUP) is
 * still detected and still tears down.
 */
static size_t handle_commands(pid_t child_pid, int *stdin_w,
                              const uint8_t *buf, size_t len) {
    static int protocol_error = 0;
    size_t off = 0;
    if (protocol_error) return len;
    while (off < len) {
        size_t clen = command_length(buf[off]);
        if (clen == 0) {
            protocol_error = 1;
            ERROR_LOG("unknown command opcode 0x%02x; ignoring all further commands",
                      buf[off]);
            return len;
        }
        if (off + clen > len) {
            /* Partial tail — caller must carry this over to the next read. */
            break;
        }
        handle_command(child_pid, stdin_w, &buf[off]);
        off += clen;
    }
    return off;
}

/* Carry-over buffer for partially-framed commands across reads. Max
 * incoming frame is CMD_SET_WINSIZE (5 bytes); keep a little slack. */
struct command_buffer {
    uint8_t data[64];
    size_t used;
};

/*
 * Read and dispatch BEAM commands. With hangup set (POLLHUP/POLLERR), keep
 * reading until EOF so commands the BEAM queued before closing — typically
 * CMD_KILL SIGKILL — are honoured before the teardown ladder runs. Returns
 * 1 while the BEAM is connected, 0 once it is gone.
 */
static int read_commands(int uds_fd, pid_t child_pid, int *stdin_w,
                         struct command_buffer *cb, int hangup) {
    for (;;) {
        ssize_t n = read(uds_fd, cb->data + cb->used, sizeof(cb->data) - cb->used);
        if (n > 0) {
            cb->used += (size_t)n;
            size_t consumed = handle_commands(child_pid, stdin_w, cb->data,
                                              cb->used);
            if (consumed > 0 && consumed < cb->used) {
                memmove(cb->data, cb->data + consumed, cb->used - consumed);
            }
            cb->used -= consumed;
            if (!hangup) return 1;
            continue;
        }
        if (n == 0) return 0; /* BEAM closed the socket */
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return !hangup;
        if (!hangup) ERROR_LOG("read(uds) failed: %s", strerror(errno));
        return 0;
    }
}

/* The leader exited on its own: sweep what is left of its process group
 * while the unreaped zombie still pins the pgid, reap it, remove the
 * cgroup, and only then report — so a caller that respawns on the exit
 * frame never collides with our leftover cgroup. */
static int finish_child_exit(int uds_fd, pid_t child_pid) {
    (void)kill(-child_pid, SIGKILL);
    int status = reap_killed_child(child_pid);
    cgroup_cleanup();
    send_child_exited(uds_fd, status);
    return 0;
}

/* The BEAM is gone, or the shepherd was asked to terminate: run the ladder
 * and report the real status when the socket can still carry it. */
static int teardown(int uds_fd, pid_t child_pid, int report) {
    int status = kill_child(child_pid);
    if (report) send_child_exited(uds_fd, status);
    return -1;
}

/*
 * Main event loop using poll().
 *
 * Watches:
 *   - UDS socket for BEAM commands and hangup (BEAM death)
 *   - Signal pipe for SIGCHLD (child death) and termination signals
 *
 * Returns 0 after a normal child exit, -1 after a teardown.
 */
static int event_loop(int uds_fd, pid_t child_pid, int *stdin_w) {
    struct pollfd fds[2];
    struct command_buffer cb;
    cb.used = 0;

    fds[0].fd = uds_fd;
    fds[0].events = POLLIN;
    fds[1].fd = signal_pipe[0];
    fds[1].events = POLLIN;

    for (;;) {
        int ret = poll(fds, 2, -1);
        if (ret < 0) {
            if (errno == EINTR) continue;
            ERROR_LOG("poll failed: %s", strerror(errno));
            return teardown(uds_fd, child_pid, 1);
        }

        if (fds[1].revents & POLLIN) {
            drain_signal_pipe();
            if (child_has_exited(child_pid))
                return finish_child_exit(uds_fd, child_pid);
            if (term_signal != 0) {
                DEBUG_LOG("signal %d, killing child %d", (int)term_signal,
                          child_pid);
                return teardown(uds_fd, child_pid, 1);
            }
        }

        short ur = fds[0].revents;
        if (ur & POLLNVAL) {
            ERROR_LOG("UDS fd invalid (POLLNVAL), killing child %d", child_pid);
            return teardown(uds_fd, child_pid, 0);
        }
        if (ur & (POLLIN | POLLHUP | POLLERR)) {
            int hangup = (ur & (POLLHUP | POLLERR)) != 0;
            if (!read_commands(uds_fd, child_pid, stdin_w, &cb, hangup)) {
                DEBUG_LOG("BEAM connection lost, killing child %d", child_pid);
                return teardown(uds_fd, child_pid, 1);
            }
        }
    }
}

/* ---- Startup ---- */

/* Parsed command line. Option globals (kill_timeout_ms, pty_mode,
 * cgroup_path, kept_environment_names) are still written by parse_args. */
struct options {
    const char *uds_path;
    const char *child_cwd;
    int token_from_fd;
    int no_new_privs;
    char **cmd_args; /* cmd + args, NULL-terminated by the OS */
};

/*
 * Usage: shepherd <uds_path> [--kill-timeout <ms>] [--token-fd] [--pty] [--cgroup-path <rel>] [--cwd <dir>] [--replace-env <count> <names...>] [--no-new-privs] [--] <cmd> [args...]
 *
 *   uds_path:       Absolute path to the UDS listener socket created by the BEAM
 *   --kill-timeout:  SIGTERM->SIGKILL escalation timeout in ms (default 5000)
 *   --token-fd:     read the 32-char hex handshake token from fd 3 (the
 *                   BEAM port channel) and send it verbatim as the first
 *                   frame after connect so the BEAM can authenticate us
 *   --cwd:          Directory to run the child in (default: inherited)
 *   --replace-env:  Count followed by the environment names the child keeps
 *   --no-new-privs: set PR_SET_NO_NEW_PRIVS in the child before exec (Linux;
 *                   accepted and ignored elsewhere)
 *   cmd:            Command to execute
 *   args:           Arguments for the command
 *
 * Returns 0 on success, -1 after printing the reason.
 */
static int parse_args(int argc, char *argv[], struct options *opts) {
    if (argc < 3) {
        fprintf(stderr,
                "usage: shepherd <uds_path> [--kill-timeout <ms>] [--token-fd] [--pty] "
                "[--cgroup-path <rel>] [--cwd <dir>] [--replace-env <count> <names...>] "
                "[--no-new-privs] [--] <cmd> [args...]\n");
        return -1;
    }

    memset(opts, 0, sizeof(*opts));
    opts->uds_path = argv[1];
    /* An empty path would connect to the Linux abstract socket namespace
     * (sun_path[0] == '\0'), which has no directory permissions at all; a
     * relative one would resolve against whatever cwd we inherited. */
    if (opts->uds_path[0] != '/') {
        fprintf(stderr, "error: uds_path must be an absolute path\n");
        return -1;
    }
    int cmd_idx = 2;

    while (cmd_idx < argc && argv[cmd_idx][0] == '-') {
        if (strcmp(argv[cmd_idx], "--kill-timeout") == 0 && cmd_idx + 1 < argc) {
            char *endptr;
            long val = strtol(argv[cmd_idx + 1], &endptr, 10);
            if (*endptr != '\0' || endptr == argv[cmd_idx + 1] || val <= 0 || val > 60000) {
                fprintf(stderr, "error: --kill-timeout must be 1-60000 ms\n");
                return -1;
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
            opts->token_from_fd = 1;
            cmd_idx += 1;
        } else if (strcmp(argv[cmd_idx], "--no-new-privs") == 0) {
            opts->no_new_privs = 1;
            cmd_idx += 1;
        } else if (strcmp(argv[cmd_idx], "--cwd") == 0 && cmd_idx + 1 < argc) {
            if (argv[cmd_idx + 1][0] == '\0') {
                fprintf(stderr, "error: --cwd must not be empty\n");
                return -1;
            }
            opts->child_cwd = argv[cmd_idx + 1];
            cmd_idx += 2;
        } else if (strcmp(argv[cmd_idx], "--replace-env") == 0 && cmd_idx + 1 < argc) {
            char *endptr;
            long count = strtol(argv[cmd_idx + 1], &endptr, 10);
            long available = (long)argc - cmd_idx - 3;
            if (*endptr != '\0' || endptr == argv[cmd_idx + 1] ||
                count < 0 || count > available) {
                fprintf(stderr, "error: invalid --replace-env count\n");
                return -1;
            }
            kept_environment_names = &argv[cmd_idx + 2];
            kept_environment_name_count = (size_t)count;
            cmd_idx += 2 + (int)count;
        } else if (strcmp(argv[cmd_idx], "--cgroup-path") == 0 && cmd_idx + 1 < argc) {
            const char *path = argv[cmd_idx + 1];
            /* Reject path traversal: no ".." components, no leading "/".
             * Reject an empty path too: cgroup_path[0] == '\0' means "no
             * cgroup", so it would silently disable requested isolation. */
            if (path[0] == '\0' || path[0] == '/' || strstr(path, "..") != NULL) {
                fprintf(stderr, "error: invalid cgroup path (must be non-empty, relative, no '..')\n");
                return -1;
            }
            /* Reject rather than silently truncate: a truncated path would
             * attach the child to (and later kill) a different cgroup than
             * the one the caller validated. */
            if (strlen(path) >= CGROUP_PATH_MAX) {
                fprintf(stderr, "error: cgroup path too long (max %d bytes)\n",
                        CGROUP_PATH_MAX - 1);
                return -1;
            }
            memcpy(cgroup_path, path, strlen(path) + 1);
            cmd_idx += 2;
        } else if (strcmp(argv[cmd_idx], "--") == 0) {
            /* End of shepherd options. The BEAM always emits this so a
             * command whose name starts with '-' can never be parsed as a
             * shepherd flag (which would let a caller re-target
             * --cgroup-path or stretch --kill-timeout behind the API). */
            cmd_idx += 1;
            break;
        } else {
            break; /* Unknown flag — treat as command */
        }
    }

    if (cmd_idx >= argc) {
        fprintf(stderr, "error: no command specified\n");
        return -1;
    }
    opts->cmd_args = &argv[cmd_idx];
    return 0;
}

/* Make sure fds 0-2 are open (on /dev/null if they were closed), so nothing
 * the shepherd opens — the UDS above all — can land on them and receive
 * ERROR_LOG/perror text meant for stderr. Runs before anything else. */
static void ensure_std_fds(void) {
    for (int fd = 0; fd <= STDERR_FILENO; fd++) {
        if (fcntl(fd, F_GETFD) != -1 || errno != EBADF) continue;
        /* Lower fds are open, so open() returns exactly fd. */
        if (open("/dev/null", O_RDWR) != fd) _exit(1);
    }
}

/* Read the handshake token from the BEAM before touching the UDS. The port
 * channel is private to the BEAM and this process. The BEAM unlinks the port
 * for this write, so a spawner killed before writing need not close fd 3:
 * bound the wait by the BEAM's own accept deadline instead of blocking
 * forever. Returns 0 on success, -1 after printing the reason. */
static int read_token(char *token) {
    size_t got = 0;
    int64_t deadline = monotonic_ms();
    if (deadline >= 0) deadline += TOKEN_READ_TIMEOUT_MS;
    while (got < TOKEN_HEX_LEN) {
        if (term_signal != 0) {
            fprintf(stderr, "error: terminated by signal %d\n", (int)term_signal);
            return -1;
        }
        int wait_ms = TOKEN_READ_TIMEOUT_MS;
        if (deadline >= 0) {
            int64_t now = monotonic_ms();
            wait_ms = (now < 0 || now >= deadline) ? 0 : (int)(deadline - now);
        }
        struct pollfd pfd = { .fd = 3, .events = POLLIN, .revents = 0 };
        int ready = poll(&pfd, 1, wait_ms);
        if (ready < 0) {
            if (errno == EINTR) continue;
            perror("token poll");
            return -1;
        }
        if (ready == 0) {
            fprintf(stderr, "error: timed out waiting for token\n");
            return -1;
        }
        ssize_t n = read(3, token + got, TOKEN_HEX_LEN - got);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("token read");
            return -1;
        }
        if (n == 0) {
            fprintf(stderr, "error: BEAM closed before sending token\n");
            return -1;
        }
        got += (size_t)n;
    }
    return 0;
}

/* Overwrite a secret; volatile so the stores cannot be elided. */
static void wipe(char *buf, size_t len) {
    volatile char *p = buf;
    while (len-- > 0) *p++ = 0;
}

static int install_handler(int sig, void (*handler)(int), int flags) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handler;
    sa.sa_flags = flags;
    sigemptyset(&sa.sa_mask);
    return sigaction(sig, &sa, NULL);
}

/* Self-pipe, SIGCHLD and termination handlers, SIGPIPE ignored. Returns 0
 * or -1 after printing the reason. */
static int install_signal_handlers(void) {
    if (cloexec_pipe(signal_pipe) != 0) {
        perror("pipe");
        return -1;
    }
    set_nonblocking(signal_pipe[0]);
    set_nonblocking(signal_pipe[1]);

    /* A launcher that blocked SIGCHLD would leave the event loop deaf to
     * the child's exit. */
    sigset_t chld;
    sigemptyset(&chld);
    sigaddset(&chld, SIGCHLD);
    (void)sigprocmask(SIG_UNBLOCK, &chld, NULL);

    if (install_handler(SIGCHLD, sigchld_handler, SA_RESTART | SA_NOCLDSTOP) != 0) {
        perror("sigaction");
        return -1;
    }

    /* Ignore SIGPIPE: a write to a BEAM that has already gone away must fail
     * with EPIPE — every write loop here checks for a negative return — rather
     * than killing the shepherd outright and orphaning the child. */
    if (install_handler(SIGPIPE, SIG_IGN, 0) != 0) {
        perror("sigaction(SIGPIPE)");
        return -1;
    }

    /* Polite termination (systemd stop, pkill, a debugger's ^C) runs the
     * same ladder and cgroup cleanup as BEAM death instead of the default
     * action, which would leave both undone. SIGINT/SIGHUP/SIGQUIT that the
     * launcher ignored (nohup, erl +Bi) stay ignored. */
    static const int term_signals[] = {SIGTERM, SIGINT, SIGHUP, SIGQUIT};
    for (size_t i = 0; i < sizeof(term_signals) / sizeof(term_signals[0]); i++) {
        int sig = term_signals[i];
        struct sigaction old;
        if (sig != SIGTERM && sigaction(sig, NULL, &old) == 0 &&
            old.sa_handler == SIG_IGN)
            continue;
        if (install_handler(sig, term_handler, SA_RESTART) != 0) {
            perror("sigaction(term)");
            return -1;
        }
    }
    return 0;
}

/* Connect to the BEAM's UDS listener, make it CLOEXEC + non-blocking and
 * send the token as the first frame. Returns the fd or -1. */
static int connect_and_authenticate(const struct options *opts,
                                    const char *token) {
    int uds_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (uds_fd < 0) {
        perror("socket");
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(opts->uds_path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "error: uds_path too long (max %zu bytes)\n",
                sizeof(addr.sun_path) - 1);
        close(uds_fd);
        return -1;
    }
    strncpy(addr.sun_path, opts->uds_path, sizeof(addr.sun_path) - 1);

    if (connect(uds_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("connect");
        close(uds_fd);
        return -1;
    }

    set_cloexec(uds_fd);

    /* Writes to the UDS are non-blocking + bounded (see write_fully). The
     * event-loop reads already tolerate EAGAIN. */
    if (set_nonblocking(uds_fd) != 0) {
        perror("fcntl(uds, O_NONBLOCK)");
        close(uds_fd);
        return -1;
    }

    /* Authenticate: the BEAM handed us a per-spawn random token over fd 3
     * and accepts FDs only from the peer that echoes it back as the very
     * first frame. Without this, any same-uid process that wins the accept
     * race would receive the child's pipe FDs via SCM_RIGHTS. */
    if (opts->token_from_fd &&
        write_fully(uds_fd, (const uint8_t *)token, TOKEN_HEX_LEN,
                    UDS_WRITE_TIMEOUT_MS) != 0) {
        fprintf(stderr, "error: token write failed\n");
        close(uds_fd);
        return -1;
    }
    return uds_fd;
}

/* chdir, environment filter and the execvp policy. Runs after the token
 * write so the token remains the first frame, and before fork so a failure
 * can use MSG_ERROR. Returns allow_execvp (0/1), or -1 after MSG_ERROR. */
static int apply_launch_context(int uds_fd, const struct options *opts) {
    if (opts->child_cwd != NULL && chdir(opts->child_cwd) != 0) {
        char msg[128];
        snprintf(msg, sizeof(msg), "chdir failed: %s", strerror(errno));
        send_error(uds_fd, msg);
        return -1;
    }

    restrict_environment();

    /* A missing PATH normally enables an execvp default. Replacement mode must not. */
    return kept_environment_names == NULL ||
           strchr(opts->cmd_args[0], '/') != NULL || getenv("PATH") != NULL;
}

/* ---- Spawn ---- */

/* Everything the post-fork child needs, prepared by the parent. */
struct child_plan {
    pid_t shepherd_pid;
    int uds_fd;
    int gate[2];         /* exec gate: child reads [0], parent writes 'G' to [1] */
    int ready[2];        /* PTY only: child writes 'R' to [1] once it leads its session */
    int parent_ends[3];  /* shepherd-side fds to close in the child (-1 = none) */
    int stdio[3];        /* fds dup2'ed onto 0/1/2 */
    int pty;             /* stdio[0] is a PTY slave: setsid + TIOCSCTTY */
    int no_new_privs;
    char **cmd_args;
    int allow_execvp;
};

/* Async-signal-safe gate wait. The child must not exec — or fork
 * grandchildren — before the shepherd has placed it in its cgroup and
 * handed its FDs to the BEAM (cgroup.procs migration moves only the
 * written pid, and a command that ran before the hand-off failed would
 * have side effects the caller is told never happened). EOF or a non-'G'
 * byte means the shepherd gave up: die without exec. */
static void child_wait_gate(int gate_fd) {
    char go = 0;
    ssize_t r;
    do {
        r = read(gate_fd, &go, 1);
    } while (r < 0 && errno == EINTR);
    close(gate_fd);
    if (r != 1 || go != 'G') _exit(127);
}

/* Become the leader of our own process group (pipe mode) or session (PTY
 * mode), so kill(-pid) reaches us and every descendant that stays in it.
 * PTY mode then tells the parent it may report the pid. */
static void child_take_group(const struct child_plan *p) {
    if (!p->pty) {
        (void)setpgid(0, 0); /* the parent does the same; either may win */
        return;
    }
    /* setsid() makes us session and group leader (pgid == pid); it is
     * required before acquiring the controlling tty. */
    if (setsid() == (pid_t)-1) child_fail("setsid", NULL, NULL, errno, 127);
    if (ioctl(p->stdio[0], TIOCSCTTY, 0) != 0)
        child_fail("TIOCSCTTY", NULL, NULL, errno, 127);
    char r = 'R';
    ssize_t w;
    do {
        w = write(p->ready[1], &r, 1);
    } while (w < 0 && errno == EINTR);
    close(p->ready[1]);
}

/* Close every fd above stderr (Linux 5.9+; ENOSYS on older kernels is
 * ignored). Everything the shepherd opens is CLOEXEC already; this also
 * covers fds the shepherd's launcher leaked to it. macOS has no cheap
 * equivalent (a close loop up to RLIMIT_NOFILE can cost ~100 ms). */
static void child_close_extra_fds(void) {
#if defined(__linux__) && defined(SYS_close_range)
    (void)syscall(SYS_close_range, 3U, ~0U, 0U);
#endif
}

/* Post-fork child path, shared by pipe and PTY mode. Only async-signal-safe
 * calls until exec. Never returns. */
__attribute__((noreturn))
static void child_prepare(const struct child_plan *p) {
    die_with_shepherd(p->shepherd_pid);
    close(p->uds_fd);
    close(signal_pipe[0]);
    close(signal_pipe[1]);
    close(p->gate[1]);
    if (p->ready[0] >= 0) close(p->ready[0]);
    for (int i = 0; i < 3; i++) {
        if (p->parent_ends[i] >= 0) close(p->parent_ends[i]);
    }

    child_take_group(p);
    child_reset_signals();
    child_wait_gate(p->gate[0]);

    if (dup2(p->stdio[0], STDIN_FILENO)  != STDIN_FILENO ||
        dup2(p->stdio[1], STDOUT_FILENO) != STDOUT_FILENO ||
        dup2(p->stdio[2], STDERR_FILENO) != STDERR_FILENO) {
        child_fail("dup2", NULL, NULL, errno, 127);
    }

#ifdef __linux__
    if (p->no_new_privs && prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
        child_fail("prctl(PR_SET_NO_NEW_PRIVS)", NULL, NULL, errno, 127);
#endif

    child_close_extra_fds();
    for (int i = 0; i < 3; i++) {
        /* PTY passes one slave fd for all three; closing it once is enough
         * and EBADF on the repeats is harmless. */
        if (p->stdio[i] > STDERR_FILENO) close(p->stdio[i]);
    }

    exec_child(p->cmd_args[0], p->cmd_args, p->allow_execvp);
}

/* Shepherd-side state of one spawn, for the shared failure path. */
struct spawn_state {
    int uds_fd;
    pid_t child_pid;
    int gate_w;   /* write end of the exec gate, -1 once released */
    int started;  /* MSG_CHILD_STARTED was sent */
};

/*
 * The single post-connect spawn failure path. Closing the gate makes a
 * parked child _exit(127) without exec; SIGKILL covers a child that is not
 * parked yet. Reap, remove the cgroup, then report: msg as MSG_ERROR (NULL
 * = nothing to say), plus MSG_CHILD_EXITED with the reaped status if the
 * BEAM was already told the child started. Process exit closes every other
 * fd.
 */
__attribute__((noreturn))
static void fail_spawn(const struct spawn_state *s, const char *msg) {
    if (s->gate_w >= 0) close(s->gate_w);
    int status = EXIT_STATUS_UNKNOWN;
    if (s->child_pid > 0) {
        signal_group(s->child_pid, SIGKILL);
        status = reap_killed_child(s->child_pid);
    }
    cgroup_cleanup();
    if (msg != NULL) send_error(s->uds_fd, msg);
    if (s->started) send_child_exited(s->uds_fd, status);
    exit(1);
}

/* Abort the spawn if a termination signal arrived meanwhile. */
static void check_terminated(const struct spawn_state *s) {
    if (term_signal == 0) return;
    char msg[64];
    snprintf(msg, sizeof(msg), "shepherd terminated by signal %d",
             (int)term_signal);
    fail_spawn(s, msg);
}

/* A pidfd for the child (Linux 5.3+), or -1. Opened while the child is
 * parked and unreaped, so it can only ever refer to this process. */
static int open_pidfd(pid_t pid) {
#if defined(__linux__) && defined(SYS_pidfd_open)
    long fd = syscall(SYS_pidfd_open, pid, 0);
    return fd >= 0 ? (int)fd : -1;
#else
    (void)pid;
    return -1;
#endif
}

/* PTY mode: wait (bounded) for the child's 'R', i.e. for it to lead its own
 * session, so MSG_CHILD_STARTED is never sent for a pid whose group does not
 * exist yet. Returns 0 on 'R', -1 on EOF (the child died; it already wrote
 * the reason to stderr), timeout or error. */
static int wait_child_ready(int ready_fd) {
    int64_t now = monotonic_ms();
    int64_t deadline = (now < 0) ? -1 : now + CHILD_READY_TIMEOUT_MS;
    int spent = 0;
    for (;;) {
        int wait_ms = remaining_ms(deadline, CHILD_READY_TIMEOUT_MS, &spent);
        if (wait_ms <= 0) return -1;
        struct pollfd pfd = {.fd = ready_fd, .events = POLLIN, .revents = 0};
        int pret = poll(&pfd, 1, wait_ms);
        if (pret < 0 && errno == EINTR) continue;
        if (pret <= 0) return -1;
        char r = 0;
        ssize_t n;
        do {
            n = read(ready_fd, &r, 1);
        } while (n < 0 && errno == EINTR);
        return (n == 1 && r == 'R') ? 0 : -1;
    }
}

/*
 * Fork the child described by plan. On return the child leads its own
 * process group (pipe: setpgid from both sides; PTY: confirmed via the
 * ready pipe) and is parked on the exec gate. Returns the child's pidfd or
 * -1.
 */
static int fork_child(struct spawn_state *s, struct child_plan *plan) {
    check_terminated(s);

    int gate[2], ready[2] = {-1, -1};
    if (cloexec_pipe(gate) != 0) fail_spawn(s, "failed to create sync pipe");
    if (plan->pty && cloexec_pipe(ready) != 0)
        fail_spawn(s, "failed to create sync pipe");
    memcpy(plan->gate, gate, sizeof(gate));
    memcpy(plan->ready, ready, sizeof(ready));
    plan->shepherd_pid = getpid();

    /* Block every signal across fork(): the child must not run the
     * shepherd's handlers (they write to the shared self-pipe) before
     * child_reset_signals() restores the defaults. */
    sigset_t all, old;
    sigfillset(&all);
    sigprocmask(SIG_BLOCK, &all, &old);
    pid_t pid = fork();
    if (pid == 0) child_prepare(plan);
    int fork_errno = errno;
    sigprocmask(SIG_SETMASK, &old, NULL);

    close(gate[0]);
    s->gate_w = gate[1];
    if (ready[1] >= 0) close(ready[1]);
    if (pid < 0) {
        char msg[96];
        snprintf(msg, sizeof(msg), "fork failed: %s", strerror(fork_errno));
        fail_spawn(s, msg);
    }
    s->child_pid = pid;

    int pidfd = open_pidfd(pid);

    if (plan->pty) {
        int rc = wait_child_ready(ready[0]);
        close(ready[0]);
        if (rc != 0) fail_spawn(s, "child failed to set up its terminal session");
    } else {
        /* Classic double setpgid: whichever side runs first creates the
         * group. EACCES (child already exec'd) cannot happen while it is
         * parked; ESRCH means it died, which the event loop reports. */
        (void)setpgid(pid, pid);
    }
    return pidfd;
}

/*
 * Hand the parked child over: cgroup placement, FDs (+ pidfd), then
 * MSG_CHILD_STARTED, then the 'G' that lets it exec. A failure at any step
 * kills the child before it ever ran the command.
 */
static void hand_off(struct spawn_state *s, int *fds, int nfds, int pidfd) {
    if (cgroup_setup(s->child_pid) != 0) fail_spawn(s, cgroup_errmsg);

    if (pidfd >= 0) fds[nfds++] = pidfd;
    if (send_fds(s->uds_fd, fds, nfds) != 0) fail_spawn(s, "failed to send FDs");
    if (pidfd >= 0) close(pidfd);

    if (send_child_started(s->uds_fd, s->child_pid) != 0) fail_spawn(s, NULL);
    s->started = 1;

    check_terminated(s);
    char go = 'G';
    ssize_t w;
    do {
        w = write(s->gate_w, &go, 1);
    } while (w < 0 && errno == EINTR);
    if (w != 1) fail_spawn(s, "sync pipe write failed");
    close(s->gate_w);
    s->gate_w = -1;
}

/* PTY mode: a single bidirectional master FD. Returns the child pid; the
 * shepherd keeps no stdin_w. */
static pid_t spawn_pty(int uds_fd, const struct options *opts,
                       int allow_execvp) {
    struct spawn_state s = {uds_fd, 0, -1, 0};
    int master_fd, slave_fd;
    if (openpty(&master_fd, &slave_fd, NULL, NULL, NULL) != 0)
        fail_spawn(&s, "openpty failed");
    set_cloexec(master_fd);
    set_cloexec(slave_fd);

    struct child_plan plan = {
        .uds_fd = uds_fd,
        .parent_ends = {master_fd, -1, -1},
        .stdio = {slave_fd, slave_fd, slave_fd},
        .pty = 1,
        .no_new_privs = opts->no_new_privs,
        .cmd_args = opts->cmd_args,
        .allow_execvp = allow_execvp,
    };
    int pidfd = fork_child(&s, &plan);

    close(slave_fd);
    pty_master_fd = master_fd;

    /* The master FD is used by the BEAM for both read and write. */
    int fds_to_send[2] = {master_fd, -1};
    hand_off(&s, fds_to_send, 1, pidfd);
    return s.child_pid;
}

/* Pipe mode (default). Returns the child pid and the shepherd's stdin
 * write end in *stdin_w. */
static pid_t spawn_pipe(int uds_fd, const struct options *opts,
                        int allow_execvp, int *stdin_w) {
    struct spawn_state s = {uds_fd, 0, -1, 0};
    int stdin_pipe[2], stdout_pipe[2], stderr_pipe[2];
    if (cloexec_pipe(stdin_pipe) != 0 || cloexec_pipe(stdout_pipe) != 0 ||
        cloexec_pipe(stderr_pipe) != 0)
        fail_spawn(&s, "failed to create pipes");

#ifdef __linux__
    /* Grow the pipe buffers from the default 64 KiB. Each buffer-sized
     * chunk costs the BEAM a full read -> EAGAIN -> enif_select ->
     * message round trip, so bigger buffers cut round trips per MiB.
     *
     * Every page is charged to the uid's pipe-user-pages-soft budget
     * (16384 pages by default) for the pipe's lifetime, and once that
     * budget is spent the kernel caps EVERY new pipe the user creates at
     * two pages (8 KiB), not just ours. So: stdout, the bulk path, gets
     * 1 MiB (256 pages; read_batch can take up to 16 chunks per call);
     * stdin and stderr get 256 KiB (64 pages each). 384 pages per spawn
     * leaves room for ~42 concurrent commands, where 1 MiB on all three
     * (768 pages) ran out at ~21. Measured on Linux against 1 MiB
     * everywhere: 16 MiB through cat via run/2 within noise, stderr drain
     * about 22% slower; stdout-only growth cost 35-56% on those rows
     * (bench/LINUX_VERIFICATION.md). Best effort: the kernel caps sizes at
     * /proc/sys/fs/pipe-max-size and may refuse growth, in which case the
     * default stands. macOS has no equivalent knob. */
    (void)fcntl(stdout_pipe[0], F_SETPIPE_SZ, 1 << 20);
    (void)fcntl(stderr_pipe[0], F_SETPIPE_SZ, 1 << 18);
    (void)fcntl(stdin_pipe[1], F_SETPIPE_SZ, 1 << 18);
#endif

    struct child_plan plan = {
        .uds_fd = uds_fd,
        .parent_ends = {stdin_pipe[1], stdout_pipe[0], stderr_pipe[0]},
        .stdio = {stdin_pipe[0], stdout_pipe[1], stderr_pipe[1]},
        .pty = 0,
        .no_new_privs = opts->no_new_privs,
        .cmd_args = opts->cmd_args,
        .allow_execvp = allow_execvp,
    };
    int pidfd = fork_child(&s, &plan);

    close(stdin_pipe[0]);
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    int fds_to_send[4] = {stdin_pipe[1], stdout_pipe[0], stderr_pipe[0], -1};
    hand_off(&s, fds_to_send, 3, pidfd);

    close(stdout_pipe[0]);
    close(stderr_pipe[0]);
    *stdin_w = stdin_pipe[1];
    return s.child_pid;
}

int main(int argc, char *argv[]) {
    ensure_std_fds();
#ifdef __linux__
    /* Not dumpable: a same-uid child cannot ptrace us or read
     * /proc/<shepherd>/{environ,mem}, and no core lands in the child's cwd.
     * execve resets this for the child. */
    (void)prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
#endif

    struct options opts;
    if (parse_args(argc, argv, &opts) != 0) return 1;

    /* FDs 3/4 are the BEAM port's :nouse_stdio channel to this shepherd.
     * Mark them close-on-exec so the child cannot inherit a handle to the
     * BEAM. (The UDS and pipe fds get their own CLOEXEC.) */
    set_cloexec(3);
    set_cloexec(4);

    if (install_signal_handlers() != 0) return 1;

    char token[TOKEN_HEX_LEN + 1] = {0};
    if (opts.token_from_fd && read_token(token) != 0) return 1;

    int uds_fd = connect_and_authenticate(&opts, token);
    wipe(token, sizeof(token));
    if (uds_fd < 0) return 1;

    int allow_execvp = apply_launch_context(uds_fd, &opts);
    if (allow_execvp < 0) return 1;

    int stdin_w = -1;
    pid_t child_pid = (pty_mode == MODE_PTY)
                          ? spawn_pty(uds_fd, &opts, allow_execvp)
                          : spawn_pipe(uds_fd, &opts, allow_execvp, &stdin_w);

    /* Enter event loop. stdin_w is passed by pointer so a CMD_CLOSE_STDIN
     * handled inside the loop is visible here — otherwise the fd would be
     * closed a second time below, racing whatever recycled the number. */
    int result = event_loop(uds_fd, child_pid, &stdin_w);

    if (stdin_w >= 0) close(stdin_w);
    close(uds_fd);
    return result >= 0 ? 0 : 1;
}
