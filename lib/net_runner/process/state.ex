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
    operations: %Operations{},
    awaiting_exit: [],
    stderr_mode: :consume,
    stderr_buffer: [],
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
          operations: Operations.t(),
          awaiting_exit: [GenServer.from()],
          stderr_mode: :consume | :redirect | :disabled,
          stderr_buffer: [binary()],
          status: status()
        }
end
