# Architecture Decision Records

## ADR-1: Shepherd Stays Alive (vs execvp-away)

**Context**: Exile's spawner binary calls `execvp()` after setting up pipes, replacing itself with the child process. This means no process watches for BEAM death.

**Decision**: NetRunner's shepherd stays alive as a watchdog. It never calls `execvp` on itself.

**Consequences**:
- (+) Detects BEAM death via UDS `POLLHUP` — guaranteed child cleanup even under `SIGKILL`
- (+) Can relay commands (kill signals, stdin close, window size) to the child
- (-) Costs one extra process per command (~100KB resident memory)
- (-) Slightly more complex C code (~950 lines vs ~200)

## ADR-2: UDS + SCM_RIGHTS (vs Named Pipes)

**Context**: Need to pass pipe file descriptors from the shepherd to the BEAM.

**Decision**: Use Unix domain sockets with `SCM_RIGHTS` ancillary data to pass FDs.

**Consequences**:
- (+) FDs passed atomically in a single `sendmsg`
- (+) UDS doubles as the command/notification channel
- (+) `POLLHUP` on UDS detects BEAM death
- (-) More complex setup than named pipes
- (-) Platform-specific: `SCM_RIGHTS` data format varies (binary vs list in OTP)

## ADR-3: NIF + enif_select (vs Port-based I/O)

**Context**: Port-based I/O (Erlang's built-in) has no backpressure — the port driver copies all data into the BEAM's mailbox immediately, potentially causing OOM.

**Decision**: Use NIF functions with `enif_select` for all I/O on pipe FDs.

**Consequences**:
- (+) Natural backpressure: reader must call `nif_read` to consume data
- (+) Integrates with BEAM's epoll/kqueue for zero-cost idle waiting
- (+) Bounded non-blocking syscalls run on normal schedulers — no dirty-scheduler handoff per chunk (see ADR-6)
- (-) NIF crashes take down the entire BEAM (mitigated by simple, well-tested C code)
- (-) More complex than Port-based approaches

## ADR-4: Pure C (vs Rust/Zig)

**Context**: The NIF and shepherd need to be compiled native code.

**Decision**: Use plain C99 with platform-specific extensions.

**Consequences**:
- (+) No additional toolchain required — `gcc`/`clang` available everywhere
- (+) Fast compilation (<1 second)
- (+) Direct access to POSIX APIs without FFI layers
- (+) ~1600 lines of C total (shepherd + NIF), easy to audit
- (-) Manual memory management (mitigated by simple allocation patterns)
- (-) No type safety beyond what C provides

## ADR-5: Watcher + Shepherd Dual Safety

**Context**: Need to guarantee no zombies under all failure modes.

**Decision**: Use both a shepherd binary (C) and a Watcher GenServer (Elixir).

**Consequences**:
- (+) Shepherd covers BEAM crash (SIGKILL, OOM, segfault)
- (+) Watcher covers GenServer crash (Elixir-level errors)
- (+) NIF destructors provide a third layer (GC-based cleanup)
- (-) Slightly redundant — both may try to kill the same process
- (-) Requires careful handling of the race (both use `kill()` which is idempotent)

## ADR-6: Normal Schedulers for All NIFs

**Context**: Originally every NIF was marked `ERL_NIF_DIRTY_JOB_IO_BOUND`, on
the theory that even a "non-blocking" read can briefly stall if the kernel has
work to do. Measurement showed the opposite trade: a dirty-scheduler handoff
costs a thread context switch, and on a host whose dirty schedulers are
contended (the BEAM starts 10 normal + 10 dirty-CPU + 10 dirty-IO threads, so a
10-core machine is oversubscribed 3:1) that handoff waits for an OS timeslice.
Measured on an Apple M1 Max: ~30 ns for a normal-scheduler NIF versus
0.5–10 ms for a dirty-IO one. A streamed chunk costs two calls (one returning
data, one returning `EAGAIN` to re-arm `enif_select`), which capped stdout
throughput at ~6 MiB/s against ~500 MiB/s for a plain `Port`.

**Decision**: Run every NIF on a normal scheduler (flags `0`).

This is sound because nothing in the NIF can block. `nif_create_fd` sets
`O_NONBLOCK` and every fd originates from `pipe()`/`pipe2()` or `openpty()`,
both of which honour it; readiness is delivered asynchronously by `enif_select`.
`kill(2)`, `dup(2)`, `fcntl(2)` and `close(2)` are all bounded.

**Consequences**:
- (+) ~280x measured stdout throughput improvement, with no VM tuning required
- (+) No dependence on dirty scheduler pool sizing (`+SDio`) or busy-wait
  settings (`+sbwt`) for acceptable performance
- (-) The non-blocking invariant is now load-bearing. `nif_create_fd` `fstat`s
  the fd and rejects anything that is not a FIFO, socket or character device: a
  regular file ignores `O_NONBLOCK` and would stall a normal scheduler. Do not
  remove that guard.
- (-) `nif_read`/`nif_write` must report the work they did via
  `enif_consume_timeslice` so a large buffer copy cannot monopolise a
  scheduler slot.

**Do not reintroduce `ERL_NIF_DIRTY_JOB_IO_BOUND` here as a safety
improvement** — it is a 2-3 order of magnitude regression and buys nothing for
calls that cannot block.

## ADR-7: Process-per-Command (vs Singleton Manager)

**Context**: erlexec uses a single port process that manages all child processes. This creates a bottleneck.

**Decision**: Each command gets its own shepherd process, pipe FDs, and GenServer.

**Consequences**:
- (+) No single bottleneck — fully parallel
- (+) Failure isolation — one command's issues don't affect others
- (+) Simple GenServer state — only tracks one child
- (-) Higher per-process overhead (one shepherd + one GenServer each)
- (-) No shared file descriptor limits management

## ADR-8: Stats in GenServer State

**Context**: Need to track I/O statistics for observability.

**Decision**: Accumulate stats as simple integer counters in the GenServer state struct.

**Consequences**:
- (+) Zero allocation cost — just integer addition on each read/write
- (+) Always available via `NetRunner.Process.stats/1`
- (+) Finalized on exit with duration and exit status
- (-) Not distributed (each GenServer has its own stats)
- (-) Lost if GenServer crashes before stats are read

## ADR-9: Default Read Size Is Exactly 65 536

**Context**: `NetRunner.Process.@default_read_size` was `65_535` — one byte
under an OS pipe buffer. A saturated pipe therefore always leaves exactly one
byte behind, and that byte costs a whole extra `GenServer.call` round trip.
Measured on a 64 MiB stdout read, two consecutive runs each:

```
max_bytes=65535: 1596 / 1826 chunks (572 / 802 of them <= 16 B), 25-31 ms
max_bytes=65536: 1024 / 1024 chunks (   0 /   0 tiny            ), 17-22 ms
```

1024 is exactly 64 MiB / 64 KiB. The shortfall costs +56–78% chunk count and
+42% wall time.

**Decision**: `@default_read_size` is `65_536`, defined once in
`NetRunner.Process`. `NetRunner.Process.Pipe.read/2` deliberately has **no**
default argument, so there is no second definition to drift.

**This constant is bounded on both sides. Do not "tidy" it.**

- It must not be **lower**: below pipe capacity it reintroduces the tiny-chunk
  remainder above.
- It must not be **higher**: `nif_read`'s fast path is
  `on_stack = max_bytes <= sizeof(stackbuf)` against
  `unsigned char stackbuf[65536]` (`c_src/net_runner_nif.c`). At 65 537 every
  read falls into `enif_alloc_binary` + `enif_realloc_binary` shrink —
  reintroducing exactly the per-call allocation cycle ADR-6's work removed, and
  giving back more than the alignment won.

**Consequences**:
- (+) One `read(2)` and one `GenServer` round trip per full pipe buffer.
- (+) Stays on the NIF's allocation-free stack path.
- (−) The win is platform-shaped. macOS has no `F_SETPIPE_SZ` equivalent and is
  inherently round-trip-bound at 64 KiB, which is where the 42% was measured.
  On Linux the shepherd sets `F_SETPIPE_SZ` to 1 MiB, so the pipe holds sixteen
  reads and the alignment argument is much weaker. A platform-conditional read
  size would genuinely fetch more per syscall on Linux, but that is a bigger
  decision and it is not this one.
- (−) `Pipe.read/2` now requires its second argument at every call site. That
  is the point.

Regression guard: `test/io_pipelining_test.exs`, "a saturated stdout read
returns full-capacity chunks". Reproduce with
`MIX_ENV=prod mix run bench/claims.exs`, section B.

## ADR-10: Set the Working Directory in the Shepherd

**Context**: Callers sometimes need to set a child working directory. NetRunner
can set it through the `Port.open` `cd:` option, in the child between `fork()`
and `exec()`, or in the shepherd before `fork()`.

**Decision**: Pass `--cwd <dir>` to the shepherd. The shepherd calls `chdir()`
after sending its token and before `fork()`.

**Consequences**:
- A failed `chdir()` returns `MSG_ERROR` with `strerror(errno)` before a child
  starts.
- `Port.open` with `cd:` cannot report this error through the shepherd.
- A child-side `chdir()` failure would look like an exit status from the child.
- The selected directory controls relative paths and relative executables.
- The shepherd also changes directory. Its later filesystem paths are absolute.
- The directory name appears in the shepherd command line, readable by any
  local user like the child's own arguments; directory names must not carry
  secrets. Moving it to the private fd-3 channel was considered and deferred:
  it would add parsing to the authentication path for a value that is
  usually as visible as the child's argv.

## ADR-11: Pass the Environment through the Port

**Context**: Callers need to change the environment that the child inherits.
NetRunner can pass these values through the shepherd command line or through
the `Port.open` `env:` option.

**Decision**: Use the `Port.open` `env:` option. Validate each name and value in
the BEAM.

**Consequences**:
- Environment values do not appear in the shepherd command line.
- The shepherd and child receive the same environment. `execvp` uses its
  `PATH` to resolve the executable.
- A port cannot set a variable to an empty value. `""` and `nil` both remove
  the variable.
- Port environment entries are character lists in the VM's native filename
  encoding (codepoints under `:utf8`, bytes under `:latin1`), so names and
  values must be valid UTF-8; the child always receives their UTF-8 bytes.
- Invalid entries raise `ArgumentError` before NetRunner starts the shepherd.
- An environment over the platform limit returns
  `{:shepherd_spawn_failed, reason}`.

## ADR-12: Filter Replacement Environments in the Shepherd, Pre-Cleared by the BEAM

**Context**: An overlay cannot remove inherited variables that the caller does
not know about. Some callers need to define the complete child environment.
Filtering only in the shepherd leaves ambient values (`RELEASE_COOKIE`, cloud
credentials) in the shepherd's own environment for the child's lifetime.
Clearing only in the BEAM, from an `:os.env/0` snapshot, races
`System.put_env/2` calls made between the snapshot and `Port.open`, and a
variable set in that window would reach the child.

**Decision**: Add `env: {:replace, environment}` with two layers. The shepherd
receives the selected names as a `--replace-env` allowlist and removes every
other variable before `fork()`; this is authoritative for the child. The BEAM
also unsets, in the `Port.open` environment, every variable from an
`:os.env/0` snapshot that the caller did not select. Untagged `env:` remains
an overlay.

**Consequences**:
- The child receives exactly the selection, independent of timing.
- The shepherd normally holds no unselected variable; one put into the BEAM
  environment during the snapshot/`Port.open` window reaches the shepherd but
  not the child.
- Values use the same port transport and validation in both modes.
- Selected names (not values) appear in the shepherd command line and count
  toward both the argument and environment size limits.
- Without `PATH`, the shepherd prevents `execvp` from using a default search
  path.
- Caller-supplied values, including `LD_PRELOAD`/`DYLD_*`, reach the shepherd
  as well as the child in both modes, so `env:` must come from trusted input.
- The BEAM-side clearing also applies to the shepherd's own exec, so loader
  variables such as `LD_LIBRARY_PATH` are gone unless selected. A shepherd
  that needs one to start (for example a dynamically linked build under Nix)
  then fails with `{:shepherd_spawn_failed, _}`; select the variable (it also
  reaches the child) or build with `SHEPHERD_STATIC=1`.

## ADR-13: Threat Model — Careless Children, Not Same-uid Adversaries

**Context**: The 1.5.0 shepherd audit (`.claude/audit/shepherd/`) showed
that a child running under the BEAM's uid can always undo NetRunner's
containment: SIGSTOP or SIGKILL its shepherd, write its own pid into another
cgroup's `cgroup.procs`, ptrace the shepherd (Yama permitting), or signal the
BEAM itself. No amount of shepherd hardening changes that; only the kernel's
uid and namespace boundaries do.

**Decision**: NetRunner contains **crashing, buggy or careless** children. It
does **not** contain an **adversarial child running under the BEAM's uid**.
Untrusted code needs a separate uid or a user+cgroup namespace. Hardening
that is cheap and local still lands where it narrows what a careless or
merely curious child can do: non-dumpable shepherd on Linux
(`PR_SET_DUMPABLE(0)`; `execve` resets it for the child), signal state reset
in the child, an opt-in `no_new_privs`.

**Consequences**:
- (+) The guarantees in the README are ones the code can actually keep.
- (+) `no_new_privs: true` is opt-in, default off: it would break legitimate
  `sudo`/`su`/`fusermount`/`newuidmap` use by children.
- (−) The cgroup teardown claim holds for cooperative descendants only; a
  child that leaves its leaf escapes `cgroup.kill`.
- (−) Debugging the shepherd with gdb/lsof needs root (non-dumpable).

## ADR-14: Sweep the Process Group Before Reaping the Leader

**Context**: The shepherd only SIGKILLed the child's group when the
**leader** outlived the SIGTERM wait (S-01): a leader that died on SIGTERM
left TERM-ignoring members running, reparented to init. A leader that simply
exited never swept its group at all (`sh -c 'sleep … & exit 0'` left an
unreachable orphan without a cgroup and a killed one with — inconsistent).
Sweeping *after* `waitpid` is unsafe: once the leader is reaped its pid, and
with it the pgid, can be reused, so `kill(-pid, …)` could hit a stranger's
group.

**Decision**: Every exit path observes the leader's exit with
`waitid(P_PID, pid, …, WEXITED | WNOWAIT)` — which leaves it a zombie — then
`kill(-pid, SIGKILL)` (direct-pid fallback), then reaps, then runs
`cgroup_cleanup`, and only then sends `MSG_CHILD_EXITED` with the leader's
real status. The teardown ladder always ends in that SIGKILL; a leader that
exits on its own gets the sweep immediately, with no grace period.

**Consequences**:
- (+) "Zero orphans" holds without cgroups, on Linux and macOS.
- (+) No pid-reuse window: a zombie leader pins its pid and pgid.
- (+) The exit frame arrives after cleanup, so a same-path respawn (Daemon
  restart) never sees a stale cgroup leaf.
- (−) **Behaviour change**: background members of the child's group are
  SIGKILLed when the child exits. A job that must outlive the command has to
  leave the group (`setsid`). SIGKILL rather than SIGTERM-then-SIGKILL is
  deliberate: the leader is already gone, and a grace period would hold the
  exit status hostage to whatever it left behind.

## ADR-15: Unconditional Exec Gate; Hand Off Before Exec

**Context**: The sync-pipe gate existed only for cgroup spawns, and even then
`'G'` was written before `send_fds`/`MSG_CHILD_STARTED`. So the command ran
before the BEAM had its fds; a hand-off failure returned `{:error, _}` after
the command's side effects (a retry ran it twice), and that failure path used
the graceful ladder. Separately, `MSG_CHILD_STARTED` could precede the
child's `setpgid`/`setsid`, so a BEAM-side `killpg` (`finish_orphaned/2`)
could get `ESRCH` against a live child — fatal on macOS, which has no
`PR_SET_PDEATHSIG`.

**Decision**: The gate is unconditional, in pipe and PTY mode. Order: fork →
child joins/creates its group, resets signals, blocks on the gate → parent
(pipe mode) `setpgid(child, child)`; PTY mode waits for the child's `'R'`
after `setsid()` → `cgroup_setup` → `send_fds` → `MSG_CHILD_STARTED` → `'G'`.
Any failure before `'G'` closes the gate (the child `_exit(127)`s without
exec), SIGKILLs and reaps it, then reports `MSG_ERROR`. On the BEAM side
`finish_orphaned/2` additionally falls back to a direct kill of the leader on
a group `ESRCH`.

**Consequences**:
- (+) A spawn that returns an error never ran the command.
- (+) The child leads its group before anyone can signal it by group.
- (+) One code path for cgroup and non-cgroup spawns.
- (−) One extra pipe and two extra context switches on every spawn's
  critical path, measured against the spawn-latency floor (Spawn Cost in
  `architecture.md`) with `MIX_ENV=prod mix run bench/perf.exs` (≥ 3 runs,
  medians; ~11% run-to-run noise).

## ADR-16: Hand a pidfd to the BEAM (Linux)

**Context**: Inside the shepherd a pid is safe to signal: the shepherd is the
parent and holds the zombie until it reaps. The BEAM has no such guarantee.
Once the shepherd is gone (or has reaped), `direct_kill` and
`finish_orphaned/2` signal a pid number that may already belong to someone
else; probe-then-kill only narrows that window.

**Decision**: On Linux the shepherd calls `pidfd_open(child, 0)` right after
`fork` and appends the pidfd as the optional last `SCM_RIGHTS` fd. The BEAM
wraps it with `nif_create_fd/2` (owner monitor closes it), signals through
`nif_pidfd_send_signal/2` whenever it would otherwise `kill(2)` the pid
directly, and closes it as soon as the exit status arrives. `ESRCH` maps to
`{:error, :not_running}`. Without a pidfd (macOS, kernels < 5.3, seccomp
denying the syscall, any `pidfd_open` failure) both sides fall back to the
old fd counts and the probe-then-kill path.

**Consequences**:
- (+) Direct kills from the BEAM are race-free on Linux, even after the
  shepherd died.
- (+) No protocol version bump: the BEAM accepts either fd count.
- (−) One more fd per running child on Linux.
- (−) A pidfd signals one process; a group-wide pidfd signal needs Linux ≥
  6.9 (`PIDFD_SIGNAL_PROCESS_GROUP`), so the orphan path still pairs it with
  `killpg`.

## ADR-17: Deferred Isolation Mechanisms

**Context**: The audit evaluated further structural options (slice F §5).

**Decision**: Not implemented; recorded so they are not re-proposed without
new information.

- **`clone3(CLONE_INTO_CGROUP)`** (Linux ≥ 5.7): atomic cgroup placement at
  creation would remove the `cgroup.procs` write and the "forked before
  migration" class. Deferred: raw syscall without a glibc wrapper, fork-like
  libc caveats, a leaf dir fd to manage — and the unconditional exec gate
  (ADR-15) already closes the escape window. Worth a prototype if cgroup
  spawn latency matters.
- **User + cgroup namespaces**: the only structural answer to a same-uid
  adversarial child (ADR-13), since `nsdelegate` turns the leaf into a real
  boundary. Deferred: unprivileged user namespaces are often restricted by
  distributions and container runtimes, the uid map is visible to the child,
  and the feature surface is large. Candidate for a future opt-in.
- **seccomp on the shepherd**: rejected. Filters survive `execve` into the
  arbitrary child, and libc/arch/sanitizer syscall variance makes a filter
  brittle.
- **`posix_spawn` instead of `fork`**: rejected. It cannot portably do
  `PR_SET_PDEATHSIG`, the exec gate or `TIOCSCTTY`, and spawn cost is
  dominated by the two `exec`s anyway (Spawn Cost in `architecture.md`).
