# NetRunner

Safe OS process execution for Elixir. Zero zombies, even under BEAM SIGKILL.

Combines NIF-based async I/O (`enif_select`) with a persistent **shepherd binary** that watches over child processes. If the BEAM crashes hard, the shepherd detects UDS hangup and kills the child. If the GenServer crashes, a Watcher process kills the child. Neither alone covers all cases — together they guarantee cleanup.

## Why not System.cmd / Port?

`System.cmd` uses Erlang ports which:
- Tie stdin/stdout lifecycle together (can't close stdin independently)
- Have no backpressure (mailbox flooding)
- Leave zombies when programs ignore stdin EOF
- Filed as [ERL-128](https://bugs.erlang.org/browse/ERL-128), marked **Won't Fix**

## Why not Exile / MuonTrap?

| Feature | System.cmd | MuonTrap | Exile | NetRunner |
|---------|-----------|----------|-------|-----------|
| No zombies on BEAM crash | No | Yes | No | Yes |
| NIF async I/O | No | No | Yes | Yes |
| Backpressure | No | No | Yes | Yes |
| Close stdin independently | No | No | Yes | Yes |
| Shepherd survives SIGKILL | N/A | Yes | No | Yes |
| No singleton bottleneck | Yes | Yes | Yes | Yes |

Exile's spawner `execvp`s away, so on hard BEAM crash (SIGKILL) children become orphans. MuonTrap has a persistent wrapper but no NIF I/O or backpressure. NetRunner combines both approaches.

## Quick Start

```elixir
# Simple command execution
{output, 0} = NetRunner.run(~w(echo hello))
# => {"hello\n", 0}

# With stdin input
{output, 0} = NetRunner.run(~w(cat), input: "from stdin")
# => {"from stdin", 0}

# Streaming (backpressure via OS pipe buffers)
NetRunner.stream!(~w(cat), input: large_data)
|> Enum.each(&process_chunk/1)

# Parallel execution (each command is fully independent)
files
|> Task.async_stream(fn file ->
  {out, 0} = NetRunner.run(["ffprobe", file])
  {file, out}
end, max_concurrency: System.schedulers_online())
|> Enum.to_list()
```

## Process API

For fine-grained control over the OS process lifecycle:

```elixir
{:ok, proc} = NetRunner.Process.start("cat", [])

:ok = NetRunner.Process.write(proc, "hello ")
:ok = NetRunner.Process.write(proc, "world")
:ok = NetRunner.Process.close_stdin(proc)

{:ok, "hello world"} = NetRunner.Process.read(proc)
:eof = NetRunner.Process.read(proc)

{:ok, 0} = NetRunner.Process.await_exit(proc)
```

```elixir
# Kill a long-running process
{:ok, proc} = NetRunner.Process.start("sleep", ["100"])
:ok = NetRunner.Process.kill(proc, :sigterm)
{:ok, 143} = NetRunner.Process.await_exit(proc)  # 128 + SIGTERM(15)
```

## Architecture

```
BEAM Process (NetRunner.Process GenServer)
    |
    |-- Port.open("priv/shepherd", [:nouse_stdio, :exit_status])
    |     |
    |     v
    |   Shepherd Binary (stays alive for child's lifetime)
    |     |-- fork() -> child process (execvp)
    |     |-- Passes pipe FDs to BEAM via UDS + SCM_RIGHTS
    |     |-- poll() loop: watches UDS + signal pipe (SIGCHLD)
    |     |-- BEAM dies (POLLHUP) -> SIGTERM -> SIGKILL child
    |     |-- Child dies (SIGCHLD) -> notify BEAM, exit
    |
    |-- NIF (enif_select on raw FDs, dirty IO schedulers)
    |     |-- Demand-driven backpressure via OS pipe buffers
    |
    v
NetRunner.Watcher (belt-and-suspenders with shepherd)
    |-- Monitors GenServer, kills OS process if GenServer crashes
```

**Three layers of zombie prevention:**
1. **Shepherd** — detects BEAM death via POLLHUP on UDS, kills child
2. **Watcher** — detects GenServer crash via `Process.monitor`, kills child via NIF
3. **NIF resource destructor** — closes FDs on GC, child sees broken pipe

## Installation

```elixir
def deps do
  [
    {:net_runner, "~> 0.1.0"}
  ]
end
```

Requires a C compiler (`gcc` or `clang`) and `make`. No Rust/Zig toolchain needed.

## License

MIT
