# NetRunner benchmark harness

Repo-only measurement probes. **Not shipped in the Hex package** — `mix.exs`'s
`files:` list deliberately omits `bench/`, so this directory exists to make the
performance claims in `CHANGELOG.md` and `docs/decisions.md` reproducible
without archaeology.

## Running

```sh
make bench            # every probe, MIX_ENV=prod, in order
make bench-perf       # one probe at a time
make bench-claims
make bench-deadlock
make bench-spawn
make bench-exec
```

Equivalently, by hand:

```sh
MIX_ENV=prod mix run bench/<probe>.exs
```

`MIX_ENV=prod` is not optional. The C layer compiles identically in dev and
prod, but the BEAM side does not — dev-mode numbers are not comparable to
anything published.

## Probes

| file | what it proves |
|---|---|
| `perf.exs` | Spawn latency, stdout throughput, stdin throughput, and concurrent-spawn scaling (exercises the `Watcher` DynamicSupervisor). The broad sweep — run it first and last. |
| `claims.exs` | Section A: worst-case latency of a trivial `os_pid/1` `handle_call` issued *while* the GenServer drains a stderr flood — the bound on `consume_stderr/1`. Section B: chunk counts and wall time for a 64 MiB stdout read at `max_bytes` 65 535 vs 65 536 — the read-size alignment claim. |
| `deadlock_probe.exs` | Bisects `run/2 :input` size 16 KiB → 4 MiB against a `stream!/2` control column. A clean `OK`/`HUNG` boundary is the signature of writer/reader serialisation; all-`OK` in both columns is the post-fix state. |
| `spawn_breakdown.exs` | Attributes spawn cost to phases (`File.dir?`, `priv_dir` resolution, `Watcher.watch`, handshake wait). Sum the phases and interrogate the remainder — the missing time is the `:socket.accept` handshake, not a measurement gap. |
| `exec_baseline.exs` | `System.cmd/2` vs raw `Port.open({:spawn_executable, …})` vs NetRunner. Establishes the single-`fork`+`exec` floor that NetRunner's two-exec design is measured against. |

## Reading the numbers

**Timing variance on a laptop is brutal.** Take medians over interleaved
rounds; never publish a single round, and never compare a "before" round taken
minutes before an "after" round. Observed back-to-back on the same host with no
code change: idle worst-case `handle_call` 21 µs then 602 µs; a 64 MB stderr
flood 245 µs then 161 µs; read chunk counts 1596 then 1773.

Effects that survive this noise are *structural* — chunk counts, `OK`/`HUNG`,
byte totals. Effects measured in microseconds against a jitter floor of the
same order (`claims.exs` section A) need interleaved medians or they say
nothing.

Every published figure is single-host unless stated otherwise. `--cgroup-path`
and the shepherd's Linux-only `F_SETPIPE_SZ` tuning are not exercised on macOS
at all; re-measure on Linux before generalising.

## Useless baselines (do not reintroduce)

Shell loops (`for i in $(seq 200); do /usr/bin/true; done`) fork a full shell
before `exec`, measured 13.8 ms/iteration, and flatter NetRunner by a factor of
three. The BEAM uses `posix_spawn` via `erl_child_setup`; the only fair
baselines are `System.cmd/2` and raw `Port.open/2`, which is why
`exec_baseline.exs` uses exactly those.

`Port.open` also returns before `exec` completes, so timing it alone
under-reports: dyld and `exec` finish asynchronously and the cost only surfaces
when the caller blocks on the handshake.
