defmodule NetRunner.Stream do
  @moduledoc """
  Stream-based interface for incremental I/O with OS processes.

  Uses `Stream.resource/3` to provide lazy, demand-driven reads from stdout.
  Input is written via a background `Task` to avoid deadlock.

  Typically used through `NetRunner.stream!/2` or `NetRunner.stream/2`.
  """

  alias NetRunner.InputWriter
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
        {:reading, InputWriter.start(pid, input)}
      end,
      fn acc -> read_next(pid, acc) end,
      fn
        {:done, writer} ->
          InputWriter.reap(writer, :done)
          cleanup_process(pid, :eof)

        {:reading, writer} ->
          # The consumer halted mid-stream.
          InputWriter.reap(writer, :halted)
          cleanup_process(pid, :halted)
      end
    )
  end

  # The writer is carried through the accumulator untouched and reaped once in
  # the after-fun. It used to be polled with `Task.yield(writer, 0)` on *every*
  # stdout chunk — a selective receive with `after 0`, so O(mailbox length) per
  # chunk: free for a bare consumer, pathological for a GenServer or LiveView
  # with unrelated traffic in its mailbox. Its only jobs were flipping the
  # accumulator and prettifying a writer crash, and `Task.async` links, so an
  # abnormal writer exit already takes the consumer down before a poll could
  # observe it.
  defp read_next(pid, {:reading, writer} = acc) do
    case Proc.read(pid) do
      {:ok, data} ->
        {[data], acc}

      # Distinct terminal accumulator: the after-fun uses it to tell a natural
      # end-of-stream apart from a consumer that halted mid-stream.
      :eof ->
        {:halt, {:done, writer}}

      {:error, :process_exited} ->
        {:halt, {:done, writer}}

      {:error, reason} ->
        raise "read error: #{inspect(reason)}"
    end
  end

  # :eof — the child closed stdout on its own, so wait briefly for it to reap.
  defp cleanup_process(pid, :eof) do
    reap_child(pid, :eof)
    Proc.stop(pid)
  end

  # Halted early — the child is still producing output nobody will read, so
  # signal it immediately and keep the wait short.
  defp cleanup_process(pid, :halted) do
    reap_child(pid, :halted)
    Proc.stop(pid)
  end

  # Proc.stop/1 is the answer to the teardown question cycle 1 left open: the
  # after-fun used to leave the server running and rely on the owner monitor,
  # which only fires when the *consumer* dies. A long-lived consumer — a
  # GenServer or LiveView streaming many commands — accumulated one Process
  # GenServer, one Watcher, a UDS socket and three pipe FDs per stream.
  defp reap_child(pid, :eof) do
    if Process.alive?(pid) do
      Proc.close_stdin(pid)
      stop_process(pid, @eof_grace_ms)
    end
  catch
    :exit, _ -> :ok
  end

  defp reap_child(pid, :halted) do
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
