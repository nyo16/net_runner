# Linux verification — handoff

**Branch**: `perf/io-pipelining-followup`
**Plan**: `.claude/plans/perf-io-followup/plan.md`
**Results so far**: `.claude/audit/2026-07-29-io-pipelining.md`

Everything in this branch was implemented and measured on **macOS 25.5, Apple
M1 Max, OTP 29 / erts 17.0.3**. Four things cannot be verified on that host.
This file is the instruction set for finishing them on Linux.

Nothing here is speculative work — the code is written, the suite is green
(184 passing), and the CHANGELOG already carries the caveats. What is missing
is *evidence* for two claims and *coverage* for two tools.

---

## State of the branch

| | |
|---|---|
| `mix test` | 184 passed, 2 excluded (`:linux_only`) — on macOS |
| `mix compile --warnings-as-errors` / `format` / `credo` / `dialyzer` / `docs` | all clean |
| `make clean && make all` | clean under `-Wall -Wextra -Werror` |
| ASan/UBSan **build** | clean under `-Werror` |
| ASan **suite** | never ran (see Task C) |
| Phase 3 (cgroup exit-status ordering) | **zero runtime evidence** (see Task A) |
| Phase 2 (read size) on Linux | unmeasured (see Task B) |

The two `:linux_only` tests excluded on macOS are in `test/leak_test.exs`
(FD-count check via `/proc/self/fd`) and `test/cgroup_test.exs`.

---

## Setup

```sh
git checkout perf/io-pipelining-followup
mix deps.get
make clean && make all          # must be warning-free under -Werror
mix test                        # expect 186 passing on Linux (the 2 :linux_only unlock)
```

If `mix test` is not green **stop here** — something is Linux-specific in the
Elixir changes and that is a finding in itself, not a setup problem.

---

## Task A — Phase 3: exit status before cgroup cleanup

**This is the one that matters.** It is the only change in the branch with no
runtime evidence behind it at all.

### The claim

`c_src/shepherd.c`, end of `event_loop()`. It used to be:

```c
cgroup_cleanup();                          /* up to 10 x usleep(100000) */
send_child_exited(uds_fd, child_status);
```

and is now the other way round. `cgroup_cleanup()` (`shepherd.c:237-263`)
writes `cgroup.kill`, then polls `rmdir` up to **ten times with
`usleep(100000)` between** — so with `--cgroup-path` set, the caller's
`await_exit` could block for up to a full second on a status the shepherd
already held in `child_status`.

### The trap — read this before measuring

**A naive cgroup run will show nothing.** Look at the loop:

```c
for (int i = 0; i < 10; i++) {
    if (rmdir(full_path) == 0) return;                 /* usually first try */
    if (errno != EBUSY && errno != ENOTEMPTY) return;  /* real error, bail */
    usleep(100000);
}
```

It only sleeps while `rmdir` returns `EBUSY`/`ENOTEMPTY`, i.e. while the kernel
still has unreaped tasks in the cgroup. A single `echo` in its own cgroup will
`rmdir` on the **first** attempt and cost 0 ms. Measure that and you will
"prove" a 0 ms delta in both orderings and learn nothing.

This is the same failure mode as N9 in
`.claude/plans/perf-io-followup/scratchpad.md`: a test that passes against a
path that never executes reads like coverage and is worse than no test.

**You must force at least one `EBUSY`.** Give the cgroup a straggler that
outlives the direct child, so `cgroup.kill` + reap takes longer than the
`rmdir` that immediately follows it:

```elixir
# A child that spawns a grandchild which outlives it. The direct child exits
# at once (so child_status is ready), but the cgroup is not empty yet.
NetRunner.run(["sh", "-c", "sleep 5 & exit 0"], cgroup_path: path)
```

Confirm you actually hit the slow path before trusting any number — e.g. strace
the shepherd and check for repeated `rmdir` + `nanosleep`, or temporarily add a
counter to the loop.

### Measuring it

Requires cgroup v2 and write access under `/sys/fs/cgroup/`. Either run as root
or delegate a subtree:

```sh
mount | grep cgroup2                     # confirm cgroup v2
sudo mkdir -p /sys/fs/cgroup/net_runner_bench
sudo chown -R "$USER" /sys/fs/cgroup/net_runner_bench
```

Note `cgroup_path` is validated as **relative** (`test/cgroup_test.exs` asserts
absolute paths and `..` are rejected), and the shepherd prefixes
`/sys/fs/cgroup/`. So pass `net_runner_bench/run1`, not the full path.

Measure `await_exit` latency both ways. The honest comparison is to flip the
two statements back locally and re-measure — the ordering is the only variable:

```sh
# after (current HEAD)
MIX_ENV=prod mix run <your probe>.exs

# before
#   edit c_src/shepherd.c: put cgroup_cleanup() back above send_child_exited()
make clean && make all
MIX_ENV=prod mix run <your probe>.exs
git checkout c_src/shepherd.c && make clean && make all
```

**Expected**: "before" shows a multi-hundred-ms (up to ~1000 ms) `await_exit`
on the straggler case; "after" shows the status arriving promptly (target
≤ 5 ms) with the cleanup happening behind it. Non-cgroup runs must be identical
in both orderings — `cgroup_cleanup` returns immediately on an empty
`cgroup_path`, which is exactly why macOS could not see this.

**If the delta does not appear**, do not paper over it. Either the straggler
case is not hitting `EBUSY` (see the trap above) or the claim is wrong — and
"the claim is wrong" is a perfectly good outcome to write down.

### Also check

`kill_child()` (`shepherd.c:330-353`) still calls `cgroup_cleanup()` last, and
that is deliberate — on the kill path the cleanup *is* the point. Do not
"consistency fix" it to match `event_loop`.

---

## Task B — Phase 2: read size on Linux

`@default_read_size` went 65 535 → 65 536 (`lib/net_runner/process.ex`,
rationale in ADR-9 in `docs/decisions.md`). Measured on macOS: 64 MiB read goes
from 1773–1834 chunks / 26–31 ms to **1024 chunks / 18–19 ms**, every round.

Linux is expected to show a **smaller** win, because the shepherd sets
`F_SETPIPE_SZ` to 1 MiB on all three pipes (`shepherd.c:794-797`), so a full
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
X4 in `.claude/plans/perf-io-followup/scratchpad.md` first. Above 65 536 every
read falls off the NIF's stack fast path into `enif_alloc_binary` + shrink. A
platform-conditional read size is a real idea but a separate, bigger decision.

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

Worth comparing against the macOS column in
`.claude/audit/2026-07-29-io-pipelining.md`:

| probe | macOS result | why Linux may differ |
|---|---|---|
| `deadlock_probe.exs` | all six sizes OK, both columns | should be identical; the deadlock was never platform-specific |
| stdin round trip, 16 MiB via `cat` | `run/2` 1002–1163 MB/s vs `stream!/2` 1074–1130 | 1 MiB pipes mean fewer round trips; both should rise together |
| stderr drain | 928–978 MB/s | 1 MiB stderr pipe → a drain pass is more likely to hit the 16-chunk budget and use the `:consume_stderr_more` resume path (see below) |
| spawn | 4.4–7.2 ms | Linux `posix_spawn`/`vfork` is usually faster than macOS |

### One Linux-specific behaviour to watch

`consume_stderr/1` is capped at `@stderr_drain_chunks` (16) per pass. On macOS a
64 KiB pipe holds exactly one chunk, so the budget almost never fires. **On
Linux a full 1 MiB pipe is exactly sixteen chunks**, so the resume path
(`handle_info(:consume_stderr_more, …)`) will be exercised routinely rather than
rarely.

That is the intended design, and the guard test
(`test/io_pipelining_test.exs`, "draining resumes after a pass exhausts its
chunk budget") already forces it. But it means Linux is where a bug in that path
would actually bite, so watch for stalled drains or `await_exit` timeouts in the
stderr tests. Symptom of a regression there: the child blocks forever on a full
stderr pipe, and the test fails by timeout rather than by assertion.

---

## When you are done

Update these, in this order:

1. **`.claude/audit/2026-07-29-io-pipelining.md`** — add a Linux column. Do not
   overwrite the macOS numbers; the point is that they are two hosts.
2. **`CHANGELOG.md`**, `[Unreleased]`:
   - The Phase 3 entry currently ends with *"**Not verified on Linux with a real
     cgroup**"*. Replace with the measurement, or with what you found instead.
   - The read-size entry says *"The win is macOS-shaped"*. Put the Linux figure
     next to it.
3. **`.claude/plans/perf-io-followup/plan.md`** — the last unchecked box in
   Phase 7 is the Linux run. Check it with a one-line note.
4. **`.claude/plans/perf-io-followup/scratchpad.md`** — append anything
   surprising. That file is the institutional memory for this work and it has
   already paid for itself twice.

Then this branch is ready to merge and tag.

---

## Context, in reading order

| file | what it gives you |
|---|---|
| `.claude/plans/perf-io-followup/plan.md` | the full plan, with per-task implementation notes appended inline |
| `.claude/plans/perf-io-followup/scratchpad.md` | decisions (E1–E10), rejected alternatives (X1–X7), dead ends (N1–N11). **Read N9 and N11 before writing any test or trusting any target.** |
| `.claude/audit/2026-07-29-io-pipelining.md` | every before/after number, plus the mutation checks |
| `CHANGELOG.md` `[Unreleased]` | the user-facing summary |
| `docs/decisions.md` ADR-9 | why the read size is exactly 65 536, bounded on both sides |
| `docs/architecture.md` | the two-`exec` spawn cost, and why `:input` must be written concurrently |
| `bench/README.md` | how to run the harness and how to read its noise |

### Two things that will save you time

**N9 — verify your test fails.** The obvious stderr-flood test passed *and*
passed the mutation that broke the code it was supposed to guard, because a
64 KiB pipe never let the drain reach its budget. Every regression guard in this
branch was mutation-checked; see the table at the end of the audit. Do the same
for anything you add.

**N11 — a stated target can be arithmetically impossible.** The plan asked for
"`run/2` 128 KiB through `cat` ≥ 500 MB/s" on a bench row that spans one ~5 ms
spawn. Check the arithmetic before chasing a number.
