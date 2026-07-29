# Scratchpad — perf-io-followup

Decisions, rejected alternatives and dead ends. Append, do not rewrite.

Companion to `.claude/plans/perf-remediation/scratchpad.md` (cycle 1). Its D1–D7 / R1–R5 / M1–M6
still hold; this file continues the numbering conceptually but uses its own prefixes (E/X/N) to
avoid collision.

## Decisions

**E1 — `run/2` must overlap writer and reader; `Stream` already had it right.**
`run_io/3` serialises write-then-read, which deadlocks for any filter command once input exceeds
stdin-buffer + stdout-buffer (~128 KiB). `NetRunner.Stream` has always spawned the writer as a
`Task` (`stream.ex:90-98`) and is immune. Two entry points to the same subsystem disagreed on the
fundamental concurrency shape, and only the less-used one was correct. Mirror `Stream`'s shape rather
than inventing a third convention.

**E2 — The default read size must equal pipe capacity exactly, and must stay `<= 65536`.**
65 535 leaves one byte in a saturated pipe, and that byte costs a whole `GenServer.call`. Measured
+42% wall time and +56–73% chunk count on a 64 MiB read. The upper bound is not cosmetic: the NIF's
fast path is `max_bytes <= sizeof(stackbuf)` with a 65 536-byte stack buffer
(`net_runner_nif.c:283-286`), so 65 537 would silently fall into the alloc-then-shrink branch and
give back more than the alignment won. Write this into `docs/decisions.md` — a bare `65_536` looks
like a magic number begging to be "tidied".

**E3 — Exit status before cgroup cleanup.**
`shepherd.c:535-538` cleans up the cgroup (up to 10 × `usleep(100000)`) *before* sending
`MSG_CHILD_EXITED`. Cycle 1 deferred this as "Linux-only, teardown-only, already bounded at ~1 s" —
that framing was wrong. It is not teardown-only: it sits on the caller's `await_exit` critical path,
so a caller can wait a full second for a status the shepherd already has in a local variable.
Swapping two statements fixes it. Deferrals age; re-read them against new evidence.

**E4 — Bound the stderr drain, but report the win honestly.**
`consume_stderr/1` recurses without a cap inside `handle_info`, which reads like unbounded
starvation. Measured worst-case concurrent `handle_call` latency is 132–279 µs against an idle
jitter floor of 21–602 µs — real, bounded by pipe capacity, and nowhere near "seconds". Bound it
(cheap, obviously correct), but do not write a changelog entry implying seconds were saved.

**E5 — The benchmark harness is part of the deliverable, not scaffolding.**
Three of five findings are numbers only because `bench/` exists, and two static-analysis findings
were *demoted* by it. Committing it makes the next cycle cheaper and stops the same items being
re-litigated from code reading. Repo-only; keep it out of the Hex `files:` list.

**E6 — Spawn latency is accepted, not fixed.**
Measured single fork+exec on this host: 2532 µs (`System.cmd`) / 2655 µs (raw `Port`). NetRunner
performs two by design → ~5.3 ms floor against 4.4–7.2 ms observed. Everything addressable in Elixir
sums to ~1% (`File.dir?` 35 µs, `priv_dir` 5 µs, `Watcher` 6.8 µs). Document the two-exec design in
`docs/architecture.md` so the next perf pass does not re-open it as a regression.

## Rejected alternatives

**X1 — Give `run/2` a default `:timeout` instead of fixing the deadlock.**
Turns a hang into a spurious timeout and silently truncates output on slow-but-healthy commands. It
treats the symptom; the writer/reader serialisation is the bug. (Explicitly the "don't solve the
symptom" trap.)

**X2 — Document "use `stream!/2` for large input" and leave `run/2` alone.**
`run/2` is the headline API, its `@doc` advertises `:input`, and the failure mode is a silent
infinite hang on default options. A documentation fix for a liveness bug is not a fix.

**X3 — Cap `:input` size in `run/2` and return an error above ~128 KiB.**
Encodes an OS pipe-buffer detail into the public API, and the real limit is
`stdin_buf + stdout_buf`, which varies by platform (macOS 16 KiB→64 KiB, Linux tunable, and the
shepherd sets 1 MiB on Linux). The threshold would be wrong on every platform in a different way.

**X4 — Round the read size up to a larger power of two (128 KiB, 1 MiB).**
Crosses the NIF's 65 536 stack-buffer threshold into `enif_alloc_binary` + `enif_realloc_binary`
shrink on every call — reintroducing exactly the per-EAGAIN allocation cycle 1 removed. On Linux with
`F_SETPIPE_SZ` 1 MiB a larger read genuinely would fetch more per syscall, but that is a
platform-conditional read size and a different (bigger) decision. Not in this cycle.

**X5 — Add `-flto` / `-O3` to the Makefile.**
Single-TU NIF (so `-O2` already inlines everything within it), syscall-bound hot path, `memcpy`
already a libc intrinsic. No measurable win, added build variance. Current flags audited and correct.

**X6 — Collapse the per-child `Watcher`s into one GenServer.**
Re-rejected. Cycle 1's R3 argued it makes spawn-path serialization worse; this cycle measured
`Watcher.watch/2` at 6.8 µs and 128-way concurrency at 791 µs/op / ~13% scheduler utilisation. There
is nothing to win.

**X7 — Fix the `nif_read` double `memcpy` now.**
~3 µs, ~5% of read CPU, and it needs new state on `io_resource_t` (a readiness hint bit). Phase 2
halves the round-trip count, which changes the ratio this tradeoff rests on — re-measure after, then
decide.

## Dead ends / measurement traps

**N1 — The perf probe hit the deadlock and looked like a benchmark bug.**
`bench/perf.exs` step 4 (`run(~w(cat), input: 16 MiB)`) wedged the whole run for 900 s. First
instinct was a bad harness. It was the product: `run/2` hangs permanently above ~128 KiB of input.
The bisect that settled it (`bench/deadlock_probe.exs`, 16 KiB → 4 MiB, `run/2` vs `stream!/2`) is
worth keeping — a clean OK/OK/OK/HUNG/HUNG/HUNG boundary against an all-OK control column.

**N2 — Shell loops are a useless `exec` baseline.**
`for i in $(seq 200); do /usr/bin/true; done` measured 13.8 ms/iteration, making NetRunner's 4.4 ms
look fast. The shell forks a full shell before exec'ing; the BEAM uses `posix_spawn` via
`erl_child_setup`. The only fair baselines are `System.cmd/2` and raw
`Port.open({:spawn_executable, …})` — both ~2.6 ms. Always compare against the same spawn mechanism.

**N3 — `Port.open` returns before `exec` completes, so it under-reports.**
`Port.open(shepherd) + Port.close` measured 400 µs, which invited the conclusion that the shepherd
was cheap. `Port.open` returns as soon as the port is created; dyld and `exec` finish asynchronously.
The cost only becomes visible because `spawn_process/3` then blocks in `:socket.accept`. Phase
attribution summed to ~600 µs of 4385 µs — the missing 87% *was* the handshake wait, not a
measurement gap. Sum your phases and interrogate the remainder.

**N4 — Static analysis over-ranked three findings; measurement demoted all three.**
`Watcher` (predicted "high impact", actual 6.8 µs), `File.dir?` ("medium", actual 0.8% of spawn), and
`pending_by_type` ("medium", actual 1–3 elements). Meanwhile the largest measured win — a one-byte
constant — was ranked third by reading. Reading code predicts *mechanism* well and *magnitude*
badly. This is the entire justification for the perf skill's Iron Law 1.

**N5 — Timing variance is still brutal (cycle 1's M5, reconfirmed).**
The same `claims.exs` run back-to-back: idle worst-case `handle_call` 21 µs then 602 µs; 64 MB
stderr flood 245 µs then 161 µs; read chunk counts 1596 then 1773. The read-size effect survives
because it is structural (chunk *counts*, not times). The stderr starvation effect does not clear
the noise floor in a single run and needs interleaved medians.

**N6 — Two plugin specialist agents are pinned to an unavailable model.**
`elixir-phoenix:elixir-reviewer` and `elixir-phoenix:otp-advisor` both failed instantly with
`404 model: claude-sonnet-4-0`. Re-dispatching the identical briefs to `scout` worked. If a
specialist agent dies in under a second, suspect its model pin, not the brief.

**N7 — ExDoc's backslash autolink escape does not work for function references.**
`` `\Mod.fun/1` `` still warned (the backslash even appeared in the warning text). The supported knob
is `skip_code_autolink_to: ["…"]` in `docs/0`, verified against `deps/ex_doc/lib/ex_doc.ex:156`.
Needed because `NetRunner.Process.Exec` is `@moduledoc false`, so `CHANGELOG.md:125` and
`docs/protocol.md:50` were autolinking a hidden function. Fixed in `mix.exs:67-71`; `mix docs` clean.

**N8 — Editing a file after a stale read shredded it.**
An `edit` anchored on line numbers from an earlier snapshot of `bench/perf.exs` spliced the new
stdin-throughput block into the middle of the stderr block, leaving an unclosed `Bench.throughput`
call. Re-read before every edit; the tag certifies the snapshot, not your memory of it.

---

## Execution notes (2026-07-29)

**E7 — The writer convention got its own module, not a copy-paste.**
`run/2` and `NetRunner.Stream` both needed `start` + `reap`, and E1's whole point is that two
entry points drifting apart is what caused the bug. Duplicating ~30 lines into both would have
recreated the drift in a new place. `NetRunner.InputWriter` (`@moduledoc false`) owns both, and
`reap/2`'s two modes (`:done` joins with a grace, `:halted` kills outright) are the settled answer
to the "reap convention" question the plan flagged in Phase 5.

**E8 — `Pipe.read/2`'s duplicate default was deleted, not redirected.**
The plan said "one source of truth; the other references it". A cross-module compile-time
attribute reference (`@default_read_size Pipe.default_read_size()`) would have worked but adds a
compile-time dependency for a constant with one real caller. Removing the default argument
entirely is strictly better: there is nothing left to drift, and the four call sites all had an
explicit `max_bytes` anyway except `consume_stderr/1`.

**E9 — `Stats.record_write/3` keeps `write_count` meaning write(2) calls.**
Folding the partial-write loop into one struct update would have silently redefined `write_count`
from "syscalls" to "logical writes". Carrying the call count as a loop parameter preserves the
observable and still writes state once. `record_read_stderr/2` needed no such care — it has no
counter, only `bytes_err`.

**E10 — The `run/2` GenServer leak was found by instrumenting, not by reading.**
Nothing in the plan mentioned it. It surfaced while checking whether the new writer task leaked:
`length(Process.list())` before/after 50 `run/2` calls was +100, i.e. two GenServers per call
(Process + Watcher), each holding a UDS socket and three pipe FDs. `run/2` never exposes the pid,
so *nothing* could stop it — the owner monitor only fires when the caller dies. This is the same
question Phase 5 carried forward for `Stream`, just worse, because `run/2` has no owner at all.
Answer for both: `NetRunner.Process.stop/1`. Count your processes; leaks do not announce
themselves.

## Dead ends (cont.)

**N9 — The obvious stderr-flood test does not guard the sharp edge.**
The plan's Phase 6 test ("concurrent `os_pid/1` under a bound during a ≥64 MB stderr flood") was
written, passed, and then **passed the mutation too** — renaming the `:consume_stderr_more` clause
so the catch-all swallows it changed nothing. Reason: a 64 KiB pipe holds exactly one
`@default_read_size` chunk, so a drain pass almost always hits EAGAIN after one read and never
reaches the 16-chunk budget. The resume path was never exercised, so dropping the message was
invisible.

The fix is to make the *drain* slow enough that the producer outruns it:
`stderr_tail_bytes: 1_048_576` makes `append_stderr_tail/3` rebuild a 1 MiB tail per 64 KiB chunk,
the pipe refills mid-loop, the budget is exhausted for real, and the mutation then fails on a 30 s
`await_exit` timeout. **Write the mutation before you trust the test.** A passing test against a
path that never executes is worse than no test — it reads like coverage.

**N10 — ASan cannot run the suite on macOS, and it is SIP, not the code.**
`SANITIZE=1 make all && mix test` aborts with "Interceptors are not working ... loaded too late
(e.g. via dlopen)". `DYLD_INSERT_LIBRARIES` does not help: SIP strips `DYLD_*` when `/bin/sh`
execs the `elixir`/`erl` wrapper scripts, so the runtime never reaches `beam.smp` and the
`dlopen`'d NIF loads into an uninstrumented process. `ASAN_OPTIONS=verify_asan_link_order=0` is a
different check and does not apply. The shepherd links the runtime directly and runs fine
standalone, which is what makes the failure look confusingly partial.

Workaround used: a UBSan-only build (`make SANITIZE=1 SAN_FLAGS="-fsanitize=undefined …"
CFLAGS_BASE="…"` — command-line assignment, because the Makefile's own `SAN_FLAGS =` overrides the
environment). UBSan has no interceptor requirement; the full suite ran clean. CI's Linux job with
`LD_PRELOAD` is still the real ASan gate.

**N11 — A plan target can be arithmetically impossible; check before chasing it.**
"`run/2` 128 KiB through `cat`: 18.2 MB/s → ≥ 500 MB/s" cannot be met: that bench row spans one
full spawn, whose floor the same plan documents at ~5.3 ms, so 128 KiB at 500 MB/s would need the
transfer *and* the spawn inside 0.25 ms. The row was measuring spawn latency in MB/s units. Fixed
by adding a 16 MiB `run/2` row (comparable to the existing 16 MiB `stream!/2` row) and relabelling
the 128 KiB one as spawn-bound. Post-fix it still reads 16.6 MB/s — correctly, because nothing
about it changed.
