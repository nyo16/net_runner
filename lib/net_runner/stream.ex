defmodule NetRunner.Stream do
  @moduledoc """
  Stream-based interface for incremental I/O with OS processes.

  Uses `Stream.resource/3` to provide lazy, demand-driven reads from stdout.
  Input is written via a background `Task` to avoid deadlock.

  Typically used through `NetRunner.stream!/2` or `NetRunner.stream/2`.
  """

  alias NetRunner.Process, as: Proc

  # A stream that reached :eof has a child which already closed stdout, so it is
  # on its way out and a short grace suffices. A consumer that halted early
  # (`stream!(~w(yes)) |> Enum.take(1)`) leaves a child that is probably still
  # running and no longer wanted, so escalate straight away rather than stalling
  # the consumer for seconds.
  @eof_grace_ms 1_000
  @halted_grace_ms 200

  @doc """
  Creates a stream that writes `input` to stdin and reads stdout chunks.

  Returns `{:ok, stream}` or `{:error, reason}`.
  """
  def stream(cmd, args, opts) do
    input = Keyword.get(opts, :input, nil)
    # Pass the caller as :owner so the Process GenServer stops (and kills the OS
    # process) if nothing ever consumes the stream. build_stream/2 re-registers
    # the real consumer as owner once iteration starts.
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
      fn ->
        # Re-register the owner here: this fun runs in the consumer, whereas the
        # :owner passed at spawn time is whichever process built the stream.
        # Building in A and consuming in B is a normal idiom, and A finishing
        # first must not kill the child out from under B. set_owner/2 replaces
        # the monitor, so the spawn-time owner still covers the window before
        # the first consumption.
        Proc.set_owner(pid, self())
        start_writer(pid, input)
      end,
      fn acc -> read_next(pid, acc) end,
      fn
        {:error, proc_pid, reason} ->
          cleanup_process(proc_pid, :halted)
          raise "writer task crashed: #{inspect(reason)}"

        :done ->
          cleanup_process(pid, :eof)

        _acc ->
          # Still :reading or {:writing, _} — the consumer halted early.
          cleanup_process(pid, :halted)
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

      # Distinct terminal accumulator: the after-fun uses it to tell a natural
      # end-of-stream apart from a consumer that halted mid-stream.
      :eof ->
        {:halt, :done}

      {:error, :process_exited} ->
        {:halt, :done}

      {:error, reason} ->
        raise "read error: #{inspect(reason)}"
    end
  end

  # :eof — the child closed stdout on its own, so wait briefly for it to reap.
  defp cleanup_process(pid, :eof) do
    if Process.alive?(pid) do
      Proc.close_stdin(pid)
      stop_process(pid, @eof_grace_ms)
    end
  catch
    :exit, _ -> :ok
  end

  # Halted early — the child is still producing output nobody will read, so
  # signal it immediately and keep the wait short.
  defp cleanup_process(pid, :halted) do
    if Process.alive?(pid) do
      Proc.kill(pid, :sigterm)
      stop_process(pid, @halted_grace_ms)
    end
  catch
    :exit, _ -> :ok
  end

  defp stop_process(pid, grace_ms) do
    case await_exit(pid, grace_ms) do
      {:ok, _status} -> :ok
      _ -> Proc.kill(pid, :sigkill)
    end
  end

  # Proc.await_exit/2 is a GenServer.call, so exhausting the grace exits the
  # consumer. Trap it here so the SIGKILL escalation in stop_process/2 is
  # reachable instead of unwinding to the cleanup clauses' catch.
  defp await_exit(pid, timeout) do
    Proc.await_exit(pid, timeout)
  catch
    :exit, _ -> :timeout
  end
end
