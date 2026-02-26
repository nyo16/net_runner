# NetRunner

[![Hex.pm](https://img.shields.io/hexpm/v/net_runner.svg)](https://hex.pm/packages/net_runner)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/net_runner)

Safe OS process execution for Elixir. Zero zombie processes, NIF-based backpressure, PTY support, and cgroup isolation.

NetRunner combines NIF-based async I/O (`enif_select`) with a persistent **shepherd binary** that watches over child processes. Three layers of cleanup guarantee zero zombies under every failure mode — BEAM crash, GenServer crash, or resource leak.

## Installation

```elixir
def deps do
  [
    {:net_runner, "~> 1.0"}
  ]
end
```

Requires a C compiler (`gcc` or `clang`) and `make`.

## Quick Start

```elixir
# Run a command, collect output
{output, 0} = NetRunner.run(~w(echo hello))
# => {"hello\n", 0}

# Pipe data through stdin
{output, 0} = NetRunner.run(~w(cat), input: "from elixir")
# => {"from elixir", 0}

# Stream with backpressure (no OOM on large output)
NetRunner.stream!(~w(cat /usr/share/dict/words))
|> Stream.filter(&String.starts_with?(&1, "elixir"))
|> Enum.to_list()

# Timeout enforcement
{:error, :timeout} = NetRunner.run(~w(sleep 100), timeout: 500)

# Output size limits
{:error, {:max_output_exceeded, _partial}} =
  NetRunner.run(["sh", "-c", "yes"], max_output_size: 1000)
```

## Why NetRunner?

`System.cmd` uses Erlang ports which tie stdin/stdout lifecycle together, have no backpressure (mailbox flooding), and leave zombies when programs ignore stdin EOF. This was filed as [ERL-128](https://bugs.erlang.org/browse/ERL-128) and marked **Won't Fix**.

| Feature | System.cmd | MuonTrap | Exile | **NetRunner** |
|---------|-----------|----------|-------|---------------|
| No zombies (BEAM SIGKILL) | - | Yes | - | **Yes** |
| NIF async I/O + backpressure | - | - | Yes | **Yes** |
| Close stdin independently | - | - | Yes | **Yes** |
| Process group kills | - | Yes | - | **Yes** |
| PTY / terminal emulation | - | - | - | **Yes** |
| cgroup isolation (Linux) | - | Yes | - | **Yes** |
| Per-process stats | - | - | - | **Yes** |
| Daemon mode (supervision) | - | Yes | - | **Yes** |

## Process API

For fine-grained control over the OS process lifecycle:

```elixir
alias NetRunner.Process, as: Proc

# Start a process
{:ok, pid} = Proc.start("cat", [])

# Write to stdin
:ok = Proc.write(pid, "hello world")
:ok = Proc.close_stdin(pid)

# Read from stdout
{:ok, "hello world"} = Proc.read(pid)
:eof = Proc.read(pid)

# Wait for exit
{:ok, 0} = Proc.await_exit(pid)
```

### Signals

```elixir
{:ok, pid} = Proc.start("sleep", ["100"])
:ok = Proc.kill(pid, :sigterm)
{:ok, 143} = Proc.await_exit(pid)  # 128 + SIGTERM(15)
```

Signals are sent to the **process group** (`kill(-pgid, sig)`), catching grandchildren too. The shepherd also sends the signal for belt-and-suspenders reliability.

### Stats

Every process tracks I/O statistics:

```elixir
{:ok, pid} = Proc.start("cat", [])
Proc.write(pid, "hello")
Proc.close_stdin(pid)
Proc.read(pid)
Proc.await_exit(pid)

stats = Proc.stats(pid)
stats.bytes_in     # => 5
stats.bytes_out    # => 5
stats.read_count   # => 1
stats.write_count  # => 1
stats.duration_ms  # => 3
stats.exit_status  # => 0
```

## PTY Mode

Run commands with a pseudo-terminal for programs that require a TTY:

```elixir
# Process sees a real terminal
{:ok, pid} = Proc.start("tty", [], pty: true)
{:ok, data} = Proc.read(pid)
# data =~ "/dev/ttys" (not "not a tty")

# Interactive programs work
{:ok, pid} = Proc.start("python3", ["-i"], pty: true)

# Resize the terminal
Proc.set_window_size(pid, 40, 120)
```

## Daemon Mode

Run long-lived processes under a supervision tree:

```elixir
# In your supervisor
children = [
  {NetRunner.Daemon,
   cmd: "redis-server",
   args: ["--port", "6380"],
   on_output: :log,
   name: MyApp.Redis}
]

Supervisor.start_link(children, strategy: :one_for_one)

# Interact with the daemon
NetRunner.Daemon.os_pid(MyApp.Redis)
NetRunner.Daemon.alive?(MyApp.Redis)
```

Output handling options:
- `:discard` (default) — silently consume output
- `:log` — log output via `Logger.info`
- `fun/1` — custom callback for each chunk

Graceful shutdown: on `terminate/2`, sends SIGTERM, waits 5 seconds, then SIGKILL.

## cgroup Support (Linux)

Isolate child processes in a cgroup v2 hierarchy:

```elixir
{:ok, pid} = Proc.start("my_worker", [],
  cgroup_path: "net_runner/job_123"
)
```

The shepherd creates the cgroup directory, moves the child into it, and cleans up (kills all processes + rmdir) on exit. No-op on macOS.

## Streaming

Lazy, demand-driven streams with backpressure:

```elixir
# Stream stdout chunks
NetRunner.stream!(~w(cat /dev/urandom), input: nil)
|> Stream.take(10)
|> Enum.map(&byte_size/1)

# Pipe input through a command
NetRunner.stream!(~w(tr a-z A-Z), input: "hello world")
|> Enum.join()
# => "HELLO WORLD"

# Non-raising variant
{:ok, stream} = NetRunner.stream(~w(sort), input: "c\nb\na\n")
Enum.to_list(stream)
# => ["a\nb\nc\n"]
```

## Options Reference

### `NetRunner.run/2`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:input` | binary \| list | `nil` | Data to write to stdin |
| `:timeout` | integer | `nil` | Wall-clock timeout in ms |
| `:max_output_size` | integer | `nil` | Max bytes to collect |
| `:stderr` | atom | `:consume` | `:consume`, `:redirect`, or `:disabled` |
| `:pty` | boolean | `false` | Use pseudo-terminal |
| `:kill_timeout` | integer | `5000` | SIGTERM→SIGKILL escalation timeout in ms |
| `:cgroup_path` | string | `nil` | cgroup v2 path (Linux only) |

### `NetRunner.Process.start/3`

Accepts all options above except `:input`, `:timeout`, and `:max_output_size`.

## Architecture

```
BEAM Process (NetRunner.Process GenServer)
    |
    |-- Port.open("priv/shepherd", [:nouse_stdio, :exit_status])
    |     |
    |     v
    |   Shepherd Binary (stays alive for child's lifetime)
    |     |-- fork() → child process (execvp)
    |     |-- Passes pipe FDs to BEAM via UDS + SCM_RIGHTS
    |     |-- poll() loop: watches UDS + signal pipe (SIGCHLD)
    |     |-- BEAM dies (POLLHUP) → SIGTERM → SIGKILL child
    |     |-- Child dies (SIGCHLD) → notify BEAM, exit
    |
    |-- NIF (enif_select on raw FDs, dirty IO schedulers)
    |     |-- Demand-driven backpressure via OS pipe buffers
    |
    v
NetRunner.Watcher (belt-and-suspenders with shepherd)
    |-- Monitors GenServer, kills OS process if GenServer crashes
```

**Three layers of zombie prevention:**

1. **Shepherd** — detects BEAM death via POLLHUP on UDS, kills child process group
2. **Watcher** — detects GenServer crash via `Process.monitor`, kills child via NIF
3. **NIF resource destructor** — closes FDs on GC, child sees broken pipe

See [docs/architecture.md](docs/architecture.md) for detailed diagrams and [docs/decisions.md](docs/decisions.md) for design rationale.

## Documentation

- [API Reference (HexDocs)](https://hexdocs.pm/net_runner)
- [Architecture](docs/architecture.md) — component diagrams, spawn sequence, zombie prevention
- [Protocol](docs/protocol.md) — shepherd ↔ BEAM byte protocol spec
- [Backpressure](docs/backpressure.md) — how demand-driven I/O works
- [Decisions](docs/decisions.md) — architecture decision records
- [Comparison](docs/comparison.md) — feature matrix vs alternatives

## Requirements

- Elixir ~> 1.17
- Erlang/OTP 27+
- C compiler (`gcc` or `clang`)
- `make`
- Linux or macOS

## License

MIT — see [LICENSE](LICENSE).
