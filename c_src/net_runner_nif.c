/*
 * net_runner_nif.c - NIF for async I/O on raw file descriptors
 *
 * All functions run on dirty IO schedulers to avoid blocking normal schedulers.
 * Uses enif_select for async readiness notification integrated with BEAM's
 * epoll/kqueue event loop.
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
    if (res->lock) {
        enif_mutex_lock(res->lock);
        if (!res->closed && res->fd >= 0) {
            close(res->fd);
            res->fd = -1;
            res->closed = 1;
        }
        enif_mutex_unlock(res->lock);
        enif_mutex_destroy(res->lock);
        res->lock = NULL;
    }
}

static void io_resource_stop(ErlNifEnv *env, void *obj, ErlNifEvent event,
                             int is_direct_call) {
    (void)env;
    (void)obj;
    (void)event;
    (void)is_direct_call;
    /* enif_select stop callback - FD is being deselected */
}

static void io_resource_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                             ErlNifMonitor *mon) {
    (void)env;
    (void)pid;
    (void)mon;
    io_resource_t *res = (io_resource_t *)obj;
    /* Owner process died - close the FD */
    if (res->lock) {
        enif_mutex_lock(res->lock);
        if (!res->closed && res->fd >= 0) {
            enif_select(env, (ErlNifEvent)res->fd, ERL_NIF_SELECT_STOP,
                        obj, NULL, enif_make_atom(env, "undefined"));
            close(res->fd);
            res->fd = -1;
            res->closed = 1;
        }
        res->monitor_active = 0;
        enif_mutex_unlock(res->lock);
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

    /* Monitor the owner process */
    if (enif_monitor_process(env, res, &owner, &res->monitor) == 0) {
        res->monitor_active = 1;
    }

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

    enif_mutex_lock(res->lock);
    if (res->closed) {
        enif_mutex_unlock(res->lock);
        return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "closed"));
    }
    int fd = res->fd;
    enif_mutex_unlock(res->lock);

    ErlNifBinary bin;
    if (!enif_alloc_binary(max_bytes, &bin)) {
        return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "alloc_failed"));
    }

    ssize_t n = read(fd, bin.data, bin.size);
    if (n > 0) {
        enif_realloc_binary(&bin, (size_t)n);
        return enif_make_tuple2(env, atom_ok, enif_make_binary(env, &bin));
    } else if (n == 0) {
        enif_release_binary(&bin);
        return atom_eof;
    } else {
        enif_release_binary(&bin);
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            /* Register for select notification */
            int sel_ret = enif_select(env, (ErlNifEvent)fd,
                                      ERL_NIF_SELECT_READ, res, NULL,
                                      atom_undefined);
            if (sel_ret < 0) {
                return enif_make_tuple2(env, atom_error,
                                        MAKE_ATOM(env, "select_failed"));
            }
            return enif_make_tuple2(env, atom_error, atom_eagain);
        }
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, errno_to_atom(errno)));
    }
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
    if (!enif_inspect_binary(env, argv[1], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &bin)) {
        return enif_make_badarg(env);
    }

    if (bin.size == 0) {
        return enif_make_tuple2(env, atom_ok, enif_make_int(env, 0));
    }

    enif_mutex_lock(res->lock);
    if (res->closed) {
        enif_mutex_unlock(res->lock);
        return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "closed"));
    }
    int fd = res->fd;
    enif_mutex_unlock(res->lock);

    ssize_t n = write(fd, bin.data, bin.size);
    if (n >= 0) {
        return enif_make_tuple2(env, atom_ok, enif_make_int64(env, (int64_t)n));
    } else {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            int sel_ret = enif_select(env, (ErlNifEvent)fd,
                                      ERL_NIF_SELECT_WRITE, res, NULL,
                                      atom_undefined);
            if (sel_ret < 0) {
                return enif_make_tuple2(env, atom_error,
                                        MAKE_ATOM(env, "select_failed"));
            }
            return enif_make_tuple2(env, atom_error, atom_eagain);
        }
        if (errno == EPIPE) {
            return enif_make_tuple2(env, atom_error, MAKE_ATOM(env, "epipe"));
        }
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, errno_to_atom(errno)));
    }
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

    /* Deregister from enif_select before closing */
    enif_select(env, (ErlNifEvent)fd, ERL_NIF_SELECT_STOP, res, NULL,
                atom_undefined);

    if (res->monitor_active) {
        enif_demonitor_process(env, res, &res->monitor);
        res->monitor_active = 0;
    }

    /* Close FD inside critical section to prevent TOCTOU race:
     * a concurrent nif_read/nif_write on a dirty scheduler could copy the FD
     * under lock then use it after we release the lock but before close(). */
    int close_ret = close(fd);
    int close_errno = errno;

    enif_mutex_unlock(res->lock);

    if (close_ret != 0 && close_errno != EINTR) {
        return enif_make_tuple2(env, atom_error,
                                MAKE_ATOM(env, errno_to_atom(close_errno)));
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
    {"nif_create_fd", 2, nif_create_fd, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_read", 2, nif_read, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_write", 2, nif_write, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_close", 1, nif_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_dup_fd", 1, nif_dup_fd, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_kill", 2, nif_kill, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_is_os_pid_alive", 1, nif_is_os_pid_alive, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_signal_number", 1, nif_signal_number, 0}
};

ERL_NIF_INIT(Elixir.NetRunner.Process.Nif, nif_funcs, load, NULL, NULL, NULL)
