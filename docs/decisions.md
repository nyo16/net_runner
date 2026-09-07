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

**Context**: The shepherd handles BEAM failure. The watcher handles Process
GenServer failure. Both can outlive the child. The kernel can reuse a numeric
PID after the parent reaps it.

**Decision**: Send normal kill requests only through the shepherd. The watcher
sends one direct SIGTERM only when the Process GenServer dies and the shepherd
stops. Stop the watcher after any recorded exit status.

**Consequences**:
- The shepherd covers BEAM failure and owns normal signaling.
- The watcher covers a Process GenServer failure after the shepherd stops.
- A watcher probe still uses a numeric PID. A stable process handle would
  remove this remaining race.
- A synthetic exit status can leave an orphan alive. Later use of its PID could
  signal an unrelated process.
- `kill/2` reports request transport, not signal delivery.

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
