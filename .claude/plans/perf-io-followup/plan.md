# Plan: NetRunner I/O pipelining and read-sizing follow-up

**Input**: `/phx:perf` session of 2026-07-28 (measured — the findings ARE the research; no
re-discovery agents were spawned, per Iron Law #7). Harness written during that session lives in
`bench/`.

**Relationship to prior work**: `.claude/plans/perf-remediation/plan.md` (input
`.claude/audit/2026-07-28-perf-regression.md`) is **complete and shipped as v1.3.0** — normal-scheduler
NIFs, `uds_carry` framing, `arm_uds`, per-VM `:persistent_term` UDS dir, `set_owner/2`,
`-fvisibility=hidden` are all in the tree and confirmed by reading HEAD. This is a **second cycle**
against the code that plan produced. Nothing here reverts it; two items below explicitly supersede
deferrals it made.

**Depth**: deep — four layers (C shepherd, Elixir process core, Elixir periphery, harness), one
liveness bug, and a measurement discipline that must survive the change.

**Baseline** (this host: macOS 25.5, Apple M1 Max 10 cores, OTP 29 / erts 17.0.3, `MIX_ENV=prod`,
default `ERL_FLAGS`):

| metric | before | target |
|---|---|---|
| `run(~w(cat), input: 256 KiB)` | **hangs forever** | completes, ≥ 500 MB/s |
| `run/2` 128 KiB through `cat` | 18.2 MB/s | ≥ 500 MB/s |
| 64 MiB stdout read, `max_bytes` default | 1773 chunks / 31 ms | 1024 chunks / ≤ 20 ms |
| worst `handle_call` latency under 256 MB stderr flood | 279 µs | ≤ 100 µs |
| exit-status delivery, Linux + `--cgroup-path` | up to **1000 ms** | ≤ 5 ms |
| `mix test` | must stay green | green |

**Measured and deliberately NOT targeted**: sequential spawn latency (4.4–7.2 ms). One fork+exec on
this host costs 2532 µs (`System.cmd`) / 2655 µs (raw `Port`); NetRunner performs two by design, so
~5.3 ms is the floor. The second exec *is* the zero-zombie guarantee. See Deferred.

---

## Iron Laws for this plan

1. **One change at a time.** Every phase has its own bench command and its own measurement. Do not
   batch two phases and attribute the delta to either.
2. **`MIX_ENV=prod` for every number.** The C layer compiles identically in dev and prod, but the
   BEAM side does not.
3. **Re-measure on Linux before publishing any figure.** Every number above is one host. Phase 3 is
   Linux-only and cannot be verified on this machine at all.

---

## Phase 0 — Make the evidence permanent

The `bench/` harness is currently untracked scaffolding. It is the only reason findings 1, 3 and 5
are numbers instead of opinions, and every later phase needs it to prove its own delta.

- [x] **[bench]** Decide the harness's home and commit it — `bench/` — stays at `bench/`, five
      probes plus `README.md`; `mix.exs` `files:` untouched so it is repo-only. Not yet
      `git add`ed — that is the commit step.
  - Files: `perf.exs` (spawn / throughput / concurrency sweep), `claims.exs` (starvation +
    read-size chunk counts), `deadlock_probe.exs` (input-size threshold), `spawn_breakdown.exs`
    (phase attribution), `exec_baseline.exs` (`System.cmd` vs raw `Port` vs NetRunner).
  - Add `bench/README.md`: how to run, what each probe proves, and the M5 warning from the previous
    scratchpad (timing variance on this host is brutal — medians over interleaved rounds, never a
    single round).
  - Decide whether `bench/` ships in the Hex package. Recommendation: **no** — leave `files:` in
    `mix.exs` untouched so it stays a repo-only tool.
- [x] **[bench]** Add a `make bench` / `mix run` alias documented in `Makefile` so the numbers are
      reproducible without archaeology — `make bench` runs all five in order; `bench-perf`,
      `bench-claims`, `bench-deadlock`, `bench-spawn`, `bench-exec` run one each. All force
      `MIX_ENV=prod`.

## Phase 1 — `run/2` deadlocks on `:input` > ~128 KiB *(liveness — do first)*

**Measured**: `run(~w(cat), input: n)` completes for n ≤ 131 072 and **hangs indefinitely** for
n ≥ 262 144. `stream!/2` completes at every size. Found by `bench/perf.exs` wedging for 900 s.

Root cause: `run_io/3` (`lib/net_runner.ex:213-228`) calls `write_all_input/2` to *completion* before
`read_all_with_limits/2` starts. `cat` fills its 64 KiB stdout pipe, blocks in `write`, therefore
stops draining stdin; we block writing a full 64 KiB stdin pipe. Neither side can move. Default
`:timeout` is `nil` → `:infinity`, so there is no escape.

- [x] **[core]** Overlap the writer with the reader — `lib/net_runner.ex` — writer and reap both
      moved to a new `NetRunner.InputWriter` (`@moduledoc false`) used by `run_io/3` *and*
      `NetRunner.Stream`, so there is exactly one convention. `:input` now accepts binary / list /
      `%Stream{}` in both, and `run/2`'s `@doc` says so.
  - In `run_io/3`, start the input writer as a `Task` and run the read loop concurrently, then join
    the writer. `NetRunner.Stream.start_writer/2` (`stream.ex:84-119`) already has the correct
    shape for all three input kinds (binary, list, enumerable/`%Stream{}`) — mirror it rather than
    inventing a second convention.
  - `write_all_input/2` currently handles only binary and list. `run/2`'s `@doc` advertises
    "binary or enumerable"; `stream!/2` accepts `%Stream{}`. Decide and document: either accept the
    same three kinds as `Stream` or narrow the docs. Do not leave the two entry points disagreeing.
  - A writer crash must not be silently swallowed. `Task.async` links, so an abnormal writer exit
    already propagates; make sure the `max_output_size` early-return path (`net_runner.ex:195-200`)
    still shuts the writer down instead of leaking it.
  - `close_stdin` must happen exactly once, after the last chunk, on every path including
    early-halt.
- [x] **[core]** Audit the sibling paths for the same shape — `InputWriter.reap/2` takes `:done`
      (join with a 5 s grace, then `Task.shutdown(:brutal_kill)`) or `:halted` (kill outright, no
      wait — the child is being SIGTERM'd anyway). The `Task.shutdown` in `run_with_pid/4` already
      covers the timeout branch: the run_io task is not trapping exits, so its `:shutdown` exit
      propagates over the link and kills the writer.
  - `kill_and_cleanup/1` (`net_runner.ex:230-239`) and the `Task.shutdown` path in
    `run_with_pid/4` (`:98`) now race a live writer task as well as the reader. Confirm the writer
    is torn down on the timeout and `max_output_exceeded` branches.
- [x] **Verify Phase 1**: all six sizes `OK` for `run/2` (was OK/OK/OK/HUNG/HUNG/HUNG); 16 MiB
      `run/2` 1002–1163 MB/s vs `stream!/2` 1074–1130 MB/s — within 1.1x, not 2x. `{:error,
      :timeout}` confirmed both when the writer has finished and when it is still parked on a full
      stdin pipe. The plan's "128 KiB ≥ 500 MB/s" row was dropped as arithmetically unreachable
      (that row spans one ~5 ms spawn); `bench/perf.exs` now carries a comparable 16 MiB `run/2`
      row instead. See `.claude/audit/2026-07-29-io-pipelining.md`.

## Phase 2 — `@default_read_size` is one byte under pipe capacity

**Measured**, 64 MiB of stdout, two consecutive runs:

```
max_bytes=65535: 1596 chunks (572 of <=16 B), 26 ms   |  1773 chunks (749 tiny), 31 ms
max_bytes=65536: 1024 chunks (  0 of <=16 B), 22 ms   |  1024 chunks (  0 tiny), 18 ms
```

1024 chunks is exactly 64 MiB / 64 KiB. At 65 535 a saturated pipe leaves exactly 1 byte behind, and
that byte costs a full extra `GenServer.call` round trip: +56–73% chunk count, **+42% wall time**.

- [x] **[core]** Change the default to `65_536` and collapse the duplicate — `Pipe.read/2`'s
      default argument was **removed** rather than pointed at the other constant, so there is no
      second definition left to drift. `@default_read_size` in `NetRunner.Process` is the only one.
  - `lib/net_runner/process.ex:27` (`@default_read_size`) and
    `lib/net_runner/process/pipe.ex:32` (`Pipe.read/2`'s own `\\ 65_535`) are two independent
    definitions of the same constant that can drift. One source of truth; the other references it.
  - **Verified safe**: `nif_read`'s fast path is `on_stack = max_bytes <= sizeof(stackbuf)` with
    `unsigned char stackbuf[65536]` (`c_src/net_runner_nif.c:283-286`), so 65 536 still takes the
    stack path. It does **not** cross into the alloc-then-shrink branch. Do not "round up" further:
    65 537 would.
  - This is the one change on Linux that partly overlaps the existing `F_SETPIPE_SZ 1 MiB` tuning
    (`shepherd.c:790-792`) — there the pipe is 1 MiB, so the alignment win is smaller. macOS has no
    `F_SETPIPE_SZ` equivalent and is inherently round-trip-bound at 64 KiB, which is exactly why
    this matters most there.
- [x] **Verify Phase 2**: 1024 chunks / 0 tiny / 18–19 ms at 65 536, every one of five rounds,
      against 1773–1834 chunks / 749–810 tiny / 26–31 ms at 65 535. Read throughput 2120 MB/s
      (`run/2`) and 2712 MB/s (`stream!/2`), above baseline.

## Phase 3 — Exit status delayed up to 1 s on Linux + cgroups

**Read in source, not measurable on this host.** `c_src/shepherd.c:534-538`:

```c
/* Cleanup cgroup on normal exit too */
cgroup_cleanup();          /* :535 — up to 10 x usleep(100000) = 1000 ms */
/* Notify BEAM of child exit */
send_child_exited(uds_fd, child_status);   /* :538 */
```

`cgroup_cleanup` (`:256-262`) retries `rmdir` ten times with `usleep(100000)` between. With
`--cgroup-path` set and any straggler not yet reaped, the child's exit status sits **undelivered for
up to a full second**, and the BEAM's Port-exit fallback is no faster because the shepherd itself is
what is sleeping.

This **supersedes** the previous plan's deferral of "`cgroup_cleanup`'s rmdir polling — Linux-only,
teardown-only, already bounded at ~1 s". It is not teardown-only: it is on the caller's
`await_exit` critical path.

- [x] **[shepherd]** Send the exit status before cleaning up the cgroup — `c_src/shepherd.c` —
      swapped; `kill_child`'s ordering left alone.
  - Swap the two calls. The status is already in `child_status` and `uds_fd` is still open; nothing
    in `cgroup_cleanup` can change either.
  - Leave the ordering in `kill_child` (`:352`) alone — there the cleanup *is* the point.
  - No effect on macOS or non-cgroup runs: `cgroup_cleanup` returns immediately when `cgroup_path`
    is empty (`:233`).
- [x] **Verify Phase 3**: `make clean && make all` warning-free under `-Werror`; `cgroup_test`,
      `exit_status_test` and `pty_test` green. **Still unverified on Linux with a real cgroup** —
      `cgroup_cleanup` returns immediately when `cgroup_path` is empty, so on macOS this is a
      provable no-op and nothing more. CHANGELOG says so explicitly rather than claiming a win.

## Phase 4 — GenServer responsiveness during stderr drain

**Measured, and smaller than a code read suggests.** Worst-case latency of a trivial `os_pid/1`
`handle_call` issued concurrently with a stderr flood:

| scenario | worst `handle_call` |
|---|---|
| idle child | 21 µs (602 µs on a loaded run — jitter floor) |
| 16 MB stderr flood | 54 / 132 µs |
| 64 MB stderr flood | 245 / 161 µs |
| 256 MB stderr flood | 217 / 279 µs |

Real, bounded at ~280 µs, **not** the "seconds of starvation" the unbounded recursion implies —
pipe capacity caps what one drain burst can consume. Priority is QUICK WIN, not DO FIRST. Record
that honestly; do not oversell it in the changelog.

- [x] **[core]** Bound the drain loop — `consume_stderr/1` capped at `@stderr_drain_chunks` (16,
      ~1 MiB) per pass; `handle_info(:consume_stderr_more, …)` sits above the catch-all and routes
      through `maybe_consume_stderr/1`, which is already a no-op for `:disabled`/closed stderr.
      **Mutation-checked**: renaming that clause (i.e. letting the catch-all swallow it) makes the
      new budget-exhaustion test fail on a 30 s `await_exit` timeout, exactly as predicted.
  - Cap at ~16 chunks or ~1 MiB per pass, then `send(self(), :consume_stderr_more)` and return so
    the loop yields to `receive`. Cost is one extra message per MiB.
  - Add the matching `handle_info(:consume_stderr_more, state)` clause **above** the catch-all at
    `:349`, or the message is silently dropped and stderr stops draining — which would deadlock the
    child on a full stderr pipe. This is the sharp edge of this task.
  - Re-entry must be idempotent: a `:consume_stderr_more` arriving after `:eof`, after the pipe is
    closed, or after `finish_exit/2` must be a no-op, not a crash.
- [x] **[core]** Remove the steady-state double copy in `append_stderr_tail/2` — now a pure
      `append_stderr_tail(tail, cap, data)`; branch 3 builds the result at exactly `cap` in one
      bitstring construction. Branches 1 and 2 untouched, including branch 1's load-bearing
      `:binary.copy`.
  - Branch 3 (`:598-599`) is the steady-state branch once the tail reaches `cap`: `combined =
    tail <> data` copies `cap + size`, then `:binary.copy(binary_part(...))` copies `cap` again —
    ~2·cap + size bytes and a transient ~72 KiB refc binary **per chunk**.
  - Replace with a single construction at exactly `cap`:
    `keep = cap - size; <<binary_part(tail, byte_size(tail) - keep, keep)::binary, data::binary>>`.
    The bitstring build produces a fresh `cap`-sized binary that pins nothing, so the outer
    `:binary.copy` becomes unnecessary.
  - **Do not touch branch 1 (`:593`)** — its `:binary.copy` is load-bearing (it wraps a
    `binary_part` of the incoming chunk and prevents pinning the parent). Branch 2 (`:595`) is
    reachable only during the first `cap` bytes of a process's life; leave it.
  - This is Tier-1-adjacent to the previous cycle's D7 decision, which gated a *chunk-deque*
    rewrite on measurement. This task is **not** that rewrite; it is three lines. Tier 2 stays
    deferred.
- [x] **[core]** Stop rebuilding state per drained chunk — tail and byte count fold through
      `consume_stderr/4`; bytes and syscall count fold through `write_loop/5` and
      `retry_write_loop/6`. `Stats.record_write/3` takes an explicit call count so `write_count`
      still means "write(2) calls", not "logical writes".
  - Each iteration allocates a new `Stats` struct and a new state map. Fold tail + byte count
    through loop parameters and write state once on exit. Same treatment applies to
    `write_loop/3` / `retry_write_loop/4` (`:409-431`, `:520-550`), ~16 iterations per 1 MiB write.
  - Low impact by itself — bundle it with the loop rewrite above, do not bill it separately.
- [x] **[core]** Add the missing `Operations.empty?` guard to `retry_pending_writes/1` — added;
      the reduce body was extracted to `retry_pending_write/2` to keep credo's nesting check happy.
      Symmetry only, as stated.
  - `retry_reads_for/2` has it (`:464`); the write path does not. **Symmetry and readability only** —
    `:ready_output` fires only after a write EAGAIN'd, so `pending` is non-empty by construction.
    Do not present this as a performance fix.
- [x] **Verify Phase 4**: medians over five interleaved rounds — 256 MB flood 52 µs (was 217/279),
      64 MB 58 µs, 16 MB 29 µs, idle 28 µs. One 686 µs outlier at 256 MB is the same jitter the
      "before" column's 602 µs *idle* sample was. Drain throughput 928–978 MB/s, above the
      955 MB/s guard.

## Phase 5 — Periphery: Stream and Daemon

- [x] **[stream]** Drop the per-chunk `Task.yield` — accumulator is now `{:reading, writer}` /
      `{:done, writer}` and the writer is reaped once in the after-fun via the shared
      `InputWriter.reap/2`. The `{:error, pid, reason}` prettification went with it: `Task.async`
      links, so an abnormal writer exit kills the consumer before any poll could observe it.
  - `Task.yield(writer, 0)` runs on **every** stdout chunk for the whole write. It is a selective
    `receive` with `after 0`, so its cost is O(mailbox length) per chunk: free for a bare consumer,
    pathological for a GenServer/LiveView-style consumer with unrelated traffic in its mailbox.
  - Its only jobs are flipping the accumulator to `:reading` and prettifying a writer crash — but
    `Task.async` links, so an abnormal writer exit already kills the consumer.
  - Cheapest correct fix: drop the poll and reap the writer once at `:eof` in `cleanup_process/2`.
    If the accumulator flip is still wanted, `Process.alive?(writer.pid)` is an O(1) BIF with no
    mailbox scan.
  - **Interaction with Phase 1**: Phase 1 gives `run/2` a writer task too. Settle the reap
    convention once and use it in both places.
- [x] **[stream]** Resolve the open question the previous cycle left explicitly unresolved —
      **resolved by stopping the server.** New public `NetRunner.Process.stop/1`; both stream
      after-fun paths and every `run/2` exit path call it. This was not cosmetic: measured **100
      leaked BEAM processes per 50 calls** (Process GenServer + Watcher, each holding a UDS socket
      and three pipe FDs) for both `run/2` and `stream!/2`, now 0. Guarded by `leak_test.exs`.
  - `perf-remediation` Phase 4 ends with: neither the old nor the new after-fun calls
    `GenServer.stop/1`, so teardown after a fully-consumed stream relies on the owner monitor.
    Either stop the server in the after-fun or document the reliance. It is still implicit in
    `stream.ex:153-160`. Carried forward rather than dropped.
- [x] **[daemon]** Stop blocking the Daemon on a backpressured child — `handle_call({:write, …})`
      returns `{:noreply, …}` and a `Task.Supervisor` child does the write and `GenServer.reply`s.
      A dead `Proc` is turned into `{:error, :process_exited}` rather than an exit, so the detached
      task cannot leave the caller waiting on a reply that never comes. Shutdown budget unchanged
      and asserted in the new test.
  - `handle_call({:write, data})` calls `Proc.write/2` (a `:infinity` `GenServer.call`) from inside
    its own `handle_call`. If the child stops reading stdin the Daemon is wedged for the whole
    stall, so `os_pid/1` and `alive?/1` (`:84-87`) hang too — including the `Proc.alive?` in
    `terminate/2` (`:120`), which then burns the shutdown budget the previous cycle carefully
    sized to fit 5 000 ms.
  - Return `{:noreply, state}` and forward the write from a task that `GenServer.reply/2`s.
  - Check this against the `@sigterm_grace_ms` / `@sigkill_grace_ms` split from the previous cycle;
    do not regress that budget.
- [x] **[daemon]** Rate-limit or batch `handle_output(:log, data)` — `:log` gets its own drain
      loop that coalesces chunks and flushes at 16 KiB **or** as soon as a read blocks (measured:
      >1 ms), so a quiet child never sits unlogged waiting for traffic. `:discard` and custom
      callbacks are untouched and still see every chunk as it arrives.
  - One `Logger` call per drained chunk. A chatty child pushes Logger past its sync threshold and
    the drain rate collapses to Logger's throughput.
- [x] **Verify Phase 5**: `teardown_test.exs` green within the full suite, plus the new
      "control calls stay responsive while the child refuses to read stdin" Daemon test.

## Phase 6 — Tests

Each must defend an observable contract and fail on a plausible regression.

- [x] **[test]** `run/2` with `:input` larger than both pipe buffers completes —
      `test/io_pipelining_test.exs`, 256 KiB / 1 MiB / 4 MiB of `:crypto.strong_rand_bytes` through
      `cat`, byte-for-byte, plus list and `Stream` variants. Bounded by an explicit 15 s
      `Task.yield` + `Task.shutdown(:brutal_kill)`, so a regression flunks instead of hanging.
- [x] **[test]** `run/2` with `:input` and an explicit `:timeout` — two cases: writer finished
      (child drained stdin then slept) and writer still parked on a full stdin pipe. Both return
      `{:error, :timeout}` and `pgrep` confirms the child is reaped.
- [x] **[test]** A saturated stdout read returns full-capacity chunks — asserts no `<= 16`-byte
      chunk mid-stream *and* that a majority are exactly 65 536. **Mutation-checked**: reverting
      the default to 65 535 fails it with "134 tiny chunks".
- [x] **[test]** The GenServer stays responsive during a large stderr flood — 64 MB flood, worst
      concurrent `os_pid/1` asserted under 50 ms, plus `bytes_err` == 64 MiB so a stalled drain
      fails too. Backed by a second test that deterministically exhausts the chunk budget (a 1 MiB
      `stderr_tail_bytes` makes each chunk expensive enough that the producer outruns the drain) —
      that is the one that actually catches a dropped `:consume_stderr_more`.
- [x] **[test]** `stderr_tail` boundary cases — existing cap-1024 test extended to assert exact
      content (one chunk crosses the cap); new cap-200 000 / 500 000-byte case (chunk smaller than
      cap, steady-state branch); new 50-line trickle at cap 100 (many small chunks, boundary
      crossed mid-line). **Mutation-checked**: `keep = cap - size - 1` fails three of ten.
- [x] **[test]** Daemon control calls stay responsive while the child refuses to read stdin —
      4 MiB into a `sleep`, then `os_pid/1`, `alive?/1` and `GenServer.stop` all timed.
- [x] **[test]** `exit_status_test.exs`, `cgroup_test.exs` and `pty_test.exs` pass unchanged.

## Phase 7 — Verification gate

- [x] `make clean && make all` — warning-free under `-Wall -Wextra -Werror`
- [x] `mix compile --warnings-as-errors`
- [x] `mix format --check-formatted`
- [x] `mix credo` — no issues (needed one extraction; see Phase 4)
- [x] `mix test` — 184 passed, 2 excluded (`:linux_only`)
- [x] `mix dialyzer` — 0 errors
- [x] `mix docs` — 0 warnings; `skip_code_autolink_to` extended with `NetRunner.InputWriter` and
      `NetRunner.Process.Pipe.read/2`, both `@moduledoc false`
- [x] Sanitizers — **partial, and the gap is a host limitation, not a result.** The ASan/UBSan
      build compiles clean under `-Werror`, but the ASan *suite* cannot run on macOS: SIP strips
      `DYLD_INSERT_LIBRARIES` when `/bin/sh` execs the `elixir`/`erl` wrappers, so the runtime
      never reaches `beam.smp` and the `dlopen`'d NIF aborts with "Interceptors are not working".
      A UBSan-only build (no interceptor requirement) ran the full suite: 184 passed, no
      diagnostics. CI's Linux `sanitizers` job with `LD_PRELOAD` remains the real ASan gate.
- [x] Re-run the full `bench/` suite and record before/after —
      `.claude/audit/2026-07-29-io-pipelining.md`
- [ ] **Linux run** — **BLOCKED: no Linux host in this session.** Phase 3 is entirely unverified
      and the Phase 2 win is macOS-shaped (Linux pipes are 1 MiB). The CHANGELOG and the audit both
      say so; do not publish either as general until this is done.

## Phase 8 — Docs

- [x] **[docs]** `CHANGELOG.md` — `Unreleased` section leads with the `run/2` `:input` hang under
      **Fixed**, followed by the leak, then Phase 3 with its unverified caveat. Also records what
      was measured and deliberately *not* changed.
- [x] **[docs]** `README.md` — `:input` row rewritten (three shapes, written concurrently, stdin
      closed after the last chunk); performance table replaced with this cycle's measurements plus
      the two-exec explanation and a pointer to ADR-9. The unverifiable "plain Erlang Port measures
      420-525 MiB/s" comparison was dropped rather than carried forward unmeasured.
- [x] **[docs]** `docs/decisions.md` — ADR-9, including the *upper* bound (65 537 falls off
      `nif_read`'s stack path) and the platform caveat. `docs/backpressure.md`'s stale `65535` and
      "NIF (dirty IO)" references were corrected while in the area.
- [x] **[docs]** `docs/architecture.md` — new "Spawn Cost: Two `exec`s, by Design" section with
      the measured single-exec baselines and the phase attribution, plus an "`:input` is written
      concurrently with reading" section explaining why that is a liveness requirement.

---

## Explicitly deferred (Iron Law #5: every finding is a task above or a deferral here)

Measured and **not worth fixing** — three items the static analysis ranked high that measurement
demoted. This is why the perf skill measures first:

- **Spawn latency / the second `exec`** (4.4–7.2 ms). One fork+exec on this host is 2532 µs
  (`System.cmd`) / 2655 µs (raw `Port`); NetRunner does two, so ~5.3 ms is the floor and the
  shepherd's exec is the entire zero-zombie guarantee. Removable overhead measured: `File.dir?`
  35 µs (0.8%), `:code.priv_dir` path resolution 5 µs (0.1%), `Watcher.watch` 6.8 µs (0.2%). Total
  addressable ≈ 1%. Only *amortisation* (shepherd pooling/reuse) moves this, and that is a design
  project with real lifetime and security questions, not a perf task.
- **`Watcher` per-child GenServer** (`watcher.ex:18`) — flagged "high impact at spawn concurrency";
  measures **6.8 µs**, and 128-way concurrent spawn runs at 791 µs/op with ~13% scheduler
  utilisation. Not a bottleneck. The previous cycle's R3 also warns that collapsing Watchers into
  one GenServer makes serialization *worse*. Confirmed deferred, twice over.
- **`File.dir?/1` per spawn** (`exec.ex:184`) — flagged "medium impact"; measures 35 µs = 0.8% of
  spawn. The lazy-recovery alternative (retry `create_uds_base_dir` on `:socket.bind` `:enoent`) is
  correct and cheap, but it buys 0.8% and adds an error path. Revisit only if spawn latency itself
  becomes the target.
- **`Operations.pending_by_type/2` intermediate list** (`operations.ex:87`) — practical `pending`
  size is 1–3; this is garbage rate, not CPU. Splitting `pending` into three maps is real
  complexity for a low single-digit percentage.
- **`:code.priv_dir` memoisation** (`exec.ex:242`) — 5 µs/spawn. Trivial to do, too small to
  justify a `:persistent_term` entry on its own; fold in only if Phase 0 touches that file anyway.

Deferred on effort or scope:

- **`nif_read`'s second `memcpy`** (`net_runner_nif.c:283-321`). Every default-size read takes the
  stack path and pays kernel→stack→binary (2 copies). ~3 µs / ~5% of read CPU, and read CPU is a
  minority of the round trip. The fix (per-resource readiness hint to pick the heap path when the
  previous call returned data) adds state to `io_resource_t` for a few percent. The current
  tradeoff is deliberate and documented at `:276-282`. **Re-measure after Phase 2** — halving the
  round-trip count changes the ratio this decision rests on.
- **Multi-reader `enif_select` fanout** (`process.ex:467-470`). With N callers parked on one pipe, a
  single readiness event costs N `read(2)` and N−1 redundant `enif_select` re-arms. Idempotent, no
  correctness bug, and N=1 in every in-tree caller (`Stream`, `Daemon`). Fix only if a multi-consumer
  use case appears.
- **Direct-NIF read bypass / `borrow_stdout/1`** (`process.ex:145`). Would cut ~2 µs and 2 scheduler
  hops per chunk — negligible at 64 KiB, 20–40% of latency on 1–4 KiB interactive chunks. But it
  breaks `Stats` accounting, `finish_exit/2`'s parked-reader sweep, and the resource's `owner`
  monitor, and two direct readers race with no ordering. High effort, narrow benefit, real API
  surface. Same family as the previous cycle's deferred batched-read API.
- **`append_stderr_tail` Tier 2** (chunk deque + lazy materialisation). Previous cycle's D7 gated
  this on measurement; Phase 4 does the three-line Tier 1 only. Still gated.

Deliberately **not** doing, with reasons:

- **`-flto` / `-O3` in the `Makefile`** (`:31`). The NIF is a single translation unit, so LTO buys
  almost nothing over `-O2`'s intra-TU inlining, and the hot path is `read(2)`/`write(2)`/`memcpy`
  where `-O3`'s vectorization is irrelevant. Both add build variance for no measurable win. Current
  flags are correct: `-O2`, no debug flags, sanitizers opt-in only at `:29`. **Recommendation:
  change nothing.**
- **`ERL_NIF_DIRTY_JOB_IO_BOUND` on any NIF.** All 8 entry points are correctly normal-scheduler,
  single-syscall, `O_NONBLOCK`-enforced. The previous cycle measured the dirty hop at ~280× cost and
  wrote D1 about it. Re-audited this session: **zero misclassifications.**
- **Setting `uds_fd` non-blocking in the shepherd.** `send_message`/`send_error` could in principle
  block if the BEAM stopped draining, but frames are ≤ 7 bytes and fit any socket buffer. Theoretical.

### Verified correct this session — do NOT "optimise" (regression guardrails)

`nif_read`'s stack-buffer + exact-size `enif_alloc_binary`; the write path's zero-copy
`enif_inspect_binary` (`nif.c:366-384`); `enif_select` armed once per EAGAIN, never per chunk;
`O_NONBLOCK` enforcement via `fstat` gating (`nif.c:203-224`); the mutex held across
`read`/`write` + `enif_select` (previous cycle's D3, non-negotiable); shepherd's `poll(fds,2,-1)`
event loop and deadline-driven `wait_for_child`; `F_SETPIPE_SZ` 1 MiB tuning; `run/*`'s list-prepend
+ single `IO.iodata_to_binary` (`net_runner.ex:199-209`); `recv_uds/1`'s progress-gated recursion
and its EOF termination; `Operations.monitor_caller/2`'s refcounted per-pid monitor;
`write_loop/3`'s `binary_part` sub-binary advance and the `update_context` fix for the 5.8 GB
re-write bug; per-VM `:persistent_term` UDS base dir; `validate_cmd_and_args/2` (three to four
orders of magnitude cheaper than the `fork`+`exec` that follows it).

## Risks

**What is most likely to break?** Phase 4's bounded drain. Adding
`handle_info(:consume_stderr_more, …)` **below** the catch-all at `process.ex:349` silently drops
the message, stderr stops draining, and the child then deadlocks on a full stderr pipe — a worse
failure than the 280 µs stall being fixed, and one that only appears with >64 KiB of stderr. The
Phase 6 stderr-flood test and the existing `stderr_tail` tests are the guard. Second most likely:
Phase 1's writer-task lifecycle, where the `max_output_exceeded` and `:timeout` branches now have a
live task to reap.

**What is the riskiest assumption?** That pipe capacity is 65 536, which is what makes Phase 2 a win
rather than a wash. It holds for Linux default and for macOS with a large writer, but macOS starts
at 16 KiB and grows, and Linux is tunable (`/proc/sys/fs/pipe-max-size`) — and the shepherd itself
sets 1 MiB on Linux (`shepherd.c:790-792`), where the alignment argument largely evaporates. The
change is never *worse* (65 536 ≥ 65 535 always, and it stays on the NIF stack path), but the
measured +42% is a macOS-shaped number. Phase 7's Linux run is where this gets honest.

**What did the measurement not cover?** (a) Linux entirely — Phase 3 is Linux-only and completely
unexercised here; (b) PTY mode, which folds stderr into the master FD and so skips the Phase 4 path
altogether; (c) `--cgroup-path` runs; (d) the stderr starvation numbers sit close to the idle jitter
floor on this host (21 µs idle vs 602 µs idle on a loaded run), so Phase 4's win needs medians over
interleaved rounds, not a single before/after; (e) concurrency was measured only to 128, and the
`Watcher` deferral rests on that — the previous cycle put the scaling cliff at ~20–50 k spawns/s and
nothing here re-tested it.

## Notes

- Scratchpad: `.claude/plans/perf-io-followup/scratchpad.md`.
- Phase ordering is load-bearing: Phase 0 makes every later delta provable; Phase 1 is a hang and
  outranks all throughput work; Phase 2 is the largest measured win per line changed; Phase 3 is
  trivial but unverifiable on this host, so it must not block the rest.
- Phases 1, 2, 3 touch disjoint files (`net_runner.ex` · `process.ex`+`pipe.ex` · `shepherd.c`) and
  could be parallelised — but Iron Law #1 above (one change at a time) exists so each measurement
  stays attributable. Parallelise the *editing*, serialise the *measuring*.
- Phase 5's writer-reap convention is shared with Phase 1; settle it once.
