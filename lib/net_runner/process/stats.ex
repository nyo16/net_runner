defmodule NetRunner.Process.Stats do
  @moduledoc """
  Accumulated I/O and lifecycle statistics for one `NetRunner.Process`.

  Returned by `NetRunner.Process.stats/1`.
  """

  defstruct bytes_in: 0,
            bytes_out: 0,
            bytes_err: 0,
            started_at: nil,
            duration_ms: nil,
            read_count: 0,
            write_count: 0,
            exit_status: nil

  @typedoc """
  Per-process counters.

    * `:bytes_in` — bytes written to the child's stdin
    * `:bytes_out` — bytes read from the child's stdout
    * `:bytes_err` — bytes read from the child's stderr (drained or explicit)
    * `:started_at` — monotonic start time, milliseconds
    * `:duration_ms` — set on exit: wall time from spawn to exit status
    * `:read_count` / `:write_count` — number of `read(2)`/`write(2)` calls
    * `:exit_status` — set on exit
  """
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

  # `count` is the number of read(2) calls the bytes took (a batched read
  # folds its whole pass into one update without changing what `read_count`
  # means).
  def record_read(%__MODULE__{} = stats, bytes, count \\ 1) do
    %{stats | bytes_out: stats.bytes_out + bytes, read_count: stats.read_count + count}
  end

  def record_read_stderr(%__MODULE__{} = stats, bytes) do
    %{stats | bytes_err: stats.bytes_err + bytes}
  end

  # `count` is the number of write(2) calls the bytes took, so a partial-write
  # loop can fold its whole run into one struct update without changing what
  # `write_count` means.
  def record_write(%__MODULE__{} = stats, bytes, count \\ 1) do
    %{stats | bytes_in: stats.bytes_in + bytes, write_count: stats.write_count + count}
  end

  def finalize(%__MODULE__{} = stats, exit_status) do
    now = System.monotonic_time(:millisecond)
    duration = if stats.started_at, do: now - stats.started_at, else: 0
    %{stats | exit_status: exit_status, duration_ms: duration}
  end
end
