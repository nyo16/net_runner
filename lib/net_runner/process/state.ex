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
    operations: %Operations{},
    awaiting_exit: [],
    stderr_mode: :consume,
    # Bounded tail of consumed stderr: only the most-recent
    # `stderr_tail_bytes` bytes are retained (the rest is drained and
    # dropped). Stats still count every byte. Held as a single binary.
    stderr_tail: <<>>,
    stderr_tail_bytes: 8_192,
    status: :starting,
    stats: %Stats{}
  ]

  @type status :: :starting | :running | :exiting | :exited
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
          operations: Operations.t(),
          awaiting_exit: [GenServer.from()],
          stderr_mode: :consume | :disabled,
          stderr_tail: binary(),
          stderr_tail_bytes: non_neg_integer(),
          status: status()
        }
end
