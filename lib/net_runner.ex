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
  With `stderr: :capture` the shape becomes `{output, exit_status, stderr}`,
  where `stderr` is the retained stderr tail.

  Malformed options are programmer errors and raise `ArgumentError` — unknown
  keys (`Keyword.validate!/2`) as well as invalid values (`:output`,
  `:input_buffer`, `:stderr`, `:stderr_tail_bytes`, `:cgroup_path`, `:cwd`,
  `:env`). Runtime spawn failures (an invalid command, shepherd errors) return
  `{:error, reason}` instead. This convention holds at every NetRunner entry
  point.

  ## Options

    * `:stderr` - `:consume` (default, drained internally so the child never
      blocks on a full stderr pipe), `:capture` (drained the same way, and the
      retained tail is returned as a third element in the result tuple) or
      `:disabled`. In `:consume`/`:capture` mode only the most-recent
      `:stderr_tail_bytes` of stderr are retained (see
      `NetRunner.Process.stderr_tail/1`); the rest is drained and dropped.
    * `:stderr_tail_bytes` - cap (bytes) on the retained stderr tail. Default
      `8192`, max `1_048_576`. `0` retains nothing. The tail is raw bytes and
      may begin mid-character, so treat it as diagnostic text, not valid UTF-8.
    * `:input` - data to write to stdin. A binary or any `Enumerable` of
      iodata chunks — the same shapes `stream!/2` accepts. Written by a
      concurrent task while stdout is being read, so an input larger than the
      OS pipe buffers does not deadlock. Stdin is closed after the last chunk.
    * `:input_buffer` - bytes of stdin coalescing for a *lazy* `:input`
      enumerable. `0` (default) writes through element-by-element —
      interactive stdin (a PTY REPL fed by a `Stream`) depends on that
      granularity. A positive value batches elements into writes of up to
      that many bytes (elements are never split), trading stdin latency for
      throughput — `input_buffer: 65_536` makes `File.stream!` line input
      cheap. Eager lists always coalesce; a plain binary is a single write.
    * `:timeout` - maximum wall-clock time in milliseconds. Sends SIGTERM then SIGKILL
      on timeout. Returns `{:error, :timeout}` instead of `{output, exit_status}`.
      A child that ignores SIGTERM delays the return by up to the 5s escalation
      grace on top of `:timeout`.
    * `:max_output_size` - maximum bytes to collect from stdout. Kills the process
      and returns `{:error, {:max_output_exceeded, partial_output}}` if exceeded.
    * `:cwd` - working directory for the child. Defaults to the BEAM working
      directory. Relative values use the BEAM working directory as their base.
      The child resolves relative paths and executables from `:cwd`. A failed
      directory change returns `{:error, {:shepherd_error, reason}}`. This
      option does not change `PWD`.
    * `:output` - result shape for collected stdout: `:binary` (default)
      concatenates chunks into one binary; `:iodata` returns the collected
      chunks as iodata and skips the final flatten — for a 64 MiB output
      that flatten is an extra full-size allocation and copy. Pass the
      iodata straight to `File.write!/2`, a socket, or
      `IO.iodata_to_binary/1` when you do need a binary.
    * `:env` - child environment changes as a map or a list of `{name, value}`
      pairs. A binary value sets a variable. `nil` and `""` remove it. Names
      and values must contain valid UTF-8 and no NUL. Names must not contain
      `=`. The child uses the modified `PATH` to resolve its executable. Use
      an absolute command path when `:env` comes from untrusted input.

  Also accepted and passed through to the underlying process: `:pty`,
  `:cgroup_path`, `:kill_timeout`.

  ## Examples

      {output, 0} = NetRunner.run(~w(echo hello))
      {"hello\\n", 0} = {output, 0}

      {_out, 1, stderr} = NetRunner.run(["sh", "-c", "echo oops >&2; exit 1"], stderr: :capture)

      {output, 0} = NetRunner.run(~w(cat), input: "from stdin")

      {:error, :timeout} = NetRunner.run(~w(sleep 100), timeout: 100)

      {:error, {:max_output_exceeded, _partial}} =
        NetRunner.run(["sh", "-c", "yes"], max_output_size: 1000)

      # With a Command struct:
      cmd = NetRunner.Command.new("echo", ["hello"], timeout: 5_000)
      {output, 0} = NetRunner.run(cmd)
  """
  @run_opts [
    :input,
    :input_buffer,
    :timeout,
    :max_output_size,
    :output,
    :cwd,
    :stderr,
    :stderr_tail_bytes,
    :pty,
    :cgroup_path,
    :kill_timeout,
    :env
  ]

  @spec run(NetRunner.Command.t() | [String.t()], keyword()) ::
          {binary() | iodata(), non_neg_integer()}
          | {binary() | iodata(), non_neg_integer(), binary()}
          | {:error, term()}
  def run(command, opts \\ [])

  def run(%NetRunner.Command{} = command, opts) do
    {cmd, args, merged_opts} = NetRunner.Command.to_cmd_args_opts(command, opts)
    run_impl(cmd, args, merged_opts)
  end

  def run([], _opts), do: {:error, {:invalid_cmd, "empty command"}}

  def run([cmd | args], opts) do
    run_impl(cmd, args, opts)
  end

  defp run_impl(cmd, args, opts) do
    opts = Keyword.validate!(opts, @run_opts)
    # Lists coalesce here, in the caller, before the input is captured by any
    # task closure (see InputWriter.prepare/1).
    input = InputWriter.prepare(Keyword.get(opts, :input, nil))
    input_buffer = InputWriter.validate_buffer!(Keyword.get(opts, :input_buffer, 0))
    timeout = Keyword.get(opts, :timeout, nil)
    max_output_size = Keyword.get(opts, :max_output_size, nil)
    output = validate_output!(Keyword.get(opts, :output, :binary))
    capture_stderr? = Keyword.get(opts, :stderr, :consume) == :capture

    if capture_stderr? and Keyword.get(opts, :pty, false) do
      # PTY folds stderr into the master fd; the captured tail would always
      # be "". Reject rather than silently ignore, like every other option.
      raise ArgumentError, "stderr: :capture is not supported with pty: true"
    end

    process_opts =
      opts
      |> Keyword.drop([:input, :input_buffer, :timeout, :max_output_size, :output])
      # run/2 never hands the pid out, so the caller's death must tear the
      # Process down — without an owner monitor a killed caller leaks the
      # GenServer, Watcher and child for the VM's lifetime.
      |> Keyword.put(:owner, self())
      |> then(fn process_opts ->
        # :capture is run/2 sugar over :consume — the Process level only
        # knows :consume/:disabled; run/2 reads the tail back at the end.
        if capture_stderr?,
          do: Keyword.put(process_opts, :stderr, :consume),
          else: process_opts
      end)

    io = %{
      input: input,
      input_buffer: input_buffer,
      max_output_size: max_output_size,
      output: output,
      capture_stderr?: capture_stderr?
    }

    case Proc.start(cmd, args, process_opts) do
      {:ok, pid} ->
        run_with_pid(pid, timeout, io)

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_output!(mode) when mode in [:binary, :iodata], do: mode

  defp validate_output!(other) do
    raise ArgumentError, ":output must be :binary or :iodata, got: #{inspect(other)}"
  end

  defp run_with_pid(pid, timeout, io) do
    task = Task.async(fn -> run_io(pid, io) end)

    result =
      (Task.yield(task, timeout || :infinity) || Task.shutdown(task))
      |> handle_run_result(pid)

    # run/2 never hands the pid to the caller, so nothing else can ever stop
    # this server. Without it, each call leaks the Process GenServer, its
    # Watcher, the UDS socket and three pipe FDs for the lifetime of the VM.
    Proc.stop(pid)
    result
  end

  defp handle_run_result({:ok, {output, exit_status}}, _pid)
       when (is_binary(output) or is_list(output)) and is_integer(exit_status) do
    {output, exit_status}
  end

  defp handle_run_result({:ok, {output, exit_status, stderr}}, _pid)
       when (is_binary(output) or is_list(output)) and is_integer(exit_status) and
              is_binary(stderr) do
    {output, exit_status, stderr}
  end

  defp handle_run_result({:ok, {:error, _} = error}, pid) do
    kill_and_cleanup(pid)
    error
  end

  defp handle_run_result(nil, pid) do
    kill_and_cleanup(pid)
    {:error, :timeout}
  end

  defp handle_run_result({:exit, reason}, pid) do
    kill_and_cleanup(pid)
    {:error, {:task_crashed, reason}}
  end

  @doc """
  Creates a stream for incremental I/O with the command.

  Accepts either a command list `[executable | args]` or a `%NetRunner.Command{}` struct.

  Returns a `Stream` that yields stdout binary chunks. Raises
  `NetRunner.Error` on process start failure and on a mid-stream read error.

  ## Options

    * `:input` - data to write to stdin (binary or any `Enumerable` of iodata)
    * `:input_buffer` - bytes of stdin coalescing for a lazy `:input`
      enumerable; `0` (default) writes through element-by-element (what
      interactive stdin wants), a positive value batches elements into
      writes of up to that many bytes for throughput. Eager lists always
      coalesce.
    * `:stderr` - `:consume` (default) or `:disabled`

  `:timeout` and `:max_output_size` are `run/2`-only options and are rejected
  here — a lazy stream has no single wall-clock to bound. Unknown options
  raise `ArgumentError`.

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

  def stream!([], _opts) do
    # Wrapped in :spawn_failed like every other spawn-stage failure raised
    # by the bang variants, so callers branching on e.reason see one shape.
    raise NetRunner.Error, reason: {:spawn_failed, {:invalid_cmd, "empty command"}}
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

  def stream([], _opts), do: {:error, {:invalid_cmd, "empty command"}}

  def stream([cmd | args], opts) do
    NRStream.stream(cmd, args, opts)
  end

  # --- Private ---

  defp read_all_with_limits(pid, max_output_size, output_mode) do
    read_all_loop(pid, max_output_size, output_mode, 0, [])
  end

  defp read_all_loop(pid, max_size, output_mode, collected, acc) do
    case Proc.read_batch(pid) do
      {:ok, chunks} ->
        new_collected = collected + chunks_size(chunks)

        if max_size && new_collected > max_size do
          # Flatten once and cut at the limit; identical bytes to truncating
          # the overflowing chunk in place, on a path that is already an error.
          # The partial is always a binary, whatever the :output mode.
          partial = IO.iodata_to_binary([acc | chunks])
          {:error, {:max_output_exceeded, binary_part(partial, 0, max_size)}}
        else
          # Nested iodata — no Enum.reverse, no per-batch list rebuild; the
          # single flatten (if :binary mode asks for one) happens at :eof.
          read_all_loop(pid, max_size, output_mode, new_collected, [acc | chunks])
        end

      :eof ->
        {:ok, finalize_output(acc, output_mode)}

      {:error, _} ->
        # Intentional (long-standing run/2 shape, unlike stream!'s raise):
        # :closed / :process_exited are ordinary end-of-output for a child
        # that died mid-stream, and the exit status the caller receives is
        # what reports the failure. A genuine read fault surfaces the same
        # way — as truncated output plus the child's status — rather than
        # discarding everything already collected.
        {:ok, finalize_output(acc, output_mode)}
    end
  end

  defp finalize_output(acc, :binary), do: IO.iodata_to_binary(acc)
  defp finalize_output(acc, :iodata), do: acc

  defp chunks_size(chunks), do: Enum.reduce(chunks, 0, &(byte_size(&1) + &2))

  defp run_io(pid, io) do
    # The writer must run concurrently with the reader. Writing to completion
    # first deadlocks any filter command once the input exceeds
    # stdin_buffer + stdout_buffer (~128 KiB on macOS): the child fills its
    # stdout pipe, blocks in write(2), and therefore stops draining stdin,
    # while we are blocked filling stdin. Neither side can move and the
    # default :timeout of nil means there is no escape.
    writer = InputWriter.start(pid, io.input, io.input_buffer)

    case read_all_with_limits(pid, io.max_output_size, io.output) do
      {:ok, output} ->
        InputWriter.reap(writer, :done)
        {:ok, exit_status} = Proc.await_exit(pid)

        if io.capture_stderr? do
          # Read the tail only after the exit: the internal drain has seen
          # stderr EOF by then, so the tail is complete.
          {output, exit_status, Proc.stderr_tail(pid)}
        else
          {output, exit_status}
        end

      {:error, _} = error ->
        InputWriter.reap(writer, :halted)
        error
    end
  end

  defp kill_and_cleanup(pid) do
    # Grace values preserved from the pre-unification implementation.
    Proc.shutdown(pid, 5_000, 0)
    :ok
  end
end
