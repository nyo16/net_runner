# Security Audit: NetRunner

> ⚠️ EXTRACTED FROM AGENT MESSAGE (Write denied; see scratchpad)

No remote attack surface; threat model is local. Command/arg handling solid (`execvp` explicit argv, no shell, NUL bytes rejected). C memory safety careful.

## WARNING — UDS listener: no restrictive perms or peer authentication
`lib/net_runner/process/exec.ex:121-137`. Socket bound in `System.tmp_dir!()` under process umask; on Linux may be world-connectable. `accept_connection` accepts the *first* connector without verifying it's our shepherd — only barrier is 8 random bytes. A local attacker winning the race could receive the child's pipe FDs via SCM_RIGHTS and inject `CMD_KILL`/`CMD_SET_WINSIZE`. Fix: create socket inside a per-spawn `0700` dir (or chmod path before `listen`), and after accept verify `SO_PEERCRED`/`LOCAL_PEERCRED` matches the shepherd Port's OS pid. CWE-283/CWE-377.

## WARNING — `nif_kill` accepts arbitrary signal number
`c_src/net_runner_nif.c:395-415`. Validates `os_pid > 0` but no range check on `sig` (unlike `shepherd.c:342` which enforces 1..31). Public module fn callable directly (`process.ex:176,294`). Blast-radius/privilege concern, not RCE. Fix: mirror shepherd's 1..31 validation; keep `nif_kill` GenServer-private.

## SUGGESTION — cgroup path: traversal blocked, symlinks not
`shepherd.c:207-234`. Leading `/` and `..` rejected, but intermediate symlinks under `/sys/fs/cgroup` could redirect `fopen`/`mkdir`. Low risk (root-owned, Linux-only). Document `cgroup_path` must be trusted config.

## SUGGESTION — `write_loop` `Process.sleep(1)` inside GenServer
`process.ex:344-351`. Blocks GenServer on (practically unreachable) 0-write branch. Prefer select-driven re-arm. (Dup with elixir-reviewer #2.)

## Clean
SCM_RIGHTS sizing, framing (`cbuf[64]` bounded), NIF read/write (1MB cap, lock-across-syscall prevents close/UAF), FD lifecycle (dtor/stop/down + `O_CLOEXEC`), async-signal-safe post-fork path, `setpgid` before exec. No SQL/XSS/`String.to_atom`/`binary_to_term`/secrets. Signal atoms via fixed `strcmp` table — no atom exhaustion.

## Suggested manual runs
`mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`, build C with `-fsanitize=address,undefined`.
