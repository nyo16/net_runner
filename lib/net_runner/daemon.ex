defmodule NetRunner.Daemon do
  @moduledoc """
  A supervised long-running OS process.

  Wraps `NetRunner.Process` for integration into a supervision tree.
  Automatically drains stdout/stderr to prevent pipe blocking. Both streams
  are delivered to the `:on_output` callback; stderr is owned by the Daemon's
  own drain task (the underlying process runs with `stderr: :disabled`), so
  `:on_output` sees the complete stderr stream in order.

  When the child exits, the Daemon stops with
  `{:shutdown, {:exit_status, status}}` so its supervisor's restart strategy
  engages — a `restart: :permanent` Daemon is restarted, a `:temporary` one is
  not. The Daemon also traps exits, so a supervisor shutdown runs
  `terminate/2` and the child receives the SIGTERM→SIGKILL escalation instead
  of being orphaned to the shepherd's POLLHUP path. The SIGTERM grace is
  `process_opts[:kill_timeout]` when given (default 3 000 ms), and
  `child_spec/1` sizes the supervisor's `shutdown:` budget to match.

  ## Usage

      # In your supervision tree:
      children = [
        {NetRunner.Daemon, cmd: "redis-server", args: ["--port", "6380"], name: MyApp.Redis}
      ]

      # Or start manually:
      {:ok, pid} = NetRunner.Daemon.start_link(cmd: "tail", args: ["-f", "/var/log/syslog"],
                                                on_output: :log)

      # Interact:
      NetRunner.Daemon.os_pid(pid)
      NetRunner.Daemon.alive?(pid)
      NetRunner.Daemon.write(pid, "input\\n")
  """

  use GenServer

  require Logger

  alias NetRunner.Process, as: Proc

  @type on_output :: :discard | :log | (binary() -> any()) | nil

  # SIGTERM grace for terminate/2, replaced by `process_opts[:kill_timeout]`
  # when the caller sets it, then a SIGKILL grace. terminate/2 must finish
  # inside the supervisor's shutdown budget or the Daemon is brutal-killed and
  # the SIGKILL escalation never runs, so child_spec/1 derives `shutdown:`
  # from the effective grace instead of relying on the 5_000 ms default.
  @sigterm_grace_ms 3_000
  @sigkill_grace_ms 1_000
  @shutdown_margin_ms 1_000

  @daemon_opts [:cmd, :args, :on_output, :process_opts]

  @doc """
  Starts a supervised daemon. Options: `:cmd` (required binary), `:args`,
  `:on_output` (see `t:on_output/0`; `nil` means `:discard`), `:process_opts`
  (forwarded to `NetRunner.Process.start_link/3`; `:stderr` is forced to
  `:disabled`), and `:name`. A missing `:cmd`, an invalid `:on_output` or
  any other malformed option raises `ArgumentError` in the caller.

  On shutdown the child gets SIGTERM, then SIGKILL after
  `process_opts[:kill_timeout]` ms (default 3 000), then up to 1 000 ms to
  exit. See `child_spec/1` for the matching supervisor `shutdown:` budget.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, daemon_opts} = Keyword.split(opts, [:name])
    # Validate on the client — both the Daemon's own keys and the wrapped
    # :process_opts — so a malformed option raises ArgumentError in the
    # caller instead of surfacing as a supervisor start_link failure (and an
    # exit signal into a non-trapping caller) from inside init/1.
    daemon_opts = Keyword.validate!(daemon_opts, @daemon_opts)
    validate_cmd!(Keyword.get(daemon_opts, :cmd))
    validate_on_output!(Keyword.get(daemon_opts, :on_output))
    daemon_opts |> process_opts() |> Proc.validate_opts!()
    GenServer.start_link(__MODULE__, daemon_opts, gen_opts)
  end

  defp validate_cmd!(cmd) when is_binary(cmd), do: :ok

  defp validate_cmd!(nil),
    do: raise(ArgumentError, "NetRunner.Daemon requires :cmd (the executable to run)")

  defp validate_cmd!(cmd),
    do: raise(ArgumentError, ":cmd must be a binary, got: #{inspect(cmd)}")

  # Checked once here rather than failing with a FunctionClauseError (logged
  # by safe_handle_output/2) on every drained chunk. nil means the default.
  defp validate_on_output!(on_output)
       when on_output in [nil, :discard, :log] or is_function(on_output, 1),
       do: :ok

  defp validate_on_output!(on_output) do
    raise ArgumentError,
          ":on_output must be :discard, :log or a 1-arity function, got: #{inspect(on_output)}"
  end

  @doc """
  Child spec whose `shutdown:` covers the whole termination ladder: the
  SIGTERM grace (`process_opts[:kill_timeout]`, default 3 000 ms), the
  1 000 ms SIGKILL grace and a 1 000 ms margin. With the defaults this is
  the usual 5 000 ms. An explicit `shutdown:` in a supervisor's child spec
  override still wins.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> super()
    |> Map.put(:shutdown, sigterm_grace(opts) + @sigkill_grace_ms + @shutdown_margin_ms)
  end

  # A non-integer :kill_timeout is rejected by start_link/1; child_spec/1 must
  # not crash on it first with an ArithmeticError.
  defp sigterm_grace(opts) do
    case opts |> Keyword.get(:process_opts, []) |> Keyword.get(:kill_timeout) do
      ms when is_integer(ms) -> ms
      _ -> @sigterm_grace_ms
    end
  end

  # Force stderr: :disabled so the underlying Process does NOT start its own
  # internal stderr consumer. The Daemon's own drain task is then the sole
  # reader of the stderr pipe, so on_output receives the full stream in
  # order rather than racing the internal consumer for chunks.
  defp process_opts(daemon_opts) do
    daemon_opts
    |> Keyword.get(:process_opts, [])
    |> Keyword.put(:stderr, :disabled)
  end

  @doc "OS pid of the child, answered from Daemon state (no hop into the Process)."
  @spec os_pid(GenServer.server()) :: non_neg_integer() | nil
  def os_pid(daemon), do: GenServer.call(daemon, :os_pid)

  @doc "Whether the underlying `NetRunner.Process` reports its child as still running."
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(daemon), do: GenServer.call(daemon, :alive?)

  @doc """
  Writes to the child's stdin.

  The write is forwarded through a single long-lived forwarder task rather
  than performed inside the Daemon's own `handle_call`, so a child that stops
  draining stdin cannot wedge `os_pid/1`, `alive?/1`, or the `Proc.alive?/1`
  in `terminate/2` — the last of which would burn the supervisor's shutdown
  budget before the SIGTERM/SIGKILL escalation ever ran.

  Writes are serialised by the forwarder: sequential writes from one caller
  stay ordered, and concurrent writers no longer interleave mid-payload.
  """
  @spec write(GenServer.server(), iodata()) :: :ok | {:error, term()}
  def write(daemon, data) when is_binary(data) or is_list(data) do
    GenServer.call(daemon, {:write, data}, :infinity)
  end

  @impl true
  def init(opts) do
    cmd = Keyword.fetch!(opts, :cmd)
    args = Keyword.get(opts, :args, [])
    on_output = Keyword.get(opts, :on_output) || :discard

    # Trap exits so (a) a supervisor :shutdown runs terminate/2 and the child
    # gets the graceful escalation, and (b) the linked Proc's exit arrives as
    # a message instead of silently killing the Daemon without terminate/2.
    Process.flag(:trap_exit, true)

    case Proc.start_link(cmd, args, process_opts(opts)) do
      {:ok, proc} ->
        # Start drain tasks. The stdout drain also awaits the exit status
        # after EOF, so its completion is the "child exited" signal.
        drain_ref = start_drain(proc, :stdout, on_output)
        stderr_drain_ref = start_drain(proc, :stderr, on_output)
        {forwarder, forwarder_ref} = start_forwarder(proc)

        # The OS pid is immutable after spawn, so fetch it exactly once and
        # answer os_pid/1 from Daemon state. Routing every call through a
        # second synchronous hop into the Proc GenServer added avoidable
        # tail latency and turned a wedged Proc into a Daemon :timeout crash
        # — the exact coupling the write forwarder exists to avoid.
        os_pid = Proc.os_pid(proc)

        {:ok,
         %{
           proc: proc,
           os_pid: os_pid,
           on_output: on_output,
           sigterm_grace: sigterm_grace(opts),
           drain_ref: drain_ref,
           stderr_drain_ref: stderr_drain_ref,
           forwarder: forwarder,
           forwarder_ref: forwarder_ref
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:os_pid, _from, state) do
    {:reply, state.os_pid, state}
  end

  def handle_call(:alive?, _from, state) do
    {:reply, Proc.alive?(state.proc), state}
  end

  def handle_call({:write, data}, from, state) do
    send(state.forwarder, {:write, from, data})
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when ref == state.drain_ref do
    # Stdout drain finished: EOF was reached AND the exit status observed.
    # Stop so the supervisor's restart strategy engages — a crashed daemon
    # must not linger as a healthy-looking GenServer over a dead child.
    Process.demonitor(ref, [:flush])

    reason =
      case result do
        {:exit_status, status} -> {:shutdown, {:exit_status, status}}
        _ -> {:shutdown, :process_exited}
      end

    {:stop, reason, state}
  end

  def handle_info({ref, _result}, state) when ref == state.stderr_drain_ref do
    # Stderr drain completed (stderr EOF) — stdout drain owns the stop.
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # A drain task went :DOWN abnormally (normal completion matches the
  # {ref, result} clauses above). A dead stdout drain means nothing observes
  # the child exit and stdout eventually wedges the child on a full pipe —
  # a Daemon in that state must not linger looking healthy. Stop; the
  # supervisor restarts a :permanent Daemon with fresh drains.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when ref in [state.drain_ref, state.stderr_drain_ref] do
    Logger.warning("[NetRunner.Daemon] drain task crashed: #{inspect(reason)}")
    {:stop, {:shutdown, :drain_crashed}, state}
  end

  # The stdin forwarder died: every future write would be sent to a dead pid
  # and its caller would hang forever on an :infinity call. Stop instead so
  # callers get a clean exit and supervisors can restart.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when ref == state.forwarder_ref do
    Logger.warning("[NetRunner.Daemon] stdin forwarder died: #{inspect(reason)}")
    {:stop, {:shutdown, :forwarder_down}, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Linked Proc exited underneath us (crash, brutal kill, ...). The child's
  # fate is already sealed by the Proc teardown; propagate so the supervisor
  # sees an abnormal exit.
  def handle_info({:EXIT, pid, reason}, state) when pid == state.proc do
    {:stop, reason, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Graceful shutdown with escalation, owned by Proc.shutdown/3. Safe on an
    # already-exited child (kill returns {:error, :not_running}) and on an
    # already-dead server (all calls trap :exit).
    Proc.shutdown(state.proc, state.sigterm_grace, @sigkill_grace_ms)

    # Explicitly stop the Proc GenServer. The link alone does not cover a
    # :normal Daemon exit (GenServer.stop(daemon)): a non-trapping linked
    # process ignores :normal exit signals, so the Proc would linger in
    # :exited state with its UDS socket and pipe resources forever.
    Proc.stop(state.proc)
    :ok
  end

  # --- stdin forwarder ---

  # One long-lived task owns all stdin writes instead of one task per write:
  # per-write task spawn/monitor churn was pure overhead, and a wedged child
  # now parks only this forwarder, never the Daemon. The forwarder exits when
  # the Daemon goes down.
  defp start_forwarder(proc) do
    daemon = self()

    {:ok, pid} =
      Task.Supervisor.start_child(NetRunner.TaskSupervisor, fn ->
        ref = Process.monitor(daemon)
        forward_loop(proc, ref)
      end)

    # Monitor it back: writes are fire-and-forget sends, so an unnoticed dead
    # forwarder would strand every future writer on an :infinity call.
    {pid, Process.monitor(pid)}
  end

  defp forward_loop(proc, ref) do
    receive do
      {:write, from, data} ->
        GenServer.reply(from, safe_write(proc, data))
        forward_loop(proc, ref)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end

  # Proc.write/2 is an :infinity GenServer.call, so a dead Proc exits the
  # caller. Inside the forwarder that would strand every queued writer on a
  # reply that never comes. Turn it into a value.
  defp safe_write(proc, data) do
    Proc.write(proc, data)
  catch
    :exit, _ -> {:error, :process_exited}
  end

  # --- drain tasks ---

  defp start_drain(proc, pipe, on_output) do
    reader = if pipe == :stdout, do: &Proc.read_batch/1, else: &Proc.read_stderr_batch/1

    # async_nolink (not async): the drain task is unlinked from the Daemon,
    # so a task crash cannot take the Daemon down. Completion arrives as
    # {ref, result} and abnormal exit as {:DOWN, ref, ...}, both handled in
    # handle_info/2.
    task =
      Task.Supervisor.async_nolink(NetRunner.TaskSupervisor, fn ->
        drain_loop(reader, proc, on_output)

        if pipe == :stdout do
          # EOF alone is not exit: wait for the real status so the Daemon
          # stops with it. await_exit/2 blocks only this task.
          await_exit_status(proc)
        else
          :ok
        end
      end)

    task.ref
  end

  defp await_exit_status(proc) do
    # await_exit only ever returns {:ok, status}; a timeout or dead server
    # surfaces as an :exit from GenServer.call, caught below.
    {:ok, status} = Proc.await_exit(proc)
    {:exit_status, status}
  catch
    :exit, _ -> :unknown
  end

  # Every drained chunk is handed to on_output immediately, in read order.
  # Batching across *blocking* reads was tried and reverted (a quiet child
  # left log lines sitting unflushed for hours); read_batch/1 is safe because
  # it never waits once it has data — a batch ends at the first EAGAIN, so
  # each call flushes exactly what the pipe had ready.
  defp drain_loop(reader, proc, on_output) do
    case safe_read(reader, proc) do
      {:ok, chunks} ->
        Enum.each(chunks, &safe_handle_output(on_output, &1))
        drain_loop(reader, proc, on_output)

      _stop ->
        # :eof, {:error, _}, or :error from safe_read/2.
        :ok
    end
  end

  # Defensive: if reader.() blows up (e.g. Proc already terminated while we were
  # mid-call), stop draining without bringing down the Daemon. This lives in its
  # own function because a rescue/catch on drain_loop/3 wraps its whole body in a
  # try, which takes the self-call above out of tail position — every drained
  # chunk then leaks a stack frame that is only popped at EOF.
  defp safe_read(reader, proc) do
    reader.(proc)
  rescue
    e ->
      Logger.warning("[NetRunner.Daemon] drain exception: #{inspect(e)}")
      :error
  catch
    :exit, _ -> :error
  end

  defp safe_handle_output(on_output, data) do
    handle_output(on_output, data)
  rescue
    e ->
      Logger.warning("[NetRunner.Daemon] on_output raised: #{inspect(e)}")
      :ok
  catch
    # A callback that *exits* (GenServer.call to a dead process is the
    # classic) must not kill the drain task: a dead stdout drain disables
    # draining AND stop-on-child-exit. Mirror safe_read/2.
    kind, reason ->
      Logger.warning("[NetRunner.Daemon] on_output #{kind}: #{inspect(reason)}")
      :ok
  end

  defp handle_output(:discard, _data), do: :ok

  defp handle_output(:log, data) do
    Logger.info(["[NetRunner.Daemon] ", data])
  end

  defp handle_output(fun, data) when is_function(fun, 1), do: fun.(data)
end
