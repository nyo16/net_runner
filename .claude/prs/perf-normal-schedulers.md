Title: perf: run NIF I/O on normal schedulers; stop discarding child exit status
Base: master
Head: perf/normal-schedulers-and-exit-status

---

Two measured defects dominated every benchmark. Investigation notes and the full harness are in `.claude/audit/2026-07-28-perf-regression.md` (not committed).

## Measured, idle M1 Max, OTP 29, **default** VM flags

| | before | after | |
|---|---|---|---|
| `Proc.start` median | 152–161 ms | **3 ms** | ~50× |
| stdout, 64 KiB reads | 6.1–6.3 MiB/s | **~650 MiB/s** | ~105× |
| `run(["/bin/echo","hi"])` | 5101 ms, exit **137** | **7 ms, exit 0** | ~700×, and correct |
| per-read, 4 KiB chunks | 9213 µs | **32 µs** | ~288× |
| `mix test` | 141/148, 7 failed, 28.1 s | **166/166, 3.6 s** | |

A plain Erlang `Port` reading the same producer measures 418–525 MiB/s on this host, so the backpressured path now beats it.

## 1. Wrong scheduler for every I/O NIF

Seven NIFs were `ERL_NIF_DIRTY_JOB_IO_BOUND` for syscalls that cannot block: every fd is `O_NONBLOCK` and readiness comes from `enif_select`. The flag bought nothing and cost a thread handoff **twice per streamed chunk** (one call returning data, one returning `EAGAIN` to re-arm). Measured ~30 ns for a normal-scheduler NIF vs 0.5–10 ms for a dirty-IO one — OTP's own `:prim_file.read` pays the same tax on this host, so it is not NetRunner-specific, but NetRunner was maximally exposed.

`nif_create_fd` now `fstat`s and rejects non-FIFO/socket/chardev fds. That is not cosmetic: a regular file ignores `O_NONBLOCK` and would stall a scheduler, and the failure mode would be a wedged VM rather than an error. The invariant that makes this change safe is now enforced instead of documented. ADR-6 in `docs/decisions.md` records the measurement and says explicitly not to reintroduce the dirty flags.

## 2. Child exit status silently discarded

`exec.ex` bound the coalesced tail of the spawn handshake to `_rest` and dropped it. Proven with a probe before touching anything:

```
slow child: iov=6  rest=<<128,0,0,230,41>>
fast child: iov=11 rest=<<128,0,0,230,44, 129,0,0,0,0>>
                        MSG_CHILD_STARTED  MSG_CHILD_EXITED status 0
```

The UDS is `SOCK_STREAM`, so a frame boundary is not a read boundary — for a child that exits before the BEAM's `recvmsg`, all three shepherd writes arrive in one 11-byte read. The status was thrown away, the socket went empty, and the 5 s `:force_exit_timeout` synthesised `137`. A real exit code of `1` was being replaced by `137`, which is how this survived three releases and a review pass.

The tail is now carried in `State.uds_carry` and parsed by `Exec.parse_uds_message/1`. Separately, **nothing had ever armed a `:socket` select**, so `handle_info({:"$socket", …})` was dead code and `MSG_ERROR` was unobservable; the socket is now armed with a `:nowait` recv. `:force_exit_timeout` is demoted to a backstop that logs when it fires.

`docs/protocol.md` previously claimed "no framing needed (each message is atomic and small)" — corrected, since that sentence is the bug.

## Also fixed

- **Spawn regression** (`c2bbea1`): `mkdir` + `chmod` + `rmdir` per spawn for the 0700 socket dir. Created once per VM now, same traversal barrier. Deliberately *not* replaced by chmod-ing the socket file — that reopens a bind→chmod race.
- **`Daemon.drain_loop/3` leaked stack without bound**: `rescue`/`catch` on the `defp` wrapped the body in a `try`, taking the recursive call out of tail position. Measured 9 033 → 40 693 words in 5 s (~64 KB/s, two drain tasks per Daemon); 800 060 vs 57 words in an isolated 200 k-iteration harness.
- **`Daemon.terminate/2`'s SIGKILL escalation was unreachable** — grace equalled the supervisor shutdown budget, *and* `await_exit/2` is a `GenServer.call` whose timeout exits the caller and unwound past the escalation.
- **Early-halted streams stalled 5 s** (`stream!(~w(yes)) |> Enum.take(1)`).
- **`:owner` monitored the stream's builder, not its consumer** — build-in-A/consume-in-B truncated output. New `NetRunner.Process.set_owner/2`.
- **`append_stderr_tail/2`** copied up to 8 KiB per chunk and returned a sub-binary pinning its ~72 KiB parent (~9× the advertised cap).
- **`:ready_input` ignored which fd fired** — wasted stderr `read(2)` + select re-arm on every stdout chunk.
- **Parked-caller monitors** refcounted per caller pid instead of per operation.
- **Swallowed `enif_monitor_process` / `enif_select(STOP)` failures** — a resource whose select relation is never dissolved is never destructed, so a failed monitor meant a permanently leaked fd.
- **Shepherd**: `kill_child` waits on the SIGCHLD self-pipe with `poll()` against a `CLOCK_MONOTONIC` deadline instead of two `usleep(100000)` ladders; `SIGPIPE` ignored (restored to `SIG_DFL` in the child, since `SIG_IGN` survives `exec`); 1 MiB pipe buffers on Linux.
- Removed `NetRunner.Stream.AbnormalExit`, defined but never raised.

## Verification

- `make clean && make all` clean under `-Wall -Wextra -Werror`
- `mix compile --warnings-as-errors`, `mix format --check-formatted`
- `mix credo --strict` — no issues; `mix dialyzer` — 0 errors
- `mix test` — 166/166
- `SANITIZE=1 make all` clean, **and** the full suite against an ASan+UBSan shepherd with `halt_on_error=1:abort_on_error=1` — exercises the new `wait_for_child` poll loop, SIGPIPE handling and framing on every spawn

New regression tests: `test/exit_status_test.exs` (coalesced-frame exit status, framing parser incl. truncated/unknown frames, `set_owner/2` replace-not-stack) and `test/teardown_test.exs` (drain-task stack bound, Daemon shutdown budget, early-halt teardown, fd-type guard).

## Reviewer notes

- **The headline multiples are host-specific.** The dirty-hop cost is inflated here by 30 busy-waiting scheduler threads on 10 cores (`+sbwt none` alone took spawn 161 → 14 ms). Direction is not in doubt — a dirty hop cannot be cheaper than no hop — but re-measure on Linux CI before quoting `~105×` externally. The README says so.
- **`res->lock` is still held across `read`/`write` + `enif_select`** in both directions. That closes the v1.1.0 use-after-close race and was deliberately not relaxed.
- **Behaviour changes to review**: three new error atoms (`:unsupported_fd_type`, `:monitor_failed`, `:select_failed`); `Exec.extract_child_started/2` and `read_uds_message` changed shape; `AbnormalExit` removed.
- **Deferred on purpose**: `Watcher.watch/2` is still a blocking `DynamicSupervisor.start_child` from `init/1` — real serialization, but ~20–50 µs against a 3 ms spawn. It is a cliff at ~20–50 k spawns/s, not a bottleneck.
