# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-02-26

Initial release.

### Core

- `NetRunner.run/2` — run a command and collect output as `{output, exit_status}`
- `NetRunner.stream!/2` / `NetRunner.stream/2` — lazy streaming I/O with backpressure
- `NetRunner.Process` — GenServer with full lifecycle control: `start/3`, `read/2`, `write/2`, `close_stdin/1`, `kill/2`, `await_exit/2`, `os_pid/1`, `alive?/1`

### Shepherd Binary (C)

- Persistent watchdog process that stays alive for the child's lifetime
- Detects BEAM death via UDS `POLLHUP` — guarantees child cleanup even under `SIGKILL`
- FD passing via `SCM_RIGHTS` over Unix domain sockets
- `poll()` event loop with self-pipe trick for `SIGCHLD` handling
- Process group kills: `setpgid(0,0)` + `kill(-pgid, sig)` catches grandchildren
- Configurable SIGTERM → SIGKILL escalation timeout (`--kill-timeout`)

### NIF I/O

- `enif_select` integration with BEAM's epoll/kqueue for async I/O
- All NIF functions on dirty IO schedulers
- Demand-driven backpressure via OS pipe buffers + `EAGAIN` + enif_select
- Resource-based FD management with destructor/stop/down callbacks

### Zombie Prevention (3 layers)

- **Shepherd** — detects BEAM crash via UDS POLLHUP, kills child process group
- **Watcher** — detects GenServer crash via `Process.monitor`, kills child via NIF
- **NIF resource destructor** — closes FDs on GC, child sees broken pipe

### PTY Support

- `pty: true` option for pseudo-terminal emulation
- `openpty()` with `setsid()` + `TIOCSCTTY` for controlling terminal
- `set_window_size/3` via `ioctl(TIOCSWINSZ)`
- Single bidirectional master FD, duped for independent stdin/stdout NIF resources
- Platform support: `<util.h>` on macOS, `<pty.h>` on Linux

### cgroup Support (Linux)

- `:cgroup_path` option for cgroup v2 resource isolation
- Creates cgroup directory, moves child to `cgroup.procs`
- Cleanup via `cgroup.kill` + `rmdir` on process exit
- No-op on macOS/BSD

### Daemon Mode

- `NetRunner.Daemon` — supervised long-running process for supervision trees
- Auto-drains stdout/stderr to prevent pipe blocking
- Output handling: `:discard` (default), `:log`, or custom `fun/1` callback
- Graceful shutdown: SIGTERM → 5s wait → SIGKILL

### Stats

- `NetRunner.Process.stats/1` — per-process I/O statistics
- Tracks: `bytes_in`, `bytes_out`, `bytes_err`, `read_count`, `write_count`, `duration_ms`, `exit_status`
- Zero-cost integer counters in GenServer state

### Safety

- Timeout enforcement on `run/2` via `:timeout` option
- Output size limits via `:max_output_size` option
- Platform support: macOS (Darwin) and Linux
