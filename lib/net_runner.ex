defmodule NetRunner do
  @moduledoc """
  Safe OS process execution for Elixir.

  Combines NIF-based async I/O with a persistent shepherd binary to guarantee
  zero zombie processes, even under BEAM SIGKILL.

  ## Quick start

      # Simple command execution
      {output, 0} = NetRunner.run(~w(echo hello))

      # Streaming with input
      NetRunner.stream!(~w(cat), input: "hello world")
      |> Enum.to_list()
      # => ["hello world"]

      # Piping data through a command
      NetRunner.stream!(~w(wc -c), input: "hello")
      |> Enum.join()
      # => "       5\\n"
  """

  alias NetRunner.InputWriter
  alias NetRunner.Process, as: Proc
  alias NetRunner.Stream, as: NRStream

  @doc """
  Runs a command and collects all output.

  Accepts either a command list `[executable | args]` or a `%NetRunner.Command{}` struct.

  Returns `{output, exit_status}` where output is the concatenated stdout.

  ## Options

    * `:stderr` - `:consume` (default, drained internally so the child never
      blocks on a full stderr pipe) or `:disabled`. In `:consume` mode only the
      most-recent `:stderr_tail_bytes` of stderr are retained (see
      `NetRunner.Process.stderr_tail/1`); the rest is drained and dropped.
    * `:stderr_tail_bytes` - cap (bytes) on the retained stderr tail. Default
      `8192`. `0` retains nothing. The tail is raw bytes and may begin
      mid-character, so treat it as diagnostic text, not valid UTF-8.
    * `:input` - data to write to stdin. A binary, a list of binaries, or a
      `Stream` — the same three shapes `stream!/2` accepts. Written by a
      concurrent task while stdout is being read, so an input larger than the
      OS pipe buffers does not deadlock. Stdin is closed after the last chunk.
    * `:timeout` - maximum wall-clock time in milliseconds. Sends SIGTERM then SIGKILL
      on timeout. Returns `{:error, :timeout}` instead of `{output, exit_status}`.
    * `:max_output_size` - maximum bytes to collect from stdout. Kills the process
      and returns `{:error, {:max_output_exceeded, partial_output}}` if exceeded.

  ## Examples

      {output, 0} = NetRunner.run(~w(echo hello))
      {"hello\\n", 0} = {output, 0}

      {output, 0} = NetRunner.run(~w(cat), input: "from stdin")

      {:error, :timeout} = NetRunner.run(~w(sleep 100), timeout: 100)

      {:error, {:max_output_exceeded, _partial}} =
        NetRunner.run(["sh", "-c", "yes"], max_output_size: 1000)

      # With a Command struct:
      cmd = NetRunner.Command.new("echo", ["hello"], timeout: 5_000)
      {output, 0} = NetRunner.run(cmd)
  """
  @spec run(NetRunner.Command.t() | [String.t()], keyword()) ::
          {binary(), non_neg_integer()} | {:error, term()}
  def run(command, opts \\ [])

  def run(%NetRunner.Command{} = command, opts) do
    {cmd, args, merged_opts} = NetRunner.Command.to_cmd_args_opts(command, opts)
    run_impl(cmd, args, merged_opts)
  end

  def run([cmd | args], opts) do
    run_impl(cmd, args, opts)
  end

  defp run_impl(cmd, args, opts) do
    input = Keyword.get(opts, :input, nil)
    timeout = Keyword.get(opts, :timeout, nil)
    max_output_size = Keyword.get(opts, :max_output_size, nil)
    process_opts = Keyword.drop(opts, [:input, :timeout, :max_output_size])

    case Proc.start(cmd, args, process_opts) do
      {:ok, pid} ->
        run_with_pid(pid, input, timeout, max_output_size)

      {:error, _reason} = error ->
        error
    end
  end

  defp run_with_pid(pid, input, timeout, max_output_size) do
    task = Task.async(fn -> run_io(pid, input, max_output_size) end)

    effective_timeout = timeout || :infinity

    result =
      case Task.yield(task, effective_timeout) || Task.shutdown(task) do
        {:ok, {output, exit_status}} when is_binary(output) and is_integer(exit_status) ->
          {output, exit_status}

        {:ok, {:error, _} = error} ->
          kill_and_cleanup(pid)
          error

        nil ->
          kill_and_cleanup(pid)
          {:error, :timeout}

        {:exit, reason} ->
          kill_and_cleanup(pid)
          {:error, {:task_crashed, reason}}
      end

    # run/2 never hands the pid to the caller, so nothing else can ever stop
    # this server. Without it, each call leaks the Process GenServer, its
    # Watcher, the UDS socket and three pipe FDs for the lifetime of the VM.
    Proc.stop(pid)
    result
  end

  @doc """
  Creates a stream for incremental I/O with the command.

  Accepts either a command list `[executable | args]` or a `%NetRunner.Command{}` struct.

  Returns a `Stream` that yields stdout binary chunks.
  Raises on process start failure.

  ## Options

    * `:input` - data to write to stdin (binary, list, or Stream)
    * `:stderr` - `:consume` (default) or `:disabled`

  ## Examples

      # Stream through a command
      NetRunner.stream!(~w(sort))
      |> Enum.to_list()

      # With input
      NetRunner.stream!(~w(tr a-z A-Z), input: "hello")
      |> Enum.join()
      # => "HELLO"

      # With a Command struct:
      cmd = NetRunner.Command.new("cat", [], input: "hello")
      NetRunner.stream!(cmd) |> Enum.to_list()
  """
  @spec stream!(NetRunner.Command.t() | [String.t()], keyword()) :: Enumerable.t()
  def stream!(command, opts \\ [])

  def stream!(%NetRunner.Command{} = command, opts) do
    {cmd, args, merged_opts} = NetRunner.Command.to_cmd_args_opts(command, opts)
    NRStream.stream!(cmd, args, merged_opts)
  end

  def stream!([cmd | args], opts) do
    NRStream.stream!(cmd, args, opts)
  end

  @doc """
  Like `stream!/2` but returns `{:ok, stream}` or `{:error, reason}`.

  Accepts either a command list `[executable | args]` or a `%NetRunner.Command{}` struct.
  """
  @spec stream(NetRunner.Command.t() | [String.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(command, opts \\ [])

  def stream(%NetRunner.Command{} = command, opts) do
    {cmd, args, merged_opts} = NetRunner.Command.to_cmd_args_opts(command, opts)
    NRStream.stream(cmd, args, merged_opts)
  end

  def stream([cmd | args], opts) do
    NRStream.stream(cmd, args, opts)
  end

  # --- Private ---

  defp read_all_with_limits(pid, max_output_size) do
    read_all_loop(pid, max_output_size, 0, [])
  end

  defp read_all_loop(pid, max_size, collected, acc) do
    case Proc.read(pid) do
      {:ok, data} ->
        new_collected = collected + byte_size(data)

        if max_size && new_collected > max_size do
          overshoot = new_collected - max_size
          keep = byte_size(data) - overshoot
          truncated = binary_part(data, 0, keep)
          partial = [truncated | acc] |> Enum.reverse() |> IO.iodata_to_binary()
          {:error, {:max_output_exceeded, partial}}
        else
          read_all_loop(pid, max_size, new_collected, [data | acc])
        end

      :eof ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, _} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp run_io(pid, input, max_output_size) do
    # The writer must run concurrently with the reader. Writing to completion
    # first deadlocks any filter command once the input exceeds
    # stdin_buffer + stdout_buffer (~128 KiB on macOS): the child fills its
    # stdout pipe, blocks in write(2), and therefore stops draining stdin,
    # while we are blocked filling stdin. Neither side can move and the
    # default :timeout of nil means there is no escape.
    writer = InputWriter.start(pid, input)

    case read_all_with_limits(pid, max_output_size) do
      {:ok, output} ->
        InputWriter.reap(writer, :done)
        {:ok, exit_status} = Proc.await_exit(pid)
        {output, exit_status}

      {:error, _} = error ->
        InputWriter.reap(writer, :halted)
        error
    end
  end

  defp kill_and_cleanup(pid) do
    Proc.kill(pid, :sigterm)

    case Proc.await_exit(pid, 5_000) do
      {:ok, _} -> :ok
      _ -> Proc.kill(pid, :sigkill)
    end
  catch
    :exit, _ -> :ok
  end
end
