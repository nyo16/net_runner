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

# Nonzero exit status
{"", 1} = NetRunner.run(~w(false))

# Multi-word commands with arguments
{output, 0} = NetRunner.run(["sh", "-c", "echo $HOME"])
```

## Streaming

Lazy, demand-driven streams with backpressure — data stays in the OS pipe buffer until you consume it, so you can stream gigabytes without OOM:

```elixir
# Stream stdout chunks with backpressure
NetRunner.stream!(~w(cat /usr/share/dict/words))
|> Stream.filter(&String.starts_with?(&1, "elixir"))
|> Enum.to_list()

# Pipe input through a command
NetRunner.stream!(~w(tr a-z A-Z), input: "hello world")
|> Enum.join()
# => "HELLO WORLD"

# Sort lines
NetRunner.stream!(~w(sort), input: "cherry\napple\nbanana\n")
|> Enum.join()
# => "apple\nbanana\ncherry\n"

# Process large files without loading into memory
File.stream!("huge.csv")
|> NetRunner.stream!(~w(grep ERROR))
|> Stream.each(&IO.write/1)
|> Stream.run()

# Non-raising variant
{:ok, stream} = NetRunner.stream(~w(sort), input: "c\nb\na\n")
Enum.to_list(stream)
# => ["a\nb\nc\n"]
```

## Timeouts and Limits

```elixir
# Kill process after 500ms
{:error, :timeout} = NetRunner.run(~w(sleep 100), timeout: 500)

# Cap output size — kills process if exceeded
{:error, {:max_output_exceeded, _partial}} =
  NetRunner.run(["sh", "-c", "yes"], max_output_size: 1000)

# Custom kill escalation: SIGTERM → wait 2s → SIGKILL
NetRunner.run(~w(my_server), kill_timeout: 2000, timeout: 10_000)
```

## Input Validation and Error Returns

`run/2` and `stream/2` return tagged errors for bad input instead of
crashing. NUL bytes inside `cmd` or `args` are rejected early (they
are undefined in `argv` on the C side).

```elixir
# Empty executable
{:error, {:invalid_cmd, _}} = NetRunner.run([""])

# NUL byte in an argument
{:error, {:invalid_args, _}} = NetRunner.run(["echo", "he\0llo"])

# Same behaviour for streaming
{:error, {:invalid_args, _}} = NetRunner.stream(["echo", "he\0llo"])

# Unknown signal atoms come back as tagged errors, not raises
{:error, :unknown_signal} = NetRunner.Signal.resolve(:sigwhatever)
{:error, :unknown_signal} = NetRunner.Signal.resolve(99)
```

## Working with Binary Output

stdout is delivered as a BEAM binary, not a String. It is safe to pass
bytes containing NUL, high-bit, or anything else through the pipeline.

```elixir
# NUL bytes round-trip unchanged
{out, 0} = NetRunner.run(["sh", "-c", ~S|printf 'a\0b\0c'|])
byte_size(out)          # => 5
out == "a\0b\0c"        # => true

# UTF-8 boundaries straddle chunks fine — just concatenate and then
# decode.
"héllo\n" =
  NetRunner.stream!(~w(echo héllo))
  |> Enum.join()
```

## Process API

For fine-grained control over the OS process lifecycle:

```elixir
alias NetRunner.Process, as: Proc

# Start a process
{:ok, pid} = Proc.start("cat", [])

# Write to stdin
:ok = Proc.write(pid, "hello world")
:ok = Proc.close_stdin(pid)

# Read from stdout (blocks until data available)
{:ok, "hello world"} = Proc.read(pid)
:eof = Proc.read(pid)

# Wait for exit
{:ok, 0} = Proc.await_exit(pid)
```

### Incremental reads and writes

```elixir
{:ok, pid} = Proc.start("cat", [])

# Write in chunks — useful for feeding large data
:ok = Proc.write(pid, "chunk 1 ")
:ok = Proc.write(pid, "chunk 2 ")
:ok = Proc.write(pid, "chunk 3")
:ok = Proc.close_stdin(pid)

# Read comes back in whatever chunks the OS delivers
{:ok, data} = Proc.read(pid)
# data => "chunk 1 chunk 2 chunk 3" (may come in multiple reads)
```

### Signals and process groups

```elixir
{:ok, pid} = Proc.start("sleep", ["100"])
:ok = Proc.kill(pid, :sigterm)
{:ok, 143} = Proc.await_exit(pid)  # 128 + SIGTERM(15)

# Signals kill the entire process group (catches grandchildren)
{:ok, pid} = Proc.start("sh", ["-c", "sleep 100 & sleep 100 & wait"])
:ok = Proc.kill(pid, :sigkill)
# All three processes (sh + both sleeps) are killed
```

Supported signals: `:sigterm`, `:sigkill`, `:sigint`, `:sighup`, `:sigusr1`, `:sigusr2`, `:sigstop`, `:sigcont`, `:sigquit`, `:sigpipe`.

### Checking process state

```elixir
{:ok, pid} = Proc.start("sleep", ["10"])

Proc.alive?(pid)   # => true
Proc.os_pid(pid)   # => 12345 (the actual OS PID)

Proc.kill(pid, :sigkill)
Proc.await_exit(pid)

Proc.alive?(pid)   # => false
```

### Stats

Every process tracks I/O statistics automatically:

```elixir
{:ok, pid} = Proc.start("cat", [])
Proc.write(pid, "hello")
Proc.close_stdin(pid)
Proc.read(pid)
Proc.await_exit(pid)

stats = Proc.stats(pid)
stats.bytes_in     # => 5       (bytes written to stdin)
stats.bytes_out    # => 5       (bytes read from stdout)
stats.bytes_err    # => 0       (bytes read from stderr, :consume mode)
stats.read_count   # => 1       (number of read calls)
stats.write_count  # => 1       (number of write calls)
stats.duration_ms  # => 3       (wall-clock time)
stats.exit_status  # => 0       (exit code)
```

### Tying an OS process to an owner

If the calling process crashes, the OS process it launched should go
with it. Pass `:owner` to have the Process GenServer monitor a pid;
on `:DOWN` it SIGKILLs the child and stops cleanly. `NetRunner.stream/2`
does this automatically with `self()`.

```elixir
# Spawn a long-lived command tied to the caller
parent = self()

spawn(fn ->
  {:ok, pid} = Proc.start("sleep", ["30"], owner: self())
  send(parent, {:os_pid, Proc.os_pid(pid)})
  exit(:boom)   # caller dies → Process SIGKILLs sleep, stops itself
end)
```

### Per-call kill timeout

Tune the SIGTERM→SIGKILL escalation window per-process. Useful when a
command has its own graceful shutdown hook you want to honour, or when
you need a fast hard-kill.

```elixir
# Give my_server 10s to drain on SIGTERM before SIGKILL
{:ok, pid} = Proc.start("my_server", [], kill_timeout: 10_000)

# Or make it effectively immediate for tests
{:ok, pid} = Proc.start("sleep", ["100"], kill_timeout: 100)
```

## PTY Mode

Run commands with a pseudo-terminal for programs that require a TTY. PTY mode is designed for **interactive and long-running programs** — shells, REPLs, curses apps.

```elixir
# Programs see a real terminal
{:ok, pid} = Proc.start("python3", ["-c", "import sys; print(sys.stdout.isatty())"], pty: true)
{:ok, data} = Proc.read(pid)
# data =~ "True"

# Interactive REPL
{:ok, pid} = Proc.start("python3", ["-i"], pty: true)
Proc.write(pid, "print(1 + 2)\n")
{:ok, data} = Proc.read(pid)

# Resize the terminal window
Proc.set_window_size(pid, 40, 120)

# Clean up when done (PTY doesn't support independent stdin close)
Proc.kill(pid, :sigkill)
Proc.await_exit(pid)
```

### PTY caveats

PTY mode differs from pipe mode in important ways:

- **No independent stdin close** — the PTY is a single bidirectional FD. Use `kill/2` to terminate.
- **Echo** — the terminal echoes input back by default, so reads include what you wrote.
- **Fast-exiting commands** — if a command exits before you call `read/1` (e.g., in iex), the PTY buffer may be lost. PTY mode is meant for long-running programs. For simple commands, use pipe mode (the default).
- **Line buffering** — the terminal line discipline buffers input until `\n` by default.

```elixir
# DON'T: Use PTY for simple commands in iex (data may be lost)
{:ok, pid} = Proc.start("echo", ["hi"], pty: true)
# ... time passes while you type ...
Proc.read(pid)  # => :eof (too late, PTY torn down)

# DO: Use pipe mode (default) for simple commands
{:ok, pid} = Proc.start("echo", ["hi"])
{:ok, "hi\n"} = Proc.read(pid)

# DO: Use PTY for interactive programs that need a terminal
{:ok, pid} = Proc.start("bash", [], pty: true)
Proc.write(pid, "echo hello\n")
{:ok, data} = Proc.read(pid)  # works — bash stays alive
```

## Daemon Mode

Run long-lived processes under a supervision tree. Automatically drains stdout/stderr to prevent pipe blocking:

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
NetRunner.Daemon.os_pid(MyApp.Redis)   # => 12345
NetRunner.Daemon.alive?(MyApp.Redis)   # => true
NetRunner.Daemon.write(MyApp.Redis, "PING\r\n")
```

Output handling options:
- `:discard` (default) — silently consume output to prevent pipe blocking
- `:log` — log each chunk via `Logger.info`
- `fun/1` — custom callback for each chunk

```elixir
# Custom output handler
{:ok, daemon} = NetRunner.Daemon.start_link(
  cmd: "tail",
  args: ["-f", "/var/log/system.log"],
  on_output: fn chunk -> MyApp.LogIngester.ingest(chunk) end
)
```

Graceful shutdown: on `terminate/2`, sends SIGTERM, waits 5 seconds, then SIGKILL.

## cgroup Support (Linux)

Isolate child processes in a cgroup v2 hierarchy for resource control:

```elixir
{:ok, pid} = Proc.start("my_worker", [],
  cgroup_path: "net_runner/job_123"
)
```

The shepherd creates the cgroup directory, moves the child into it, and cleans up on exit (kills all processes via `cgroup.kill`, then removes the directory). No-op on macOS.

## Command DSL

Bundle an executable, default args, and default options into a reusable
`%NetRunner.Command{}`. Both `run/2` and `stream/2` accept it, and
call-site options override the defaults.

```elixir
alias NetRunner.Command

# Inline construction
cmd = Command.new("curl", ["-sS"], timeout: 30_000)
{body, 0} = NetRunner.run(cmd, args: ["https://example.com"])

# Extend at call time (args append; opts merge with runtime winning)
listing = Command.new("ls", ["-la"])
{out, 0} = NetRunner.run(listing, args: ["/tmp"])

# `defcommand` in your own module captures a reusable template:
defmodule MyCmds do
  use NetRunner.Command

  defcommand :curl, "curl", ["-sS", "--max-time", "30"]
  defcommand :echo, "echo"
end

{out, 0} = NetRunner.run(MyCmds.echo(["hi"]))
{:ok, stream} = NetRunner.stream(MyCmds.curl(["https://example.com"]))
```

## Error Handling Cheatsheet

```elixir
case NetRunner.run(["my_tool", arg], timeout: 5_000) do
  {output, 0} ->
    {:ok, output}

  {_partial, status} when status != 0 ->
    {:error, {:nonzero_exit, status}}

  {:error, :timeout} ->
    {:error, :took_too_long}

  {:error, {:max_output_exceeded, partial}} ->
    {:error, {:too_much_output, byte_size(partial)}}

  {:error, {:invalid_cmd, msg}} ->
    {:error, {:bad_cmd, msg}}

  {:error, {:invalid_args, msg}} ->
    {:error, {:bad_args, msg}}
end
```

## Parallel Execution

Every NetRunner process is fully independent — no shared state, no singleton bottleneck:

```elixir
# Process files in parallel
files
|> Task.async_stream(fn file ->
  {out, 0} = NetRunner.run(["ffprobe", "-hide_banner", file])
  {file, out}
end, max_concurrency: System.schedulers_online())
|> Enum.to_list()

# Fan-out pattern
urls
|> Task.async_stream(fn url ->
  {body, 0} = NetRunner.run(["curl", "-s", url], timeout: 30_000)
  body
end, max_concurrency: 20)
|> Enum.to_list()
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

## Performance

Spawn overhead is ~20-25ms per process (fork + execvp + UDS handshake + FD passing). This is a one-time cost — actual I/O is sub-millisecond. For comparison, `System.cmd` is ~10-15ms (simpler setup, same fork cost).

The tradeoff: ~10ms extra spawn time buys you backpressure, zero zombies, and process group kills. For long-running processes or large data streams, the spawn cost is negligible.

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

Apache-2.0 — see [LICENSE](LICENSE).
