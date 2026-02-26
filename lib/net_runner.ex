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

  ## Examples

      {output, 0} = NetRunner.run(~w(echo hello))
      {"hello\\n", 0} = {output, 0}

      {output, 0} = NetRunner.run(~w(cat), input: "from stdin")
  """
  def run([cmd | args], opts \\ []) do
    input = Keyword.get(opts, :input, nil)
    process_opts = Keyword.drop(opts, [:input])

    {:ok, pid} = Proc.start(cmd, args, process_opts)

    # Write input if provided
    if input do
      write_all_input(pid, input)
    else
      Proc.close_stdin(pid)
    end

    # Read all stdout
    output = read_all(pid)

    # Wait for exit
    {:ok, exit_status} = Proc.await_exit(pid)

    {output, exit_status}
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

  defp read_all(pid) do
    read_all(pid, [])
  end

  defp read_all(pid, acc) do
    case Proc.read(pid) do
      {:ok, data} -> read_all(pid, [data | acc])
      :eof -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, _} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
