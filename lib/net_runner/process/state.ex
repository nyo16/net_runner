defmodule NetRunner.Process.State do
  @moduledoc false

  alias NetRunner.Process.{Operations, Pipe, Stats}

  defstruct [
    :shepherd_port,
    :uds_socket,
    :stdin,
    :stdout,
    :stderr,
    :os_pid,
    :exit_status,
    :cmd,
    :args,
    :owner_ref,
    # Belt-and-suspenders Watcher pid; told to stand down once the exit
    # status is delivered so it can never signal a reused OS pid.
    :watcher,
    operations: %Operations{},
    awaiting_exit: [],
    stderr_mode: :consume,
    # Bounded tail of consumed stderr: only the most-recent
    # `stderr_tail_bytes` bytes are retained (the rest is drained and
    # dropped). Stats still count every byte. Held as a single binary.
    stderr_tail: <<>>,
    stderr_tail_bytes: 8_192,
    # Unconsumed bytes read from the shepherd's UDS. The socket is a byte
    # stream, so a read can deliver half a frame or several frames at once —
    # a frame boundary is not a read boundary. Anything not yet parsed lives
    # here until the next read completes it.
    uds_carry: <<>>,
    # True while a :continue_writes self-send is in flight; dedupes budget
    # yields so a retry pass over N parked writes queues one resume message,
    # not N.
    continue_writes_scheduled?: false,
    status: :running,
    stats: %Stats{}
  ]

  @type status :: :running | :exiting | :exited
  @type t :: %__MODULE__{
          shepherd_port: port() | nil,
          uds_socket: :socket.socket() | nil,
          stdin: Pipe.t() | nil,
          stdout: Pipe.t() | nil,
          stderr: Pipe.t() | nil,
          os_pid: non_neg_integer() | nil,
          exit_status: non_neg_integer() | nil,
          cmd: String.t(),
          args: [String.t()],
          owner_ref: reference() | nil,
          watcher: pid() | nil,
          operations: Operations.t(),
          awaiting_exit: [GenServer.from()],
          stderr_mode: :consume | :disabled,
          stderr_tail: binary(),
          stderr_tail_bytes: non_neg_integer(),
          uds_carry: binary(),
          continue_writes_scheduled?: boolean(),
          status: status(),
          stats: Stats.t()
        }
end
