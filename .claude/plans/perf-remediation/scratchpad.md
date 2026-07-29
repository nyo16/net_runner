# Scratchpad — perf-remediation

Decisions, rejected alternatives and dead ends. Append, do not rewrite.

## Decisions

**D1 — Non-blocking NIFs belong on normal schedulers.**
`ERL_NIF_DIRTY_JOB_IO_BOUND` is for calls that may block. Every fd here is an `O_NONBLOCK` pipe or
pty master and readiness comes from `enif_select`, so nothing in this NIF can block. Measured on the
dev host: normal-scheduler NIF 26–53 ns vs dirty-IO 495–670 µs; stdout throughput 6.3 → 1759 MiB/s
with default VM flags. Anyone tempted to "restore" the dirty flags as a safety measure must read
`docs/decisions.md` first — hence the Phase 8 task to write it down there.

**D2 — Enforce the invariant instead of documenting it.**
D1 is only safe while every fd honours `O_NONBLOCK`. A regular-file fd would ignore it and block a
scheduler, and the symptom would be a wedged VM rather than an error. `nif_create_fd` therefore
`fstat`s and rejects anything that is not FIFO / socket / chardev.

**D3 — Keep the mutex across `read`/`write` + `enif_select`.**
It looks like contention but is not: each fd has its own resource and its own mutex, and PTY mode
dups the master so stdin and stdout are separate resources. It closes a real use-after-close race
(v1.1.0 copied `res->fd` under the lock, released it, then syscalled). Both paths release the lock
before any `enif_select(STOP)`, so there is no lock-order inversion with the ERTS-invoked
`down`/`stop` callbacks. Non-negotiable.

**D4 — The UDS is a byte stream; frame boundaries are not read boundaries.**
The shepherd learned this in `f75659f` (carry-over buffer in `event_loop`). The BEAM side did not,
which is the entire root cause of the 5 s / exit-137 bug. The fix is symmetric: carry the tail.

**D5 — Event-driven exit delivery, timeout as backstop.**
`:force_exit_timeout` stays, but only as a last resort with a warning log. Silent fallbacks that
synthesise a plausible-looking value (`137`) are how this bug survived three releases and a review
pass — a real exit code of `1` was being replaced by `137` and nothing complained.

**D6 — One `0700` directory per VM, not per spawn.**
Same traversal barrier, mkdir/chmod amortised to zero, `152 → 20 ms` on spawn.

**D7 — Tier 2 of the stderr-tail fix is gated on measurement.**
The chunk-deque rewrite is real work with real state. The tier-1 fix (no concat when the chunk
already exceeds the cap, `:binary.copy` to release the pinned parent) is three lines. Measure after
Phase 1 before building tier 2.

## Rejected alternatives

**R1 — `chmod` the socket file instead of using a `0700` directory.**
Reopens a bind→chmod race: between `:socket.bind` and the `chmod` the socket is world-accessible, and
an attacker who wins the accept race receives the child's pipe FDs via `SCM_RIGHTS`. The directory
is the correct barrier.

**R2 — Ship `+sbwt none` guidance as the fix.**
It works spectacularly on the dev host (spawn 161 → 14 ms, stdout 6.3 → 256 MiB/s) but a library
cannot set VM flags for its users, and the flag has global effects on unrelated workloads. It is an
operator note, not a fix. D1 removes the need for it.

**R3 — Collapse the per-process Watchers into one GenServer.**
Would make the spawn-path serialization worse, not better, and put a fleet of 5 s `send_after`
timers in one mailbox. If the ceiling is ever hit, partition the `DynamicSupervisor` instead.

**R4 — Wire up `NetRunner.Stream.AbnormalExit`.**
Making `stream!/2` raise on a non-zero child exit is a behaviour change that needs its own decision.
Deleting the never-raised module is the honest move for a perf pass; the API surface was claiming a
guarantee that did not exist.

**R5 — `ioctl(FIONREAD)` before `read()` to size the binary exactly.**
Trades an allocation for a syscall. The stack-buffer approach gets an exactly-sized binary with
neither.

## Dead ends / measurement traps

**M1 — The first benchmark harness measured the bug, not the code.**
`NetRunner.run/2` includes `await_exit`, which stalls 5 s on every fast command. The 5 s tax swamped
every throughput number until the harness was rewritten to drive `NetRunner.Process` directly and
time only the I/O phase.

**M2 — Busy-polling `Proc.stats/1` starves the thing you are measuring.**
The stderr harness spun on `Proc.stats(pid)` with no sleep, competing with the GenServer's own drain
loop and hanging the scenario. Needs a `:timer.sleep(2)`.

**M3 — `dd ... 2>/dev/null >&2` writes to `/dev/null`, not to stderr.**
Redirection order matters: `2>/dev/null` first points fd 2 at `/dev/null`, then `>&2` points fd 1
there too. The working form is `1>&2 2>/dev/null`. Cost an hour chasing a phantom "stderr never
drains" bug on HEAD.

**M4 — v1.1.0 really does never drain stderr.**
Not a harness artefact: 0 bytes after 60 s and 120 s. A child writing more than one pipe buffer to
stderr deadlocks on v1.1.0. `v1.1.2`/HEAD fixed it, so HEAD is *much* better here — worth saying out
loud, because the headline of this investigation is otherwise all regressions.

**M5 — Timing variance on this host is brutal.**
The same measurement moved 6.2 → 0.5 ms/call between a loaded and an idle machine. Every number in
the audit is a median of interleaved rounds across versions, not a single run. Do not trust a
single-round comparison.

**M6 — The double-close hypothesis was wrong.**
Suspected `io_resource_stop` (closes `event`) and `io_resource_dtor` (closes `res->fd`) could double
close. Checked the erl_nif docs: a resource with an undissolved `enif_select` relation is *never*
destructed, and every path that arms a `STOP` first sets `fd = -1; closed = 1` under the mutex. No
bug. The real hazard in that area is the opposite one — a resource whose relation is never dissolved
leaks the fd forever, which is exactly why the `enif_monitor_process` failure path must not be
swallowed.
