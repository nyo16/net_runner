# NetRunner Code Review — `git diff HEAD~5`

**Verdict: REQUIRES CHANGES** (1 blocker) → **RESOLVED** (fixes applied, verified)

## Resolution (fixes applied this session)
Verified: `mix format --check-formatted` ✅ · `mix compile --warnings-as-errors` (clean C rebuild) ✅ · `mix credo --strict` no issues ✅ · `mix test` 140 passed/2 excluded ✅ (was 139; +1 Daemon drain-isolation test).

- 🔴 BLOCKER stderr `:redirect` — removed the unimplemented option; `:stderr` now validated (`:consume`/`:disabled` only) at spawn time; docs, typespec, README updated.
- 🟠 UDS perms — socket moved into a per-spawn `0700` dir (blocks cross-user FD hijack); also fixed an empty-dir tmp leak on failure paths. Peer-credential check (`SO_PEERCRED`) deferred — platform-divergent.
- 🟠 `nif_kill` — added 1..31 signal range check (mirrors shepherd).
- 🟠 `Process.sleep(1)` write loop — zero-byte write now mapped to `:eagain`+`enif_select` in the NIF; dead Elixir branches removed.
- 🟠 Daemon — `Task.async` → `Task.Supervisor.async_nolink`; added `NetRunner.TaskSupervisor` to the app tree; new isolation test.
- 🟡 `handle_uds_message` logs shepherd errors; `Operations` O(n)→O(1) reverse index; `Command.new` guard clauses; test fixes (poll instead of sleep(500), unique `pgrep` marker, `assert_raise` message patterns).

Deferred (low value / regression risk): `write_all_input` error propagation (broken-pipe on stdin is normal for `head`-style commands — fatal would regress); cgroup symlink note (root/Linux, trusted config); minor test-hygiene suggestions.

---


Scope: recent commits #4–#6 on `master` (Command DSL, review fixes, UDS drain race fix). No task ID/plan detected — requirements coverage not applicable. Agents: elixir-reviewer, security-analyzer, testing-reviewer, verification (run directly).

## Verification — PASS
compile `-Werror` (incl. C) ✅ · format ✅ · credo --strict (no issues) ✅ · test 139 passed/2 excluded ✅ · dialyzer skipped.

## Findings by severity

### 🔴 BLOCKER (1)
**`stderr: :redirect` documented but not implemented** — `lib/net_runner.ex:36,122`, `lib/net_runner/process.ex:110`, `lib/net_runner/process/exec.ex:69`.
`:redirect` ("merged with stdout") is in the public docs and `state.ex` typespec, but the GenServer only drains stderr when `stderr_mode == :consume`. The shepherd always pipes stderr to a dedicated FD (`shepherd.c:749`); in `:redirect` mode nothing reads it. Result: **stderr is silently lost, and a child emitting enough stderr can block on a full pipe buffer → hang.** *Verified by reviewer.*
Fix: implement redirect (drain stderr into the stdout buffer/stream) **or** remove `:redirect` from the API and raise `ArgumentError` on unknown `:stderr` values.

### 🟠 WARNINGS (4)
1. **UDS: no restrictive perms + no peer authentication** — `lib/net_runner/process/exec.ex:121-137`. Socket in `tmp_dir!` under umask; `accept_connection` trusts the first connector (only barrier: 8 random bytes). A local attacker winning the race gets the child's pipe FDs via SCM_RIGHTS and can inject `CMD_KILL`/`CMD_SET_WINSIZE`. Fix: per-spawn `0700` dir (or chmod before `listen`) + verify `SO_PEERCRED`/`LOCAL_PEERCRED` against the shepherd Port pid. (CWE-283/377)
2. **`Task.async` in `Daemon.start_drain/3` can crash the Daemon** — `lib/net_runner/daemon.ex:122`. Linked task; if `drain_loop` raises, the `:EXIT` takes down the Daemon. Use `Task.Supervisor.async_nolink` + a supervised `Task.Supervisor`.
3. **`nif_kill` accepts arbitrary signal number** — `c_src/net_runner_nif.c:395-415`. No 1..31 range check (shepherd.c:342 has one). Blast-radius concern. Fix: mirror the range check; keep `nif_kill` GenServer-private.
4. **`Process.sleep(1)` inside `handle_call` write loop** — `lib/net_runner/process.ex:350`. Blocks the GenServer (and queued callers) on the zero-byte-write branch. Treat as EAGAIN: park via `Operations.park`, let `enif_select` re-arm. *(flagged by elixir + security)*

### 🟡 SUGGESTIONS (high-value subset)
- **`test/process_test.exs:187`** `Process.sleep(500)` gates async cleanup → CI flake. Poll alive-state up to 3s. *(testing BLOCKER, demoted: test-only)*
- **`test/net_runner_test.exs:87-99`** global `pgrep -x sleep` count racy under `async: true` → tag `:serial` or track pids.
- **`lib/net_runner.ex:171-179`** `write_all_input` swallows `Proc.write/2` errors (broken pipe). Propagate.
- **`lib/net_runner/process.ex:554`** `handle_uds_message/1` catch-all drops `{:shepherd_error, msg}` — log at `Logger.warning`.
- **`lib/net_runner/process/operations.ex:82`** `demonitor_for_op/2` O(n) over monitors map; add reverse index.
- **`lib/net_runner/command.ex:59-66`** prefer guard-clause heads over `unless/raise`.
- **No `NetRunner.Daemon` test file** — drain/crash-recovery/3 on_output modes/SIGTERM shutdown untested.
- **`test/command_test.exs:483-515`** `Code.compile_string` fixed module names pollute BEAM table on rerun; use `:erlang.unique_integer`.
- cgroup symlink note (`shepherd.c:207-234`), signal-test atom-table coverage — low priority.

## Clean / no concerns
SCM_RIGHTS sizing & framing (`cbuf[64]` bounded), NIF read/write 1MB cap + lock-across-syscall (no UAF), FD lifecycle (dtor/stop/down + `O_CLOEXEC`), async-signal-safe post-fork path, `setpgid` before exec, no shell/injection (execvp explicit argv, NUL rejected), signal atoms via fixed strcmp table.

## Suggested manual security runs
`mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`, C build with `-fsanitize=address,undefined`.
