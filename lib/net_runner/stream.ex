defmodule NetRunner.Stream do
  @moduledoc """
  Stream-based interface for incremental I/O with OS processes.

  Uses `Stream.resource/3` to provide lazy, demand-driven reads from stdout.
  Input is written via a background `Task` to avoid deadlock.

  Typically used through `NetRunner.stream!/2` or `NetRunner.stream/2`.
  """

  alias NetRunner.Process, as: Proc

  defmodule AbnormalExit do
    defexception [:exit_status, :stderr]

    @impl true
    def message(%{exit_status: status, stderr: stderr}) do
      msg = "process exited with status #{status}"
      if stderr && stderr != "", do: "#{msg}: #{stderr}", else: msg
    end
  end

  @doc """
  Creates a stream that writes `input` to stdin and reads stdout chunks.

  Returns `{:ok, stream}` or `{:error, reason}`.
  """
  def stream(cmd, args, opts) do
    input = Keyword.get(opts, :input, nil)
    # Pass the caller as :owner so the Process GenServer stops (and kills
    # the OS process) if the stream consumer crashes before Stream.resource's
    # after callback would otherwise run.
    process_opts =
      opts
      |> Keyword.drop([:input])
      |> Keyword.put_new(:owner, self())

    case Proc.start(cmd, args, process_opts) do
      {:ok, pid} ->
        stream = build_stream(pid, input)
        {:ok, stream}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Like `stream/3` but raises on error.
  """
  def stream!(cmd, args, opts) do
    case stream(cmd, args, opts) do
      {:ok, s} -> s
      {:error, reason} -> raise "failed to start process: #{inspect(reason)}"
    end
  end

  defp build_stream(pid, input) do
    Stream.resource(
      fn -> start_writer(pid, input) end,
      fn acc -> read_next(pid, acc) end,
      fn
        {:error, proc_pid, reason} ->
          cleanup_process(proc_pid)
          raise "writer task crashed: #{inspect(reason)}"

        _acc ->
          cleanup_process(pid)
      end
    )
  end

  defp start_writer(pid, nil) do
    # No input — close stdin immediately
    Proc.close_stdin(pid)
    :reading
  end

  defp start_writer(pid, input) when is_binary(input) do
    writer =
      Task.async(fn ->
        Proc.write(pid, input)
        Proc.close_stdin(pid)
      end)

    {:writing, writer}
  end

  defp start_writer(pid, %Stream{} = input) do
    start_writer(pid, {:enumerable, input})
  end

  defp start_writer(pid, {:enumerable, enumerable}) do
    writer =
      Task.async(fn ->
        Enum.each(enumerable, fn chunk ->
          Proc.write(pid, chunk)
        end)

        Proc.close_stdin(pid)
      end)

    {:writing, writer}
  end

  defp start_writer(pid, input) when is_list(input) do
    start_writer(pid, {:enumerable, input})
  end

  defp read_next(pid, {:writing, writer} = acc) do
    # Check if writer is done, but don't block
    case Task.yield(writer, 0) do
      {:ok, _} -> read_next(pid, :reading)
      {:exit, reason} -> {:halt, {:error, pid, reason}}
      nil -> do_read(pid, acc)
    end
  end

  defp read_next(pid, :reading) do
    do_read(pid, :reading)
  end

  defp do_read(pid, acc) do
    case Proc.read(pid) do
      {:ok, data} ->
        {[data], acc}

      :eof ->
        {:halt, acc}

      {:error, :process_exited} ->
        {:halt, acc}

      {:error, reason} ->
        raise "read error: #{inspect(reason)}"
    end
  end

  defp cleanup_process(pid) do
    if Process.alive?(pid) do
      Proc.close_stdin(pid)

      case Proc.await_exit(pid, 5_000) do
        {:ok, _status} -> :ok
        _ -> Proc.kill(pid, :sigkill)
      end
    end
  catch
    :exit, _ -> :ok
  end
end
