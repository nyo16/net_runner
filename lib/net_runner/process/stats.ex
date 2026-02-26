defmodule NetRunner.Process.Stats do
  @moduledoc false

  defstruct bytes_in: 0,
            bytes_out: 0,
            bytes_err: 0,
            started_at: nil,
            duration_ms: nil,
            read_count: 0,
            write_count: 0,
            exit_status: nil

  @type t :: %__MODULE__{
          bytes_in: non_neg_integer(),
          bytes_out: non_neg_integer(),
          bytes_err: non_neg_integer(),
          started_at: integer() | nil,
          duration_ms: non_neg_integer() | nil,
          read_count: non_neg_integer(),
          write_count: non_neg_integer(),
          exit_status: non_neg_integer() | nil
        }

  def new do
    %__MODULE__{started_at: System.monotonic_time(:millisecond)}
  end

  def record_read(%__MODULE__{} = stats, bytes) do
    %{stats | bytes_out: stats.bytes_out + bytes, read_count: stats.read_count + 1}
  end

  def record_read_stderr(%__MODULE__{} = stats, bytes) do
    %{stats | bytes_err: stats.bytes_err + bytes}
  end

  def record_write(%__MODULE__{} = stats, bytes) do
    %{stats | bytes_in: stats.bytes_in + bytes, write_count: stats.write_count + 1}
  end

  def finalize(%__MODULE__{} = stats, exit_status) do
    now = System.monotonic_time(:millisecond)
    duration = if stats.started_at, do: now - stats.started_at, else: 0
    %{stats | exit_status: exit_status, duration_ms: duration}
  end
end
