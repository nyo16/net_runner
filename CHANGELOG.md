# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-02-26

### Added

- **Core process management** — `NetRunner.run/2` for simple command execution, `NetRunner.stream!/2` and `NetRunner.stream/2` for lazy streaming I/O
- **NetRunner.Process** — GenServer managing a single OS process with full lifecycle control: `read/2`, `write/2`, `close_stdin/1`, `kill/2`, `await_exit/2`
- **Persistent shepherd binary** — C watchdog process that detects BEAM death via UDS POLLHUP and guarantees child cleanup, even under SIGKILL
- **NIF-based async I/O** — `enif_select` integration with BEAM's epoll/kqueue for demand-driven backpressure on dirty IO schedulers
- **Three-layer zombie prevention** — Shepherd (BEAM crash), Watcher GenServer (GenServer crash), NIF resource destructor (GC)
- **Process group kills** — `setpgid(0,0)` + `kill(-pgid, sig)` catches grandchildren
- **Configurable kill escalation** — SIGTERM → configurable timeout → SIGKILL via `:kill_timeout` option
- **PTY support** — `pty: true` option for terminal emulation with `openpty()`, controlling terminal setup, and `set_window_size/3`
- **cgroup v2 support** (Linux only) — `:cgroup_path` option for resource isolation, automatic cleanup on exit
- **NetRunner.Daemon** — supervised long-running process wrapper with auto-drain and graceful shutdown for supervision trees
- **Per-process stats** — `NetRunner.Process.stats/1` tracks bytes in/out, read/write counts, duration, exit status
- **Timeout and output limits** — `:timeout` and `:max_output_size` options on `run/2`
- **Platform support** — macOS (Darwin) and Linux with platform-specific compilation flags
