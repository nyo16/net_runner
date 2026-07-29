# Plan: NetRunner performance remediation

**Input**: `.claude/audit/2026-07-28-perf-regression.md` (measured investigation — the findings ARE
the research, no re-discovery agents were spawned).
**Depth**: deep — four layers (C NIF, C shepherd, Elixir process core, Elixir periphery), one
build-blocking cross-slice API, and a protocol framing change.
**Baseline to beat** (HEAD `150a84c`, this host, default `ERL_FLAGS`):

| metric | before | target (measured on throwaway patches) |
|---|---|---|
| `Proc.start` median | 152–161 ms | ≤ 25 ms |
| stdout read, 8 MiB | 6.1–6.3 MiB/s | ≥ 150 MiB/s |
| `run(["/bin/echo","hi"])` | 5101 ms, exit **137** | < 100 ms, exit **0** |
| `mix test` | 141/148, 7 failed | 148/148 |
| Daemon drain-task stack | grows ~64 KB/s, unbounded | bounded (< 1 000 words steady state) |

---

## Status of work already in flight

Two slices were dispatched before this plan was requested and have **already written to the tree**.
They are Phase 1 and Phase 4 below, kept as checked items with a verification task each, because
nothing has been compiled or tested yet.

```
 M Makefile                  ← Phase 1 (CLayer)
 M c_src/net_runner_nif.c    ← Phase 1 (CLayer)
 M c_src/shepherd.c          ← Phase 1 (CLayer)
 M lib/net_runner/daemon.ex  ← Phase 4 (Peripheral)
 M lib/net_runner/stream.ex  ← Phase 4 (Peripheral)
```

> **The tree does not compile right now.** `stream.ex` calls
> `NetRunner.Process.set_owner(pid, self())`, which does not exist yet. Phase 0 is a hard
> prerequisite for any verification.

---

## Phase 0 — Unblock the build

- [ ] **[core]** Add `NetRunner.Process.set_owner/2` — `lib/net_runner/process.ex`
  - Public `set_owner(server, owner_pid)` → `:ok`, plus a `handle_call({:set_owner, pid}, …)`.
  - Demonitor the existing `state.owner_ref` (with `[:flush]`) before monitoring the new pid, so
    repeated calls **replace** rather than stack. `Stream` calls it once per consumption on top of
    the spawn-time `:owner`.
  - Reuse the existing `:DOWN` path: `on_owner_down/1` (`process.ex:309-322`) already SIGKILLs the
    OS process and stops the GenServer.
  - Guard against `is_pid/1` and monitor-after-death (a dead pid delivers `:DOWN` immediately,
    which is correct behaviour — do not special-case it).

## Phase 1 — C layer: get off the dirty schedulers *(written, unverified)*

Audit §2 and §8. This is the single largest win: measured **6.3 → 1759 MiB/s** on stdout with
default VM flags, and `nif_is_os_pid_alive` 670 µs → 1.6 µs.

- [x] **[nif]** Flags → `0` for `nif_read`, `nif_write`, `nif_create_fd`, `nif_close`,
      `nif_dup_fd`, `nif_kill`, `nif_is_os_pid_alive`; rewrite the stale file-header comment
- [x] **[nif]** `enif_consume_timeslice` proportional to bytes moved, called after the mutex is
      released
- [x] **[nif]** Stop allocating before the read can succeed — stack buffer + exact
      `enif_alloc_binary(n)` for `max_bytes <= 64 KiB`, alloc-then-shrink above that
- [x] **[nif]** `fstat` guard in `nif_create_fd`: reject non-FIFO/socket/chardev with
      `{:error, :unsupported_fd_type}` (a regular file ignores `O_NONBLOCK` and would block a
      normal scheduler)
- [x] **[nif]** Surface previously-swallowed failures: `enif_monitor_process` →
      `{:error, :monitor_failed}`; `enif_select(STOP)` return checked in `nif_close` and
      `io_resource_down`
- [x] **[shepherd]** `kill_child` waits on `poll(signal_pipe)` against a `CLOCK_MONOTONIC`
      deadline instead of two `usleep(100000)` ladders
- [x] **[shepherd]** `signal(SIGPIPE, SIG_IGN)` in `main`
- [x] **[shepherd]** Linux-only best-effort `fcntl(F_SETPIPE_SZ, 1 MiB)` on the passed pipe ends
      (~16× fewer readiness round trips per MiB)
- [x] **[build]** `-fvisibility=hidden` in `NIF_CFLAGS`
- [ ] **Verify Phase 1**: `make clean && make all` warning-free under `-Werror`; read the diff and
      confirm (a) `res->lock` is still held across `read`/`write` + `enif_select` in both
      directions — that closes a real use-after-close race and must not be relaxed; (b) no
      Erlang-visible return shape changed beyond the three new error atoms; (c) the 64 KiB stack
      buffer is not a VLA and cannot be reached with `max_bytes > 65536`

## Phase 2 — Correct exit-status delivery (audit §3)

Root cause is proven with a probe: for a child that exits before the BEAM's `recvmsg`, the shepherd's
three stream segments coalesce and `exec.ex:316` binds `MSG_CHILD_EXITED` to `_rest` and drops it.
Evidence: `iov=11  rest=<<128,0,0,230,44, 129,0,0,0,0>>`.

- [ ] **[core]** Stop discarding the coalesced tail — `lib/net_runner/process/exec.ex`
  - `extract_child_started/2` returns `{:ok, pid, rest}`; also thread the tail through the
    `@msg_error` and `@msg_child_exited` clauses so nothing is silently dropped.
  - `read_child_started_from_socket/1` returns `{:ok, pid, <<>>}` for shape parity.
- [ ] **[core]** Carry the tail in state — `lib/net_runner/process/state.ex`
  - Add `uds_carry: <<>>` with a `@type` entry and a comment explaining that a `SOCK_STREAM` peer
    may coalesce frames, so a frame boundary is not a read boundary.
  - `setup_after_connection/7` populates it.
- [ ] **[core]** Consume the carry before the socket — `Exec.read_uds_message/1`
  - Signature becomes carry-aware (`read_uds_message(socket, carry)` → `{result, rest}`) so a
    buffered `MSG_CHILD_EXITED` or `MSG_ERROR` is parsed from the carry first and only a genuine
    shortfall touches the socket. Keep the existing opcode-first read flow for the socket path.
- [ ] **[core]** Dispatch a buffered exit at init — `lib/net_runner/process.ex`
  - In `init/1`, if the carry holds `<<0x81, status::big-32, _::binary>>`, post it to `self()` so
    `finish_exit/2` runs from `handle_info/2` (do not reshape `init/1` to call it directly).
- [ ] **[core]** Make the UDS event-driven — `lib/net_runner/process.ex`
  - Arm the socket with `:socket.recv(sock, 1, [], :nowait)` after setup and re-arm after each
    message, so the existing `handle_info({:"$socket", socket, :select, _info}, …)` clause at
    `process.ex:273` stops being dead code. Today nothing ever registers a select, which is why the
    dropped frame is unrecoverable and why mid-life `MSG_ERROR` frames are invisible
    (`process.ex:581` never runs).
  - Handle the `{:select, select_info}` / `{:ok, byte}` / `{:error, _}` triple from a `:nowait`
    recv; a `:nowait` recv that returns data immediately must be dispatched without waiting for a
    select message.
- [ ] **[core]** Demote `:force_exit_timeout` to a genuine last resort
  - Keep the 5 s timer and the synthetic `137` as a backstop, but it must no longer be the primary
    exit path. Consider shortening it now that delivery is event-driven, and log at
    `Logger.warning` when it fires so this failure mode is never silent again.
- [ ] **[core]** Simplify `drain_uds_for_exit/2` (`process.ex:550-570`)
  - The 5 × 500 ms **blocking** `:socket.recv` ladder wedges the GenServer for up to 2.5 s: no
    calls answered, no `:ready_input` serviced, no stderr drained. With event-driven delivery it is
    redundant — reduce to a single non-blocking drain of the carry plus socket, or delete it.

## Phase 3 — Recover the spawn regression (audit §4, commit `c2bbea1`)

`File.mkdir_p!` + `File.chmod!` per spawn plus two `File.rmdir` = three extra file syscalls, each a
scheduler hop. Measured `152 → 20 ms` with a VM-global directory.

- [ ] **[core]** One `0700` directory per VM — `lib/net_runner/process/exec.ex`
  - Memoise the base dir in `:persistent_term` (created on first use with `mkdir_p!` + `chmod!`),
    and put per-spawn sockets inside it. Same traversal barrier, mkdir/chmod amortised to zero.
  - Do **not** replace the directory with a `chmod` on the socket itself — that reopens a
    bind→chmod race window. Record this in the scratchpad as a rejected alternative.
  - Handle a stale `:persistent_term` entry whose directory was reaped by tmp cleaners: verify with
    `File.dir?/1` and re-create rather than crashing every spawn.
- [ ] **[core]** Drop the now-unnecessary `File.rmdir` from `cleanup_listener/2` and
      `cleanup_uds_dir/1`; keep the `File.rm` of the socket file and its `:enoent` tolerance
- [ ] **[core]** Sweep the base dir on application start — `lib/net_runner/application.ex`
      *(scope check: only if the per-VM dir can outlive the VM; otherwise skip and note why)*

## Phase 4 — Periphery: daemon and stream *(written, unverified)*

Audit §5 and §7 rows S4/S5/S7/S8.

- [x] **[daemon]** `drain_loop/3` is a real tail call again; the defensive `rescue`/`catch` moved
      into a one-call-deep `safe_read/2`. Measured before/after on an isolated 200 k-iteration
      harness: **800 060 → 57** words of stack
- [x] **[daemon]** `terminate/2` grace split into `@sigterm_grace_ms 3_000` + `@sigkill_grace_ms
      1_000` so worst case (~4.0 s) fits inside the 5 000 ms supervisor shutdown budget and the
      SIGKILL branch is reachable
- [x] **[daemon]** *(bug found in passing)* `Proc.await_exit/2` is a `GenServer.call`, so exhausting
      the grace **exits the caller** — the old function-level `catch :exit, _ -> :ok` unwound past
      the `case` and made the escalation unreachable regardless of the grace value. Wrapped in a
      private `safe_await_exit/2` returning `:timeout`
- [x] **[stream]** Early-halted streams tear down immediately: `do_read/2` returns
      `{:halt, :done}` on `:eof` / `{:error, :process_exited}`, so the after-fun can distinguish
      natural exhaustion (`:eof` → `close_stdin` + 1 000 ms grace) from a consumer bailing out
      (`:halted` → SIGTERM + 200 ms + SIGKILL). Was a flat 5 000 ms stall on
      `stream!(~w(yes)) |> Enum.take(1)`
- [x] **[stream]** Owner is re-registered from `Stream.resource`'s start-fun, which runs in the
      **consumer**, via `Proc.set_owner(pid, self())`. Previously `:owner` monitored whoever *built*
      the stream, so build-in-A/consume-in-B truncated output when A finished
- [x] **[stream]** Dead `NetRunner.Stream.AbnormalExit` deleted (never raised anywhere)
- [ ] **Verify Phase 4**: review the `:done` accumulator against `read_next/2`'s clauses — confirm
      `:done` is terminal-only and can never reach a `read_next/2` head; confirm
      `Enum.to_list/1` over a normally-exiting command yields byte-identical chunks
- [ ] **[stream]** Decide the open question the Peripheral agent flagged: neither the old nor the
      new after-fun calls `GenServer.stop/1`, so GenServer teardown after a fully-consumed stream
      still relies on the owner monitor. Either stop the server explicitly in the after-fun or
      document the reliance — do not leave it implicit

## Phase 5 — Per-chunk Elixir costs (audit §6 and §7 rows S1–S3)

These are invisible today because the dirty-scheduler hop is ~1000× larger. Once Phase 1 lands they
become the top per-chunk costs, so they must be measured *after* Phase 1, not before.

- [ ] **[core]** Fix `append_stderr_tail/2` (`process.ex:506-517`, commit `150a84c`)
  - Today: `tail <> data` then `binary_part`. Three costs — the whole ~72 KiB concat is discarded
    when `byte_size(data) >= cap`; ~129× write amplification on 64 B line-buffered chunks; and
    `binary_part` returns a **sub-binary** that pins the ~72 KiB parent, so an 8 KiB cap retains
    ~73 KiB per live process.
  - Tier 1 (do now): short-circuit `cap == 0`; when `byte_size(data) >= cap` slice `data` alone; and
    `:binary.copy/1` the result so the parent is released.
  - Tier 2 (only if a benchmark justifies it): bounded chunk deque + running size in `State`, O(1)
    push, compact every ~64 chunks, materialise lazily in `handle_call(:stderr_tail, …)` which is
    called at most once per process. **Gate on measurement — do not build tier 2 speculatively.**
- [ ] **[core]** Discriminate the ready fd (`process.ex:238`, `:244`, `:389-404`)
  - `handle_info({:select, _resource, …})` throws the resource away, so `retry_pending_reads/1`
    unconditionally calls `consume_stderr/1` — a wasted `read(2)` + `enif_select` re-arm on **every
    stdout chunk**, even with `stderr: :disabled`-style workloads that produce no stderr at all.
  - `Pipe` already carries `resource` (`pipe.ex:6`) — match it and dispatch to the right pipe. This
    also removes one of the two `pending_by_type` scans per event.
- [ ] **[core]** Stop scanning the pending map twice per readiness event
      (`operations.ex:80-82`, called from `process.ex:390-391` and `:440`)
  - Early-return when `map_size(pending) == 0` (the overwhelmingly common case), and replace the two
    `Enum.filter`s plus `pending ++ stderr_pending` with a single `Enum.reduce`.
- [ ] **[core]** Refcount the parked-caller monitor (`operations.ex:25`, commit `f75659f`)
  - One `Process.monitor` + `demonitor` pair per read that hits `EAGAIN` — i.e. roughly per chunk —
    for what is normally a single long-lived consumer. Key by caller pid
    (`%{pid => {mref, count}}`): park increments, pop decrements, demonitor at zero.
  - Side benefit: `pop_by_monitor/2` can then reclaim **all** of a dead caller's ops, which is more
    correct than today's one-op-per-`:DOWN`.

## Phase 6 — Tests

The 7 current failures are all the exit-status bug or timing flakes; Phases 1–3 should clear them.
Each new test must defend an observable contract and fail on a plausible regression.

- [ ] **[test]** Coalesced-frame regression — a fast-exiting child returns its **real** status
      quickly: `run(["/bin/echo","hi"]) == {"hi\n", 0}` and `run(["/bin/sh","-c","exit 3"])` gives
      `3`, both well under 1 s. This is the test that would have caught audit §3
- [ ] **[test]** `MSG_ERROR` from the shepherd is observed mid-life (proves the `:nowait` arming
      works and `process.ex:273` is live)
- [ ] **[test]** `nif_create_fd` rejects a regular-file fd with `{:error, :unsupported_fd_type}`
- [ ] **[test]** Early-halted stream tears down in well under 1 s and kills the OS process
      (`stream!(~w(yes)) |> Enum.take(1)`)
- [ ] **[test]** Daemon drain-task stack stays bounded across a large volume of output
      (assert `Process.info(task, :stack_size)` does not grow monotonically) — the regression guard
      for audit §5
- [ ] **[test]** `stderr_tail` retains exactly the last `stderr_tail_bytes` and `stderr_tail_bytes:
      0` retains nothing while still draining (child never blocks)
- [ ] **[test]** `set_owner/2` replaces rather than stacks: after re-registering, the death of the
      *original* owner must NOT kill the process; the death of the new owner must
- [ ] **[test]** Existing `test/cgroup_test.exs` and `test/pty_test.exs` still pass — the `fstat`
      guard must accept a pty master (`S_ISCHR`) and the `F_SETPIPE_SZ` change must not alter
      semantics

## Phase 7 — Verification gate

- [ ] `make clean && make all` — no warnings under `-Wall -Wextra -Werror`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix format --check-formatted`
- [ ] `mix credo`
- [ ] `mix test` — 148/148
- [ ] `mix dialyzer` — the `Exec` return-shape changes (`{:ok, pid}` → `{:ok, pid, rest}`,
      carry-aware `read_uds_message`) are exactly what Dialyzer catches
- [ ] `make clean && SANITIZE=1 make all && mix test` — ASan/UBSan, since Phase 1 touched the fd
      lifecycle and the shepherd's wait path. CI's `sanitizers` job gates publish
- [ ] Re-run the audit benchmarks and record before/after in `.claude/audit/`: spawn median, stdout
      MiB/s, `run(["/bin/echo","hi"])` latency + status, Daemon drain stack growth
- [ ] Confirm the numbers hold with **default** `ERL_FLAGS` — the whole point is that users must not
      need `+sbwt none`

## Phase 8 — Docs

- [ ] **[docs]** `CHANGELOG.md` — new `Unreleased` section. The existing entry is already stale
      (it claims `write_loop` was "bounded with a 1 ms sleep-retry", but HEAD maps `{:ok, 0}` to
      `:eagain` in the NIF instead); fix that line while you are there
- [ ] **[docs]** `README.md` performance section — replace any dirty-scheduler claim with the real
      invariant (bounded non-blocking syscalls on normal schedulers, readiness via `enif_select`),
      and publish measured throughput
- [ ] **[docs]** `docs/decisions.md` — record the scheduler decision and its measurement, so nobody
      "restores" `ERL_NIF_DIRTY_JOB_IO_BOUND` as a safety improvement later
- [ ] **[docs]** `docs/protocol.md` — state explicitly that the UDS is a byte stream and frames may
      coalesce, so readers must carry partial/extra bytes (the shepherd side already learned this
      in `f75659f`; the BEAM side did not)

---

## Explicitly deferred (not in this plan)

- **Watcher supervisor partitioning** (audit §7 row S6). `Watcher.watch/2` is a blocking
  `DynamicSupervisor.start_child` from `Process.init/1` — a global serialization point worth
  ~20–50 µs of exclusive supervisor time per spawn. Against a ~20 ms spawn that is <0.3%. It is a
  scaling cliff (~20–50 k spawns/s), not a current bottleneck. Revisit only with a benchmark that
  hits it. Do **not** "fix" it by collapsing Watchers into one GenServer — that makes the
  serialization worse.
- **`+sbwt none` VM tuning.** A real 11–41× effect on this host, but a library cannot ship VM flags.
  Mention it in the README as an operator note only; Phase 1 removes the need for it.
- **`cgroup_cleanup`'s rmdir polling** (`shepherd.c:255-262`). Linux-only, teardown-only, already
  bounded at ~1 s.
- **Batched read API** (`{:read_many, n}`) to amortise the per-chunk `GenServer.call`. Inherent to
  the current design; revisit only if profiling after Phase 1 shows message passing dominating.
- **Wiring up `AbnormalExit`** so `stream!/2` raises on a non-zero exit. That is a deliberate
  behaviour change and needs its own decision, not a perf pass.

## Risks

**What is most likely to break?** Phase 2. It changes `Exec`'s return shapes, adds a state field,
and makes a previously-dead `handle_info` clause live. `:socket`'s `:nowait` API has three distinct
return shapes and the `{:"$socket", …}` message must be matched before the catch-all at
`process.ex:305`. A mistake here does not fail loudly — it degrades to the *current* behaviour
(5 s timeout, status 137), which is exactly what the Phase 6 fast-child test exists to catch.

**What is the riskiest assumption?** That `read`/`write` on these fds can never block a normal
scheduler. It rests on every fd being an `O_NONBLOCK` pipe or pty master. Phase 1's `fstat` guard
turns that from a comment into an enforced precondition, which is why it is not optional. If a
regular-file fd ever reached `nif_create_fd`, the symptom would be a stalled scheduler, not an
error — the guard is the difference between a rejected call and a wedged VM.

**What did the measurement *not* cover?** Everything was measured on one host: macOS 25.5,
Apple M1 Max (10 cores), OTP 29 / erts 17.0.3. The dirty-hop cost is inflated there by
30 busy-waiting scheduler threads on 10 cores; on a Linux CI runner with fewer cores the *absolute*
gain will be smaller. The direction is not in doubt (a dirty hop can never be cheaper than no hop),
but the headline "280×" is host-specific and must not be published as a general number. Re-measure
on Linux before it goes in the README.

## Notes

- Scratchpad: `.claude/plans/perf-remediation/scratchpad.md` (decisions, rejected alternatives,
  dead ends).
- Phase ordering is load-bearing: Phase 0 unblocks the build, Phase 1 is the only change big enough
  to move the headline numbers, and Phase 5 is unmeasurable until Phase 1 lands.
- Slice boundaries (`c_src/` · `daemon.ex`+`stream.ex` · `process*.ex`) are disjoint by file and can
  be parallelised again, but Phase 0's `set_owner/2` and Phase 2's `Exec` shape changes are shared
  contracts and must be settled before any fan-out.
