# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

Performance follow-up cycle (from the 2026-08-31 `/phx:perf` reports; numbers
are medians on an Apple M1 Max, `MIX_ENV=prod`, harness under `bench/`).

Audit-remediation cycle (2026-08-31 project-health audit, second pass: all 39
remaining findings across shepherd/NIF, lib, tests, docs, and CI).

### Security

- **cgroup isolation fails closed.** `cgroup_setup` now checks the
  `cgroup.procs` write *and* flush (migration errors like EPERM/EBUSY surface
  at `fclose` behind stdio buffering) and fails the spawn with a descriptive
  `MSG_ERROR` instead of silently running the child unconfined. A
  pre-existing cgroup leaf directory is now fatal too (teardown would not be
  owned), and the directory is created `0700`.
- **cgroup attach no longer races `execvp`.** The child blocks on a sync
  pipe after `fork` and only execs once the shepherd has migrated it into
  the cgroup — descendants can no longer escape limits or `cgroup.kill`
  teardown. Non-cgroup spawns are byte-for-byte unchanged.
- **Signals no longer use a cached child PID.** `kill/2` sends requests only
  through the shepherd. This prevents a late request from signaling a process
  that reused the child PID. A closed shepherd connection returns
  `{:error, :transport_closed}`. The watcher stops after any recorded exit
  status. See ADR-5.
- **`nif_read` can no longer expose uninitialized heap.** The shrink of a
  >64 KiB read buffer now handles `enif_realloc_binary` failure with an
  alloc+copy fallback.

### Fixed

- **EINTR is retried** in the NIF `read(2)`/`write(2)` loops and shepherd
  I/O; a transient signal can no longer permanently wedge a drain loop.
- **Shepherd diagnostics surface.** A spawn-stage `MSG_ERROR` (cgroup
  failure, fork failure, …) now returns `{:error, {:shepherd_error, msg}}`
  to the caller instead of a misleading fd-count mismatch; post-spawn errors
  are logged and recorded in state.
- **Shepherd UDS writes are nonblocking** with a bounded `poll(POLLOUT)`
  deadline, so a wedged peer cannot park the shepherd after reap and skip
  cgroup cleanup.

### Changed

- **`NetRunner.Process.Nif` renamed to `NetRunner.Nif`** (internal,
  `@moduledoc false`, but referenced in tests/benches).
- **Option-validation convention unified.** Malformed options (unknown keys,
  bad values for `:stderr`, `:stderr_tail_bytes`, `:cgroup_path`, `:env`,
  `:output`, `:input_buffer`) raise `ArgumentError` at every entry point;
  runtime spawn failures keep `{:error, reason}` returns, and `stream!/2`
  uniformly wraps spawn-stage reasons as
  `%NetRunner.Error{reason: {:spawn_failed, reason}}`.
- **Wire protocol centralized** in `NetRunner.Process.Protocol` (constants,
  parser, encoders); no inline frame bytes remain in `Process`/`Exec`.
- **`Daemon.os_pid/1`** answers from cached daemon state instead of a
  blocking double GenServer hop.
- **Docs corrected**: `--token-fd` handshake (never argv), Watcher's
  deliberate single-SIGTERM/no-escalation design, Layer-3 cleanup via the
  NIF owner monitor (not GC), write-budget loop exit in `backpressure.md`;
  `Process.read/2` documents the 1 MiB cap and non-FIFO reader wakeup.
- **CI supply chain**: Dependabot now covers GitHub Actions; every workflow
  action is SHA-pinned; `.credo.exs` committed; `mix deps.unlock
  --check-unused` gate added; musl container pinned by digest; the Linux
  test job delegates `/sys/fs/cgroup/net_runner` so cgroup positive-path
  tests actually execute.

### Added

- **`NetRunner.Process.read_batch/3` and `read_stderr_batch/3`.** Read up to
  `max_chunks` pipe chunks in one GenServer round trip. A batch never waits
  once it has data (it ends at the first EAGAIN), and an EOF/error after ≥1
  chunk is deferred to the next call so collected data is always delivered
  first. `read/2` is unchanged.
- **`:input_buffer` option for `run/2` and `stream!/2`.** Bytes of stdin
  coalescing for a *lazy* `:input` enumerable. Default `0` keeps
  element-granular write-through (interactive/PTY stdin depends on it);
  `input_buffer: 65_536` batches a `File.stream!`-style line stream into
  64 KiB writes (measured 12× faster on 16 MiB of ~80-byte lines).
- **`output: :iodata` option for `run/2`.** Returns collected stdout as
  iodata, skipping the terminal `IO.iodata_to_binary/1` flatten — an extra
  full-size allocation and copy for large outputs. Default `:binary`
  unchanged; the `max_output_exceeded` partial is always a binary.

### Changed

- **Internal read batching.** `run/2`, `stream!/2`, and `Daemon` drain
  stdout/stderr via batched reads, cutting GenServer round trips per MiB
  wherever the kernel pipe holds more than one chunk (Linux's 1 MiB
  shepherd-grown pipes; on macOS the 64 KiB pipe bounds batches at ~1 chunk).
  `stream!/2` may now emit several ≤64 KiB chunks per resource step; chunk
  sizes and ordering are unchanged, but code timing-coupled to
  one-read-per-element may observe the difference.
- **Eager list `:input` is written in coalesced batches.** A list is fully
  realised, so write-through granularity is unobservable; coalescing happens
  in the caller's process before any task closure captures the list (closure
  capture of a 200k-element list alone cost ~2×20 ms). 16 MiB of ~80-byte
  list elements: 711 ms → 30 ms (1.54× a single-binary write).
- **Parked-write bookkeeping slimmed and bounded.** `Operations` dropped two
  of its four maps (the monitor ref now rides in the pending entry), and a
  multi-writer resume pass shares ONE write budget with a deduplicated
  `:continue_writes` self-send — the server's occupancy bound no longer
  multiplies by the number of parked writers.
- **`Stats.read_count`** now counts read(2) calls under batched reads (one
  count per chunk), keeping its meaning unchanged.

## [1.4.0] - 2026-08-31

Two cycles in one release. First, an audit-remediation pass over the
2026-08-31 project-health audit: security hardening of the shepherd/NIF
boundary, supervision-correctness fixes for `Daemon`/`Watcher`, API
validation, and test-suite health. Second, the measurement-driven performance
cycle below (numbers are medians on an Apple M1 Max, OTP 29 / erts 17.0.3,
`MIX_ENV=prod`; the harness is committed under `bench/`).

### Security

- **Authenticated FD channel.** The BEAM delivers a per-spawn 16-byte random
  token to the shepherd over the private fd-3 port channel (never argv —
  `/proc/<pid>/cmdline` is world-readable); the shepherd echoes it as the
  very first frame after connecting, and the BEAM verifies it (plus the peer
  uid, where the platform exposes credentials) before accepting any FDs via
  `SCM_RIGHTS`. A rejected connection no longer aborts the spawn: the BEAM
  keeps accepting until the deadline, so a rogue connect costs only itself
  rather than turning into a spawn DoS. Protocol documented in
  `docs/protocol.md`.
- **No signalling after reap, on every path.** Besides `kill/2` and the
  Watcher stand-down, the owner-DOWN path now also refuses to signal an
  `:exited` process, and the Watcher's timed SIGKILL escalation was removed
  outright — a 5-seconds-later alive?→kill from a process with no reap
  authority is a check-then-act race against OS pid reuse. Escalation is the
  shepherd's job (its POLLHUP SIGTERM→SIGKILL ladder); the Watcher keeps
  only its immediate SIGTERM probe for the shepherd-died-first case.
- **cgroup ownership guard.** The shepherd only `cgroup.kill`s and removes a
  cgroup directory it created itself; a pre-existing directory is attached to
  but never destroyed. `cgroup_path` must now sit under a `net_runner/`
  prefix and be under 256 bytes — over-length paths are rejected instead of
  silently truncated to a different cgroup.
- **Port FDs are CLOEXEC.** The shepherd marks fds 3/4 (the `:nouse_stdio`
  port channel) close-on-exec, so the child cannot inherit a handle to the
  BEAM.
- **Private UDS base directory, atomically.** The socket directory is created
  with a raw `mkdir(dir, 0700)` NIF (never observable with wider
  permissions), a pre-existing directory is never adopted, and the memoised
  path is re-verified (owner, mode, real directory) before every bind.
- **No FD leaks on spawn error paths.** FDs received via `SCM_RIGHTS` but not
  yet wrapped in NIF resources are closed on every failure path (new
  `nif_close_fd/1`), including the dup'd PTY write fd; `nif_create_fd`'s
  contract is now "on error the caller retains fd ownership", removing a
  latent double-close.
- **`io_resource_stop` marks the resource closed under its lock** before
  closing the fd, so the destructor can never close a recycled fd a second
  time.
- **No signalling after reap.** `kill/2` on an exited process returns
  `{:error, :not_running}`, and the `Watcher` stands down as soon as the exit
  status is delivered — a reused OS pid can never be signalled (found
  independently by two auditors as SEC-4/ARCH-M1).
- **`set_window_size/3` validates** rows/cols into `0..65535`
  (`{:error, :invalid_window_size}`), and `:stderr_tail_bytes` is capped at
  1 MiB.

### Added

- **`:env` option** (`run/2`, `stream!/2`, `Process.start/3`): a map of
  environment variables for the child; a binary value sets, `nil` unsets.
  PATH resolution happens before `:env` applies — pass absolute command
  paths when overriding `PATH`.
- **`stderr: :capture` for `run/2`** — returns the retained stderr tail as a
  third tuple element: `{output, exit_status, stderr}`.
- **`NetRunner.Error`** exception with the original reason in `:reason`;
  `stream!/2` raises it on spawn failure and mid-stream read errors instead
  of ad-hoc `RuntimeError`s.
- **`NetRunner.Process.shutdown/3`** — the single owner of the
  SIGTERM→await→SIGKILL escalation ladder, now used by `run/2`, `Stream`
  teardown and `Daemon.terminate/2`.

### Changed (potentially breaking for lax callers)

- **`run/2` now sets an owner monitor on its internal process**: a caller
  that dies mid-`run/2` tears down the child instead of leaking it (the
  Stream path already behaved this way).
- **`Daemon` stops on infrastructure failure too**: a crashed drain task or
  a dead stdin forwarder now stops the Daemon (`{:shutdown, :drain_crashed}`
  / `{:shutdown, :forwarder_down}`) instead of leaving a healthy-looking
  GenServer that silently stopped draining; `on_output` callbacks that
  *exit* (not just raise) are contained; and `Daemon` terminate explicitly
  stops its `NetRunner.Process` so `GenServer.stop(daemon)` leaks nothing.
- **`close_stdin/1` fails parked writers eagerly** with `{:error, :closed}`
  instead of leaving them parked until child exit.
- **`kill/3`** gained an optional call-timeout argument (default 5_000).
- **`run(cmd, pty: true, stderr: :capture)` raises `ArgumentError`** — PTY
  folds stderr into the master fd, so the captured tail would always be
  empty; rejecting beats silently returning `""`.
- **`:env` values travel as raw bytes** (`execve` semantics): non-UTF-8
  values no longer raise from inside spawn, and UTF-8 values are no longer
  transcoded to codepoints.
- **`Daemon` stops when its child exits**, with
  `{:shutdown, {:exit_status, n}}`, so `restart: :permanent` supervisors
  restart it; previously it lingered as a healthy-looking GenServer over a
  dead child. `Daemon` also traps exits so a supervisor shutdown runs the
  graceful SIGTERM→SIGKILL escalation.
- **Options are validated at every entry point** (`Keyword.validate!/2`):
  unknown or misplaced options (e.g. `:timeout` on the stream path) now raise
  `ArgumentError` instead of being silently ignored.
- **`run([])`/`stream!([])`** return `{:error, {:invalid_cmd, "empty
  command"}}` / raise `NetRunner.Error` instead of `FunctionClauseError`.
- **`:input` accepts any `Enumerable`** of iodata chunks (`File.stream!`,
  `Range`, function streams), not just binaries, lists and `%Stream{}`.
- **`Process.write/2` normalises iodata to a binary at the API boundary**;
  the NIF now accepts binaries only.
- **Stdin writes are bounded per scheduling slice**: a fast-draining child no
  longer keeps the write loop occupying the GenServer for the whole payload —
  `kill/2` and reads interleave; the write resumes from the mailbox.
- **Stats**: stderr bytes read by an external `read_stderr/2` caller now
  count in `bytes_err`, not `bytes_out`.
- The dead `:starting` state, `Pipe.owner`/`Pipe.type` fields and
  `Signal.resolve!/1` were removed.

---

The measurement-driven cycle:

### Fixed

- **`run/2` hung forever on `:input` larger than ~128 KiB.** `run_io/3` wrote
  the whole of `:input` to completion before the read loop started, so any
  filter command — `cat`, `gzip`, `jq` — filled its 64 KiB stdout pipe, blocked
  in `write(2)`, stopped draining stdin, and left us blocked filling a full
  stdin pipe. Neither side could move, and `run/2`'s default `:timeout` of
  `nil` means `:infinity`, so there was no escape. Measured: completed for
  input ≤ 131 072 bytes, hung indefinitely at ≥ 262 144. `stream!/2` was never
  affected — it has always written from a `Task`. The writer now runs
  concurrently with the reader in both entry points, sharing one
  implementation (`NetRunner.InputWriter`) so they cannot drift apart again.
  16 MiB through `cat`: `run/2` 1163 MB/s vs `stream!/2` 1130 MB/s.
  - `run/2`'s `:input` now accepts the same three shapes as `stream!/2` — a
    binary, a list of binaries, or a `Stream`. The docs previously advertised
    "binary or enumerable" while the code handled only binaries and lists.
- **`run/2` and `stream!/2` leaked a `NetRunner.Process` GenServer per call.**
  Neither hands the pid to the caller, so nothing could ever stop it; teardown
  relied on an owner monitor that only fires when the *caller* dies. A
  long-lived caller (a GenServer, a LiveView) accumulated one Process
  GenServer, one `Watcher`, a UDS socket and three pipe FDs per command, with
  no bound. Measured 100 leaked processes per 50 calls, now 0. New public
  `NetRunner.Process.stop/1`; the stream after-fun and every `run/2` exit path
  call it. This also resolves the teardown question 1.3.0 left open.
- **Exit status could be delayed up to 1 s on Linux with `--cgroup-path`.** The
  shepherd ran `cgroup_cleanup()` — which retries `rmdir` ten times with
  `usleep(100000)` between — *before* sending `MSG_CHILD_EXITED`, so a caller
  could wait a full second in `await_exit` for a status the shepherd already
  held in a local variable. The two calls are now swapped;
  nothing in `cgroup_cleanup` can change `child_status` or `uds_fd`. Ordering
  in `kill_child` is deliberately unchanged. **Not verified on Linux with a
  real cgroup** — this cycle was measured on macOS, where `cgroup_cleanup`
  returns immediately and the change is a no-op.

### Changed

- **Default read size is now 65 536, was 65 535.** One byte under pipe
  capacity leaves exactly one byte behind in a saturated pipe, and that byte
  costs a whole extra `GenServer.call` round trip. Measured on a 64 MiB stdout
  read: 1596–1826 chunks (572–802 of them ≤ 16 bytes) and 25–31 ms at 65 535,
  versus 1024 chunks (zero tiny) and 17–22 ms at 65 536 — +56–78% chunk count
  and +42% wall time for the one-byte shortfall. 65 536 is also the exact size
  of `nif_read`'s stack buffer, so it stays on the allocation-free fast path;
  see ADR-9. `Pipe.read/2`'s duplicate default was removed rather than
  updated. The win is macOS-shaped: Linux sets `F_SETPIPE_SZ` to 1 MiB, where
  the alignment argument is much weaker.
- **The stderr drain loop is bounded.** `consume_stderr/1` recursed inside
  `handle_info` for as long as the pipe kept producing. Now capped at 16 chunks
  (~1 MiB) per pass, resuming via a self-sent message, at a cost of one extra
  message per MiB. Honest scope: measured worst-case latency of a concurrent
  trivial `handle_call` under a 256 MB stderr flood was **279 µs**, not the
  "seconds of starvation" the unbounded recursion suggests — pipe capacity
  already caps what one burst can consume. It is now ~28 µs, at the idle jitter
  floor. Drain throughput is unchanged (928–969 MB/s).
- **`NetRunner.Daemon.write/2` no longer blocks the Daemon.** It called
  `NetRunner.Process.write/2` (an `:infinity` `GenServer.call`) from inside its
  own `handle_call`, so a child that stopped draining stdin wedged `os_pid/1`,
  `alive?/1` and — worst — the `Proc.alive?/1` in `terminate/2`, burning the
  supervisor's 5 000 ms shutdown budget before the SIGTERM/SIGKILL escalation
  could run. Writes are now forwarded through a single long-lived forwarder
  task, so the Daemon stays responsive, sequential writes from one caller
  stay ordered, and concurrent writers are serialised by the forwarder.
- **`Daemon` `on_output: :log` logs each drained chunk immediately.** A
  batch-across-reads scheme was tried during this cycle and reverted: a
  blocking read held already-drained bytes for as long as the child stayed
  quiet (log lines sitting unflushed for hours), and the OS pipe already
  coalesces bursts into large read chunks, so per-read `Logger` calls are
  bounded (~16/MiB at saturation). Custom `on_output` functions are
  unaffected and still see every chunk as it arrives.

### Performance

- `NetRunner.Stream` no longer polls the input writer with `Task.yield(writer,
  0)` on **every** stdout chunk. That is a selective `receive` with `after 0`,
  so its cost is O(mailbox length) per chunk: free for a bare consumer,
  pathological for a GenServer or LiveView with unrelated traffic in its
  mailbox. The writer is reaped once, in the after-fun.
- `append_stderr_tail/2`'s steady-state branch built `tail <> data` and then
  sliced it back down to the cap — ~2·cap + size bytes copied and a transient
  ~72 KiB refc binary per chunk. It now builds the result at exactly `cap` in
  one pass.
- The write and stderr-drain loops carry their byte and syscall counts as loop
  parameters and write state once on exit, instead of allocating a `Stats`
  struct and a state map per iteration (~16 iterations per 1 MiB write).

### Added

- `NetRunner.Process.stop/1` — stops the server, releasing its pipes, UDS
  socket and `Watcher` entry. Idempotent.
- `bench/` — the measurement harness, with `make bench`. Repo-only; it is not
  in the Hex package. Three of this cycle's findings are numbers rather than
  opinions only because it exists, and it demoted three static-analysis
  findings that reading the code had ranked high.

### Measured and deliberately not changed

- **Spawn latency (4.4–7.2 ms).** One `fork`+`exec` on this host costs 2532 µs
  (`System.cmd`) / 2655 µs (raw `Port`); NetRunner performs two by design and
  the second one *is* the zero-zombie guarantee, so ~5.3 ms is the floor.
  Everything addressable on the Elixir side sums to ~1% (`File.dir?/1` 35 µs,
  `:code.priv_dir` 5 µs, `Watcher.watch/2` 6.8 µs). Only shepherd pooling would
  move this, and that is a design project with real lifetime and security
  questions. See `docs/architecture.md`.
- **The per-child `Watcher` GenServer**, flagged as high-impact by static
  analysis, measures 6.8 µs; 128-way concurrent spawn runs at 846 µs/op with
  ~13% scheduler utilisation. Not a bottleneck.
- **`-flto` / `-O3`.** The NIF is a single translation unit, so `-O2` already
  inlines everything within it, and the hot path is `read(2)`/`write(2)`/
  `memcpy`. Build variance for no measurable win.

## [1.3.0] - 2026-07-28

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
- **A partially-completed write restarted from offset 0 on every readiness
  event** — `retry_write_loop/4` advanced through the payload internally but
  never wrote the remaining bytes back to the parked operation, so each
  `:ready_output` re-sent the payload from the beginning. The child received the
  same bytes over and over and the write never completed. Latent before this
  release and only reachable at particular pipe capacities; enlarging the pipes
  (below) exposed it as a hang, observed as **5.8 GB written for a 100 KB
  payload** across 707,801 writes. `Operations.update_context/3` now persists
  the remainder.
- **`arm_uds/1` could spin on a zero-byte read** — a peer at EOF is permanently
  readable, so recursing on `{:ok, <<>>}` would loop the GenServer forever and
  starve every parked caller. Only a non-empty read now earns another pass, and
  partial data delivered alongside a `:select` or an error tuple is retained
  instead of dropped.
- **`finish_exit/2` could truncate buffered output** — now that the exit status
  arrives as soon as the shepherd sends it, it can land while the child's output
  is still in the pipe. Parked readers were failed with
  `{:error, :process_exited}`, which `NetRunner.Stream` treats as a normal end
  of stream, silently losing data. Parked reads are now served from the pipe
  first; only what cannot be satisfied is failed.
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

## [1.2.2] - 2026-06-28

Bounded the stderr buffer and made `Daemon` stderr handling deterministic.

### Added

- **`NetRunner.Process.stderr_tail/1`** — returns the retained tail of consumed
  stderr, with a `:stderr_tail_bytes` option (default 8 KB) controlling how
  much is kept. Useful for diagnosing why a command failed.

### Fixed

- **Unbounded `stderr_buffer` growth in `:consume` mode** — stderr was drained
  to keep the child from blocking on a full pipe, but every chunk was retained
  for the life of the process. Retention is now capped at
  `:stderr_tail_bytes`; a cap of 0 drains and drops. Stats still count every
  byte.
- **Lost initial stderr chunk in `:consume` mode**
  — `kick_stderr_read` in `init/1` sent `{:stderr_data, data}` to
  `self()` but no `handle_info/2` clause matched, so the first (and
  often only) chunk of stderr for fast-exiting processes was silently
  dropped. The missing handler now appends to the stderr buffer and
  drains any remainder.
- **`Daemon` stderr interleaving** — the Daemon now forces
  `stderr: :disabled` on its child process so its own drain task is the sole
  reader, instead of racing the process's internal consumer for chunks.

## [1.2.1] - 2026-06-06

Follow-up review pass: stderr API surface, UDS permissions, signal
validation, and Daemon drain isolation.

### Fixed

- **UDS socket permissions** — the socket lived directly in the
  world-traversable tmp dir, so a same-host attacker who won the accept race
  against the real shepherd would receive the child's pipe FDs via
  `SCM_RIGHTS`. It now lives inside a per-spawn `0700` directory, reducing the
  threat to same-uid processes.
- **`write_loop` spin on `{:ok, 0}`** — if the kernel ever returned
  0 bytes on a non-empty write, the GenServer would recurse forever.
  The NIF now maps a zero-byte write on a non-empty buffer to
  `:eagain` and registers `enif_select` for write readiness.
- **`nif_kill` signal range** — signals outside POSIX `1..31` are rejected in
  the NIF as well as in `Signal.resolve`, mirroring `shepherd.c`'s `CMD_KILL`
  validation and bounding the blast radius of a stray call.
- **`:stderr` option validation** — reject anything other than `:consume` or
  `:disabled` at the spawn boundary rather than silently ignoring it.
- **O(1) demonitor for parked callers** — `Operations` gained an
  `op_monitors` reverse index so popping a parked operation no longer scans
  the monitor map.
- **Daemon drain isolation** — drain tasks moved to
  `Task.Supervisor.async_nolink/2` under a new `NetRunner.TaskSupervisor`, so
  a drain-task crash cannot take the Daemon down through a linked task.

## [1.2.0] - 2026-04-17

### Fixed

- **`read_uds_message` race** — replaced the `:peek` + full-recv
  pattern (which could time out if the payload arrived a moment
  after the opcode) with an opcode-first read flow and longer
  timeouts.
- **Exit status lost on a slow UDS** — on slow CI runners (notably macOS) the
  socket buffer could trail the shepherd `Port`'s `{:exit_status, _}`
  notification, so the real status was missed. `drain_uds_for_exit/2` retries
  the read instead of falling straight through to the forced timeout.

## [1.1.2] - 2026-04-17

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

## [1.1.0] - 2026-03-21

### Added

- **Command DSL** — `NetRunner.Command` for reusable command templates, with
  `defcommand` for compile-time definitions. `NetRunner.run/2` and
  `NetRunner.stream/2` accept a `%NetRunner.Command{}` in place of a
  `[cmd | args]` list.

## [1.0.4] - 2026-03-01

### Fixed

- Publish pipeline ran with the wrong `MIX_ENV`, so `ex_doc` was unavailable
  when building docs for Hex.

## [1.0.1] - 2026-03-01

### Fixed

- Security hardening and file-descriptor leak fixes across the NIF and
  shepherd.

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
