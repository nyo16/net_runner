# Linux verification

## Reproducing the Linux tables (current)

The two Linux-only tables the docs publish are reproduced by one script:

```sh
MIX_ENV=prod mix run bench/linux_ab.exs
```

- **cgroup exit latency** ("cgroup exit latency" below; ADR-14 addendum in
  `docs/decisions.md`): `sh -c 'sleep 60 & exit 0'` with and without
  `cgroup_path:`, 100 sequential exits per variant, 3 runs, reporting p50, p90,
  mean and the count ≥ 50 ms. Needs a writable cgroup v2 (root, or a delegated
  `/sys/fs/cgroup/net_runner`); otherwise only this part is skipped, with the
  reason.
- **`pipe_size: :grown` vs `:default`** (`docs/backpressure.md`): 64 MiB `dd`
  via `stream!/2`, 16 MiB through `cat` via `run/2` and a 16 MiB stderr drain,
  median of 5 samples per row, 3 runs.

Off Linux the script prints why and exits. Apply the CLAUDE.md bench
discipline (≥ 3 runs, medians, ~11% noise floor) before comparing numbers.

**Current behaviour, not to be reverted**: every shepherd exit path sweeps the
group, reaps, runs `cgroup_cleanup` and only *then* sends `MSG_CHILD_EXITED`
(ADR-14). The cleanup's `rmdir` retries back off 1, 2, 4 … 512 ms (PERF-9).

---

> **Everything from here to "Pipe sizes and the per-user budget" is a
> historical handoff** for the `perf/io-pipelining-followup` branch
> (2026-08), kept for its method notes. Its branch, test counts and Task A
> are obsolete: Task A's "report the exit before the cgroup cleanup" ordering
> was reversed by ADR-14, so do not re-apply any of it.

## Historical: state of the branch (2026-08)

Everything in that branch was implemented and measured on **macOS 25.5, Apple
M1 Max, OTP 29 / erts 17.0.3**; four things could not be verified on that
host. At the time the suite was 236 tests / 4 properties, with the
`:linux_only` tests in `test/cgroup_test.exs` excluded on macOS. The planning
artifacts lived under the gitignored `tmp/` and are not needed.

## Setup

```sh
mix deps.get
make clean && make all
mix test                        # the :linux_only tests unlock on Linux
```

If `mix test` is not green **stop here** — something is Linux-specific and
that is a finding in itself, not a setup problem.

---

## Task A (historical, superseded by ADR-14) — cgroup cleanup and the exit frame

The 2026-08 branch moved `send_child_exited` *above* `cgroup_cleanup()` and
asked for a before/after measurement. That ordering is gone: ADR-14 runs the
group sweep, the reap and `cgroup_cleanup` **before** `MSG_CHILD_EXITED` on
every path, so a same-path respawn (a `Daemon` restart) never sees a stale
leaf, and PERF-9 replaced the fixed 100 ms `rmdir` retry with exponential
backoff. The old "flip the statements back and re-measure" recipe and the note
that `kill_child()` alone cleans up last are obsolete; do not re-apply them.

One method note still holds for any cgroup latency measurement: **a naive run
shows nothing**. The `rmdir` only retries while the kernel still has the
`cgroup.kill`ed tasks in the leaf, so a lone `echo` removes its leaf on the
first attempt. Give the cgroup a straggler that outlives the direct child —
`sh -c 'sleep 60 & exit 0'`, as `bench/linux_ab.exs` does — and confirm the
slow path is hit (e.g. strace the shepherd for repeated `rmdir` +
`nanosleep`) before trusting a number. Results: "cgroup exit latency" below.

---

## Task B — Phase 2: read size on Linux

`@default_read_size` went 65 535 → 65 536 (`lib/net_runner/process.ex`,
rationale in ADR-9 in `docs/decisions.md`). Measured on macOS: 64 MiB read goes
from 1773–1834 chunks / 26–31 ms to **1024 chunks / 18–19 ms**, every round.

Linux is expected to show a **smaller** win, because the shepherd grows the
stdout pipe to 1 MiB with `fcntl(F_SETPIPE_SZ, 1 << 20)` (stdin and stderr get
256 KiB; see "Pipe sizes and the per-user budget" below), so a full stdout
pipe already yields sixteen 64 KiB reads rather than one. The alignment
argument largely evaporates there.

```sh
MIX_ENV=prod mix run bench/claims.exs      # section B; run 5x, take medians
```

Section B passes both sizes explicitly, so it is a valid A/B regardless of what
the default is.

**What to record**: the Linux chunk counts and wall times for both sizes. The
change is never *worse* (65 536 ≥ 65 535, and both stay under `nif_read`'s
65 536-byte stack buffer — see the upper bound in ADR-9), so this is about
honesty in the published number, not about whether to keep the change.

**Do not** raise the read size to exploit the 1 MiB Linux pipe without reading
the upper bound in ADR-9 (`docs/decisions.md`) first. `nif_read`'s fast path is
`on_stack = max_bytes <= sizeof(stackbuf)` against a 65 536-byte stack buffer,
so at 65 537 every read falls into `enif_alloc_binary` + `enif_realloc_binary`
shrink — reintroducing exactly the per-call allocation cycle the previous cycle
removed, and giving back more than the alignment won. A platform-conditional
read size is a real idea, but it is a separate and bigger decision.

---

## Task C — ASan suite

The build is clean; the **suite has never run under ASan**.

macOS SIP strips `DYLD_INSERT_LIBRARIES` when `/bin/sh` execs the `elixir`/`erl`
wrapper scripts, so the runtime never reaches `beam.smp` and the `dlopen`'d NIF
aborts with *"Interceptors are not working ... loaded too late (e.g. via
dlopen)"*. Linux has no such problem — `LD_PRELOAD` survives.

Same invocation CI uses (`.github/workflows/ci.yml`, `sanitizers` job):

```sh
SANITIZE=1 make clean all
ASAN_OPTIONS="detect_leaks=1:abort_on_error=1" \
UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1" \
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libasan.so.8 \
  mix test
```

Adjust the `libasan.so` path for your distro (`gcc -print-file-name=libasan.so`).

**Pay attention to** the shepherd's exit path (Task A touched it) and
`append_stderr_tail/3` in `lib/net_runner/process.ex`, whose steady-state branch
was rewritten to build the tail at exactly `cap` in one bitstring construction.
That one is pure Elixir, but it feeds buffers the NIF wrote into.

A UBSan-only build was run on macOS as a partial substitute (full suite, no
diagnostics), so UBSan findings here would be surprising. ASan findings would
not be — it has genuinely never run against this code.

---

## Task D — full bench sweep, Linux column

```sh
make bench      # all five probes, MIX_ENV=prod
```

Read `bench/README.md` first, especially the variance section: medians over
interleaved rounds, never a single round, and never a "before" round taken
minutes apart from an "after" round.

Compare against the macOS column, measured on an idle Apple M1 Max (10 cores),
OTP 29 / erts 17.0.3, `MIX_ENV=prod`:

| probe | macOS result | why Linux may differ |
|---|---|---|
| `deadlock_probe.exs` | all six sizes OK, both columns | should be identical; the deadlock was never platform-specific |
| stdin round trip, 16 MiB via `cat` | `run/2` 1002–1163 MB/s vs `stream!/2` 1074–1130 | grown pipes (stdin 256 KiB, stdout 1 MiB) mean fewer round trips; both should rise together |
| stderr drain | 928–978 MB/s | 256 KiB stderr pipe → four chunks per full pipe, below the 16-chunk drain budget |
| spawn | 4.4–7.2 ms | Linux `posix_spawn`/`vfork` is usually faster than macOS |
| spawn with `cgroup_path:` | n/a (raises `ArgumentError` off Linux since 1.7.0) | `cgroup_setup` (mkdir + `cgroup.procs` write on cgroupfs) now runs *before* the child's `execvp`, gated by a sync pipe. Run `spawn_breakdown.exs` with and without `cgroup_path:` on a delegated subtree and record the delta here |
| ≥48 concurrent 64 MiB `stream!/2` reads | n/a (64 KiB pipes regardless) | `pipe-user-pages-soft` (default 64 MiB) is exhausted by ~42 concurrent spawns at 384 pages each; past it every new pipe for the uid is capped at 8 KiB. Compare the per-stream chunk count (`Proc.stats/1` `read_count`) at 1, 32 and 48 concurrent streams — a jump of 8× or more confirms the cliff. Chunk counts are structural, so no median/variance discipline is needed |

### One Linux-specific behaviour to watch

`consume_stderr/1` is capped at `@stderr_drain_chunks` (16) per pass. On macOS a
64 KiB pipe holds exactly one chunk, so the budget almost never fires. On
Linux the stderr pipe is 256 KiB (four chunks), so a single full pipe still
does not reach the budget; the resume path
(`handle_info(:consume_stderr_more, …)`) runs only when the child keeps
refilling the pipe during a pass.

The guard test (`test/io_pipelining_test.exs`, "draining resumes after a pass
exhausts its chunk budget") forces that path on every platform. Watch for
stalled drains or `await_exit` timeouts in the stderr tests: the symptom of a
regression there is a child blocked forever on a full stderr pipe, and the
test fails by timeout rather than by assertion.

## Pipe sizes and the per-user budget (measured 2026-10-31)

Every pipe page counts against `/proc/sys/fs/pipe-user-pages-soft` (16384 pages
by default) for the pipe's lifetime, and a user at that limit gets two-page
(8 KiB) pipes for **everything** it creates afterwards (pipe(7)). With 1 MiB on
all three pipes, ~21 concurrent spawns exhausted it; the symptom in CI was
`io_pipelining_test.exs` reading 16 MiB as 2048 × 8 KiB chunks.

A/B in one Linux container (Docker `elixir:1.18`, arm64, `--cpus=4`,
`MIX_ENV=prod mix run bench/perf.exs`, variants interleaved, medians of 3–5 runs,
MB/s; the ~11% run-to-run noise floor applies, and the `stream!` row is the
noisiest):

| variant | pages/spawn | ~concurrent | `cat` 16 MiB `run/2` | `cat` 16 MiB `stream!` | stderr drain 16 MiB |
|---|---|---|---|---|---|
| all three 1 MiB (≤ 1.4.1) | 768 | 21 | 2282 | 2646 | 2903 |
| stdout 1 MiB only | 288 | 56 | 1484 | 1524 | 1263 |
| all three 256 KiB | 192 | 85 | 1844 | 2077 | 2247 |
| **stdout 1 MiB, stdin/stderr 256 KiB (chosen)** | 384 | 42 | 2148 | 1905 | 2276 |

The chosen variant doubles the headroom, keeps `run/2` with large input within
noise and stdout `read_batch` at up to 16 chunks, and costs about 22% on bulk
stderr drains.

## cgroup exit latency (PERF-9, measured 2026-11-15)

`NetRunner.run(["sh", "-c", "sleep 60 & exit 0"], cgroup_path: …)`, measured in a
Docker `elixir:1.18` container (OrbStack, kernel 7.2, `--privileged`, cgroup v2,
`--cpus=4`, `MIX_ENV=prod`) as 100 sequential calls per run, 3 runs. "Slow" means
≥ 50 ms. The no-cgroup control is the same command without `cgroup_path:`.

| shepherd `cgroup_cleanup` retry | p50 | p90 | mean | slow / 100 | no-cgroup mean |
|---|---|---|---|---|---|
| fixed 100 ms sleep (≤ 1.6.0) | 1.0–1.2 ms | 1.6–2.2 ms | 6.3–10.4 ms | 5–9 | 0.9 ms |
| backoff 1, 2, 4 … 512 ms | 1.4–1.9 ms | 2.0–6.2 ms | 1.6–3.1 ms | 0 | 1.2–3.6 ms |

The win is in the tail: about one exit in fourteen used to wait a full 100 ms
sleep. The "after" runs shared the host with other builds, which is why their
no-cgroup control is noisier too. Reproduce the "after" row with
`MIX_ENV=prod mix run bench/linux_ab.exs`; the "before" row is history (≤ 1.6.0)
and needs no re-measurement.

---

## Context, in reading order

Everything below is in the repo.

| file | what it gives you |
|---|---|
| `CHANGELOG.md` | what broke, what changed, what was measured, with the caveats spelled out |
| `docs/decisions.md` ADR-9 | why the read size is exactly 65 536, bounded on *both* sides |
| `docs/architecture.md` | the two-`exec` spawn cost, and why `:input` must be written concurrently with reading |
| `bench/README.md` | how to run the harness and how to read its noise |
| `test/io_pipelining_test.exs` | the Phase 1/2/4 regression guards, with the reasoning in comments |

### Two things that will save you time

**Verify your test fails.** Every regression guard on this branch was
mutation-checked — the change it guards was reverted and the test confirmed to
fail. Three examples, all of which did fail as intended: reverting
`@default_read_size` to 65 535 ("134 tiny chunks"); renaming the
`handle_info(:consume_stderr_more, …)` clause so the catch-all swallows it
(30 s `await_exit` timeout); and `keep = cap - size - 1` in
`append_stderr_tail/3` (3 of 10 tail tests). Do the same for anything you add,
especially for cgroup latency, where the slow path is easy to miss entirely.

**A stated target can be arithmetically impossible.** The original plan asked
for "`run/2` 128 KiB through `cat` ≥ 500 MB/s" on a bench row that spans one
full spawn — whose floor the same plan documents at ~5.3 ms. That would need
the transfer *and* the spawn inside 0.25 ms. The row was measuring spawn
latency in MB/s units. Check the arithmetic before chasing a number.
