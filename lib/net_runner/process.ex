defmodule NetRunner.Process do
  @moduledoc """
  GenServer managing a single OS process lifecycle.

  Handles read/write on pipes, graceful shutdown, and exit status tracking.
  Uses NIF-backed async I/O with `enif_select` for backpressure.

  ## PTY mode

  Pass `pty: true` to get a pseudo-terminal. This is for **interactive and
  long-running programs** (shells, REPLs, curses apps). Key differences from
  pipe mode:

    * No independent stdin close — the PTY is a single bidirectional FD.
      Use `kill/2` to terminate the process.
    * The terminal echoes input back, so reads include what you wrote.
    * Fast-exiting commands may lose output if you don't read immediately —
      the PTY buffer is torn down when the slave side closes.
    * For simple commands, use pipe mode (the default).
  """

  use GenServer

  alias NetRunner.Process.{Exec, Nif, Operations, Pipe, Stats}
  alias NetRunner.Signal

  @default_read_size 65_535

  # Backstop only. Exit status normally arrives over the UDS; this fires when
  # the shepherd died without delivering one.
  @force_exit_timeout 5_000

  # --- Public API ---

  def start_link(cmd, args \\ [], opts \\ []) do
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, {cmd, args, opts}, gen_opts)
  end

  def start(cmd, args \\ [], opts \\ []) do
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start(__MODULE__, {cmd, args, opts}, gen_opts)
  end

  @doc "Read from stdout. Blocks until data available or EOF."
  def read(process, max_bytes \\ @default_read_size) do
    GenServer.call(process, {:read, :stdout, max_bytes}, :infinity)
  end

  @doc "Read from stderr."
  def read_stderr(process, max_bytes \\ @default_read_size) do
    GenServer.call(process, {:read, :stderr, max_bytes}, :infinity)
  end

  @doc "Write to stdin."
  def write(process, data) do
    GenServer.call(process, {:write, data}, :infinity)
  end

  @doc "Close stdin pipe."
  def close_stdin(process) do
    GenServer.call(process, :close_stdin)
  end

  @doc "Send a signal to the OS process."
  def kill(process, signal \\ :sigterm) do
    GenServer.call(process, {:kill, signal})
  end

  @doc "Wait for the process to exit. Returns `{:ok, exit_status}`."
  def await_exit(process, timeout \\ :infinity) do
    GenServer.call(process, :await_exit, timeout)
  end

  @doc "Get the OS PID."
  def os_pid(process) do
    GenServer.call(process, :os_pid)
  end

  @doc "Check if the process is alive."
  def alive?(process) do
    GenServer.call(process, :alive?)
  end

  @doc "Get accumulated stats."
  def stats(process) do
    GenServer.call(process, :stats)
  end

  @doc """
  Returns the retained tail of consumed stderr.

  In the default `:consume` stderr mode, stderr is drained to keep the child
  from blocking on a full pipe; only the most-recent `:stderr_tail_bytes`
  bytes (default 8 KB) are retained and returned here. Useful for diagnosing
  why a command failed.

  The tail is raw bytes and may begin mid-character if stderr was truncated,
  so treat it as diagnostic text rather than guaranteed-valid UTF-8. Returns
  `""` in `:disabled` mode.
  """
  @spec stderr_tail(GenServer.server()) :: binary()
  def stderr_tail(process) do
    GenServer.call(process, :stderr_tail)
  end

  @doc "Set PTY window size (rows, cols). Only works in PTY mode."
  def set_window_size(process, rows, cols) do
    GenServer.call(process, {:set_window_size, rows, cols})
  end

  @doc """
  Re-registers the process whose death should tear this OS process down.

  Replaces any previous owner monitor rather than stacking on it.
  `NetRunner.Stream` uses this to move the monitor from the process that
  *built* the stream to the one actually consuming it — otherwise the builder
  finishing first SIGKILLs a child the consumer is still reading.
  """
  @spec set_owner(GenServer.server(), pid()) :: :ok
  def set_owner(process, owner) when is_pid(owner) do
    GenServer.call(process, {:set_owner, owner})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({cmd, args, opts}) do
    case Exec.spawn_process(cmd, args, opts) do
      {:ok, state} ->
        # Optionally monitor an "owner" process (typically the stream
        # consumer). If it dies before the OS process exits we kill the
        # OS process and stop cleanly instead of leaking a GenServer.
        owner_ref =
          case Keyword.get(opts, :owner) do
            pid when is_pid(pid) -> Process.monitor(pid)
            _ -> nil
          end

        state = %{state | stats: Stats.new(), owner_ref: owner_ref}
        # Register with watcher for belt-and-suspenders cleanup
        NetRunner.Watcher.watch(self(), state.os_pid)
        # Start reading stderr in :consume mode
        if state.stderr_mode == :consume do
          kick_stderr_read(state)
        end

        # A child that exited before spawn_process/3 returned delivered its
        # exit status in the same recvmsg as MSG_CHILD_STARTED, so parse the
        # carry before anything else. Then arm the socket so later frames
        # arrive as messages instead of waiting for the shepherd Port to die.
        state = arm_uds(state)

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:read, pipe_name, max_bytes}, from, state) do
    pipe = get_pipe(state, pipe_name)

    if is_nil(pipe) do
      {:reply, {:error, :closed}, state}
    else
      case Pipe.read(pipe, max_bytes) do
        {:ok, data} ->
          stats = Stats.record_read(state.stats, byte_size(data))
          {:reply, {:ok, data}, %{state | stats: stats}}

        :eof ->
          {:reply, :eof, state}

        {:error, :eagain} ->
          {ops, _ref} = Operations.park(state.operations, {:read, pipe_name}, from, max_bytes)
          {:noreply, %{state | operations: ops}}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:write, data}, from, state) do
    if is_nil(state.stdin) do
      {:reply, {:error, :closed}, state}
    else
      do_write(data, from, state)
    end
  end

  def handle_call(:close_stdin, _from, state) do
    result =
      if state.stdin do
        # Close via NIF (BEAM side)
        Pipe.close(state.stdin)
      else
        :ok
      end

    # Also tell shepherd to close its copy
    send_shepherd_command(state, <<0x02>>)

    {:reply, result, %{state | stdin: nil}}
  end

  def handle_call({:kill, signal}, _from, state) do
    case Signal.resolve(signal) do
      {:ok, sig_num} ->
        if state.os_pid do
          # Send through shepherd protocol for process group kill
          send_shepherd_command(state, <<0x01, sig_num::8>>)
          # Also direct NIF kill as belt-and-suspenders
          Nif.nif_kill(state.os_pid, sig_num)
          {:reply, :ok, %{state | status: :exiting}}
        else
          {:reply, {:error, :no_pid}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:await_exit, from, state) do
    if state.status == :exited do
      {:reply, {:ok, state.exit_status}, state}
    else
      {:noreply, %{state | awaiting_exit: [from | state.awaiting_exit]}}
    end
  end

  def handle_call(:os_pid, _from, state) do
    {:reply, state.os_pid, state}
  end

  def handle_call(:alive?, _from, state) do
    {:reply, state.status in [:starting, :running, :exiting], state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  def handle_call(:stderr_tail, _from, state) do
    {:reply, state.stderr_tail, state}
  end

  def handle_call({:set_window_size, rows, cols}, _from, state) do
    send_shepherd_command(state, <<0x03, rows::big-16, cols::big-16>>)
    {:reply, :ok, state}
  end

  def handle_call({:set_owner, owner}, _from, state) do
    # Replace, don't stack: Stream calls this on top of the spawn-time :owner.
    if state.owner_ref, do: Process.demonitor(state.owner_ref, [:flush])
    {:reply, :ok, %{state | owner_ref: Process.monitor(owner)}}
  end

  # --- enif_select notifications ---
  # When a FD becomes ready, enif_select sends:
  #   {:select, resource, ref, :ready_input | :ready_output}

  @impl true
  def handle_info({:select, resource, _ref, :ready_input}, state) do
    # enif_select is one-shot per fd and the resource says which pipe woke us.
    # Servicing both would cost a read(2) plus a select re-arm on the other
    # pipe for every chunk of this one.
    {:noreply, handle_ready_input(state, resource)}
  end

  def handle_info({:select, _resource, _ref, :ready_output}, state) do
    # Only stdin is ever selected for write, so there is nothing to discriminate.
    {:noreply, retry_pending_writes(state)}
  end

  # Shepherd port exit. Normally the exit status already arrived over the UDS
  # and this is a no-op; it is the fallback for a shepherd that died without
  # delivering one.
  def handle_info({port, {:exit_status, _status}}, state)
      when port == state.shepherd_port do
    state = maybe_read_exit_status(state)

    if state.status != :exited do
      Process.send_after(self(), :force_exit_timeout, @force_exit_timeout)
    end

    {:noreply, state}
  end

  def handle_info(:force_exit_timeout, state) do
    if state.status != :exited do
      require Logger

      Logger.warning(
        "[NetRunner] no exit status from shepherd for #{inspect(state.cmd)} after " <>
          "#{@force_exit_timeout}ms; synthesising 137. A real status should have " <>
          "arrived over the UDS — this path losing a genuine exit code is a bug."
      )

      {:noreply, finish_exit(state, 137)}
    else
      {:noreply, state}
    end
  end

  # UDS readiness from the :nowait recv armed by arm_uds/1. This is how
  # MSG_CHILD_EXITED and MSG_ERROR normally arrive.
  def handle_info({:"$socket", socket, :select, _info}, state)
      when socket == state.uds_socket do
    {:noreply, arm_uds(state)}
  end

  def handle_info({:"$socket", socket, :abort, _info}, state)
      when socket == state.uds_socket do
    # Socket torn down — nothing further will arrive. The shepherd Port exit
    # and the force-exit backstop still cover the exit status.
    {:noreply, state}
  end

  # A parked caller (read/write) died — drop its entries silently instead of
  # letting them linger until process exit. The owner case is handled first.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_reference(ref) do
    if ref == state.owner_ref do
      on_owner_down(state)
    else
      case Operations.pop_by_monitor(state.operations, ref) do
        {[], _ops} ->
          {:noreply, state}

        {_ops_removed, ops} ->
          {:noreply, %{state | operations: ops}}
      end
    end
  end

  # Initial stderr chunk from kick_stderr_read in init/1. Without this clause
  # the data would be silently dropped by the catch-all below.
  def handle_info({:stderr_data, data}, state) when is_binary(data) do
    stats = Stats.record_read_stderr(state.stats, byte_size(data))
    state = %{state | stderr_tail: append_stderr_tail(state, data), stats: stats}
    # Drain anything else buffered and re-arm enif_select on EAGAIN.
    {:noreply, consume_stderr(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp on_owner_down(state) do
    if state.os_pid do
      case Signal.resolve(:sigkill) do
        {:ok, sig_num} ->
          send_shepherd_command(state, <<0x01, sig_num::8>>)
          Nif.nif_kill(state.os_pid, sig_num)

        _ ->
          :ok
      end
    end

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Best-effort cleanup. Order: close pipes (lets child see EOF), then
    # UDS (shepherd detects POLLHUP, kills child), then the shepherd Port.
    if state.stdin, do: Pipe.close(state.stdin)
    if state.stdout, do: Pipe.close(state.stdout)
    if state.stderr, do: Pipe.close(state.stderr)

    if state.uds_socket do
      :socket.close(state.uds_socket)
    end

    if is_port(state.shepherd_port) do
      try do
        Port.close(state.shepherd_port)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # --- Private helpers ---

  defp get_pipe(state, :stdout), do: state.stdout
  defp get_pipe(state, :stderr), do: state.stderr
  defp get_pipe(_, _), do: nil

  defp do_write(data, from, state) do
    write_loop(data, from, state)
  end

  # Writes data in a loop: partial writes retry immediately until EAGAIN
  # (which registers enif_select) or completion. This keeps enif_select
  # in charge of readiness notifications; any path that parks the caller
  # without going through the NIF's EAGAIN path must not be taken here.
  # A zero-byte write on a non-empty buffer is mapped to :eagain inside the
  # NIF (which registers select), so it can never reach this loop.
  defp write_loop(<<>>, _from, state), do: {:reply, :ok, state}

  defp write_loop(data, from, state) do
    case Pipe.write(state.stdin, data) do
      {:ok, bytes_written} ->
        stats = Stats.record_write(state.stats, bytes_written)
        state = %{state | stats: stats}
        total = byte_size(data)

        if bytes_written >= total do
          {:reply, :ok, state}
        else
          remaining = binary_part(data, bytes_written, total - bytes_written)
          write_loop(remaining, from, state)
        end

      {:error, :eagain} ->
        # enif_select is now registered for write readiness
        {ops, _ref} = Operations.park(state.operations, :write, from, data)
        {:noreply, %{state | operations: ops}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp handle_ready_input(state, resource) do
    cond do
      pipe_matches?(state.stdout, resource) ->
        retry_reads_for(state, {:read, :stdout})

      pipe_matches?(state.stderr, resource) ->
        state
        |> retry_reads_for({:read, :stderr})
        |> maybe_consume_stderr()

      true ->
        # Unrecognised resource (pipe already closed). Service both rather
        # than drop a readiness event.
        state
        |> retry_reads_for({:read, :stdout})
        |> retry_reads_for({:read, :stderr})
        |> maybe_consume_stderr()
    end
  end

  defp pipe_matches?(%Pipe{resource: resource}, resource) when not is_nil(resource), do: true
  defp pipe_matches?(_pipe, _resource), do: false

  defp maybe_consume_stderr(%{stderr_mode: :consume, stderr: stderr} = state)
       when not is_nil(stderr),
       do: consume_stderr(state)

  defp maybe_consume_stderr(state), do: state

  defp retry_reads_for(state, type) do
    # The common case is nothing parked, so skip the map traversal entirely.
    if Operations.empty?(state.operations) do
      state
    else
      Enum.reduce(Operations.pending_by_type(state.operations, type), state, fn
        {ref, {_type, from, max_bytes}}, acc ->
          retry_single_read(acc, ref, pipe_for_type(acc, type), from, max_bytes)
      end)
    end
  end

  defp pipe_for_type(state, {:read, :stdout}), do: state.stdout
  defp pipe_for_type(state, {:read, :stderr}), do: state.stderr

  defp retry_single_read(state, ref, nil, from, _max_bytes) do
    GenServer.reply(from, {:error, :closed})
    {_, ops} = Operations.pop(state.operations, ref)
    %{state | operations: ops}
  end

  defp retry_single_read(state, ref, pipe, from, max_bytes) do
    case Pipe.read(pipe, max_bytes) do
      {:ok, data} ->
        GenServer.reply(from, {:ok, data})
        {_, ops} = Operations.pop(state.operations, ref)
        stats = Stats.record_read(state.stats, byte_size(data))
        %{state | operations: ops, stats: stats}

      :eof ->
        GenServer.reply(from, :eof)
        {_, ops} = Operations.pop(state.operations, ref)
        %{state | operations: ops}

      {:error, :eagain} ->
        state

      {:error, _} = error ->
        GenServer.reply(from, error)
        {_, ops} = Operations.pop(state.operations, ref)
        %{state | operations: ops}
    end
  end

  defp retry_pending_writes(state) do
    pending = Operations.pending_by_type(state.operations, :write)

    Enum.reduce(pending, state, fn {ref, {:write, from, data}}, acc ->
      if is_nil(acc.stdin) do
        GenServer.reply(from, {:error, :closed})
        {_, ops} = Operations.pop(acc.operations, ref)
        %{acc | operations: ops}
      else
        retry_write_loop(ref, from, data, acc)
      end
    end)
  end

  defp retry_write_loop(ref, from, data, state) do
    case Pipe.write(state.stdin, data) do
      {:ok, bytes_written} ->
        stats = Stats.record_write(state.stats, bytes_written)
        state = %{state | stats: stats}
        total = byte_size(data)

        if bytes_written >= total do
          GenServer.reply(from, :ok)
          {_, ops} = Operations.pop(state.operations, ref)
          %{state | operations: ops}
        else
          remaining = binary_part(data, bytes_written, total - bytes_written)
          retry_write_loop(ref, from, remaining, state)
        end

      {:error, :eagain} ->
        # Persist the remaining bytes. enif_select is already re-registered,
        # but the parked op must carry forward what is left to write: leaving
        # the original payload in place restarts the write from offset 0 on
        # every readiness event, so the child receives the same bytes again and
        # again and the write never completes. Observed as 5.8 GB written for a
        # 100 KB payload.
        %{state | operations: Operations.update_context(state.operations, ref, data)}

      {:error, _} = error ->
        GenServer.reply(from, error)
        {_, ops} = Operations.pop(state.operations, ref)
        %{state | operations: ops}
    end
  end

  defp kick_stderr_read(state) do
    if state.stderr do
      # Do an initial read to get enif_select registered. If data is
      # immediately available, hand it to handle_info/2 so the GenServer
      # buffers it (can't update state from init/1 without reshaping it).
      case Pipe.read(state.stderr, @default_read_size) do
        {:ok, data} ->
          send(self(), {:stderr_data, data})

        :eof ->
          :ok

        {:error, :eagain} ->
          # enif_select registered, we'll get :ready_input
          :ok

        {:error, _} ->
          :ok
      end
    end
  end

  # Appends `data` to the retained stderr tail, keeping only the most-recent
  # `stderr_tail_bytes` bytes. A cap of 0 retains nothing (drain-and-drop);
  # the pipe is still drained so the child never blocks. All bytes are still
  # counted in stats — only retention is bounded.
  #
  # The `:binary.copy/1` calls are load-bearing: binary_part/3 on a refc
  # binary returns a sub-binary that pins its parent, so without the copy an
  # 8 KiB tail would retain the whole ~72 KiB concat for the life of the
  # process.
  defp append_stderr_tail(%{stderr_tail_bytes: 0}, _data), do: <<>>

  defp append_stderr_tail(%{stderr_tail: tail, stderr_tail_bytes: cap}, data) do
    size = byte_size(data)

    cond do
      size >= cap ->
        # The chunk alone already fills the cap, so concatenating the old tail
        # would copy bytes the following slice immediately discards.
        :binary.copy(binary_part(data, size - cap, cap))

      byte_size(tail) + size <= cap ->
        tail <> data

      true ->
        combined = tail <> data
        :binary.copy(binary_part(combined, byte_size(combined) - cap, cap))
    end
  end

  defp consume_stderr(state) do
    case Pipe.read(state.stderr) do
      {:ok, data} ->
        stats = Stats.record_read_stderr(state.stats, byte_size(data))
        consume_stderr(%{state | stderr_tail: append_stderr_tail(state, data), stats: stats})

      :eof ->
        state

      {:error, :eagain} ->
        state

      {:error, _} ->
        state
    end
  end

  defp send_shepherd_command(state, command) do
    if state.uds_socket do
      :socket.send(state.uds_socket, command)
    end
  end

  defp maybe_read_exit_status(%{status: :exited} = state), do: state

  defp maybe_read_exit_status(state) do
    # The shepherd is gone. Whatever it managed to write is either already in
    # our carry or still sitting in the socket buffer, so one non-blocking
    # sweep gets it. There is deliberately no retry ladder: a blocking recv
    # here wedges the GenServer (no calls answered, no readiness serviced, no
    # stderr drained) and the force-exit backstop already covers a shepherd
    # that wrote nothing at all.
    arm_uds(state)
  end

  # Drains every complete frame the socket will give us right now, then leaves
  # a :nowait select armed so the next frame arrives as a message.
  defp arm_uds(%{status: :exited} = state), do: state
  defp arm_uds(%{uds_socket: nil} = state), do: state

  defp arm_uds(state) do
    state = drain_uds_carry(state)

    if state.status == :exited do
      state
    else
      recv_uds(state)
    end
  end

  # One `:socket.recv` per call, then re-enter only on demonstrated progress.
  # A zero-byte read must terminate the loop: a peer at EOF is permanently
  # readable, so recursing on it would spin the GenServer forever and starve
  # every parked caller. Only a non-empty read earns another pass.
  defp recv_uds(state) do
    case :socket.recv(state.uds_socket, 0, [], :nowait) do
      {:ok, data} when byte_size(data) > 0 ->
        arm_uds(%{state | uds_carry: state.uds_carry <> data})

      {:ok, _empty} ->
        # Treated as EOF: nothing more will arrive, and re-arming a select on
        # an EOF socket would produce an endless readiness storm.
        drain_uds_carry(state)

      {:select, {_info, data}} when is_binary(data) and byte_size(data) > 0 ->
        # Partial data alongside the select registration — keep the bytes.
        drain_uds_carry(%{state | uds_carry: state.uds_carry <> data})

      {:select, _info} ->
        state

      {:error, {_reason, data}} when is_binary(data) and byte_size(data) > 0 ->
        drain_uds_carry(%{state | uds_carry: state.uds_carry <> data})

      {:error, _reason} ->
        # Includes :closed (shepherd gone) and :ealready (a select from an
        # earlier arm is still outstanding and will deliver on its own).
        state
    end
  end

  # Parses buffered bytes only — never reads the socket, so it cannot block.
  defp drain_uds_carry(state) do
    case Exec.parse_uds_message(state.uds_carry) do
      {:ok, msg, rest} ->
        drain_uds_carry(apply_uds_message(%{state | uds_carry: rest}, msg))

      :incomplete ->
        state

      {:error, _reason} ->
        # Unknown opcode: drop the buffer rather than re-parsing it forever.
        %{state | uds_carry: <<>>}
    end
  end

  defp apply_uds_message(state, {:child_exited, status}), do: finish_exit(state, status)

  defp apply_uds_message(state, {:shepherd_error, msg}) do
    require Logger

    Logger.warning("[NetRunner] shepherd reported error: #{inspect(msg)}")
    state
  end

  defp finish_exit(state, exit_status) do
    stats = Stats.finalize(state.stats, exit_status)

    # Exit status now arrives over the UDS as soon as the shepherd sends it,
    # which can be while the child's output is still sitting in the pipe. Serve
    # parked readers from that buffer first — the child's write ends are closed
    # by now, so a read returns the remaining bytes and then :eof rather than
    # EAGAIN. Failing them outright here would silently truncate a stream.
    state =
      state
      |> Map.put(:stats, stats)
      |> retry_reads_for({:read, :stdout})
      |> retry_reads_for({:read, :stderr})

    # Reply to all awaiting callers
    Enum.each(state.awaiting_exit, fn from ->
      GenServer.reply(from, {:ok, exit_status})
    end)

    # Anything still parked (writes, or a reader whose pipe is already gone)
    # can never be satisfied now.
    Operations.reply_all(state.operations, {:error, :process_exited})

    %{
      state
      | exit_status: exit_status,
        status: :exited,
        awaiting_exit: [],
        operations: %Operations{}
    }
  end
end
