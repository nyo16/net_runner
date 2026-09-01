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

  alias NetRunner.Nif
  alias NetRunner.Process.{Exec, Operations, Pipe, Protocol, Stats}
  alias NetRunner.Signal

  # Exactly the size of nif_read's stack buffer, and one macOS pipe buffer
  # (grown capacity). Linux pipes are grown to 1 MiB by the shepherd
  # (F_SETPIPE_SZ, best effort), so there a saturated pipe takes ~16 reads to
  # drain — still cheap, since each read is a full 64 KiB. The bounds remain
  # load-bearing: 65_535 leaves one byte in a saturated macOS pipe and costs a
  # whole extra GenServer round trip per chunk (+42% wall time on a 64 MiB
  # read), and anything above 65_536 falls off the NIF's stack fast path into
  # enif_alloc_binary + shrink. Do NOT change without a benchmark. See
  # docs/decisions.md.
  @default_read_size 65_536

  # Chunks a single stderr drain pass may consume before yielding back to
  # `receive`. @default_read_size each, so ~1 MiB per pass and one extra
  # message per MiB. Without a bound, consume_stderr/1 recurses inside
  # handle_info for as long as the pipe keeps producing and every concurrent
  # handle_call waits behind it.
  @stderr_drain_chunks 16

  # Successful write(2) calls a single stdin write may issue before yielding
  # back to `receive` (mirrors @stderr_drain_chunks). A fast-draining child
  # otherwise keeps write_loop/5 running for the whole payload and every
  # concurrent handle_call — kill/2 included — waits behind it. On yield the
  # caller stays parked and the remaining sub-binary resumes via self-send.
  @write_budget 16

  # Backstop only. Exit status normally arrives over the UDS; this fires when
  # the shepherd died without delivering one.
  @force_exit_timeout 5_000

  # Graceful stop budget for stop/1. terminate/2 only closes FDs and a Port,
  # so this is a backstop against a wedged server, not an expected wait.
  @stop_timeout_ms 5_000

  # --- Public API ---

  # Every option a spawned process understands. Unknown keys raise up front
  # (Keyword.validate!) instead of being silently ignored — a misspelt
  # :stderr_tail_byte or a run/2-level :timeout must not pass unnoticed.
  @process_opts [
    :name,
    :owner,
    :pty,
    :stderr,
    :stderr_tail_bytes,
    :cgroup_path,
    :kill_timeout,
    :env
  ]

  @doc """
  Starts the process GenServer linked to the caller.

  Malformed options — unknown keys or invalid values for `:stderr`,
  `:stderr_tail_bytes`, `:cgroup_path` or `:env` — are programmer errors and
  raise `ArgumentError` here, in the caller, matching every other NetRunner
  entry point. `{:error, reason}` is reserved for runtime spawn failures
  (invalid command bytes, shepherd handshake errors, ...).
  """
  @spec start_link(String.t(), [String.t()], keyword()) :: GenServer.on_start()
  def start_link(cmd, args \\ [], opts \\ []) do
    opts = validate_opts!(opts)
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, {cmd, args, opts}, gen_opts)
  end

  @doc """
  Like `start_link/3` but without a link. Same option convention: malformed
  options raise `ArgumentError`; runtime spawn failures return
  `{:error, reason}`.
  """
  @spec start(String.t(), [String.t()], keyword()) :: GenServer.on_start()
  def start(cmd, args \\ [], opts \\ []) do
    opts = validate_opts!(opts)
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start(__MODULE__, {cmd, args, opts}, gen_opts)
  end

  # Client-side option validation: unknown keys (Keyword.validate!) and bad
  # option values (Exec.validate_opts!) raise ArgumentError in the caller —
  # one convention for every entry point — rather than poisoning init/1.
  defp validate_opts!(opts) do
    opts
    |> Keyword.validate!(@process_opts)
    |> Exec.validate_opts!()
  end

  @doc """
  Stops the server, releasing its pipes, UDS socket and `Watcher` entry.

  Idempotent and safe on an already-dead server. Safe to call while the OS
  process is still running: `terminate/2` closes the pipes and the UDS, which
  the shepherd sees as POLLHUP and turns into a kill. Callers that want the
  child reaped first should `await_exit/2` (or `kill/2`) beforehand.

  Nothing else stops the server on its own — the owner monitor only fires when
  the owner dies — so any caller that holds a `NetRunner.Process` for a
  bounded span must call this or leak it.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(process) do
    if is_pid(process) and not Process.alive?(process) do
      :ok
    else
      GenServer.stop(process, :normal, @stop_timeout_ms)
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Read from stdout. Blocks until data available or EOF.

  `max_bytes` is a request cap, not a promise: the NIF caps a single read at
  1 MiB (1_048_576 bytes), so a larger `max_bytes` still yields at most 1 MiB
  per call. Reads are "up to" `max_bytes` anyway, so the cap only shows up as
  extra round trips when a caller sizes reads to a >1 MiB pipe.

  With several callers parked reading the *same* pipe, wakeup order on
  readiness is arbitrary-but-sticky (map iteration order), not FIFO — the
  same bounded unfairness documented for concurrent `write/2` interleaving.
  """
  @spec read(GenServer.server(), pos_integer()) :: {:ok, binary()} | :eof | {:error, term()}
  def read(process, max_bytes \\ @default_read_size) do
    GenServer.call(process, {:read, :stdout, max_bytes}, :infinity)
  end

  @doc "Read from stderr. Same `max_bytes` cap and wakeup order as `read/2`."
  @spec read_stderr(GenServer.server(), pos_integer()) ::
          {:ok, binary()} | :eof | {:error, term()}
  def read_stderr(process, max_bytes \\ @default_read_size) do
    GenServer.call(process, {:read, :stderr, max_bytes}, :infinity)
  end

  @doc """
  Reads up to `max_chunks` chunks from stdout in one server round trip.

  Blocks like `read/2` until at least one chunk is available or EOF, but once
  the first chunk arrives it never waits for more: the batch stops at the
  first EAGAIN, so it cannot hold data back while the child is quiet.
  Returns `{:ok, chunks}` with chunks in read order. `:eof` (and read errors)
  are only returned when no data was collected in this call — a batch cut
  short by EOF is delivered and the *next* call returns `:eof`.

  `max_bytes` is capped at 1 MiB per chunk by the NIF, like `read/2`.
  """
  @spec read_batch(GenServer.server(), pos_integer(), pos_integer()) ::
          {:ok, [binary()]} | :eof | {:error, term()}
  def read_batch(process, max_bytes \\ @default_read_size, max_chunks \\ @stderr_drain_chunks) do
    GenServer.call(process, {:read_batch, :stdout, max_bytes, max_chunks}, :infinity)
  end

  @doc """
  Like `read_batch/3` but for stderr.

  Sensible when the internal stderr consumer is not running (`stderr:
  :disabled` — how `Daemon` drains); under `stderr: :consume` an external
  batch reader is safe but races the internal drain for chunks.
  """
  @spec read_stderr_batch(GenServer.server(), pos_integer(), pos_integer()) ::
          {:ok, [binary()]} | :eof | {:error, term()}
  def read_stderr_batch(
        process,
        max_bytes \\ @default_read_size,
        max_chunks \\ @stderr_drain_chunks
      ) do
    GenServer.call(process, {:read_batch, :stderr, max_bytes, max_chunks}, :infinity)
  end

  @doc """
  Write to stdin. Accepts iodata; normalised to a binary here, at the API
  boundary, so the NIF and the write loop deal in binaries only.

  A payload is not atomic against concurrent writers: a budget yield or a
  full-pipe park lets another caller's write splice between this payload's
  chunks. Serialise externally (as `Daemon` does via its forwarder) when
  payload atomicity matters.
  """
  @spec write(GenServer.server(), iodata()) :: :ok | {:error, term()}
  def write(process, data) do
    GenServer.call(process, {:write, IO.iodata_to_binary(data)}, :infinity)
  end

  @doc "Close stdin pipe."
  @spec close_stdin(GenServer.server()) :: :ok | {:error, term()}
  def close_stdin(process) do
    GenServer.call(process, :close_stdin)
  end

  @doc "Send a signal to the OS process."
  @spec kill(GenServer.server(), atom() | pos_integer(), timeout()) :: :ok | {:error, term()}
  def kill(process, signal \\ :sigterm, timeout \\ 5_000) do
    GenServer.call(process, {:kill, signal}, timeout)
  end

  @doc """
  Graceful shutdown with escalation: SIGTERM, wait up to `term_grace_ms`,
  then SIGKILL and (when `kill_grace_ms > 0`) wait again.

  Returns `{:ok, exit_status}` when the exit was observed within the grace,
  `:timeout` otherwise. Safe on an already-dead or already-exited server —
  every call in here traps `:exit`.

  This is the single owner of the SIGTERM→SIGKILL ladder; do not hand-roll
  it at call sites.
  """
  @spec shutdown(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :timeout
  def shutdown(process, term_grace_ms, kill_grace_ms) do
    safe_signal(process, :sigterm)

    case safe_await_exit(process, term_grace_ms) do
      {:ok, _} = ok ->
        ok

      :timeout ->
        safe_signal(process, :sigkill)

        if kill_grace_ms > 0 do
          safe_await_exit(process, kill_grace_ms)
        else
          :timeout
        end
    end
  end

  defp safe_signal(process, signal) do
    # Short call timeout: shutdown/3 is used inside Daemon.terminate/2 whose
    # whole budget is 5 s — a wedged server must not consume it in one call.
    kill(process, signal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_await_exit(process, timeout) do
    # await_exit only ever returns {:ok, status}; a timeout surfaces as an
    # :exit from GenServer.call, caught below.
    await_exit(process, timeout)
  catch
    :exit, _ -> :timeout
  end

  @doc "Wait for the process to exit. Returns `{:ok, exit_status}`."
  @spec await_exit(GenServer.server(), timeout()) :: {:ok, non_neg_integer()}
  def await_exit(process, timeout \\ :infinity) do
    GenServer.call(process, :await_exit, timeout)
  end

  @doc "Get the OS PID."
  @spec os_pid(GenServer.server()) :: non_neg_integer() | nil
  def os_pid(process) do
    GenServer.call(process, :os_pid)
  end

  @doc "Check if the process is alive."
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(process) do
    GenServer.call(process, :alive?)
  end

  @doc "Get accumulated stats. See `NetRunner.Process.Stats.t/0`."
  @spec stats(GenServer.server()) :: Stats.t()
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

  @doc """
  Set PTY window size (rows, cols). Only works in PTY mode. Values outside
  0..65535 do not fit the 2-byte protocol fields and are rejected.
  """
  @spec set_window_size(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def set_window_size(process, rows, cols)
      when is_integer(rows) and rows in 0..65_535 and is_integer(cols) and cols in 0..65_535 do
    GenServer.call(process, {:set_window_size, rows, cols})
  end

  def set_window_size(_process, _rows, _cols), do: {:error, :invalid_window_size}

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

        # Register with watcher for belt-and-suspenders cleanup. Keep the pid:
        # once the exit status is delivered the Watcher is told to stand down,
        # so it can never signal a reused OS pid after the child was reaped.
        watcher =
          case NetRunner.Watcher.watch(self(), state.os_pid, state.shepherd_port) do
            {:ok, pid} -> pid
            _ -> nil
          end

        state = %{state | watcher: watcher}

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
          stats = record_pipe_read(state.stats, pipe_name, byte_size(data))
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

  def handle_call({:read_batch, pipe_name, max_bytes, max_chunks}, from, state) do
    pipe = get_pipe(state, pipe_name)

    if is_nil(pipe) do
      {:reply, {:error, :closed}, state}
    else
      case batch_read(pipe, max_bytes, max_chunks) do
        {:ok, chunks, bytes, calls} ->
          stats = record_pipe_read(state.stats, pipe_name, bytes, calls)
          {:reply, {:ok, chunks}, %{state | stats: stats}}

        :eof ->
          {:reply, :eof, state}

        {:error, :eagain} ->
          # Park exactly like a single read; the context shape tells the
          # retry path to resume as a batch.
          {ops, _ref} =
            Operations.park(
              state.operations,
              {:read, pipe_name},
              from,
              {:batch, max_bytes, max_chunks}
            )

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
    send_shepherd_command(state, Protocol.close_stdin())

    # Fail parked writes eagerly: an EAGAIN-parked writer registered select
    # on the resource that was just closed, so no readiness event will ever
    # wake it — left parked it hangs on its :infinity call until child exit.
    state = fail_parked_writes(state)

    {:reply, result, %{state | stdin: nil}}
  end

  def handle_call({:kill, signal}, _from, %{status: :exited} = state) do
    # The child was already reaped: its OS pid may belong to a brand-new
    # process by now, so signalling it would be a cross-process kill.
    _ = signal
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:kill, signal}, _from, state) do
    case Signal.resolve(signal) do
      {:ok, sig_num} ->
        if state.os_pid do
          # Send through shepherd protocol for process group kill
          send_shepherd_command(state, Protocol.kill(sig_num))

          maybe_direct_kill(state, sig_num)

          {:reply, :ok, maybe_mark_exiting(state, signal)}
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
    {:reply, state.status in [:running, :exiting], state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  def handle_call(:stderr_tail, _from, state) do
    {:reply, state.stderr_tail, state}
  end

  def handle_call({:set_window_size, rows, cols}, _from, state) do
    send_shepherd_command(state, Protocol.set_winsize(rows, cols))
    {:reply, :ok, state}
  end

  def handle_call({:set_owner, owner}, _from, state) do
    # Replace, don't stack: Stream calls this on top of the spawn-time :owner.
    if state.owner_ref, do: Process.demonitor(state.owner_ref, [:flush])
    {:reply, :ok, %{state | owner_ref: Process.monitor(owner)}}
  end

  # Only signals whose default disposition terminates the child move the
  # state machine to :exiting; SIGSTOP/SIGCONT/SIGWINCH-style signals leave a
  # running child running.
  @terminating_signals [:sigterm, :sigkill, :sigint, :sighup, :sigquit, :sigpipe]
  @terminating_signal_numbers [1, 2, 3, 9, 13, 15]

  defp maybe_mark_exiting(state, signal)
       when signal in @terminating_signals or signal in @terminating_signal_numbers,
       do: %{state | status: :exiting}

  defp maybe_mark_exiting(state, _signal), do: state

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
    tail = append_stderr_tail(state.stderr_tail, state.stderr_tail_bytes, data)
    state = %{state | stderr_tail: tail, stats: stats}
    # Drain anything else buffered and re-arm enif_select on EAGAIN.
    {:noreply, consume_stderr(state)}
  end

  # Resumption of a drain pass that hit @stderr_drain_chunks. MUST stay above
  # the catch-all below: matched by it instead, the message is silently
  # dropped, stderr stops draining, and the child deadlocks on a full stderr
  # pipe. maybe_consume_stderr/1 makes re-entry a no-op when stderr is
  # disabled or already closed, so a straggler arriving after :eof or
  # finish_exit/2 costs one function call.
  def handle_info(:consume_stderr_more, state) do
    {:noreply, maybe_consume_stderr(state)}
  end

  # Resumption of a write that exhausted @write_budget. The caller is parked
  # with the remaining sub-binary as context; this drives it exactly like a
  # :ready_output event would.
  def handle_info(:continue_writes, state) do
    # Clear the dedupe flag first: this pass may exhaust the budget again and
    # must be able to schedule its own resume.
    state = %{state | continue_writes_scheduled?: false}
    {:noreply, retry_pending_writes(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp on_owner_down(%{status: :exited} = state) do
    # The child was already reaped — its OS pid may belong to a brand-new
    # process by now (same rule as the {:kill, _} clause above). Just stop.
    {:stop, :normal, state}
  end

  defp on_owner_down(state) do
    if state.os_pid do
      case Signal.resolve(:sigkill) do
        {:ok, sig_num} ->
          send_shepherd_command(state, Protocol.kill(sig_num))

          maybe_direct_kill(state, sig_num)

        _ ->
          :ok
      end
    end

    {:stop, :normal, state}
  end

  # The shepherd owns the reap, so while it lives it is the only safe
  # signaller: it holds the child as a zombie until waitpid, so the pid
  # cannot be recycled while CMD_KILL is serviceable. Only when the shepherd
  # is gone (child orphaned and un-reaped — pid still not recyclable) does
  # the direct NIF kill take over.
  defp maybe_direct_kill(state, sig_num) do
    unless shepherd_alive?(state) do
      Nif.nif_kill(state.os_pid, sig_num)
    end
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
    write_loop(data, from, state, 0, 0)
  end

  # Writes data in a loop: partial writes retry immediately until EAGAIN
  # (which registers enif_select) or completion. This keeps enif_select
  # in charge of readiness notifications; the only other exit is the
  # @write_budget yield below, which self-sends :continue_writes so progress
  # never depends on a readiness event that was never registered.
  # A zero-byte write on a non-empty buffer is mapped to :eagain inside the
  # NIF (which registers select), so it can never reach this loop.
  #
  # Bytes and syscall count are carried as loop parameters and folded into the
  # state exactly once on exit — a 1 MiB write takes ~16 iterations and used to
  # allocate a Stats struct and a state map on each of them.
  defp write_loop(<<>>, _from, state, written, calls) do
    {:reply, :ok, commit_write(state, written, calls)}
  end

  defp write_loop(data, from, state, written, calls) when calls >= @write_budget do
    # Budget exhausted: a fast-draining child would otherwise keep this loop
    # occupying the GenServer for the whole payload. Park the caller with the
    # remaining bytes and resume from the mailbox, letting queued calls
    # (kill/2, read/2) in between.
    state = commit_write(state, written, calls)
    {ops, _ref} = Operations.park(state.operations, :write, from, data)
    state = schedule_continue_writes(%{state | operations: ops})
    {:noreply, state}
  end

  defp write_loop(data, from, state, written, calls) do
    case Pipe.write(state.stdin, data) do
      {:ok, bytes_written} ->
        written = written + bytes_written
        calls = calls + 1
        total = byte_size(data)

        if bytes_written >= total do
          {:reply, :ok, commit_write(state, written, calls)}
        else
          remaining = binary_part(data, bytes_written, total - bytes_written)
          write_loop(remaining, from, state, written, calls)
        end

      {:error, :eagain} ->
        # enif_select is now registered for write readiness
        state = commit_write(state, written, calls)
        {ops, _ref} = Operations.park(state.operations, :write, from, data)
        {:noreply, %{state | operations: ops}}

      {:error, _} = error ->
        {:reply, error, commit_write(state, written, calls)}
    end
  end

  defp commit_write(state, 0, 0), do: state

  defp commit_write(state, written, calls) do
    %{state | stats: Stats.record_write(state.stats, written, calls)}
  end

  # At most one :continue_writes is ever in flight: the flag is set here and
  # cleared when the message is received. Without it, every budget yield in a
  # multi-writer retry pass queued its own resume and the mailbox filled with
  # redundant wakeups.
  defp schedule_continue_writes(%{continue_writes_scheduled?: true} = state), do: state

  defp schedule_continue_writes(state) do
    send(self(), :continue_writes)
    %{state | continue_writes_scheduled?: true}
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
        {ref, {_type, from, max_bytes, _mref}}, acc ->
          retry_single_read(acc, ref, type, pipe_for_type(acc, type), from, max_bytes)
      end)
    end
  end

  defp pipe_for_type(state, {:read, :stdout}), do: state.stdout
  defp pipe_for_type(state, {:read, :stderr}), do: state.stderr

  defp retry_single_read(state, ref, _type, nil, from, _max_bytes) do
    GenServer.reply(from, {:error, :closed})
    {_, ops} = Operations.pop(state.operations, ref)
    %{state | operations: ops}
  end

  # A parked batch read retries as a batch — the context shape carries the
  # batch parameters through the park/resume cycle.
  defp retry_single_read(
         state,
         ref,
         {:read, pipe_name},
         pipe,
         from,
         {:batch, max_bytes, max_chunks}
       ) do
    case batch_read(pipe, max_bytes, max_chunks) do
      {:ok, chunks, bytes, calls} ->
        GenServer.reply(from, {:ok, chunks})
        {_, ops} = Operations.pop(state.operations, ref)
        stats = record_pipe_read(state.stats, pipe_name, bytes, calls)
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

  defp retry_single_read(state, ref, {:read, pipe_name}, pipe, from, max_bytes) do
    case Pipe.read(pipe, max_bytes) do
      {:ok, data} ->
        GenServer.reply(from, {:ok, data})
        {_, ops} = Operations.pop(state.operations, ref)
        stats = record_pipe_read(state.stats, pipe_name, byte_size(data))
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

  # Reads up to `max_chunks` chunks in one pass. Never waits once data has
  # been collected: the first EAGAIN after ≥1 chunk ends the batch, and an
  # EOF/error after ≥1 chunk is deferred to the caller's next call so data
  # already read is always delivered first.
  defp batch_read(pipe, max_bytes, max_chunks) do
    batch_read(pipe, max_bytes, max_chunks, [], 0, 0)
  end

  defp batch_read(_pipe, _max_bytes, 0, chunks, bytes, calls) do
    {:ok, Enum.reverse(chunks), bytes, calls}
  end

  defp batch_read(pipe, max_bytes, remaining, chunks, bytes, calls) do
    case Pipe.read(pipe, max_bytes) do
      {:ok, data} ->
        batch_read(
          pipe,
          max_bytes,
          remaining - 1,
          [data | chunks],
          bytes + byte_size(data),
          calls + 1
        )

      terminal when chunks == [] ->
        terminal

      _terminal ->
        {:ok, Enum.reverse(chunks), bytes, calls}
    end
  end

  # Bytes read from stderr are stderr bytes no matter who read them — the
  # internal drain or an external read_stderr/2 caller. Routing both through
  # record_read used to count external stderr reads as stdout traffic.
  defp record_pipe_read(stats, pipe_name, bytes, calls \\ 1)
  defp record_pipe_read(stats, :stdout, bytes, calls), do: Stats.record_read(stats, bytes, calls)
  defp record_pipe_read(stats, :stderr, bytes, _calls), do: Stats.record_read_stderr(stats, bytes)

  defp retry_pending_writes(state) do
    # Driven by :ready_output (a write EAGAIN'd earlier) and by
    # :continue_writes (a budget yield); the empty? guard makes stragglers
    # from either source a cheap no-op. ONE @write_budget is shared across
    # the whole pass: with N parked writers a per-op budget multiplied the
    # GenServer's occupancy bound by N, starving queued calls (kill/2
    # included) at exactly the moment fan-in made the server busiest.
    # Map iteration order is arbitrary-but-sticky per ref, so one large
    # parked write can absorb the budget for several consecutive passes
    # while later refs wait. Bounded unfairness, not starvation: every pass
    # moves ≥1 budget's worth of someone's bytes and finished ops are popped.
    if Operations.empty?(state.operations) do
      state
    else
      {state, _budget} =
        state.operations
        |> Operations.pending_by_type(:write)
        |> Enum.reduce({state, @write_budget}, &retry_pending_write/2)

      state
    end
  end

  defp fail_parked_writes(state) do
    state.operations
    |> Operations.pending_by_type(:write)
    |> Enum.reduce(state, fn {ref, {:write, from, _data, _mref}}, acc ->
      GenServer.reply(from, {:error, :closed})
      {_, ops} = Operations.pop(acc.operations, ref)
      %{acc | operations: ops}
    end)
  end

  # Budget already spent by earlier ops in this pass: leave the op parked and
  # make sure a resume is queued for it.
  defp retry_pending_write({_ref, {:write, _from, _data, _mref}}, {state, 0}) do
    {schedule_continue_writes(state), 0}
  end

  defp retry_pending_write({ref, {:write, from, data, _mref}}, {state, budget}) do
    if is_nil(state.stdin) do
      GenServer.reply(from, {:error, :closed})
      {_, ops} = Operations.pop(state.operations, ref)
      {%{state | operations: ops}, budget}
    else
      retry_write_loop(ref, from, data, state, 0, 0, budget)
    end
  end

  defp retry_write_loop(ref, _from, data, state, written, calls, 0 = _budget) do
    # Same yield as write_loop/5: keep the op parked with the remaining bytes
    # and resume from the mailbox instead of monopolising the GenServer.
    state = commit_write(state, written, calls)
    state = schedule_continue_writes(state)
    {%{state | operations: Operations.update_context(state.operations, ref, data)}, 0}
  end

  defp retry_write_loop(ref, from, data, state, written, calls, budget) do
    case Pipe.write(state.stdin, data) do
      {:ok, bytes_written} ->
        written = written + bytes_written
        calls = calls + 1
        budget = budget - 1
        total = byte_size(data)

        if bytes_written >= total do
          GenServer.reply(from, :ok)
          state = commit_write(state, written, calls)
          {_, ops} = Operations.pop(state.operations, ref)
          {%{state | operations: ops}, budget}
        else
          remaining = binary_part(data, bytes_written, total - bytes_written)
          retry_write_loop(ref, from, remaining, state, written, calls, budget)
        end

      {:error, :eagain} ->
        # Persist the remaining bytes. enif_select is already re-registered,
        # but the parked op must carry forward what is left to write: leaving
        # the original payload in place restarts the write from offset 0 on
        # every readiness event, so the child receives the same bytes again and
        # again and the write never completes. Observed as 5.8 GB written for a
        # 100 KB payload.
        state = commit_write(state, written, calls)
        {%{state | operations: Operations.update_context(state.operations, ref, data)}, budget}

      {:error, _} = error ->
        GenServer.reply(from, error)
        state = commit_write(state, written, calls)
        {_, ops} = Operations.pop(state.operations, ref)
        {%{state | operations: ops}, budget}
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
  # `cap` bytes. A cap of 0 retains nothing (drain-and-drop); the pipe is
  # still drained so the child never blocks. All bytes are still counted in
  # stats — only retention is bounded.
  defp append_stderr_tail(_tail, 0, _data), do: <<>>

  defp append_stderr_tail(tail, cap, data) do
    size = byte_size(data)

    cond do
      size >= cap ->
        # The chunk alone already fills the cap, so concatenating the old tail
        # would copy bytes the following slice immediately discards. The
        # :binary.copy/1 is load-bearing: binary_part/3 on a refc binary
        # returns a sub-binary that pins its ~64 KiB parent for the life of
        # the process.
        :binary.copy(binary_part(data, size - cap, cap))

      byte_size(tail) + size <= cap ->
        # Only reachable during the first `cap` bytes of the process's life.
        tail <> data

      true ->
        # Steady state once the tail is full. Build the result at exactly
        # `cap` in one pass: `tail <> data` followed by a slice would copy
        # cap + size and then cap again, ~2*cap + size bytes and a transient
        # ~72 KiB refc binary per chunk. Bitstring construction always
        # produces a fresh binary, so it pins nothing and needs no copy.
        keep = cap - size
        <<binary_part(tail, byte_size(tail) - keep, keep)::binary, data::binary>>
    end
  end

  defp consume_stderr(state) do
    consume_stderr(state, @stderr_drain_chunks, state.stderr_tail, 0)
  end

  # Budget exhausted: yield to `receive` so concurrent handle_call work is not
  # queued behind an arbitrarily long drain, and resume from the mailbox.
  # enif_select is NOT armed on this path (we stopped short of EAGAIN), so the
  # self-send is the only thing that keeps the pipe draining.
  defp consume_stderr(state, 0, tail, bytes) do
    send(self(), :consume_stderr_more)
    commit_stderr(state, tail, bytes)
  end

  defp consume_stderr(state, budget, tail, bytes) do
    case Pipe.read(state.stderr, @default_read_size) do
      {:ok, data} ->
        tail = append_stderr_tail(tail, state.stderr_tail_bytes, data)
        consume_stderr(state, budget - 1, tail, bytes + byte_size(data))

      # :eof, {:error, :eagain} (enif_select re-armed) or a hard error — all
      # end the pass without scheduling a resume.
      _stop ->
        commit_stderr(state, tail, bytes)
    end
  end

  defp commit_stderr(state, _tail, 0), do: state

  defp commit_stderr(state, tail, bytes) do
    %{state | stderr_tail: tail, stats: Stats.record_read_stderr(state.stats, bytes)}
  end

  defp send_shepherd_command(state, command) do
    if state.uds_socket do
      :socket.send(state.uds_socket, command)
    end
  end

  # A live shepherd port means a live shepherd: it still holds the child as
  # a zombie until waitpid, so the OS pid cannot be recycled and CMD_KILL
  # over the UDS is the safe signalling path. Direct NIF kills must wait
  # until this is false — the BEAM has no reap authority over the pid.
  defp shepherd_alive?(state) do
    is_port(state.shepherd_port) and Port.info(state.shepherd_port) != nil
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
    case Protocol.parse_uds_message(state.uds_carry) do
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
    # Recorded (not just logged) so a caller inspecting the server after a
    # degraded spawn can see what the shepherd reported.
    %{state | last_shepherd_error: msg}
  end

  defp finish_exit(state, exit_status) do
    stats = Stats.finalize(state.stats, exit_status)

    # The exit status is in hand, so the belt-and-suspenders Watcher must
    # stand down: its whole purpose is covering a crash *before* the child
    # was reaped, and any later probe would race OS pid reuse.
    if state.watcher, do: NetRunner.Watcher.stand_down(state.watcher)

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
