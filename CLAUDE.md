# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
mix deps.get              # Fetch dependencies
mix compile               # Compile Elixir + C code (via elixir_make)
mix test                  # Run full test suite (~250 tests)
mix test test/process_test.exs          # Run a single test file
mix test test/process_test.exs:10       # Run a single test at line
mix format                # Auto-format code
mix format --check-formatted            # Check formatting (CI)
mix compile --warnings-as-errors        # Compile with strict warnings
mix credo --strict        # Lint with credo
mix dialyzer              # Static type analysis
make clean && make all    # Rebuild C code only, into _build/$MIX_ENV/lib/net_runner/priv (MIX_ENV defaults to dev)
```

## Architecture

NetRunner is a safe OS process execution library for Elixir with NIF-based backpressure, zero zombie guarantees, PTY support, and cgroup isolation.

### Three-Tier Design

**Elixir Layer** (`lib/`) — GenServer-based process management, stream API, daemon mode.

**NIF Layer** (`c_src/net_runner_nif.c`) — Wraps FDs in NIF resources with `enif_select` for async I/O. All NIFs run on normal schedulers (flags 0; every syscall is bounded non-blocking — ADR-6). On EAGAIN, registers with BEAM's epoll/kqueue; the GenServer parks callers in an operations queue and retries when `{:select, _, _, :ready_input/:ready_output}` arrives.

**Shepherd Layer** (`c_src/shepherd.c`) — Persistent C binary spawned per command via `Port.open`. Forks the child, passes pipe FDs to BEAM via SCM_RIGHTS over a UDS socket, then enters a `poll()` loop. Detects BEAM death via POLLHUP and escalates SIGTERM→SIGKILL on the child's process group.

### Zero Zombie Prevention (4 mechanisms)

1. **Shepherd** — `PR_SET_PDEATHSIG` (Linux) plus BEAM-death detection (POLLHUP on UDS), then a SIGTERM→SIGKILL ladder on the child's process group
2. **`Process` orphan kill** — `kill_orphan/2` on GenServer termination: shepherd/group SIGKILL plus a pidfd signal to the leader where a pidfd exists; never kills by pid number
3. **Watcher GenServer** — monitors the Process GenServer; on DOWN sends a single SIGTERM probe by pid number (ADR-16 residual); escalation is the shepherd's job
4. **NIF owner monitor** — `io_resource_down` closes FDs when the owning process dies (the destructor only runs for resources with no live `enif_select`)

### Spawn Sequence

1. BEAM creates a UDS listener at a random private temp path and a random 32-hex token
2. `Port.open` (`:nouse_stdio`) launches shepherd with the UDS path as argv[1] and `--token-fd`; BEAM writes the token over fd 3
3. Shepherd connects and echoes the token as the first frame (BEAM rejects unauthenticated connects)
4. Shepherd forks the child, which blocks on the exec gate; shepherd sends pipe FDs (plus a Linux pidfd when `pidfd_open` succeeds) via SCM_RIGHTS, then `MSG_CHILD_STARTED(pid)`
5. Shepherd writes `'G'` to the exec gate; only then does the child `execvp`
6. GenServer wraps FDs (and pidfd) in NIF resources, registers with Watcher

### Key Module Relationships

- `NetRunner` — top-level API (`run/2`, `stream!/2`, `stream/2`)
- `NetRunner.Process` — GenServer owning the OS process lifecycle
- `NetRunner.Process.Exec` — spawn mechanics (UDS listener, Port, token auth, SCM_RIGHTS, Pipe creation)
- `NetRunner.Process.Options` — spawn-option contract: key list, validation, env/cgroup normalisation, `default_kill_timeout/0`
- `NetRunner.Nif` — NIF stubs (`nif_read`, `nif_write`, `nif_close`, `nif_create_fd`, `nif_kill`, `nif_kill_group`, `nif_pidfd_send_signal`, …)
- `NetRunner.Process.Protocol` — shepherd wire format: frame constants, parser, command encoders, shepherd argv grammar, fd layout
- `NetRunner.Process.Cgroup` — BEAM-side cgroup leaf removal when the shepherd dies without cleaning up
- `NetRunner.Process.Pipe` — thin struct around a NIF FD resource
- `NetRunner.Process.Operations` — pending operation queue (park on EAGAIN, retry on select)
- `NetRunner.Stream` — `Stream.resource` wrapper with concurrent input writer Task
- `NetRunner.Daemon` — supervised long-running process with output draining
- `NetRunner.Watcher` — belt-and-suspenders process monitor
- `NetRunner.InputWriter` — internal; owns the `:input` writer Task lifecycle for `run/2` and `Stream`
- `NetRunner.Command` — reusable command templates with default args/options
- `NetRunner.Error` — exception raised by the bang variants
- `NetRunner.Process.Stats` — I/O and lifecycle stats returned by `NetRunner.Process.stats/1`
- `NetRunner.Signal` — internal; signal atom to platform number resolution via NIF

### Shepherd Protocol (`c_src/protocol.h`)

BEAM→Shepherd: `CMD_KILL(signal)`, `CMD_CLOSE_STDIN`, `CMD_SET_WINSIZE(rows,cols)`
Shepherd→BEAM: `MSG_CHILD_STARTED(pid)`, `MSG_CHILD_EXITED(status)`, `MSG_ERROR(msg)`

## C Code

- C99, compiled with `-Wall -Wextra -Wformat-security -Wvla -Wshadow`; `-Werror` is opt-in via `WERROR=1` (CI sets it)
- Platform detection in Makefile: `-D_GNU_SOURCE` (Linux) or `-D_DARWIN_C_SOURCE` (macOS)
- Two build artifacts in `$MIX_APP_PATH/priv` (`_build/<env>/lib/net_runner/priv`, what `:code.priv_dir(:net_runner)` resolves to): `shepherd` (executable) and `net_runner_nif.so` (shared lib). There is no top-level `priv/`
- NIF functions run on normal schedulers (no dirty flags, ADR-6); every syscall they reach is bounded

## Conventions

- Elixir ≥ 1.17, OTP ≥ 27; CI matrix: Elixir/OTP 1.17.3/27.2, 1.18.3/27.2, 1.19.7/28.3.3, 1.20.2/28.3.3, 1.20.2/29.0 (plus a `--cover` leg) on ubuntu x86, 1.20.2/29.0 on ubuntu arm and macOS, plus Alpine (musl, OTP 27) and ASan/UBSan legs
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

## Third-Party Contributions (maintainer policy)

- **Respect the contributor's PR.** Never cherry-pick, copy, or
  re-implement a third-party PR's work in our own commits. Review it,
  then either merge their PR or request specific changes / a rebase from
  the author. If master already covers it, say so on the PR and ask the
  author how they want to proceed.
- **Trust nothing: every third-party PR gets a security check** before
  any recommendation to merge, assuming the author could be malicious or
  compromised: build-time execution (Makefile/mix.exs), CI/workflow and
  publish-job changes, C memory safety, auth/handshake, signal/pid
  routing, env/secret leakage, hidden Unicode, per-commit provenance.
  Dependency bumps (Dependabot included) get the `deps-audit` check.
- **Never build or run third-party PR code on the host.** Static review
  first; anything that must execute runs in a disposable container.
