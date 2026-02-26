# Architecture Decision Records

## ADR-1: Shepherd Stays Alive (vs execvp-away)

**Context**: Exile's spawner binary calls `execvp()` after setting up pipes, replacing itself with the child process. This means no process watches for BEAM death.

**Decision**: NetRunner's shepherd stays alive as a watchdog. It never calls `execvp` on itself.

**Consequences**:
- (+) Detects BEAM death via UDS `POLLHUP` — guaranteed child cleanup even under `SIGKILL`
- (+) Can relay commands (kill signals, stdin close, window size) to the child
- (-) Costs one extra process per command (~100KB resident memory)
- (-) Slightly more complex C code (~500 lines vs ~200)

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
- (+) Dirty IO schedulers prevent BEAM scheduler stalls
- (-) NIF crashes take down the entire BEAM (mitigated by simple, well-tested C code)
- (-) More complex than Port-based approaches

## ADR-4: Pure C (vs Rust/Zig)

**Context**: The NIF and shepherd need to be compiled native code.

**Decision**: Use plain C99 with platform-specific extensions.

**Consequences**:
- (+) No additional toolchain required — `gcc`/`clang` available everywhere
- (+) Fast compilation (<1 second)
- (+) Direct access to POSIX APIs without FFI layers
- (+) ~850 lines total, easy to audit
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

## ADR-6: Dirty IO Schedulers for All NIFs

**Context**: Even "non-blocking" reads can briefly stall if the kernel has work to do.

**Decision**: Mark all NIF functions as `ERL_NIF_DIRTY_JOB_IO_BOUND`.

**Consequences**:
- (+) Never blocks BEAM's normal schedulers
- (+) 10 dirty IO threads by default, configurable via `+SDio`
- (-) Slightly higher latency (thread context switch to dirty scheduler)
- (-) Limited by dirty scheduler pool size under extreme concurrency

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
- (+) Always available via `Process.stats/1`
- (+) Finalized on exit with duration and exit status
- (-) Not distributed (each GenServer has its own stats)
- (-) Lost if GenServer crashes before stats are read
