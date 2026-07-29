# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

Performance and correctness pass driven by measurement. Two defects dominated
every benchmark: all NIF I/O was routed through dirty IO schedulers, and the
exit status of any fast-exiting command was silently discarded. Numbers below
are medians on an Apple M1 Max (10 cores), OTP 29, default VM flags.

### Fixed

- **All NIF I/O moved off dirty IO schedulers** (`~280x` stdout throughput:
  6.3 -> ~650 MiB/s; `nif_is_os_pid_alive` 670 us -> 1.6 us per call). Every
  fd is `O_NONBLOCK` and readiness comes from `enif_select`, so no call in the
  NIF can block — the `ERL_NIF_DIRTY_JOB_IO_BOUND` flag bought nothing and cost
  a thread handoff on every call, twice per streamed chunk. See ADR-6 in
  `docs/decisions.md`; do not reintroduce it.
  - `nif_create_fd` now `fstat`s the fd and rejects anything that is not a
    FIFO, socket or character device (`{:error, :unsupported_fd_type}`). A
    regular file ignores `O_NONBLOCK` and would stall a scheduler, so the
    previously-implicit invariant is now enforced.
  - `nif_read`/`nif_write` report work via `enif_consume_timeslice`.
- **Exit status of fast-exiting commands was discarded** — `run(["/bin/echo",
  "hi"])` took 5.1 s and returned `137` instead of `0`. The UDS is a byte
  stream: for a child that exits before the BEAM's `recvmsg`, the `SCM_RIGHTS`
  iov byte, `MSG_CHILD_STARTED` and `MSG_CHILD_EXITED` coalesce into one
  11-byte read, and `extract_child_started/2` matched the first frame and threw
  the rest away. The tail is now carried in `State.uds_carry` and parsed by
  `Exec.parse_uds_message/1`. Same command is now ~7 ms and returns `0`.
- **The UDS was never watched** — nothing armed a `:socket` select, so the
  `{:"$socket", …, :select, …}` clause was dead code, `MSG_CHILD_EXITED` could
  only be read reactively after the shepherd `Port` died, and `MSG_ERROR`
  frames were invisible. The socket is now armed with a `:nowait` recv and
  re-armed after each frame. The 5 s `:force_exit_timeout` is demoted to a
  backstop and logs a warning when it fires.
- **`drain_uds_for_exit`'s blocking retry ladder removed** — up to 5 x 500 ms of
  blocking `:socket.recv` inside the GenServer, during which it answered no
  calls, serviced no readiness and drained no stderr. Replaced with a single
  non-blocking sweep.
- **Spawn latency recovered** (152 ms -> ~3 ms median): the per-spawn `0700`
  socket directory added `mkdir`, `chmod` and `rmdir` file syscalls to every
  spawn. The directory is now created once per VM, with the same traversal
  barrier.
- **`NetRunner.Daemon` drain loop leaked stack without bound** — `rescue`/
  `catch` clauses on `drain_loop/3` wrapped the body in a `try`, taking the
  recursive call out of tail position and retaining a frame per chunk
  (~64 KB/s of stack per drain task, two tasks per Daemon). The defensive
  handling moved into a `safe_read/2` helper.
- **`Daemon.terminate/2`'s SIGKILL escalation was unreachable** — the 5 s
  `await_exit` grace equalled the `use GenServer` shutdown budget, so the
  supervisor brutal-killed the Daemon first. Additionally `await_exit/2` is a
  `GenServer.call`, so exhausting the grace *exited* the caller and unwound
  past the escalation. Grace split into 3 s + 1 s with an exit-trapping wrapper.
- **Early-terminated streams stalled 5 s** — `stream!(~w(yes)) |> Enum.take(1)`
  waited out the full graceful-exit grace for a child that ignores stdin
  closure. Natural EOF and consumer-halt are now distinguished; a halt
  escalates immediately.
- **`:owner` monitored the wrong process** — it captured whoever *built* the
  stream, so building in one process and consuming in another SIGKILLed the
  child mid-consumption. `NetRunner.Process.set_owner/2` re-registers from the
  consumer.
- **`append_stderr_tail/2` copied and pinned more than the cap** — `tail <>
  data` then `binary_part/3` copied up to 8 KiB per chunk (~129x amplification
  on line-buffered stderr), discarded the whole concat whenever the chunk
  already exceeded the cap, and returned a sub-binary pinning its ~72 KiB
  parent. Now slices without concatenating when possible and copies to release
  the parent.
- **`:ready_input` ignored which fd fired** — every stdout chunk also issued a
  wasted `read(2)` plus `enif_select` re-arm on stderr. The select message's
  resource is now matched against the pipes.
- **Parked-caller monitors are refcounted per caller pid** — a streaming
  consumer parks once per chunk, so a `Process.monitor`/`demonitor` pair per
  operation was a per-chunk cost. `pop_by_monitor/2` now reclaims all of a dead
  caller's operations at once.
- **`enif_monitor_process` and `enif_select(STOP)` failures are no longer
  swallowed** — a resource whose select relation is never dissolved is never
  destructed, so a silently-failed monitor meant a permanently leaked fd.
  Surfaced as `{:error, :monitor_failed}` / `{:error, :select_failed}`.
- **Shepherd: `kill_child` no longer polls `waitpid` with `usleep(100000)`** —
  a child dying 1 ms after SIGTERM cost up to 100 ms, twice. Now waits on the
  existing SIGCHLD self-pipe with `poll()` against a `CLOCK_MONOTONIC`
  deadline.
- **Shepherd: `SIGPIPE` is ignored** so a write to a departed BEAM returns
  `EPIPE` instead of killing the shepherd and orphaning the child. The default
  disposition is restored in the child before `execvp`, since `SIG_IGN`
  survives exec.
- **Shepherd: pipe buffers grown to 1 MiB on Linux** (`F_SETPIPE_SZ`,
  best-effort), cutting readiness round trips per MiB by ~16x.

### Changed

- `-fvisibility=hidden` for the NIF; only `nif_init` needs to be exported.
- Removed `NetRunner.Stream.AbnormalExit`, which was defined but never raised.
  Streams do not surface non-zero child exit statuses; the module implied
  otherwise.

### Added

- `NetRunner.Process.set_owner/2` — re-register the process whose death tears
  the OS process down. Replaces the previous monitor rather than stacking.
- `NetRunner.Process.Exec.parse_uds_message/1` — pure framing parser for the
  shepherd protocol, with tests for coalesced, truncated and unknown frames.
- Regression tests: `test/exit_status_test.exs` (coalesced-frame exit status,
  framing, `set_owner/2` semantics) and `test/teardown_test.exs` (drain-task
  stack bound, Daemon shutdown budget, early-halted stream teardown, fd-type
  guard).

## [1.1.2]

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
  0 bytes on a non-empty write, the GenServer would recurse forever.
  The NIF now maps a zero-byte write on a non-empty buffer to
  `:eagain` and registers `enif_select` for write readiness.
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
