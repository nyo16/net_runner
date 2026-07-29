# Test Review: NetRunner Test Suite (HEAD~5 diff scope)

> ⚠️ EXTRACTED FROM AGENT MESSAGE (agent lacked Write access; see scratchpad)

## Summary

Suite is well-structured — `async: true` throughout, Command DSL tests comprehensive for pure-logic. Three meaningful issues: a `Process.sleep` timing anti-pattern, a flaky global zombie-count assertion, and zero coverage for `NetRunner.Daemon`.

## Iron Law Violations
None apply (no DB, Mox, factories). All files `async: true`.

## Issues

### BLOCKER
- **test/process_test.exs:187** — `Process.sleep(500)` gates async OS-process cleanup. On loaded CI, 500ms may be too short for shepherd to detect DOWN, escalate SIGTERM→SIGKILL, reap child. Fix: poll `Process.alive?`/`os_pid_alive?` every 50ms up to 3s, flunk on expiry.

### WARNING
- **test/net_runner_test.exs:87-99** — `count_sleep_processes` uses system-wide `pgrep -x sleep`; with `async: true`, concurrent tests spawning `sleep 100` inflate the count past `start_count + 1`. Fix: `@tag :serial`/`async: false`, or track OS pids explicitly.
- **test/signal_test.exs:41-42** — `assert_raise` lacks message pattern. Add `~r/unknown signal/` to both `resolve!(:bogus)` and `resolve!(99)`.
- **test/process_test.exs:101,110** — `os_pid`/`alive?` blocks discard `Proc.kill`/`Proc.await_exit` return values; failed kill leaks silently. Assert `:ok`/`{:ok, _}`.

### SUGGESTION
- No test file for `NetRunner.Daemon` — drain tasks, crash recovery in `handle_info`, three `on_output` modes, graceful SIGTERM→SIGKILL `terminate/2` all untested.
- test/command_test.exs:394 — direct struct literal bypasses `Command.new/3` validation.
- test/command_test.exs:483-515 — `Code.compile_string` uses fixed module names (`TestBadExec` etc.) polluting BEAM table on reruns; use `:erlang.unique_integer([:positive])`.
- test/signal_test.exs — only `:sigterm`/`:sigkill` exercised; parameterize `:sigint`/`:sighup` to guard NIF atom-table drift.
