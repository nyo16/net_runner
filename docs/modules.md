# Module Dependency Diagram

```mermaid
graph TD
    NR[NetRunner] --> S[NetRunner.Stream]
    NR --> P[NetRunner.Process]
    NR --> IW[NetRunner.InputWriter]
    NR --> ERR[NetRunner.Error]
    NR --> CMD[NetRunner.Command]
    NR --> OPT[Process.Options]
    S --> P
    S --> IW
    S --> ERR
    IW --> P
    D[NetRunner.Daemon] --> P
    P --> EX[Process.Exec]
    P --> OPT
    P --> OP[Process.Operations]
    P --> PI[Process.Pipe]
    P --> PR[Process.Protocol]
    P --> CG[Process.Cgroup]
    P --> NI[NetRunner.Nif]
    P --> SIG[NetRunner.Signal]
    P --> STATS[Process.Stats]
    P --> W[NetRunner.Watcher]
    EX --> PR
    EX --> NI
    EX --> PI
    EX --> ST[Process.State]
    PR --> OPT
    PI --> NI
    ST --> OP
    SIG --> NI
    W --> NI
    W --> SIG

    subgraph "C Native"
        SH[shepherd.c]
        NIFC[net_runner_nif.c]
        PROTO[protocol.h]
        UTIL[utils.h]
    end

    NI -.->|loads| NIFC
    EX -.->|spawns| SH
    NIFC --> PROTO
    NIFC --> UTIL
    SH --> PROTO
```

The Elixir edges are exactly those reported by `mix xref graph` (compile,
export and runtime references); regenerate from it when modules change.

The OTP application (NetRunner.Application) starts no NetRunner module
directly; it supervises `NetRunner.WatcherSupervisor` (a `DynamicSupervisor`
that each Watcher is started under) and `NetRunner.TaskSupervisor`.

## Module Reference

### Public API

| Module | Purpose |
|--------|---------|
| `NetRunner` | Top-level API: `run/2`, `stream!/2`, `stream/2` |
| `NetRunner.Process` | GenServer managing a single OS process lifecycle |
| `NetRunner.Stream` | `Stream.resource` wrapper for incremental I/O |
| `NetRunner.Daemon` | Supervised long-running process for supervision trees |
| `NetRunner.Command` | Reusable command templates with default arguments and options (`use NetRunner.Command`) |
| `NetRunner.Error` | Exception raised by the bang variants (`stream!/2`); the original term is in `:reason` |
| `NetRunner.Process.Stats` | I/O and lifecycle statistics struct returned by `NetRunner.Process.stats/1` |

### Internal Modules

| Module | Purpose |
|--------|---------|
| NetRunner.Signal | Signal atom → platform-specific number resolution via NIF |
| NetRunner.InputWriter | Owns the `:input` writer Task lifecycle for `run/2` and `NetRunner.Stream` |
| NetRunner.Process.Exec | Spawn mechanics: private UDS listener, `Port.open`, accept and token authentication, SCM\_RIGHTS fd receive and wrapping |
| NetRunner.Process.Options | The spawn-option contract: key list, value validation, `:env`/`:cgroup_path` normalisation, `default_kill_timeout/0` |
| NetRunner.Process.Cgroup | BEAM-side removal of a cgroup leaf whose shepherd died without cleaning up |
| NetRunner.Nif | NIF function stubs (@on\_load :load\_nifs) |
| NetRunner.Process.Protocol | Shepherd wire format: frame constants, parser, command encoders, shepherd argv grammar, SCM\_RIGHTS fd layout |
| NetRunner.Process.Pipe | Thin struct around a NIF FD resource (a PTY master's read side maps EIO to EOF) |
| NetRunner.Process.State | GenServer state struct |
| NetRunner.Process.Operations | Pending operation queue (park on EAGAIN, retry on ready) |
| NetRunner.Watcher | GenServer started by `NetRunner.Process` under `NetRunner.WatcherSupervisor`; sends one SIGTERM probe when the Process GenServer dies |
| NetRunner.Application | OTP application: starts `NetRunner.WatcherSupervisor` (DynamicSupervisor) and `NetRunner.TaskSupervisor` (Task.Supervisor used by Daemon) |

### C Components

| File | Lines | Purpose |
|------|-------|---------|
| `c_src/shepherd.c` | ~1870 | Persistent child watchdog: token handshake (listener uid check), fork, exec gate, FD/pidfd pass, poll loop (UDS, signals, port channel), kill escalation, PTY, cgroup |
| `c_src/net_runner_nif.c` | ~830 | NIF: read/write/close/create_fd/dup_fd/kill/kill_group/pidfd_send_signal/signal_number with enif_select |
| `c_src/protocol.h` | ~60 | Shared protocol constants |
| `c_src/utils.h` | ~35 | Debug/error macros |
