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

  @doc "Set PTY window size (rows, cols). Only works in PTY mode."
  def set_window_size(process, rows, cols) do
    GenServer.call(process, {:set_window_size, rows, cols})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({cmd, args, opts}) do
    case Exec.spawn_process(cmd, args, opts) do
      {:ok, state} ->
        state = %{state | stats: Stats.new()}
        # Register with watcher for belt-and-suspenders cleanup
        NetRunner.Watcher.watch(self(), state.os_pid)
        # Start reading stderr in :consume mode
        if state.stderr_mode == :consume do
          kick_stderr_read(state)
        end

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

  def handle_call({:set_window_size, rows, cols}, _from, state) do
    send_shepherd_command(state, <<0x03, rows::big-16, cols::big-16>>)
    {:reply, :ok, state}
  end

  # --- enif_select notifications ---
  # When a FD becomes ready, enif_select sends:
  #   {:select, resource, ref, :ready_input | :ready_output}

  @impl true
  def handle_info({:select, _resource, _ref, :ready_input}, state) do
    # A read FD is ready — retry all pending reads
    state = retry_pending_reads(state)
    {:noreply, state}
  end

  def handle_info({:select, _resource, _ref, :ready_output}, state) do
    # A write FD is ready — retry all pending writes
    state = retry_pending_writes(state)
    {:noreply, state}
  end

  # Shepherd port exit
  def handle_info({port, {:exit_status, _status}}, state)
      when port == state.shepherd_port do
    # Shepherd died. Read exit status from UDS if we haven't already.
    state = maybe_read_exit_status(state)

    # If we still haven't received exit status, schedule a forced timeout
    if state.status != :exited do
      Process.send_after(self(), :force_exit_timeout, 5_000)
    end

    {:noreply, state}
  end

  def handle_info(:force_exit_timeout, state) do
    if state.status != :exited do
      {:noreply, finish_exit(state, 137)}
    else
      {:noreply, state}
    end
  end

  # UDS message from shepherd (via active socket)
  def handle_info({:"$socket", socket, :select, _info}, state)
      when socket == state.uds_socket do
    state = handle_uds_message(state)
    {:noreply, state}
  end

  # Initial stderr chunk from kick_stderr_read in init/1. Without this clause
  # the data would be silently dropped by the catch-all below.
  def handle_info({:stderr_data, data}, state) when is_binary(data) do
    stats = Stats.record_read_stderr(state.stats, byte_size(data))
    state = %{state | stderr_buffer: [data | state.stderr_buffer], stats: stats}
    # Drain anything else buffered and re-arm enif_select on EAGAIN.
    {:noreply, consume_stderr(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Best-effort cleanup
    if state.stdin, do: Pipe.close(state.stdin)
    if state.stdout, do: Pipe.close(state.stdout)
    if state.stderr, do: Pipe.close(state.stderr)

    if state.uds_socket do
      :socket.close(state.uds_socket)
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
  # (which registers enif_select) or completion.
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
          # Partial write — retry remainder immediately to either complete
          # or hit EAGAIN (which registers enif_select for readiness notification)
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

  defp retry_pending_reads(state) do
    pending = Operations.pending_by_type(state.operations, {:read, :stdout})
    stderr_pending = Operations.pending_by_type(state.operations, {:read, :stderr})

    state =
      Enum.reduce(pending ++ stderr_pending, state, fn {ref, {type, from, max_bytes}}, acc ->
        pipe = pipe_for_type(acc, type)
        retry_single_read(acc, ref, pipe, from, max_bytes)
      end)

    # Also handle internal stderr consumption
    if state.stderr_mode == :consume and state.stderr do
      consume_stderr(state)
    else
      state
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
        # Still parked, update data (enif_select already registered)
        {_, ops} = Operations.pop(state.operations, ref)
        {ops, _new_ref} = Operations.park(ops, :write, from, data)
        %{state | operations: ops}

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

  defp consume_stderr(state) do
    case Pipe.read(state.stderr) do
      {:ok, data} ->
        stats = Stats.record_read_stderr(state.stats, byte_size(data))
        consume_stderr(%{state | stderr_buffer: [data | state.stderr_buffer], stats: stats})

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
    case Exec.read_uds_message(state.uds_socket) do
      {:child_exited, status} ->
        finish_exit(state, status)

      _ ->
        state
    end
  end

  defp handle_uds_message(state) do
    case Exec.read_uds_message(state.uds_socket) do
      {:child_exited, status} ->
        finish_exit(state, status)

      _ ->
        state
    end
  end

  defp finish_exit(state, exit_status) do
    stats = Stats.finalize(state.stats, exit_status)

    # Reply to all awaiting callers
    Enum.each(state.awaiting_exit, fn from ->
      GenServer.reply(from, {:ok, exit_status})
    end)

    # Reply to any pending operations with appropriate errors
    Operations.reply_all(state.operations, {:error, :process_exited})

    %{
      state
      | exit_status: exit_status,
        status: :exited,
        awaiting_exit: [],
        operations: %Operations{},
        stats: stats
    }
  end
end
