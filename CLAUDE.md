# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
mix deps.get              # Fetch dependencies
mix compile               # Compile Elixir + C code (via elixir_make)
mix test                  # Run full test suite (47 tests)
mix test test/process_test.exs          # Run a single test file
mix test test/process_test.exs:10       # Run a single test at line
mix format                # Auto-format code
mix format --check-formatted            # Check formatting (CI)
mix compile --warnings-as-errors        # Compile with strict warnings
mix credo --strict        # Lint with credo
mix dialyzer              # Static type analysis
make clean && make all    # Rebuild C code only
```

## Architecture

NetRunner is a safe OS process execution library for Elixir with NIF-based backpressure, zero zombie guarantees, PTY support, and cgroup isolation.

### Three-Tier Design

**Elixir Layer** (`lib/`) — GenServer-based process management, stream API, daemon mode.

**NIF Layer** (`c_src/net_runner_nif.c`) — Wraps FDs in NIF resources with `enif_select` for async I/O on dirty IO schedulers. On EAGAIN, registers with BEAM's epoll/kqueue; the GenServer parks callers in an operations queue and retries when `{:select, _, _, :ready_input/:ready_output}` arrives.

**Shepherd Layer** (`c_src/shepherd.c`) — Persistent C binary spawned per command via `Port.open`. Forks the child, passes pipe FDs to BEAM via SCM_RIGHTS over a UDS socket, then enters a `poll()` loop. Detects BEAM death via POLLHUP and escalates SIGTERM→SIGKILL on the child's process group.

### Zero Zombie Prevention (3 layers)

1. **Shepherd** — detects BEAM death (POLLHUP on UDS), kills child process group
2. **Watcher GenServer** — monitors Process GenServer, kills OS process on DOWN
3. **NIF destructor** — closes FDs on garbage collection

### Spawn Sequence

1. BEAM creates UDS listener at random temp path
2. `Port.open` launches shepherd with UDS path as argv[1]
3. Shepherd connects, forks child, sends pipe FDs via SCM_RIGHTS
4. Shepherd sends `MSG_CHILD_STARTED(pid)` over UDS
5. GenServer wraps FDs in NIF resources, registers with Watcher

### Key Module Relationships

- `NetRunner` — top-level API (`run/2`, `stream!/2`, `stream/2`)
- `NetRunner.Process` — GenServer owning the OS process lifecycle
- `NetRunner.Process.Exec` — spawn logic (UDS, Port, SCM_RIGHTS, Pipe creation)
- `NetRunner.Process.Nif` — NIF stubs (`nif_read`, `nif_write`, `nif_close`, `nif_create_fd`, `nif_kill`)
- `NetRunner.Process.Pipe` — struct wrapping a NIF resource with owner/type metadata
- `NetRunner.Process.Operations` — pending operation queue (park on EAGAIN, retry on select)
- `NetRunner.Stream` — `Stream.resource` wrapper with concurrent input writer Task
- `NetRunner.Daemon` — supervised long-running process with output draining
- `NetRunner.Watcher` — belt-and-suspenders process monitor
- `NetRunner.Signal` — signal atom to platform number resolution via NIF

### Shepherd Protocol (`c_src/protocol.h`)

BEAM→Shepherd: `CMD_KILL(signal)`, `CMD_CLOSE_STDIN`, `CMD_SET_WINSIZE(rows,cols)`
Shepherd→BEAM: `MSG_CHILD_STARTED(pid)`, `MSG_CHILD_EXITED(status)`, `MSG_ERROR(msg)`

## C Code

- C99, compiled with `-Wall -Wextra -Werror`
- Platform detection in Makefile: `-D_GNU_SOURCE` (Linux) or `-D_DARWIN_C_SOURCE` (macOS)
- Two build artifacts: `priv/shepherd` (executable) and `priv/net_runner_nif.so` (shared lib)
- NIF functions run on dirty IO schedulers to avoid blocking BEAM

## Conventions

- Elixir ~> 1.17, CI tests against 1.17 and 1.18 on OTP 27
- All public API functions have `@doc` and `@spec`
- Tests are async where possible (`async: true`)
- Credo strict mode enforced: max cyclomatic complexity 9, max nesting depth 2

## Performance Rules (learned; details in `.claude/solutions/`)

- **Never hand a large list/map to another process raw.** `Task.async`
  closures and messages copy the whole structure into the receiving heap
  (~20 ms per boundary for a 200k-cons list, and the refc bump per binary
  is paid per element). Reduce to a few flat refc binaries in the sender
  first — binaries cross process boundaries for free. See
  `InputWriter.prepare/1` for the pattern; bisect suspect cases by running
  the same code inline vs spawned.
- **Verify achievable batch size before batching syscalls/messages.** The
  cap is `pipe_capacity / read_size`: macOS pipes (64 KiB = read size)
  yield 1-chunk batches, Linux (1 MiB shepherd-grown) up to 16. Instrument
  with a batch-size histogram probe before trusting a message-count
  projection, and bench on the platform the optimization targets.
- **Bench discipline**: `MIX_ENV=prod mix run bench/perf.exs`, ≥3 runs,
  compare medians, ~11% run-to-run spread is the noise floor; measure
  BEFORE a fix lands so the gain is measured, not asserted; A/B on the
  same machine state when a gate reads ambiguous. `@default_read_size`
  and scheduler placement are benchmark-pinned DO-NOT-REOPEN
  (`docs/decisions.md`).
