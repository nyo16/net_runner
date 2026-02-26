# Shepherd ↔ BEAM Protocol

## Transport

Communication between the BEAM and the shepherd binary occurs over a Unix domain socket (UDS) with `SOCK_STREAM` semantics.

## Connection Lifecycle

1. BEAM creates a UDS listener at a random temp path
2. BEAM spawns shepherd via `Port.open` with the UDS path as argv[1]
3. Shepherd connects to the UDS
4. Shepherd forks the child process
5. Shepherd sends pipe FDs via `SCM_RIGHTS` (1 message)
6. Shepherd sends `MSG_CHILD_STARTED` (may be in same recv as FDs)
7. Bidirectional command/notification flow begins
8. On child exit: `MSG_CHILD_EXITED`, shepherd exits
9. On BEAM death: shepherd sees `POLLHUP`, kills child

## FD Passing (SCM_RIGHTS)

Immediately after fork, the shepherd sends file descriptors using `sendmsg()` with `SCM_RIGHTS` ancillary data.

**Pipe mode** (3 FDs):
```
[stdin_write_fd, stdout_read_fd, stderr_read_fd]
```

**PTY mode** (1 FD):
```
[master_fd]  (bidirectional — used for both read and write)
```

The iov payload is a single dummy byte (`0x00`). The BEAM receives this via `:socket.recvmsg/5` and decodes FDs from the control message as native-endian 32-bit integers.

## Message Format

All messages are byte-oriented, no framing needed (each message is atomic and small).

### BEAM → Shepherd Commands

| Byte | Command | Payload | Description |
|------|---------|---------|-------------|
| `0x01` | `CMD_KILL` | `signal_number` (1 byte) | Kill the child process group with given signal |
| `0x02` | `CMD_CLOSE_STDIN` | (none) | Close shepherd's copy of stdin write FD |
| `0x03` | `CMD_SET_WINSIZE` | `rows` (2 bytes, big-endian) + `cols` (2 bytes, big-endian) | Set PTY window size via `ioctl(TIOCSWINSZ)` |

### Shepherd → BEAM Messages

| Byte | Message | Payload | Description |
|------|---------|---------|-------------|
| `0x80` | `MSG_CHILD_STARTED` | `pid` (4 bytes, big-endian) | Child process PID after successful fork+exec |
| `0x81` | `MSG_CHILD_EXITED` | `status` (4 bytes, big-endian) | Child exit status (exit code or 128+signal) |
| `0x82` | `MSG_ERROR` | `length` (2 bytes, big-endian) + `message` (N bytes) | Error message string |

## Exit Status Encoding

- Normal exit: `WEXITSTATUS(status)` (0-255)
- Signal death: `128 + WTERMSIG(status)` (e.g., SIGKILL=9 → 137)

## Kill Protocol

When BEAM sends `CMD_KILL`:
1. Shepherd calls `kill(-child_pid, signal)` (process group kill)
2. Falls back to `kill(child_pid, signal)` if group doesn't exist

The BEAM also sends a direct NIF kill as belt-and-suspenders.

## Close Stdin Protocol

Both sides must close their copy of stdin for the child to see EOF:
1. BEAM closes its NIF resource (closes the FD)
2. BEAM sends `CMD_CLOSE_STDIN` to shepherd
3. Shepherd closes its copy of `stdin_write_fd`

Only then does the child's `read(STDIN_FILENO)` return 0 (EOF).

## BEAM Death Detection

The shepherd watches the UDS with `poll()`:
- `POLLHUP` or `POLLERR` → BEAM died
- Triggers `kill_child()`: SIGTERM → configurable timeout → SIGKILL
- Also triggers cgroup cleanup if configured
