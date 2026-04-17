# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

Focused code-review pass across the NIF, shepherd, and Elixir layers.
Correctness-first: closes two real-world race/leak bugs, hardens the
post-fork child window, and adds an AddressSanitizer + UBSan CI job.

### Fixed

- **FD leak in `nif_create_fd`** when `enif_mutex_create` failed
  — the destructor previously gated `close(fd)` on a non-NULL lock,
  so a failed mutex allocation leaked the file descriptor and armed
  a NULL-deref in any later `nif_close`. The mutex result is checked
  and the dtor now closes the fd unconditionally.
- **Use-after-close race in NIF read/write vs. close/down**
  — `nif_read`/`nif_write` copied `res->fd` under the mutex and
  released the lock before the syscall; a concurrent `nif_close` or
  owner-death callback could close the fd before the syscall ran,
  letting the read/write target a recycled fd. The mutex is now held
  across the syscall and the subsequent `enif_select` registration;
  the actual `close()` is deferred to the `io_resource_stop` callback
  so BEAM can drain pending selects before the fd is released.
- **Lost initial stderr chunk in `:consume` mode**
  — `kick_stderr_read` in `init/1` sent `{:stderr_data, data}` to
  `self()` but no `handle_info/2` clause matched, so the first (and
  often only) chunk of stderr for fast-exiting processes was silently
  dropped. The missing handler now appends to the stderr buffer and
  drains any remainder.
- **`write_loop` spin on `{:ok, 0}`** — if the kernel ever returned
  0 bytes on a non-empty write, the GenServer would recurse forever
  on the dirty scheduler. Bounded with a 1 ms sleep-retry.
- **Shepherd UDS command framing** — the event loop parsed only
  `buf[0]`, discarding any coalesced or tail commands (e.g.
  `CMD_CLOSE_STDIN` followed immediately by `CMD_KILL`). Frames are
  now length-dispatched per opcode with a carry-over buffer across
  `poll()` iterations.
- **Post-fork child stdio and signal safety** — replaced `fprintf` /
  `strerror` in the post-fork / pre-exec window with a `write(2)`-
  based `child_fail()` helper (async-signal-safe). Every `dup2`,
  `setsid`, and `TIOCSCTTY` return is now checked; on failure the
  child exits 127 with a diagnostic instead of running with broken
  stdio.
- **`waitpid` after SIGKILL** — replaced the unbounded
  `waitpid(child_pid, NULL, 0)` with a bounded WNOHANG loop
  (~3 s cap) so the shepherd cannot hang on a child stuck in
  uninterruptible kernel sleep (D-state).
- **SIGCHLD reap loop** — reap all pending children per SIGCHLD
  (`while waitpid(-1, ..., WNOHANG) > 0`) so a coalesced signal
  never leaks zombies.
- **Cgroup / UDS path hardening** — validate every `snprintf` return,
  reject too-long UDS paths, set `FD_CLOEXEC` on the PTY master,
  treat user-requested cgroup setup failure as fatal, and replace
  the fixed 100 ms `usleep` in `cgroup_cleanup` with a bounded
  polling `rmdir`.
- **`Stream` consumer crash cleanup** — `Stream.resource`'s `after`
  callback is only run on normal termination. A consumer crash
  orphaned the `NetRunner.Process` GenServer and its OS child.
  `NetRunner.Process.start/3` now accepts an `:owner` option that
  monitors the caller; `NetRunner.Stream.stream/3` passes `self()`,
  so a consumer crash SIGKILLs the OS process and stops the
  GenServer.
- **Watcher blocking on `Process.sleep`** — the 5 s sleep in
  `handle_info/2` wedged the Watcher unresponsive (including to
  supervisor shutdown). Replaced with `Process.send_after/3` and a
  new `:escalate_to_sigkill` handler.
- **Parked-caller tracking in `Operations`** — callers parked on
  EAGAIN are now `Process.monitor/1`-ed; dead callers are pruned on
  `:DOWN` instead of lingering in the pending map until process
  exit.
- **`read_uds_message` race** — replaced the `:peek` + full-recv
  pattern (which could time out if the payload arrived a moment
  after the opcode) with an opcode-first read flow and longer
  timeouts.
- **`cmd` / `args` validation** — reject non-binary, empty, or
  NUL-containing cmd and args at the spawn boundary. Passing NUL
  bytes through `Port.open`'s `args:` is undefined on the C side.
- **`NetRunner.run/2` error surface** — previously pattern-matched
  `{:ok, pid}` from `Proc.start`, raising `MatchError` when
  validation failed. Now returns `{:error, reason}` cleanly.
- **`File.rm` cleanup of UDS socket** — tolerate `:enoent`
  (shepherd may have unlinked), propagate other errors.
- **`Signal.resolve` integer range** — integer signals outside
  POSIX `1..31` now return `{:error, :unknown_signal}` instead of
  being forwarded to `kill(2)`.
- **`Signal` single source of truth** — `Signal.resolve` delegates
  to the NIF for known-atom lookup instead of maintaining a duplicate
  allow-list that drifted from the C side.
- **Daemon drain resilience** — drain-task crashes used to match a
  catch-all `:DOWN` handler and silently stop draining; the pipe
  then filled until the child blocked. Narrowed to recognised refs
  with a warning log; `drain_loop` wrapped in `try/rescue/catch` so
  a reader or logger exception cannot take the daemon down through
  the linked Task.
- **`terminate/2`** explicitly closes the shepherd `Port` after the
  UDS socket for deterministic teardown order.

### Added

- **AddressSanitizer + UBSan** — opt-in build via `SANITIZE=1 make all`
  or `make asan`. New CI job (`sanitizers`) rebuilds the NIF and
  shepherd with `-fsanitize=address,undefined`, preloads `libasan`,
  and runs the full `mix test`. The publish job depends on it.
- **Stale UDS socket sweep** in `test/test_helper.exs` (before and
  after the suite) — stops accumulation from test crashes before
  `cleanup_listener/2` runs.
- **Regression tests** for: NUL-byte validation in `cmd` and `args`,
  `Signal.resolve` range + type handling, `:owner` monitor SIGKILL
  path, stderr-only fast-exit stats, binary-with-NUL round-trip, and
  `NetRunner.run` / `NetRunner.stream` returning validation errors
  cleanly.

## [1.0.0] - 2026-02-26

Initial release.

### Core

- `NetRunner.run/2` — run a command and collect output as `{output, exit_status}`
- `NetRunner.stream!/2` / `NetRunner.stream/2` — lazy streaming I/O with backpressure
- `NetRunner.Process` — GenServer with full lifecycle control: `start/3`, `read/2`, `write/2`, `close_stdin/1`, `kill/2`, `await_exit/2`, `os_pid/1`, `alive?/1`

### Shepherd Binary (C)

- Persistent watchdog process that stays alive for the child's lifetime
- Detects BEAM death via UDS `POLLHUP` — guarantees child cleanup even under `SIGKILL`
- FD passing via `SCM_RIGHTS` over Unix domain sockets
- `poll()` event loop with self-pipe trick for `SIGCHLD` handling
- Process group kills: `setpgid(0,0)` + `kill(-pgid, sig)` catches grandchildren
- Configurable SIGTERM → SIGKILL escalation timeout (`--kill-timeout`)

### NIF I/O

- `enif_select` integration with BEAM's epoll/kqueue for async I/O
- All NIF functions on dirty IO schedulers
- Demand-driven backpressure via OS pipe buffers + `EAGAIN` + enif_select
- Resource-based FD management with destructor/stop/down callbacks

### Zombie Prevention (3 layers)

- **Shepherd** — detects BEAM crash via UDS POLLHUP, kills child process group
- **Watcher** — detects GenServer crash via `Process.monitor`, kills child via NIF
- **NIF resource destructor** — closes FDs on GC, child sees broken pipe

### PTY Support

- `pty: true` option for pseudo-terminal emulation
- `openpty()` with `setsid()` + `TIOCSCTTY` for controlling terminal
- `set_window_size/3` via `ioctl(TIOCSWINSZ)`
- Single bidirectional master FD, duped for independent stdin/stdout NIF resources
- Platform support: `<util.h>` on macOS, `<pty.h>` on Linux

### cgroup Support (Linux)

- `:cgroup_path` option for cgroup v2 resource isolation
- Creates cgroup directory, moves child to `cgroup.procs`
- Cleanup via `cgroup.kill` + `rmdir` on process exit
- No-op on macOS/BSD

### Daemon Mode

- `NetRunner.Daemon` — supervised long-running process for supervision trees
- Auto-drains stdout/stderr to prevent pipe blocking
- Output handling: `:discard` (default), `:log`, or custom `fun/1` callback
- Graceful shutdown: SIGTERM → 5s wait → SIGKILL

### Stats

- `NetRunner.Process.stats/1` — per-process I/O statistics
- Tracks: `bytes_in`, `bytes_out`, `bytes_err`, `read_count`, `write_count`, `duration_ms`, `exit_status`
- Zero-cost integer counters in GenServer state

### Safety

- Timeout enforcement on `run/2` via `:timeout` option
- Output size limits via `:max_output_size` option
- Platform support: macOS (Darwin) and Linux
