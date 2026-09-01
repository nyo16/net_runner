/*
 * net_runner_nif.c - NIF for async I/O on raw file descriptors
 *
 * Every function here runs on a NORMAL scheduler, deliberately. nif_create_fd
 * puts each fd in O_NONBLOCK and rejects anything that is not a pipe, socket
 * or character device (a PTY master), so every syscall in this file is
 * bounded: read/write cannot wait, and kill/dup/fcntl/close never could.
 * Readiness is delivered by enif_select through BEAM's own epoll/kqueue loop,
 * so there is nothing here to block on.
 *
 * Do NOT reintroduce ERL_NIF_DIRTY_JOB_IO_BOUND. A dirty-scheduler handoff
 * measured ~0.5-10 ms on a busy host (30 spinning scheduler threads on 10
 * cores must wait for an OS timeslice) against ~30 ns for a plain
 * normal-scheduler NIF call, and a streamed chunk pays two hops — one
 * nif_read returning data, one returning EAGAIN to re-arm enif_select. That
 * single flag cost ~280x of the achievable stdout throughput. Running on a
 * normal scheduler instead obliges nif_read/nif_write to declare the work
 * they did via enif_consume_timeslice.
 *
 * Resources:
 *   io_resource_t - wraps a raw FD with mutex protection, owner monitoring,
 *                   and proper cleanup via dtor/stop/down callbacks
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "erl_nif.h"
#include "protocol.h"
#include "utils.h"

/* ---- Resource type for file descriptors ---- */

typedef struct {
    int fd;
    int closed;
    ErlNifMutex *lock;
    ErlNifPid owner;
    ErlNifMonitor monitor;
    int monitor_active;
} io_resource_t;

static ErlNifResourceType *io_resource_type = NULL;

/* Resource callbacks */
static void io_resource_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    io_resource_t *res = (io_resource_t *)obj;
    /* Normal-path safety net: a resource dropped without nif_close still
     * releases its fd here. create_fd failure paths neutralise fd/closed
     * before release, so this never double-closes a caller-owned fd. */
    if (res->lock) {
        enif_mutex_lock(res->lock);
    }
    if (!res->closed && res->fd >= 0) {
        close(res->fd);
        res->fd = -1;
        res->closed = 1;
    }
    if (res->lock) {
        enif_mutex_unlock(res->lock);
        enif_mutex_destroy(res->lock);
        res->lock = NULL;
    }
}

static void io_resource_stop(ErlNifEnv *env, void *obj, ErlNifEvent event,
                             int is_direct_call) {
    (void)env;
    (void)is_direct_call;
    io_resource_t *res = (io_resource_t *)obj;
    /* BEAM guarantees no further use of this event by the NIF is in flight
     * when this callback runs. Mark the resource closed under the lock
     * before closing, so the dtor (or any late caller) can never observe a
     * still-open-looking fd and close it a second time. */
    if (res->lock) {
        enif_mutex_lock(res->lock);
        res->closed = 1;
        res->fd = -1;
        enif_mutex_unlock(res->lock);
    }
    if ((int)event >= 0) {
        close((int)event);
    }
}

static void io_resource_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                             ErlNifMonitor *mon) {
    (void)pid;
    (void)mon;
    io_resource_t *res = (io_resource_t *)obj;
    int fd_to_stop = -1;
    if (res->lock) {
        enif_mutex_lock(res->lock);
        if (!res->closed && res->fd >= 0) {
            fd_to_stop = res->fd;
            res->fd = -1;
            res->closed = 1;
        }
        res->monitor_active = 0;
        enif_mutex_unlock(res->lock);
    }
    if (fd_to_stop >= 0) {
        /* Hand fd off to the stop callback — it will close it after any
         * in-flight enif_select completes. */
        if (enif_select(env, (ErlNifEvent)fd_to_stop, ERL_NIF_SELECT_STOP,
                        obj, NULL, enif_make_atom(env, "undefined")) < 0) {
            /* No stop callback will run and there is no caller to report to,
             * so close directly rather than leak the fd for the lifetime of
             * the VM. */
            close(fd_to_stop);
        }
    }
}

static ErlNifResourceTypeInit io_resource_init = {
    .dtor = io_resource_dtor,
    .stop = io_resource_stop,
    .down = io_resource_down,
    .members = 3
};

/* ---- Atoms ---- */
static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_eagain;
static ERL_NIF_TERM atom_eof;
static ERL_NIF_TERM atom_undefined;
static ERL_NIF_TERM atom_true;
static ERL_NIF_TERM atom_false;

#define MAKE_ATOM(env, name) enif_make_atom(env, name)

/* Map errno to atom string (subset relevant to pipe I/O) */
static const char *errno_to_atom(int err) {
    switch (err) {
    case EAGAIN:     return "eagain";
    case EBADF:      return "ebadf";
    case EINVAL:     return "einval";
    case EIO:        return "eio";
    case ENOMEM:     return "enomem";
    case ENOSPC:     return "enospc";
    case EPERM:      return "eperm";
    case EPIPE:      return "epipe";
    case ESRCH:      return "esrch";
    case EACCES:     return "eacces";
    case ENOENT:     return "enoent";
    case EMFILE:     return "emfile";
    case ENFILE:     return "enfile";
    case EFAULT:     return "efault";
    case EINTR:      return "eintr";
    default:         return "unknown";
    }
}

/*
 * Charge the scheduler for a byte copy.
 *
 * nif_read/nif_write run on normal schedulers, so they must declare the work
 * they did or they distort the reduction budget of the calling process. Model:
 * ~1 MiB of copying counts as one full ~1 ms timeslice. That is deliberately
 * pessimistic (a 1 MiB copy measures ~30-60 us on an M1), which is the safe
 * direction — over-reporting only yields the scheduler sooner. Anything
 * smaller still pays the 1% floor, since enif_consume_timeslice rejects 0.
 */
static void consume_bytes_timeslice(ErlNifEnv *env, size_t n) {
    int pct = (int)((n * 100) / 1048576);
    if (pct < 1) pct = 1;
    if (pct > 100) pct = 100;
    (void)enif_consume_timeslice(env, pct);
}

/* ---- NIF Functions ---- */

/*
 * create_fd(fd_int, owner_pid) -> {:ok, resource} | {:error, reason}
 *
 * Wraps a raw FD integer into a NIF resource with owner monitoring.
 * Sets the FD to non-blocking mode.
 */
static ERL_NIF_TERM nif_create_fd(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 2);

    int fd;
    if (!enif_get_int(env, argv[0], &fd)) {
        return enif_make_badarg(env);
    }

    ErlNifPid owner;
    if (!enif_get_local_pid(env, argv[1], &owner)) {
        return enif_make_badarg(env);
    }

    /* Enforce the non-blocking precondition this whole NIF depends on rather
     * than trusting it: O_NONBLOCK is honoured by pipes, sockets and PTY
     * masters, but a regular file ignores it and read() on one WOULD block a
     * normal scheduler. */
    struct stat st;
    if (fstat(fd, &st) != 0) {
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "invalid_fd"));
    }
    if (!S_ISFIFO(st.st_mode) && !S_ISSOCK(st.st_mode) &&
        !S_ISCHR(st.st_mode)) {
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "unsupported_fd_type"));
    }

    /* Set non-blocking */
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) {
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "invalid_fd"));
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) {
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "fcntl_failed"));
    }

    io_resource_t *res = enif_alloc_resource(io_resource_type,
                                             sizeof(io_resource_t));
    if (!res) {
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "alloc_failed"));
    }

    res->fd = fd;
    res->closed = 0;
    res->lock = enif_mutex_create("io_resource");
    res->owner = owner;
    res->monitor_active = 0;

    if (!res->lock) {
        /* Mutex allocation failed. Contract: on ANY create_fd failure the
         * caller retains ownership of the fd and closes it via nif_close_fd
         * — so neutralise the resource before releasing it, or the dtor
         * would close here AND the caller would close again, racing a
         * recycled fd. */
        res->fd = -1;
        res->closed = 1;
        enif_release_resource(res);
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "mutex_failed"));
    }

    /* Monitor the owner process. This monitor is the only leak safety net the
     * resource has: a resource with a live enif_select relation is never
     * destructed, so without it a brutally-killed owner would leak the fd for
     * the lifetime of the VM. Refuse to hand out a resource we cannot clean
     * up. */
    if (enif_monitor_process(env, res, &owner, &res->monitor) != 0) {
        res->fd = -1; /* caller keeps ownership, see mutex_failed above */
        res->closed = 1;
        enif_release_resource(res);
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "monitor_failed"));
    }
    res->monitor_active = 1;

    ERL_NIF_TERM resource_term = enif_make_resource(env, res);
    enif_release_resource(res);

    return enif_make_tuple2(env, atom_ok, resource_term);
}

/*
 * nif_read(resource, max_bytes) -> {:ok, binary} | {:error, :eagain} | :eof
 *
 * Reads up to max_bytes from the FD. Returns :eagain if would block.
 * Caller should use enif_select for readiness notification on :eagain.
 */
static ERL_NIF_TERM nif_read(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 2);

    io_resource_t *res;
    if (!enif_get_resource(env, argv[0], io_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }

    unsigned int max_bytes;
    if (!enif_get_uint(env, argv[1], &max_bytes) || max_bytes == 0) {
        return enif_make_badarg(env);
    }
    if (max_bytes > 1048576) max_bytes = 1048576; /* Cap at 1MB */

    /* Read into a stack buffer for the common sizes and allocate an
     * exactly-sized binary only once we know how many bytes actually arrived.
     * Allocating up front cost a full max_bytes alloc+free on every EAGAIN —
     * roughly half of all calls in a demand-driven loop — plus an
     * enif_realloc_binary shrink on every short read. 64 KiB of stack is well
     * inside a scheduler thread's stack budget; above that we keep the
     * alloc-then-shrink path rather than growing the C frame to 1 MiB. */
    unsigned char stackbuf[65536];
    ErlNifBinary bin;
    unsigned char *dst;
    int on_stack = max_bytes <= sizeof(stackbuf);

    /* Only the heap path touches bin before a successful alloc; zero it so no
     * compiler has to prove that. */
    memset(&bin, 0, sizeof(bin));

    if (on_stack) {
        dst = stackbuf;
    } else if (enif_alloc_binary(max_bytes, &bin)) {
        dst = bin.data;
    } else {
        return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "alloc_failed"));
    }

    /* Hold the lock across read() + enif_select so that a concurrent
     * nif_close / down callback cannot close the fd mid-syscall. read() is
     * non-blocking (O_NONBLOCK) so the lock is held only briefly. */
    enif_mutex_lock(res->lock);
    if (res->closed || res->fd < 0) {
        enif_mutex_unlock(res->lock);
        if (!on_stack) enif_release_binary(&bin);
        return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "closed"));
    }
    int fd = res->fd;

    /* Retry EINTR at the syscall: callers treat any result other than ok /
     * eagain as terminal without re-arming enif_select, so a stray signal
     * must not permanently kill a drain loop. O_NONBLOCK means the retry
     * cannot sleep. */
    ssize_t n;
    do {
        n = read(fd, dst, (size_t)max_bytes);
    } while (n < 0 && errno == EINTR);
    int saved_errno = errno;

    if (n > 0) {
        enif_mutex_unlock(res->lock);
        if (on_stack) {
            if (!enif_alloc_binary((size_t)n, &bin)) {
                return enif_make_tuple2(env, atom_error,
                                        MAKE_ATOM(env, "alloc_failed"));
            }
            memcpy(bin.data, stackbuf, (size_t)n);
        } else if (!enif_realloc_binary(&bin, (size_t)n)) {
            /* Shrink failed: bin still spans max_bytes with only n valid
             * bytes. Never hand Erlang the uninitialized tail — copy the
             * n bytes into an exactly-sized binary instead. */
            ErlNifBinary exact;
            if (!enif_alloc_binary((size_t)n, &exact)) {
                enif_release_binary(&bin);
                return enif_make_tuple2(env, atom_error,
                                        MAKE_ATOM(env, "alloc_failed"));
            }
            memcpy(exact.data, bin.data, (size_t)n);
            enif_release_binary(&bin);
            bin = exact;
        }
        consume_bytes_timeslice(env, (size_t)n);
        return enif_make_tuple2(env, atom_ok, enif_make_binary(env, &bin));
    }
    if (n == 0) {
        enif_mutex_unlock(res->lock);
        if (!on_stack) enif_release_binary(&bin);
        return atom_eof;
    }
    if (saved_errno == EAGAIN || saved_errno == EWOULDBLOCK) {
        int sel_ret = enif_select(env, (ErlNifEvent)fd,
                                  ERL_NIF_SELECT_READ, res, NULL,
                                  atom_undefined);
        enif_mutex_unlock(res->lock);
        if (!on_stack) enif_release_binary(&bin);
        if (sel_ret < 0) {
            return enif_make_tuple2(env, atom_error,
                                    MAKE_ATOM(env, "select_failed"));
        }
        return enif_make_tuple2(env, atom_error, atom_eagain);
    }
    enif_mutex_unlock(res->lock);
    if (!on_stack) enif_release_binary(&bin);
    return enif_make_tuple2(env, atom_error,
                            MAKE_ATOM(env, errno_to_atom(saved_errno)));
}

/*
 * nif_write(resource, binary) -> {:ok, bytes_written} | {:error, :eagain}
 *
 * Writes binary data to the FD. Returns :eagain if would block.
 */
static ERL_NIF_TERM nif_write(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 2);

    io_resource_t *res;
    if (!enif_get_resource(env, argv[0], io_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }

    ErlNifBinary bin;
    /* Binaries only. Iolists are normalised to a binary at the Elixir API
     * boundary (NetRunner.Process.write/2); accepting them here duplicated
     * that flattening logic and hid an extra copy inside the NIF. */
    if (!enif_inspect_binary(env, argv[1], &bin)) {
        return enif_make_badarg(env);
    }

    /* Hold the lock across write() + enif_select so that a concurrent
     * close cannot reap the fd mid-syscall. */
    enif_mutex_lock(res->lock);
    if (res->closed || res->fd < 0) {
        enif_mutex_unlock(res->lock);
        return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "closed"));
    }
    int fd = res->fd;

    /* Retry EINTR at the syscall — see nif_read. */
    ssize_t n;
    do {
        n = write(fd, bin.data, bin.size);
    } while (n < 0 && errno == EINTR);
    int saved_errno = errno;

    if (n > 0) {
        enif_mutex_unlock(res->lock);
        consume_bytes_timeslice(env, (size_t)n);
        return enif_make_tuple2(env, atom_ok, enif_make_int64(env, (int64_t)n));
    }
    /* write() returning 0 on a non-empty buffer (bin.size > 0 here) is rare
     * but legal. Treat it like EAGAIN: register for write readiness and let
     * the caller re-arm via :ready_output, rather than spinning. */
    if (n == 0 || saved_errno == EAGAIN || saved_errno == EWOULDBLOCK) {
        int sel_ret = enif_select(env, (ErlNifEvent)fd,
                                  ERL_NIF_SELECT_WRITE, res, NULL,
                                  atom_undefined);
        enif_mutex_unlock(res->lock);
        if (sel_ret < 0) {
            return enif_make_tuple2(env, atom_error,
                                    MAKE_ATOM(env, "select_failed"));
        }
        return enif_make_tuple2(env, atom_error, atom_eagain);
    }
    enif_mutex_unlock(res->lock);
    if (saved_errno == EPIPE) {
        return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "epipe"));
    }
    return enif_make_tuple2(env, atom_error,
                            MAKE_ATOM(env, errno_to_atom(saved_errno)));
}

/*
 * nif_close(resource) -> :ok | {:error, reason}
 *
 * Closes the FD and deregisters from enif_select.
 */
static ERL_NIF_TERM nif_close(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 1);

    io_resource_t *res;
    if (!enif_get_resource(env, argv[0], io_resource_type, (void **)&res)) {
        return enif_make_badarg(env);
    }

    enif_mutex_lock(res->lock);
    if (res->closed) {
        enif_mutex_unlock(res->lock);
        return atom_ok; /* Already closed, idempotent */
    }

    int fd = res->fd;
    res->closed = 1;
    res->fd = -1;

    if (res->monitor_active) {
        enif_demonitor_process(env, res, &res->monitor);
        res->monitor_active = 0;
    }

    enif_mutex_unlock(res->lock);

    /* Hand fd off to the stop callback — BEAM waits for any in-flight select
     * registration to drain before calling stop, which then close()s the fd.
     * Concurrent nif_read/nif_write serialize on res->lock; once they observe
     * closed==1 they early-out without touching the fd. */
    int sel_ret = enif_select(env, (ErlNifEvent)fd, ERL_NIF_SELECT_STOP, res,
                              NULL, atom_undefined);
    if (sel_ret < 0) {
        /* Diagnostic only, not a retry request: the fd is already marked
         * closed and the monitor is already gone, so there is nothing left to
         * roll back or call again. The fd is leaked and the caller should log
         * that fact. */
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "select_failed"));
    }

    return atom_ok;
}

/*
 * nif_dup_fd(fd_int) -> {:ok, new_fd} | {:error, reason}
 *
 * Duplicates a raw FD. Used for PTY mode where the same master FD
 * needs separate NIF resources for read and write.
 */
static ERL_NIF_TERM nif_dup_fd(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 1);

    int fd;
    if (!enif_get_int(env, argv[0], &fd)) {
        return enif_make_badarg(env);
    }

    int new_fd = dup(fd);
    if (new_fd < 0) {
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, errno_to_atom(errno)));
    }

    return enif_make_tuple2(env, atom_ok, enif_make_int(env, new_fd));
}

/*
 * nif_close_fd(fd_int) -> :ok | {:error, reason}
 *
 * Closes a raw FD that was never wrapped in an io_resource. Used on spawn
 * error paths to release FDs received via SCM_RIGHTS that would otherwise
 * leak for the lifetime of the VM.
 */
static ERL_NIF_TERM nif_close_fd(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 1);

    int fd;
    if (!enif_get_int(env, argv[0], &fd) || fd < 0) {
        return enif_make_badarg(env);
    }

    /* EINTR: POSIX leaves the fd state unspecified, but on Linux and macOS
     * the descriptor is already freed. Reporting an error would invite the
     * caller to close again and race whatever recycled the number. */
    if (close(fd) == 0 || errno == EINTR) {
        return atom_ok;
    }
    return enif_make_tuple2(env, atom_error,
                            MAKE_ATOM(env, errno_to_atom(errno)));
}

/*
 * nif_mkdir_private(path) -> :ok | {:error, reason}
 *
 * Raw mkdir(path, 0700). Unlike File.mkdir_p! + File.chmod!, the directory
 * is never observable with wider permissions, and an existing directory
 * (whoever owns it) is reported as :eexist instead of being adopted.
 */
static ERL_NIF_TERM nif_mkdir_private(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 1);

    ErlNifBinary path_bin;
    if (!enif_inspect_binary(env, argv[0], &path_bin) ||
        path_bin.size == 0 || path_bin.size > 4095) {
        return enif_make_badarg(env);
    }

    char path[4096];
    memcpy(path, path_bin.data, path_bin.size);
    path[path_bin.size] = '\0';
    if (strlen(path) != path_bin.size) {
        return enif_make_badarg(env); /* embedded NUL */
    }

    if (mkdir(path, 0700) == 0) {
        return atom_ok;
    }
    if (errno == EEXIST) {
        return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "eexist"));
    }
    return enif_make_tuple2(env, atom_error,
                            MAKE_ATOM(env, errno_to_atom(errno)));
}

/*
 * nif_kill(os_pid, signal) -> :ok | {:error, reason}
 *
 * Sends a signal to an OS process.
 */
static ERL_NIF_TERM nif_kill(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 2);

    int os_pid;
    if (!enif_get_int(env, argv[0], &os_pid) || os_pid <= 0) {
        return enif_make_badarg(env);
    }

    int sig;
    if (!enif_get_int(env, argv[1], &sig)) {
        return enif_make_badarg(env);
    }
    /* Reject signals outside the POSIX range, mirroring shepherd.c's
     * CMD_KILL validation. Bounds the blast radius of a stray nif_kill. */
    if (sig < 1 || sig > 31) {
        return enif_make_badarg(env);
    }

    if (kill((pid_t)os_pid, sig) == 0) {
        return atom_ok;
    }

    return enif_make_tuple2(env, atom_error,
                            MAKE_ATOM(env, errno_to_atom(errno)));
}

/*
 * nif_is_os_pid_alive(os_pid) -> true | false
 *
 * Checks if an OS process exists using kill(pid, 0).
 */
static ERL_NIF_TERM nif_is_os_pid_alive(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 1);

    int os_pid;
    if (!enif_get_int(env, argv[0], &os_pid) || os_pid <= 0) {
        return enif_make_badarg(env);
    }

    if (kill((pid_t)os_pid, 0) == 0) {
        return atom_true;
    }

    return atom_false;
}

/*
 * nif_signal_number(signal_atom) -> {:ok, number} | {:error, :unknown_signal}
 *
 * Converts a signal atom to its platform-specific number.
 */
static ERL_NIF_TERM nif_signal_number(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    ASSERT_ARGC(env, argc, 1);

    char atom_buf[32];
    if (!enif_get_atom(env, argv[0], atom_buf, sizeof(atom_buf),
                       ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }

    int sig = -1;
    if (strcmp(atom_buf, "sigterm") == 0) sig = SIGTERM;
    else if (strcmp(atom_buf, "sigkill") == 0) sig = SIGKILL;
    else if (strcmp(atom_buf, "sigint") == 0) sig = SIGINT;
    else if (strcmp(atom_buf, "sighup") == 0) sig = SIGHUP;
    else if (strcmp(atom_buf, "sigusr1") == 0) sig = SIGUSR1;
    else if (strcmp(atom_buf, "sigusr2") == 0) sig = SIGUSR2;
    else if (strcmp(atom_buf, "sigstop") == 0) sig = SIGSTOP;
    else if (strcmp(atom_buf, "sigcont") == 0) sig = SIGCONT;
    else if (strcmp(atom_buf, "sigquit") == 0) sig = SIGQUIT;
    else if (strcmp(atom_buf, "sigpipe") == 0) sig = SIGPIPE;

    if (sig < 0) {
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, "unknown_signal"));
    }

    return enif_make_tuple2(env, atom_ok, enif_make_int(env, sig));
}

/* ---- NIF Initialization ---- */

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;

    io_resource_type = enif_open_resource_type_x(
        env, "io_resource", &io_resource_init,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);

    if (!io_resource_type) return -1;

    atom_ok = MAKE_ATOM(env, "ok");
    atom_error = MAKE_ATOM(env, "error");
    atom_eagain = MAKE_ATOM(env, "eagain");
    atom_eof = MAKE_ATOM(env, "eof");
    atom_undefined = MAKE_ATOM(env, "undefined");
    atom_true = MAKE_ATOM(env, "true");
    atom_false = MAKE_ATOM(env, "false");

    return 0;
}

static ErlNifFunc nif_funcs[] = {
    /* Flags are 0 on purpose — see the file header. Every syscall reachable
     * from here is bounded, so a dirty-scheduler hop would be pure latency. */
    {"nif_create_fd", 2, nif_create_fd, 0},
    {"nif_read", 2, nif_read, 0},
    {"nif_write", 2, nif_write, 0},
    {"nif_close", 1, nif_close, 0},
    {"nif_dup_fd", 1, nif_dup_fd, 0},
    {"nif_close_fd", 1, nif_close_fd, 0},
    {"nif_mkdir_private", 1, nif_mkdir_private, 0},
    {"nif_kill", 2, nif_kill, 0},
    {"nif_is_os_pid_alive", 1, nif_is_os_pid_alive, 0},
    {"nif_signal_number", 1, nif_signal_number, 0}
};

ERL_NIF_INIT(Elixir.NetRunner.Nif, nif_funcs, load, NULL, NULL, NULL)
