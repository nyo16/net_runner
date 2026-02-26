# NetRunner vs Alternatives

## Feature Matrix

| Feature | NetRunner | Exile | MuonTrap | erlexec | System.cmd |
|---------|-----------|-------|----------|---------|------------|
| Independent stdin close | Yes | Yes | No | Yes | No |
| Backpressure | Yes (enif_select) | Yes (enif_select) | No (Port) | Limited | No (Port) |
| Zero zombies (BEAM SIGKILL) | Yes (shepherd) | No | Yes (muontrap) | No | No |
| Zero zombies (GenServer crash) | Yes (watcher) | Partial | No | Yes | N/A |
| Process group kills | Yes (kill -pgid) | No | Yes | Yes | No |
| PTY support | Yes | No | No | Yes | No |
| cgroup support | Yes (Linux) | No | Yes | No | No |
| Stream API | Yes | Yes | No | No | No |
| Per-process stats | Yes | No | No | No | No |
| Daemon mode | Yes | No | Yes | No | No |
| Window size control | Yes | No | No | No | No |
| Kill escalation timeout | Configurable | Fixed | Fixed | Configurable | N/A |
| Concurrency model | Process-per-cmd | Process-per-cmd | Process-per-cmd | Single manager | Blocking |
| Language | C NIF + Elixir | C NIF + Elixir | C wrapper + Elixir | C port + Erlang | Built-in |
| BEAM scheduler safe | Yes (dirty IO) | Yes (dirty IO) | N/A | N/A | No |

## Architecture Comparison

### System.cmd / Erlang Ports
```
BEAM → Port Driver → child (stdin+stdout coupled)
```
- Stdin and stdout lifecycle tied together
- No backpressure — data floods mailbox
- No zombie prevention on BEAM crash

### Exile
```
BEAM → NIF (enif_select) → child (spawner execvp's away)
```
- Excellent I/O model with backpressure
- Spawner calls execvp — no watchdog for BEAM crashes
- No process group kills

### MuonTrap
```
BEAM → Port → muontrap binary → child
```
- Persistent wrapper prevents zombies
- Port-based I/O — no backpressure
- cgroup support on Linux

### erlexec
```
BEAM → single exec-port → all children
```
- Single port manages all children — bottleneck
- Rich feature set (PTY, process groups)
- Erlang-native, Elixir wrapper available

### NetRunner
```
BEAM → NIF (enif_select) + shepherd binary → child
```
- Best of Exile (NIF I/O) + MuonTrap (persistent wrapper)
- Process group kills with grandchild cleanup
- Three-layer zombie prevention
- PTY + cgroup + stats + daemon mode

## When to Use What

| Use Case | Recommended |
|----------|-------------|
| Simple command execution, don't care about edge cases | `System.cmd` |
| Need backpressure for large data streams | **NetRunner** or Exile |
| Must guarantee no zombies under all failure modes | **NetRunner** or MuonTrap |
| Need PTY/terminal emulation | **NetRunner** or erlexec |
| Need cgroup resource isolation (Linux) | **NetRunner** or MuonTrap |
| Erlang-only project, no Elixir | erlexec |
| Need all of the above | **NetRunner** |
