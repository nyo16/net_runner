# Audit: I/O pipelining and read-sizing follow-up — before/after

**Plan**: `.claude/plans/perf-io-followup/plan.md` (cycle 2, against the code
`.claude/plans/perf-remediation/plan.md` shipped as v1.3.0).

**Host**: macOS 25.5, Apple M1 Max (10 cores), OTP 29 / erts 17.0.3,
`MIX_ENV=prod`, default `ERL_FLAGS`. **Single host. macOS only.** Nothing here
has been re-measured on Linux, and Phase 3 cannot be exercised on this machine
at all.

Harness: `bench/`, run via `make bench`. See `bench/README.md` for the variance
warning — figures below are medians over interleaved rounds where the effect is
close to the jitter floor, and single structural counts where it is not.

## Plan targets

| metric | before | target | after | verdict |
|---|---|---|---|---|
| `run(~w(cat), input: 256 KiB)` | hangs forever | completes, ≥ 500 MB/s | completes | met |
| `run/2` stdin round trip, 16 MiB through `cat` | n/a (hung) | ≥ 500 MB/s | 1002–1163 MB/s | met |
| 64 MiB stdout read, default `max_bytes` | 1773 chunks / 31 ms | 1024 chunks / ≤ 20 ms | 1024 chunks / 18–19 ms | met |
| worst `handle_call` under 256 MB stderr flood | 279 µs | ≤ 100 µs | 52 µs (median of 5) | met |
| exit-status delivery, Linux + `--cgroup-path` | up to 1000 ms | ≤ 5 ms | **unverified** | see below |
| `mix test` | green | green | 184 passed, 2 excluded | met |

The plan's "`run/2` 128 KiB through `cat`: 18.2 → ≥ 500 MB/s" row was
**arithmetically unreachable and has been dropped**. That row spans one spawn
(~5 ms floor, explicitly deferred) plus 0.125 MiB of I/O, so 500 MB/s would
require the transfer *and* the spawn inside 0.25 ms. `bench/perf.exs` now
carries a 16 MiB `run/2` row alongside the existing 16 MiB `stream!/2` row so
the two are comparable, and keeps the 128 KiB row labelled as spawn-bound.
Measured now at 16.6–17.3 MB/s, i.e. unchanged — as expected.

## Phase 1 — `run/2` deadlock on `:input` > ~128 KiB

`bench/deadlock_probe.exs`, `run/2` column (`stream!/2` control was all-OK
before and after):

| payload | before | after |
|---|---|---|
| 16 KiB | OK | OK 12 ms |
| 64 KiB | OK | OK 7 ms |
| 128 KiB | OK | OK 6 ms |
| 256 KiB | **HUNG** | OK 6 ms |
| 1 MiB | **HUNG** | OK 6 ms |
| 4 MiB | **HUNG** | OK 9 ms |

Throughput parity with the always-concurrent path (`bench/perf.exs`, 16 MiB
through `cat`): `run/2` 1002–1163 MB/s vs `stream!/2` 1074–1130 MB/s — within
1.1x, comfortably inside the plan's ~2x bound.

## Phase 2 — read size

`bench/claims.exs` section B, 64 MiB of stdout, five interleaved rounds. Both
sizes are passed explicitly, so this stays a valid guard regardless of the
default.

| `max_bytes` | chunks | chunks ≤ 16 B | wall |
|---|---|---|---|
| 65 535 | 1773–1834 | 749–810 | 26–31 ms |
| 65 536 | 1024 (every round) | 0 (every round) | 18–19 ms |

1024 is exactly 64 MiB / 64 KiB. −42% chunk count, −35% wall time. This is a
structural count, not a timing, which is why it survives the noise floor.

**Platform caveat**: this is a macOS-shaped number. Linux sets `F_SETPIPE_SZ`
to 1 MiB in the shepherd, where a full pipe already yields sixteen reads and
the alignment argument is much weaker. The change is never *worse*
(65 536 ≥ 65 535 and both stay on `nif_read`'s stack path), but do not publish
the 42% as general.

## Phase 3 — exit status before cgroup cleanup

**Not measured. Not measurable on this host.** `cgroup_cleanup()` returns
immediately when `cgroup_path` is empty, which is every run on macOS, so
swapping it with `send_child_exited()` is a provable no-op here and nothing
more. The claim — that a caller could wait up to 1 s in `await_exit` for a
status the shepherd already held — is read from source
(`cgroup_cleanup` retries `rmdir` 10x with `usleep(100000)`), not observed.

What *was* verified: `make clean && make all` warning-free under
`-Wall -Wextra -Werror`, `test/cgroup_test.exs` + `test/exit_status_test.exs`
+ `test/pty_test.exs` green, and the full suite green under UBSan.

**Open: needs a Linux run with a real cgroup before the figure is published.**

## Phase 4 — stderr drain bounding

`bench/claims.exs` section A, worst-case latency of a concurrent trivial
`os_pid/1` `handle_call`, five interleaved rounds (µs):

| scenario | before (2 rounds) | after (5 rounds) | median after |
|---|---|---|---|
| idle child | 21 / 602 | 25, 25, 28, 29, 35 | 28 |
| 16 MB stderr flood | 54 / 132 | 26, 28, 29, 31, 45 | 29 |
| 64 MB stderr flood | 245 / 161 | 37, 38, 58, 62, 84 | 58 |
| 256 MB stderr flood | 217 / 279 | 43, 47, 52, 66, 686 | 52 |

The 686 µs sample is the same jitter the "before" column's 602 µs idle sample
was — this effect sits close to the noise floor and single rounds mean nothing
here. Post-change the flood rows are indistinguishable from idle.

Drain throughput did not pay for the bound: `bench/perf.exs` "drain 16MB
stderr (tail 8KB)" measured 928–978 MB/s, against a ≥ 955 MB/s guard and a
baseline of 969 MB/s.

## Phase 5 — leak found while fixing the teardown question

Not in the plan's target table; found by instrumenting the writer-reap work.
`run/2` and `stream!/2` each leaked the `NetRunner.Process` GenServer, its
`Watcher`, a UDS socket and three pipe FDs per call, because neither hands the
pid to the caller and the owner monitor only fires when the caller dies.

| | before | after |
|---|---|---|
| BEAM processes after `run/2` x50 | +100 | 0 |
| BEAM processes after `stream!/2` x50 | +100 | 0 |

Guarded by `test/leak_test.exs`, "GenServer lifecycle".

## Deferrals re-confirmed by measurement

| item | measured | share of spawn |
|---|---|---|
| `File.dir?/1` per spawn | 32.2 µs | 0.6% |
| `:code.priv_dir` path resolution | 3.5–4.6 µs | 0.1% |
| `Watcher.watch/2` | 6.6–7.8 µs | 0.15% |
| UDS open+bind+listen+close+unlink | 124.6 µs | 2.5% |
| `Proc.start/3` (full spawn, no I/O) | 4821–5012 µs | — |

`bench/exec_baseline.exs`: one `fork`+`exec` costs 2001 µs (`System.cmd/2`) /
2038 µs (raw `Port`); NetRunner's two cost 4749 µs, i.e. 673 µs above 2x a raw
exec. The second exec is the zero-zombie guarantee. Concurrency: 128-way
`run(["/usr/bin/true"])` at 758–846 µs/op with ~13–44% utilisation on 5 of 20
schedulers — not a bottleneck.

## Verification gate

| check | result |
|---|---|
| `make clean && make all` (`-Wall -Wextra -Werror`) | clean |
| `mix compile --warnings-as-errors` | clean |
| `mix format --check-formatted` | clean |
| `mix credo` | no issues |
| `mix test` | 184 passed, 2 excluded (`:linux_only`) |
| `mix dialyzer` | 0 errors |
| `mix docs` | 0 warnings |
| UBSan build + `mix test` | 184 passed, no diagnostics |
| ASan build | compiles clean under `-Werror` |
| ASan **runtime** suite | **not executable on this host** |
| Linux run | **not done** |

### Why the ASan suite did not run

macOS SIP strips `DYLD_INSERT_LIBRARIES` when `/bin/sh` execs the `elixir` /
`erl` wrapper scripts, so the ASan runtime never reaches `beam.smp`. The NIF is
then `dlopen`'d into an uninstrumented process and ASan aborts with
"Interceptors are not working ... loaded too late (e.g. via dlopen)". The
shepherd binary links the runtime directly and runs fine standalone; only the
NIF path is affected.

UBSan alone has no interceptor requirement, so a UBSan-only build was used to
get real runtime coverage of the shepherd change on this host. **CI's Linux
`sanitizers` job with `LD_PRELOAD` remains the actual ASan gate**, and it gates
publish.

## Mutation checks

The new regression guards were verified to fail on the defect they describe,
not merely to pass:

| mutation | expected to fail | result |
|---|---|---|
| `@default_read_size` back to `65_535` | full-capacity chunk test | failed: "134 tiny chunks" |
| `:consume_stderr_more` clause renamed (i.e. moved below the catch-all) | both stderr drain tests | failed: `await_exit` timed out after 30 s |
| `append_stderr_tail` branch 3 `keep = cap - size - 1` | tail boundary tests | 3 of 10 failed |

The second is the one that mattered: the first drain test (latency under a
64 MB flood) passed the mutation on its own, because a 64 KiB pipe rarely
refills fast enough for a single pass to reach the 16-chunk budget. The test
that catches it forces the budget by making each drained chunk expensive
(`stderr_tail_bytes: 1_048_576`), so the producer outruns the drain.
