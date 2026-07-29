# Code Review: NetRunner Elixir Layer (git diff HEAD~5)

> ⚠️ EXTRACTED FROM AGENT MESSAGE (Write denied; see scratchpad)

**Status**: ⚠️ Changes Requested — 7 issues (1 blocker, 3 warnings, 3 suggestions)

## BLOCKER
**1. `stderr: :redirect` documented but never implemented** — `lib/net_runner/process/exec.ex:69` / `lib/net_runner/process.ex:110`. `:redirect` is advertised in `NetRunner.run/2` & `stream!/2` docs ("merged with stdout"), but the GenServer only branches on `:consume`; `:redirect` falls through identically to `:disabled` — callers silently lose all stderr. Either implement redirect (interleave stderr into stdout read path) or remove `:redirect` and raise `ArgumentError` on unknown values.

## WARNINGS
**2. `Process.sleep(1)` inside `handle_call` write loop** — `lib/net_runner/process.ex:350`. Blocks GenServer 1ms on zero-byte write; stalls callers queued behind it if it fires. Treat zero-byte return as EAGAIN: park via `Operations.park`, let `enif_select` drive retry. (Dup with security SUGGESTION.)

**3. `Task.async` in `Daemon.start_drain/3` without await — linked task can crash Daemon** — `lib/net_runner/daemon.ex:122`. `Task.async` links task to Daemon; if `drain_loop` raises, `:EXIT` takes down the Daemon. Collecting result via `handle_info({ref, result}, ...)` is the `Task.Supervisor.async_nolink` pattern, not `Task.async`. Use `Task.Supervisor.async_nolink(NetRunner.TaskSupervisor, ...)`; add a `Task.Supervisor` under the app tree.

**4. `demonitor_for_op/2` is O(n) over monitors map** — `lib/net_runner/process/operations.ex:82`. Reverse lookup `op_ref → mref` via `Enum.find` over full map (indexed `mref → op_ref`). Add reverse index for O(1) `pop/2`. Low urgency, structurally wrong for hot path.

## SUGGESTIONS
**5. `write_all_input` discards `Proc.write/2` return values** — `lib/net_runner.ex:171-179`. Broken-pipe error (child exited before consuming stdin) silently swallowed; `run_io` returns `{output, exit_status}` instead of surfacing write failure. Pattern-match and propagate.

**6. `Command.new/3` uses `unless/raise` instead of guard clauses** — `lib/net_runner/command.ex:59-66`. Prefer `when is_binary(executable) and is_list(args)` head + fallback clause raising `ArgumentError`.

**7. `handle_uds_message/1` silently drops shepherd errors** — `lib/net_runner/process.ex:554`. Catch-all `_ -> state` discards `{:shepherd_error, msg}`/`:unknown_message`. Log at `Logger.warning` at minimum.

## Pre-existing (brief)
- `lib/net_runner/process.ex:494` — `consume_stderr/1` doesn't guard `state.stderr` nil; low risk currently.
