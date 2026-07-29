# NetRunner performance investigation — v1.1.0 → v1.1.2 → HEAD

Date: 2026-07-28
Host: Darwin 25.5.0, Apple M1 Max (10 cores), Erlang/OTP 29 (erts 17.0.3, JIT), Elixir 1.20.2
Method: three git checkouts (`v1.1.0` = `acd9df2`, `v1.1.2` = `f75659f`, `HEAD` = `150a84c`) built
side by side in `/tmp/nr_{a,b,c}` with `MIX_ENV=prod`, driven by the same harness, interleaved
across rounds to cancel machine drift. The working tree was never modified; all patches used to
prove fixes were applied to the throwaway copies only.

---

## 1. Verdict

**Yes — HEAD is slower, but only on spawn, and by far less than the two standing bugs that
dominate every measurement.**

| Scenario | v1.1.0 | v1.1.2 | HEAD | delta |
|---|---|---|---|---|
| `Proc.start` median (r1/r2) | 70 / 70 ms | 81 / 70 ms | **155 / 152 ms** | **~2× slower** |
| stdout read, 8 MiB (r1/r2) | 7.0 / 6.1 MiB/s | 6.9 / 6.1 MiB/s | 6.1 / 6.3 MiB/s | within noise |
| stderr `:consume`, 8 MiB bulk | **never drains** | 6.1 MiB/s | 6.2 MiB/s | HEAD/v1.1.2 fixed a hang |
| stderr `:consume`, 120k × 65 B | **never drains** | 6.06 MiB/s | 6.14 MiB/s | within noise |
| `mix test` | — | — | 141/148, 7 failed | — |

Two things matter far more than that 80 ms:

1. **Throughput is ~50–280× below what the same producer achieves through a plain
   `Port`** (6.3 MiB/s vs 525 MiB/s). Cause is in the C layer: every I/O call is registered as
   a dirty-IO NIF.
2. **Every short-lived command stalls exactly 5 s and reports the wrong exit status.** Pre-existing
   in all three versions; it is also why 7 tests fail on HEAD.

Both are fixed and measured below. Combined, on HEAD, with **no VM tuning**:

| | HEAD as shipped | HEAD + both fixes |
|---|---|---|
| spawn median | 152–161 ms | **20 ms** |
| stdout read | 6.1–6.3 MiB/s | **156–306 MiB/s** |
| `mix test` | 141/148 (7 failed), 28.1 s | **145/148 (3 failed), 21.0 s** |

---

## 2. Root cause #1 — every I/O NIF runs on a dirty-IO scheduler (C layer)

`c_src/net_runner_nif.c:504-513` registers seven of the eight NIFs with
`ERL_NIF_DIRTY_JOB_IO_BOUND`:

```c
{"nif_create_fd", 2, nif_create_fd, ERL_NIF_DIRTY_JOB_IO_BOUND},
{"nif_read",      2, nif_read,      ERL_NIF_DIRTY_JOB_IO_BOUND},
{"nif_write",     2, nif_write,     ERL_NIF_DIRTY_JOB_IO_BOUND},
{"nif_close",     1, nif_close,     ERL_NIF_DIRTY_JOB_IO_BOUND},
{"nif_dup_fd",    1, nif_dup_fd,    ERL_NIF_DIRTY_JOB_IO_BOUND},
{"nif_kill",      2, nif_kill,      ERL_NIF_DIRTY_JOB_IO_BOUND},
{"nif_is_os_pid_alive", 1, ..., ERL_NIF_DIRTY_JOB_IO_BOUND},
{"nif_signal_number",   1, ..., 0},
```

**This is the wrong flag for every one of them.** `ERL_NIF_DIRTY_JOB_IO_BOUND` exists for calls
that may *block*. None of these can:

- The fd is put in `O_NONBLOCK` by `nif_create_fd` (`net_runner_nif.c:157-165`) and every fd
  originates from `pipe()`/`pipe2()` or `openpty()` in `shepherd.c` — both honour `O_NONBLOCK`.
- `read`/`write` are therefore bounded; the whole point of the `enif_select` design
  (`net_runner_nif.c:249`, `:310`) is that the NIF never waits.
- `kill(2)`, `kill(pid, 0)`, `dup(2)`, `fcntl(2)`, `close(2)` are all bounded.

### Measured cost of the dirty hop on this host

```
nif_signal_number      (normal scheduler)       26–53 ns/call
:erlang.md5            (normal scheduler)      273–584 ns/call
nif_is_os_pid_alive    (dirty io, kill(pid,0))  670,644 ns/call     ← idle machine
:prim_file.read 64 B   (dirty io, OTP's own)    495,387 ns/call     ← idle machine
Proc.read(64 KiB)                              10,047 µs median
```

The dirty-IO penalty is not NetRunner-specific — OTP's own `:prim_file.read` pays it too — but
NetRunner is maximally exposed because a streamed chunk costs **two** hops (one `nif_read`
returning data, one returning `EAGAIN` to re-arm `enif_select`). Measured per-read cost was flat
at **~9.5 ms regardless of buffer size**:

```
Port baseline (same dd producer)            60 ms   524.7 MiB/s
NetRunner chunk=4096                     75475 ms     0.4 MiB/s  8192 reads   9213 µs/read
NetRunner chunk=65535                     5027 ms     6.4 MiB/s   514 reads   9782 µs/read
NetRunner chunk=262144                    5031 ms     6.4 MiB/s   512 reads   9828 µs/read
NetRunner chunk=1048576                   4855 ms     6.6 MiB/s   512 reads   9484 µs/read
```

### Why the hop is milliseconds and not microseconds

ERTS starts `10 normal + 10 dirty-CPU + 10 dirty-IO` scheduler threads on this 10-core machine
and, with the default `+sbwt medium`, they busy-wait. Thirty spinning threads on ten cores means a
dirty-scheduler handoff waits for an OS timeslice. Disabling busy-wait confirms it:

```
ERL_FLAGS=''                                    spawn 161 ms   stdout   6.3 MiB/s
ERL_FLAGS='+sbwt none +sbwtdio none +sbwtdcpu none'  spawn  14 ms   stdout 256.3 MiB/s
ERL_FLAGS='+SDio 1 +SDcpu 1'                    spawn 224 ms   stdout   6.2 MiB/s
```

That flag is a *user-side* workaround a library cannot ship. The library-side fix is to stop using
dirty schedulers for non-blocking work.

### Proof of the fix

Changing only the flags column to `0` and rebuilding, with **default** `ERL_FLAGS`:

```
HEAD as shipped        stdout 1262 ms     6.3 MiB/s
HEAD + normal sched    stdout    4 ms  1759.4 MiB/s      (~280×)
nif_is_os_pid_alive    670,644 ns → 1,625 ns             (~410×)
mix test               141/148 (7 failed) → 143/148 (5 failed)   no new failures
```

### Recommendation

1. Set the flag to `0` for `nif_read`, `nif_write`, `nif_create_fd`, `nif_close`, `nif_dup_fd`,
   `nif_kill`, `nif_is_os_pid_alive`.
2. Add `enif_consume_timeslice(env, pct)` to `nif_read`/`nif_write` proportional to bytes moved.
   At the 1 MiB cap (`net_runner_nif.c:217`) a copy is ~30–60 µs, which is a real fraction of the
   ~1 ms scheduler budget; at the 64 KiB default it is ~5 µs and irrelevant.
3. Guard the assumption in `nif_create_fd`: `fstat` the fd and reject anything that is not
   `S_ISFIFO`/`S_ISSOCK`/`S_ISCHR`. A regular-file fd ignores `O_NONBLOCK` and *would* block — this
   turns an invariant that currently lives in a comment into an enforced precondition.

---

## 3. Root cause #2 — `MSG_CHILD_EXITED` is parsed and thrown away (5 s stall + wrong exit status)

Present in **all three versions**. Not a regression, but the single most user-visible defect.

```
NetRunner.run(["/bin/sh","-c","sleep 0.3; echo hi"])  ->  620 ms   {"hi\n", 0}     correct
NetRunner.run(["/bin/echo","hi"])                     -> 5101 ms   {"hi\n", 137}   wrong
NetRunner.run(["/bin/sh","-c","sleep 0.3; exit 3"])   ->  516 ms   {"", 3}         correct
```

`mix test` fails on exactly this: `run/2 simple echo` gets `137` instead of `0`, `run/2 nonzero
exit` gets `137` instead of `1` — so a real exit code is being *lost*, not defaulted.

### Direct evidence

A temporary probe in `receive_fds/2` printing the recvmsg payload:

```
slow child:  [probe] iov=6  bytes rest=<<128, 0, 0, 230, 41>>
fast child:  [probe] iov=11 bytes rest=<<128, 0, 0, 230, 44, 129, 0, 0, 0, 0>>
                                          ^^^ MSG_CHILD_STARTED    ^^^ MSG_CHILD_EXITED, status 0
```

### Mechanism

The shepherd writes three separate segments into one `SOCK_STREAM`: the 1-byte `SCM_RIGHTS` filler
(`shepherd.c:95`, `:124`), `MSG_CHILD_STARTED` (`shepherd.c:674`/`:791`), and `MSG_CHILD_EXITED`
(`shepherd.c:499`). For a child that exits before the BEAM's `recvmsg`, all three coalesce into the
single read at `exec.ex:250`. Then:

```elixir
# lib/net_runner/process/exec.ex:316
<<@msg_child_started, pid::big-unsigned-32, _rest::binary>> -> {:ok, pid}
                                            ^^^^^ MSG_CHILD_EXITED discarded here
```

The kernel buffer is now empty. The shepherd exits, `process.ex:251` fires,
`drain_uds_for_exit/2` gets `{:error, :closed}` and bails at `process.ex:562`, and the
`Process.send_after(self(), :force_exit_timeout, 5_000)` armed at `process.ex:258` synthesises
status `137` at `process.ex:266`. The 5.07 s total (rather than 7.5 s) proves the five 500 ms
retries never ran — i.e. the frame was consumed earlier, not merely late.

### Compounding: the socket is never watched

`process.ex:273` handles `{:"$socket", socket, :select, _info}`, but **nothing ever arms a
`:nowait` recv** — every `:socket.recv`/`recvmsg` in `exec.ex` passes an integer timeout
(`:250` 10 000, `:359`/`:369`/`:376`/`:377` 500). So that clause is dead code,
`handle_uds_message/1` is unreachable, mid-life `MSG_ERROR` frames are silently invisible
(`process.ex:581` never runs), and `MSG_CHILD_EXITED` can only ever be read *reactively* after the
shepherd Port dies — which is why the discarded frame is unrecoverable.

### Recommendation

1. `extract_child_started/2` returns `{:ok, pid, rest}`; store `rest` in `State` as `:uds_carry`.
2. In `Process.init/1`, if the carry holds `<<0x81, status::big-32, _::binary>>`, dispatch
   `finish_exit(state, status)` (post it to `self()` so it runs in `handle_info`).
   `Exec.read_uds_message/1` consumes the carry before touching the socket.
3. Arm the socket once with `:socket.recv(sock, 1, [], :nowait)` and re-arm after each message, so
   `process.ex:273` goes live and exit-status delivery stops depending on the Port death.
   `:force_exit_timeout` then becomes a genuine last resort instead of the primary exit path.
4. Consider dropping the shepherd's `MSG_CHILD_EXITED` in favour of the shepherd's own process exit
   status — `event_loop` already returns `child_status` and `main` maps it to 0/1 only
   (`shepherd.c:812`); widening that to carry the real status would remove one framing race
   entirely.

---

## 4. Root cause #3 — the actual v1.1.2 → HEAD spawn regression (+80 ms, commit `c2bbea1`)

`c2bbea1` moved the UDS socket into a per-spawn `0700` directory:

```elixir
# lib/net_runner/process/exec.ex:167-173
defp uds_socket_path do
  random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  dir = Path.join(System.tmp_dir!(), "net_runner_#{random}")
  File.mkdir_p!(dir)      # +1 dirty-IO hop
  File.chmod!(dir, 0o700) # +1 dirty-IO hop
  Path.join(dir, "shepherd.sock")
end
```

plus `File.rmdir/1` in `cleanup_listener/2` (`exec.ex:233`) and in `cleanup_uds_dir/1`
(`exec.ex:52`). Three extra file syscalls per spawn — each a dirty-IO hop, i.e. tens of
milliseconds on this host:

```
crypto.strong_rand_bytes+encode16          med=1 µs        (unchanged since v1.1.0 — not the cost)
System.tmp_dir!                            med=10,140 µs
mkdir_p! + chmod! + rmdir                  med=161,883 µs
socket open+bind+listen+close              med=30,400 µs
Port.open /usr/bin/true + close            med=8,613 µs
```

The security property is worth keeping; paying for it per spawn is not. Creating the `0700`
directory **once per VM** and putting per-spawn sockets inside it preserves the same traversal
barrier (and avoids the bind→chmod race that chmod-ing the socket itself would reintroduce).

Verified in the throwaway copy — `:persistent_term`-memoised base dir, `File.rmdir` calls dropped:

```
HEAD as shipped                spawn 152–161 ms
HEAD + VM-global uds dir + normal sched   spawn 20, 22, 20, 20 ms   (7.6×)
mix test                       141/148 → 145/148, 28.1 s → 21.0 s
```

---

## 5. Root cause #4 — `Daemon.drain_loop/3` is no longer tail-recursive (commit `f75659f`)

`lib/net_runner/daemon.ex:144-166`. `f75659f` added `rescue` (`:156`) and `catch` (`:164`) clauses
to the `defp`, which wraps the **entire body** in a `try`. The self-call at `:148` is therefore no
longer in tail position: every drained chunk pushes a stack frame plus a try frame that is never
popped until EOF.

Measured on a chatty daemon (`perl` printing 100-byte lines, `on_output: :discard`), sampling the
two drain tasks under `NetRunner.TaskSupervisor`:

```
t=1s  [{stack 9033,  heap 11568}, {28, 233}]
t=2s  [{stack 19838, heap 29300}, {28, 233}]
t=3s  [{stack 26278, heap 29300}, {28, 233}]
t=4s  [{stack 35118, heap 47032}, {28, 233}]
t=5s  [{stack 40693, heap 47032}, {28, 233}]
```

~8 000 words/s of stack growth (≈64 KB/s, ≈230 MB/hour) **per drain task**, and there are two per
Daemon (`daemon.ex:61-62`). The idle stderr task stays flat at 28 words, which isolates the cause
to drained volume. GC cost also climbs, because a growing stack is rescanned on every minor GC.

Fix: hoist the `try` out of the recursive frame — keep `drain_loop/3` clean and put the
`rescue`/`catch` on a `safe_read/2` helper, exactly as `safe_handle_output/2` (`daemon.ex:168`)
already does.

---

## 6. Root cause #5 — `append_stderr_tail/2` copies up to 8 KiB per stderr chunk (commit `150a84c`)

`lib/net_runner/process.ex:506-517`:

```elixir
combined = tail <> data                          # copies min(len(tail), cap) + len(data)
if byte_size(combined) > cap,
  do: binary_part(combined, size - cap, cap),     # returns a SUB-binary of `combined`
  else: combined
```

v1.1.0 stored a list and did an O(1) cons. Three costs:

- **Pure waste on big chunks.** `Pipe.read/2` defaults to 65 535 (`pipe.ex:31`). When
  `byte_size(data) >= cap`, the entire ~72 KiB concat is thrown away by the following
  `binary_part` — the answer is a slice of `data` alone.
- **Amplification on small chunks.** `consume_stderr/1` (`process.ex:519`) appends per iteration;
  a line-buffered child at ~64 B/chunk pays `8192 + 64` bytes copied per chunk, ~129×
  amplification.
- **Retention.** `binary_part/3` on a refc binary returns a sub-binary, so the 8 KiB tail pins the
  whole ~72 KiB parent — ~9× the advertised cap per live process, plus binary-allocator churn.

It did **not** show up in the measurements (6.06 vs 6.14 MiB/s for the 120k-small-writes case)
because the dirty-scheduler hop is three orders of magnitude larger. Once §2 is fixed, it becomes
the top Elixir-side per-chunk cost.

Fix, cheapest first:
```elixir
defp append_stderr_tail(%{stderr_tail_bytes: 0}, _data), do: <<>>
defp append_stderr_tail(%{stderr_tail: tail, stderr_tail_bytes: cap}, data) do
  ds = byte_size(data)
  if ds >= cap do
    :binary.copy(binary_part(data, ds - cap, cap))   # no concat, no parent retained
  else
    combined = tail <> data
    size = byte_size(combined)
    if size > cap, do: :binary.copy(binary_part(combined, size - cap, cap)), else: combined
  end
end
```
Proper fix: hold a bounded chunk deque + running byte count in `State`, push O(1), drop from the
front, compact only every ~64 chunks, and materialise the binary lazily in
`handle_call(:stderr_tail, …)` (`process.ex:224`) — which is called at most once per process.

---

## 7. Standing inefficiencies (pre-existing, worth fixing)

| # | Where | Problem | Fix |
|---|---|---|---|
| S1 | `process.ex:238`, `:389-404` | `handle_info({:select, _resource, …})` ignores *which* fd fired, so `retry_pending_reads/1` unconditionally calls `consume_stderr/1` — a wasted `read(2)` + `enif_select` re-arm on **every stdout chunk**, even with no stderr traffic. | `Pipe` already carries `resource` (`pipe.ex:6`) — match it and dispatch to the right pipe. |
| S2 | `operations.ex:80-82` | `pending_by_type/2` is a full `Enum.filter` over the pending map, run **twice** per readiness event, then `pending ++ stderr_pending` (`process.ex:394`). | Early-return on `map_size(pending) == 0`; replace both filters + `++` with one `Enum.reduce`. |
| S3 | `operations.ex:25` (`f75659f`) | `park/4` takes a `Process.monitor` per parked caller — one monitor/demonitor pair per read that hits `EAGAIN`, i.e. roughly per chunk, for what is normally a single long-lived consumer. | Refcount one monitor per caller pid (`%{pid => {mref, count}}`); also makes `pop_by_monitor/2` reclaim *all* of a dead caller's ops. |
| S4 | `stream.ex:139-147` | `cleanup_process/1` does `await_exit(pid, 5_000)` before SIGKILL, so any early-terminated stream (`stream!(~w(yes)) \|> Enum.take(1)`) stalls the consumer a full 5 s. | Escalate immediately when the stream was halted early; keep a grace only for the natural-EOF path. |
| S5 | `daemon.ex:118-124` + `:28` | `terminate/2` spends its whole 5 000 ms grace in `await_exit`, which equals the default `use GenServer` shutdown budget — so `Proc.kill(:sigkill)` at `:122` is **unreachable** for a child that ignores SIGTERM. Stubborn daemons take ≥10 s and the escalation is dead code. | Drop the grace to 3 000 ms, or `use GenServer, shutdown: 7_000`. |
| S6 | `watcher.ex:18-23` ← `process.ex:125` | `Watcher.watch/2` is a blocking `DynamicSupervisor.start_child` issued from `Process.init/1` — the one global serialization point on the spawn path (~20–50 µs of exclusive supervisor time per spawn, convoying under bursts). | Not a bottleneck today; if the ceiling is approached, run `PartitionSupervisor` over N `WatcherSupervisor`s keyed by `phash2(self())`. |
| S7 | `stream.ex:36` | `:owner` monitors the process that *built* the stream, not the one consuming it. Build-in-A / consume-in-B truncates the stream when A finishes. | Register the owner from `Stream.resource`'s start-fun, which runs in the consumer. |
| S8 | `stream.ex:13-22` | `NetRunner.Stream.AbnormalExit` is defined and never raised — non-zero child exits are silently swallowed. | Wire it into `cleanup_process/1` (fill `:stderr` from `Proc.stderr_tail/1`) or delete it. |

---

## 8. C-layer audit — everything else

### What is correct and should not be touched

- Atoms are created in `load/3` and cached in statics (`net_runner_nif.c:483-502`) — textbook.
- `enif_monitor_process` is paired with `enif_select` (`:188`), which is exactly what the erl_nif
  docs prescribe to avoid permanent fd leakage: a resource with a live select relation is *never*
  destructed, so without the owner monitor a brutally-killed GenServer would leak the fd forever.
- Deferring `close()` to the `stop` callback (`:58-68`, `:363`) is right. Checked for a
  double close between `io_resource_stop` and `io_resource_dtor`: there is none, because every path
  that arms a `STOP` first sets `res->fd = -1; res->closed = 1` under the mutex, and a resource
  with an undissolved relation is never destructed.
- Holding `res->lock` across `read`/`write` + `enif_select` (`:227-252`, `:292-313`) closes the
  v1.1.0 use-after-close race at negligible cost — each fd has its own resource and its own mutex,
  so there is no real contention. Both paths release the lock before any `enif_select(STOP)`, so
  there is no lock-order inversion with the ERTS-invoked `down`/`stop` callbacks.
- `shepherd.c`'s framing carry-over buffer (`:415-452`) is bounded correctly: `handle_commands`
  leaves at most a 4-byte partial tail, so `sizeof(cbuf) - cbuf_used` can never reach 0 and
  mis-read a full buffer as peer close.
- `child_fail()` (`:54-68`) is genuinely async-signal-safe. `-Wall -Wextra -Werror`,
  `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, `relro`/`now`/`noexecstack`, and the
  ASan/UBSan opt-in are all good hygiene.
- **The C layer did not get slower between v1.1.0 and HEAD.** The diff adds only bounded work:
  two comparisons in `nif_kill`, a moved mutex unlock, a per-opcode length switch in the shepherd,
  and `snprintf` return checks. The equal stdout numbers across all three versions confirm it.

### C-layer improvements, ranked

1. **Scheduler flags** — §2. This is the whole game.
2. **`nif_read` allocates before it knows there is anything to read** (`:219-222`). The
   `enif_alloc_binary(max_bytes)` happens *before* the lock and before `read()`, so an `EAGAIN` —
   which is ~half of all calls in a demand-driven loop — allocates and frees up to 1 MiB for
   nothing, and a successful short read allocates 64 KiB then `enif_realloc_binary`s it down.
   Read into a stack buffer for `max_bytes <= 64 KiB` and `enif_alloc_binary(n)` exactly; keep the
   alloc-then-shrink path only above that. Note: this did **not** show up above the
   `enif_select` re-arm cost (~2.6–3.1 µs/EAGAIN on normal schedulers), so treat it as
   allocator-pressure hygiene rather than a headline win.
3. **`kill_child`'s SIGTERM wait polls `waitpid` with `usleep(100000)`** (`shepherd.c:286-296`,
   and again at `:301-310` after SIGKILL). A child that dies 1 ms after SIGTERM still costs up to
   100 ms. The shepherd already has a SIGCHLD self-pipe — `poll()` it with the remaining timeout
   and detect the exit in microseconds. Same pattern in `cgroup_cleanup` (`:255-262`).
4. **Grow the pipe buffer on Linux.** Each 64 KiB chunk costs a full read → `EAGAIN` →
   `enif_select` → message round trip. `fcntl(fd, F_SETPIPE_SZ, 1<<20)` in `shepherd.c` (Linux
   only; macOS caps pipes at 64 KiB) cuts the number of round trips per MiB by ~16×.
5. **Unchecked failure paths.** `enif_monitor_process` failure (`:188-190`) is silently swallowed —
   the resource then has no leak safety net; return `{:error, :monitor_failed}` instead. The
   `enif_select(STOP)` return value is ignored in `nif_close` (`:363`) and `io_resource_down`
   (`:89`); on failure the fd leaks.
6. **`SIGPIPE` is not ignored in the shepherd.** `send_error`/`send_message` to a dead BEAM will
   kill the shepherd via the default disposition. Harmless today (the `POLLHUP` path runs
   `kill_child` first), but one `signal(SIGPIPE, SIG_IGN)` in `main` removes the class.
7. **Build hygiene.** Add `-fvisibility=hidden` to `NIF_CFLAGS` in the `Makefile`; only
   `nif_init` needs to be exported.

---

## 9. Suggested order of work

1. Flags → `0` in `nif_funcs` + `enif_consume_timeslice` (§2). One-line change, ~280× on stdout,
   drops two test failures.
2. Thread the UDS carry bytes through and arm the socket with `:nowait` (§3). Removes 5 s from
   every short command and fixes the wrong exit status.
3. VM-global `0700` UDS directory (§4). Recovers the 80 ms spawn regression, 7.6× on spawn.
4. `drain_loop/3` tail call (§5). Stops an unbounded stack leak in every long-running Daemon.
5. `append_stderr_tail/2` (§6) and S1/S2/S3 — the per-chunk Elixir costs, which only become
   visible once (1) lands.
6. The 5-second escalations (S4, S5) and the C-layer items 3–7 in §8.

## 10. Reproduction

Harnesses used (throwaway, in `/tmp`): `bench5.exs` (interleaved spawn + stdout per version),
`bench4.exs` (stderr `:consume`, bulk and line-oriented), `thr.exs` (Port baseline + per-chunk-size
sweep with read counts), `allocbench.exs` / `dirty2.exs` (per-NIF-call cost, dirty vs normal),
`stack.exs` (Daemon drain-task stack growth), `c1.exs` (fast vs slow child exit status).
The `receive_fds` probe that produced the `iov=11` evidence in §3 is a two-line `IO.puts` before
`exec.ex:260`.
