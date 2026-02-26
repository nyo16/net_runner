defmodule NetRunner.Process.Pipe do
  @moduledoc false

  alias NetRunner.Process.Nif

  defstruct [:resource, :owner, :type]

  @type pipe_type :: :stdin | :stdout | :stderr
  @type t :: %__MODULE__{
          resource: reference() | nil,
          owner: pid(),
          type: pipe_type()
        }

  @doc """
  Creates a new pipe by wrapping a raw FD in a NIF resource.
  """
  def new(fd, owner, type) when type in [:stdin, :stdout, :stderr] do
    case Nif.nif_create_fd(fd, owner) do
      {:ok, resource} ->
        {:ok, %__MODULE__{resource: resource, owner: owner, type: type}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Reads up to `max_bytes` from the pipe.
  Returns `{:ok, binary}`, `{:error, :eagain}`, or `:eof`.
  """
  def read(%__MODULE__{resource: res}, max_bytes \\ 65_535) do
    Nif.nif_read(res, max_bytes)
  end

  @doc """
  Writes data to the pipe.
  Returns `{:ok, bytes_written}` or `{:error, :eagain}`.
  """
  def write(%__MODULE__{resource: res}, data) do
    Nif.nif_write(res, data)
  end

  @doc """
  Closes the pipe. Idempotent.
  """
  def close(%__MODULE__{resource: nil}), do: :ok

  def close(%__MODULE__{resource: res}) do
    Nif.nif_close(res)
  end
end
