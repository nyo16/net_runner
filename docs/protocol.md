# Shepherd ↔ BEAM Protocol

## Transport

Communication between the BEAM and the shepherd binary occurs over a Unix domain socket (UDS) with `SOCK_STREAM` semantics.

## Connection Lifecycle

1. BEAM creates a UDS listener at a random temp path (inside a per-VM 0700
   directory) and generates a per-spawn 16-byte random token
2. BEAM spawns shepherd via `Port.open` with the UDS path as argv[1] and the
   `--token-fd` flag, then writes the 32-byte hex token to the shepherd over
   the private fd-3 port channel. For a replacement environment, the port
   environment already unsets every unselected variable the BEAM saw, and
   `--replace-env` carries the selected-name allowlist
3. Shepherd reads the token from fd 3, connects to the UDS and writes the
   32 hex bytes verbatim as its very first frame
4. BEAM verifies the token (and, where the platform exposes peer
   credentials, the peer uid); a failed or stalling connection is closed and
   the BEAM keeps accepting until the deadline
5. Shepherd enters `--cwd` when present (`MSG_ERROR` and exit on failure)
6. For a replacement environment, shepherd removes every variable outside the
   selected-name allowlist
7. Shepherd forks the child. The child sets up its process group (pipe mode:
   `setpgid(0, 0)`; PTY mode: `setsid()`, then signals the shepherd with an
   `'R'` byte), resets every signal disposition and its signal mask, and
   blocks on the exec gate
8. Shepherd: pipe mode `setpgid(child, child)`; on Linux `pidfd_open(child)`;
   cgroup placement when `--cgroup-path` is set
9. Shepherd sends the FDs via `SCM_RIGHTS` (1 message; the pidfd, when
   obtained, is the last fd)
10. Shepherd sends `MSG_CHILD_STARTED` (can share the FD receive)
11. Shepherd writes `'G'` to the gate; only now does the child `execvp`
12. Bidirectional command/notification flow starts
13. On child exit: SIGKILL of the remaining process group (while the zombie
    leader still pins the pgid), reap, cgroup cleanup, *then*
    `MSG_CHILD_EXITED`, shepherd exits
14. On BEAM death (`POLLHUP`/`POLLERR`/`POLLNVAL`) or a SIGTERM/SIGINT/SIGHUP/
    SIGQUIT to the shepherd: drain queued commands, then the teardown ladder
    (see [BEAM Death Detection](#beam-death-detection))

Any shepherd failure in steps 8–11 closes the gate (the child `_exit(127)`s
without exec), SIGKILLs and reaps the child, and only then sends `MSG_ERROR`
when the UDS is usable. The BEAM therefore never sees an error for a spawn
whose command ran.

## Authentication Handshake

The token authenticates the connecting peer as the shepherd this BEAM just
spawned. Without it, any same-uid process that won the `accept` race would
receive the child's pipe FDs via `SCM_RIGHTS`. The token is:

- 16 random bytes (`:crypto.strong_rand_bytes/1`), hex-encoded to 32 ASCII
  chars (`TOKEN_HEX_LEN` in `protocol.h`)
- delivered over the `:nouse_stdio` port channel (fd 3), **never argv**:
  `/proc/<pid>/cmdline` is world-readable on Linux and `KERN_PROCARGS2` is
  same-uid readable on macOS, so an argv token would be visible to exactly
  the attacker it exists to stop
- written by the shepherd as the first 32 bytes on the socket, before any
  FD or message

A connection that fails authentication (wrong bytes, wrong peer uid, or a
stall past the accept deadline) is closed and the listener keeps accepting,
so an impostor costs only its own connection.

The shepherd binary and the Elixir library always ship together, so there is
no compatibility shim for token-less shepherds.

The shepherd applies `--cwd` after sending its token (it never learns whether
the BEAM accepted it). The token must remain the first frame on the socket.

A shepherd that never receives its token exits after `TOKEN_READ_TIMEOUT_MS`
(10 s, the BEAM's accept deadline). The BEAM unlinks the port for the token
write, so a spawner killed before writing need not close fd 3; this bound
keeps such a shepherd from waiting forever. It has no child yet, so nothing
else is left behind.

## FD Passing (SCM_RIGHTS)

Once the child is parked on the exec gate, the shepherd sends file descriptors using `sendmsg()` with `SCM_RIGHTS` ancillary data.

**Pipe mode** (3 FDs, or 4 with a pidfd):
```
[stdin_write_fd, stdout_read_fd, stderr_read_fd]
[stdin_write_fd, stdout_read_fd, stderr_read_fd, pidfd]
```

**PTY mode** (1 FD, or 2 with a pidfd):
```
[master_fd]          (bidirectional — used for both read and write)
[master_fd, pidfd]
```

The pidfd is optional and always last: Linux ≥ 5.3 only, skipped silently on
`ENOSYS` or any other `pidfd_open` failure. The shepherd closes its own copy
after sending. The BEAM accepts either count, wraps the pidfd with
`nif_create_fd/2` (so the owner monitor closes it) and uses it for direct
signals via `nif_pidfd_send_signal/2`.

The iov payload is a single dummy byte (`0x00`). The BEAM receives this via `:socket.recvmsg/5` and decodes FDs from the control message as native-endian 32-bit integers.

## Message Format

Messages are byte-oriented and fixed-layout: a 1-byte opcode followed by an
opcode-determined payload.

### Framing is the reader's job

The transport is `SOCK_STREAM`, so **a frame boundary is not a read boundary**.
A single `read`/`recvmsg` can deliver part of one message, several messages, or
the tail of the `SCM_RIGHTS` iov byte followed by two whole messages. Both
sides must therefore buffer:

- The shepherd keeps a carry-over buffer across `poll()` iterations and
  dispatches per-opcode lengths (`command_length/1` in `shepherd.c`).
- The BEAM keeps `State.uds_carry` and parses with
  `NetRunner.Process.Protocol.parse_uds_message/1`, retaining any unconsumed tail.

This is not theoretical. For a child that exits before the BEAM's `recvmsg`,
the iov byte, `MSG_CHILD_STARTED` and `MSG_CHILD_EXITED` all coalesce into one
11-byte read. An earlier version parsed `MSG_CHILD_STARTED` and discarded the
remainder, losing the exit status for every fast-exiting command — the caller
then waited out a 5 s timeout and received a synthetic `137` instead of the
real status.

### Unknown opcodes

An unknown opcode means the two sides disagree about framing, so nothing after
it in the buffer can be trusted. Both sides discard the rest of the current
buffer instead of resynchronising byte by byte (which would reinterpret payload
bytes as commands); the shepherd logs it once to its stderr. There is no
version negotiation: shepherd and library always ship together.

### BEAM → Shepherd Commands

| Byte | Command | Payload | Description |
|------|---------|---------|-------------|
| `0x01` | `CMD_KILL` | `signal_number` (1 byte) | Kill the child process group with given signal |
| `0x02` | `CMD_CLOSE_STDIN` | (none) | Close shepherd's copy of stdin write FD |
| `0x03` | `CMD_SET_WINSIZE` | `rows` (2 bytes, big-endian) + `cols` (2 bytes, big-endian) | Set PTY window size via `ioctl(TIOCSWINSZ)` |

### Shepherd → BEAM Messages

| Byte | Message | Payload | Description |
|------|---------|---------|-------------|
| `0x80` | `MSG_CHILD_STARTED` | `pid` (4 bytes, big-endian) | Child PID, sent once the child leads its process group and is parked on the exec gate (before `execvp`) |
| `0x81` | `MSG_CHILD_EXITED` | `status` (4 bytes, big-endian) | Child exit status (exit code or 128+signal), sent after the group sweep, reap and cgroup cleanup |
| `0x82` | `MSG_ERROR` | `length` (2 bytes, big-endian) + `message` (N bytes) | Error text (up to 255 bytes). Before FD passing, this frame has no FDs |

## Exit Status Encoding

- Normal exit: `WEXITSTATUS(status)` (0-255)
- Signal death: `128 + WTERMSIG(status)` (e.g., SIGKILL=9 → 137)
- Neither (should not happen): `255` (`EXIT_STATUS_UNKNOWN`). The status is
  always in `0..255`, never `0xFFFFFFFF`
- A child that could not be reaped after SIGKILL (stuck in uninterruptible
  sleep) is reported as `137`
- A failure after `MSG_CHILD_STARTED` but before exec (e.g. SIGTERM to the
  shepherd mid-hand-off) sends `MSG_ERROR` followed by
  `MSG_CHILD_EXITED(137)`

## Kill Protocol

When BEAM sends `CMD_KILL`:
1. Shepherd calls `kill(-child_pid, signal)` (process group kill)
2. Falls back to `kill(child_pid, signal)` if group doesn't exist

If the command cannot be sent (or the shepherd is gone), the BEAM signals
the child directly: through the pidfd when it has one (race-free; `ESRCH`
→ `{:error, :not_running}`), otherwise by probing the pid and then
`kill(2)`.

## Close Stdin Protocol

Both sides must close their copy of stdin for the child to see EOF:
1. BEAM closes its NIF resource (closes the FD)
2. BEAM sends `CMD_CLOSE_STDIN` to shepherd
3. Shepherd closes its copy of `stdin_write_fd`

Only then does the child's `read(STDIN_FILENO)` return 0 (EOF).

## BEAM Death Detection

The shepherd watches the UDS with `poll()`:
- `POLLHUP`, `POLLERR` or `POLLNVAL` → BEAM died. Readable bytes are drained
  through the command parser first, so a `CMD_KILL` the BEAM sent just before
  closing (e.g. `kill(pid, :sigkill)` followed by `stop/1`) is honoured
  instead of being replaced by the ladder
- SIGTERM/SIGINT/SIGHUP/SIGQUIT delivered to the shepherd take the same path
  through its self-pipe
- Triggers `kill_child()`: SIGTERM to the group → wait for the leader's exit
  without reaping it (`WNOWAIT`) up to `--kill-timeout` → **always** SIGKILL
  the group (direct-pid fallback) → reap → cgroup cleanup
- Sends `MSG_CHILD_EXITED` with the reaped status when the UDS is still
  usable (the signal path), then exits

## Exec Failure

A child that cannot exec writes `execvp: <cmd>: <reason> (errno N)` to its
stderr and exits `127` for `ENOENT` (and a replacement environment without
`PATH`), `126` for every other errno (`EACCES`, `ENOEXEC`, ...), following
the shell convention.
