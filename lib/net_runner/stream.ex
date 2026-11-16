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
  # on its way out and a short grace suffices; a caller-supplied :kill_timeout
  # replaces it. A consumer that halted early (`stream!(~w(yes)) |>
  # Enum.take(1)`) leaves a child that is probably still running and no longer
  # wanted, so it escalates after a fixed 200 ms: an abandoned consumer must not
  # be blocked for a long :kill_timeout.
  @eof_grace_ms 1_000
  @halted_grace_ms 200

  @doc """
  Creates a stream that writes `input` to stdin and reads stdout chunks.

  Returns `{:ok, stream}` or `{:error, reason}`.

  ## Teardown

  When the stream ends, the child gets SIGTERM, then SIGKILL after a grace:

    * stdout reached EOF: stdin is closed and the grace is `:kill_timeout`
      when given, otherwise 1 000 ms.
    * the consumer halted early (e.g. `Enum.take/2`): a fixed 200 ms, so an
      abandoned consumer is never blocked for a long `:kill_timeout`.
  """
  # :timeout / :max_output_size are run/2-only: a lazy stream has no single
  # wall-clock or collected size to bound, so they are rejected here rather
  # than silently ignored.
  @stream_opts [
    :input,
    :input_buffer,
    :stderr,
    :stderr_tail_bytes,
    :pty,
    :cgroup_path,
    :kill_timeout,
    :cwd,
    :env,
    :no_new_privs,
    :pipe_size,
    :owner,
    :name
  ]

  @spec stream(String.t(), [String.t()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(cmd, args, opts) do
    opts = Keyword.validate!(opts, @stream_opts)
    # Eager lists are coalesced and validated before the spawn (as in run/2).
    input = InputWriter.prepare(Keyword.get(opts, :input, nil))
    input_buffer = InputWriter.validate_buffer!(Keyword.get(opts, :input_buffer, 0))
    eof_grace = Keyword.get(opts, :kill_timeout, @eof_grace_ms)
    # Pass the caller as :owner so the Process GenServer stops (and kills the OS
    # process) if nothing ever consumes the stream. build_stream/4 re-registers
    # the real consumer as owner once iteration starts.
    process_opts =
      opts
      |> Keyword.drop([:input, :input_buffer])
      |> Keyword.put_new(:owner, self())

    case Proc.start(cmd, args, process_opts) do
      {:ok, pid} ->
        stream = build_stream(pid, input, input_buffer, eof_grace)
        {:ok, stream}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Like `stream/3` but raises on error.
  """
  @spec stream!(String.t(), [String.t()], keyword()) :: Enumerable.t()
  def stream!(cmd, args, opts) do
    case stream(cmd, args, opts) do
      {:ok, s} -> s
      {:error, reason} -> raise NetRunner.Error, reason: {:spawn_failed, reason}
    end
  end

  defp build_stream(pid, input, input_buffer, eof_grace) do
    Stream.resource(
      fn ->
        # Re-register the owner here: this fun runs in the consumer, whereas the
        # :owner passed at spawn time is whichever process built the stream.
        # Building in A and consuming in B is a normal idiom, and A finishing
        # first must not kill the child out from under B. set_owner/2 replaces
        # the monitor, so the spawn-time owner still covers the window before
        # the first consumption.
        Proc.set_owner(pid, self())
        {:reading, InputWriter.start(pid, input, input_buffer)}
      end,
      fn acc -> read_next(pid, acc) end,
      fn
        {:done, writer} ->
          InputWriter.reap(writer, :done)
          cleanup_process(pid, :eof, eof_grace)

        {:reading, writer} ->
          # The consumer halted mid-stream.
          InputWriter.reap(writer, :halted)
          cleanup_process(pid, :halted, eof_grace)
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
    case Proc.read_batch(pid) do
      # Whatever the batch collected becomes the stream's next elements —
      # `{chunks, acc}` is the normal `Stream.resource` shape. Element sizes
      # stay ≤ the read size and ordering is preserved; several elements may
      # now be emitted per resource step.
      {:ok, chunks} ->
        {chunks, acc}

      # Distinct terminal accumulator: the after-fun uses it to tell a natural
      # end-of-stream apart from a consumer that halted mid-stream.
      :eof ->
        {:halt, {:done, writer}}

      {:error, :process_exited} ->
        {:halt, {:done, writer}}

      {:error, reason} ->
        raise NetRunner.Error, reason: {:read_error, reason}
    end
  end

  # :eof: the child closed stdout on its own, so close stdin and give it the
  # EOF grace (the caller's :kill_timeout when given) to exit before SIGKILL.
  # :halted: the child is still producing output nobody will read, so it gets
  # the fixed short grace.
  #
  # Proc.stop/1 is the answer to the teardown question cycle 1 left open: the
  # after-fun used to leave the server running and rely on the owner monitor,
  # which only fires when the *consumer* dies. A long-lived consumer — a
  # GenServer or LiveView streaming many commands — accumulated one Process
  # GenServer, one Watcher, a UDS socket and three pipe FDs per stream.
  defp cleanup_process(pid, reason, eof_grace) do
    reap_child(pid, reason, eof_grace)
    Proc.stop(pid)
  end

  defp reap_child(pid, reason, eof_grace) do
    if Process.alive?(pid) do
      if reason == :eof, do: Proc.close_stdin(pid)
      grace = if reason == :eof, do: eof_grace, else: @halted_grace_ms
      Proc.shutdown(pid, grace, 0)
    end

    :ok
  catch
    :exit, _ -> :ok
  end
end
