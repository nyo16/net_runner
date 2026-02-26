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

  alias NetRunner.Process, as: Proc
  alias NetRunner.Stream, as: NRStream

  @doc """
  Runs a command and collects all output.

  Returns `{output, exit_status}` where output is the concatenated stdout.

  ## Options

    * `:stderr` - `:consume` (default, captured internally), `:redirect` (merged with stdout),
      or `:disabled`
    * `:input` - data to write to stdin (binary or enumerable)
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
  """
  def run([cmd | args], opts \\ []) do
    input = Keyword.get(opts, :input, nil)
    timeout = Keyword.get(opts, :timeout, nil)
    max_output_size = Keyword.get(opts, :max_output_size, nil)
    process_opts = Keyword.drop(opts, [:input, :timeout, :max_output_size])

    {:ok, pid} = Proc.start(cmd, args, process_opts)

    # Run I/O in a task so we can enforce timeout via Task.yield
    task =
      Task.async(fn ->
        if input do
          write_all_input(pid, input)
        else
          Proc.close_stdin(pid)
        end

        case read_all_with_limits(pid, max_output_size) do
          {:ok, output} ->
            {:ok, exit_status} = Proc.await_exit(pid)
            {output, exit_status}

          {:error, _} = error ->
            error
        end
      end)

    effective_timeout = timeout || :infinity

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
  end

  @doc """
  Creates a stream for incremental I/O with the command.

  Returns a `Stream` that yields stdout binary chunks.
  Raises on process start failure.

  ## Options

    * `:input` - data to write to stdin (binary, list, or Stream)
    * `:stderr` - `:consume` (default), `:redirect`, or `:disabled`

  ## Examples

      # Stream through a command
      NetRunner.stream!(~w(sort))
      |> Enum.to_list()

      # With input
      NetRunner.stream!(~w(tr a-z A-Z), input: "hello")
      |> Enum.join()
      # => "HELLO"
  """
  def stream!([cmd | args], opts \\ []) do
    NRStream.stream!(cmd, args, opts)
  end

  @doc """
  Like `stream!/2` but returns `{:ok, stream}` or `{:error, reason}`.
  """
  def stream([cmd | args], opts \\ []) do
    NRStream.stream(cmd, args, opts)
  end

  # --- Private ---

  defp write_all_input(pid, input) when is_binary(input) do
    Proc.write(pid, input)
    Proc.close_stdin(pid)
  end

  defp write_all_input(pid, input) when is_list(input) do
    Enum.each(input, &Proc.write(pid, &1))
    Proc.close_stdin(pid)
  end

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
