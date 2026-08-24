defmodule NetRunner.Daemon do
  @moduledoc """
  A supervised long-running OS process.

  Wraps `NetRunner.Process` for integration into a supervision tree.
  Automatically drains stdout/stderr to prevent pipe blocking. Both streams
  are delivered to the `:on_output` callback; stderr is owned by the Daemon's
  own drain task (the underlying process runs with `stderr: :disabled`), so
  `:on_output` sees the complete stderr stream in order.

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

  alias NetRunner.Process, as: Proc

  @type on_output :: :discard | :log | (binary() -> any())

  # terminate/2 must finish inside the supervisor's shutdown budget, which is the
  # `use GenServer` default of 5_000 ms above — past that the Daemon is
  # brutal-killed and the SIGKILL escalation never runs. Keep
  # @sigterm_grace_ms + @sigkill_grace_ms comfortably under that 5_000 ms.
  @sigterm_grace_ms 3_000
  @sigkill_grace_ms 1_000

  # Logger blocks its caller once the queue passes the sync threshold, so one
  # Logger call per drained chunk collapses the drain rate to Logger's
  # throughput. Consecutive chunks are coalesced into one message while the
  # child is saturating us, and flushed as soon as a read blocks (the child
  # went quiet) or the batch reaches @log_flush_bytes — so nothing sits
  # unlogged waiting for traffic that may never come.
  @log_flush_bytes 16_384
  @log_read_idle_us 1_000

  def start_link(opts) do
    {gen_opts, daemon_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, daemon_opts, gen_opts)
  end

  def os_pid(daemon), do: GenServer.call(daemon, :os_pid)
  def alive?(daemon), do: GenServer.call(daemon, :alive?)

  @doc """
  Writes to the child's stdin.

  The write is forwarded from a task rather than performed inside the
  Daemon's own `handle_call`, so a child that stops draining stdin cannot
  wedge `os_pid/1`, `alive?/1`, or the `Proc.alive?/1` in `terminate/2` —
  the last of which would burn the supervisor's shutdown budget before the
  SIGTERM/SIGKILL escalation ever ran.

  Sequential writes from one caller stay ordered (each call returns only once
  its bytes are in the pipe). Concurrent writers from different processes are
  no longer serialised by the Daemon, but interleaving two writers into one
  stdin stream was never well-defined anyway.
  """
  @spec write(GenServer.server(), binary()) :: :ok | {:error, term()}
  def write(daemon, data), do: GenServer.call(daemon, {:write, data}, :infinity)

  @impl true
  def init(opts) do
    cmd = Keyword.fetch!(opts, :cmd)
    args = Keyword.get(opts, :args, [])
    on_output = Keyword.get(opts, :on_output, :discard)

    # Force stderr: :disabled so the underlying Process does NOT start its own
    # internal stderr consumer. The Daemon's own drain task (below) is then the
    # sole reader of the stderr pipe, so on_output receives the full stream in
    # order rather than racing the internal consumer for chunks.
    process_opts =
      opts
      |> Keyword.get(:process_opts, [])
      |> Keyword.put(:stderr, :disabled)

    case Proc.start_link(cmd, args, process_opts) do
      {:ok, proc} ->
        # Start drain task for stdout
        drain_ref = start_drain(proc, :stdout, on_output)
        stderr_drain_ref = start_drain(proc, :stderr, on_output)

        {:ok,
         %{
           proc: proc,
           on_output: on_output,
           drain_ref: drain_ref,
           stderr_drain_ref: stderr_drain_ref
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:os_pid, _from, state) do
    {:reply, Proc.os_pid(state.proc), state}
  end

  def handle_call(:alive?, _from, state) do
    {:reply, Proc.alive?(state.proc), state}
  end

  def handle_call({:write, data}, from, state) do
    proc = state.proc

    Task.Supervisor.start_child(NetRunner.TaskSupervisor, fn ->
      GenServer.reply(from, safe_write(proc, data))
    end)

    {:noreply, state}
  end

  # Proc.write/2 is an :infinity GenServer.call, so a dead Proc exits the
  # caller. Inside the Daemon that crashed the Daemon; inside a detached task
  # it would instead hang the original caller forever on a reply that never
  # comes. Turn it into a value.
  defp safe_write(proc, data) do
    Proc.write(proc, data)
  catch
    :exit, _ -> {:error, :process_exited}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Drain task completed — process EOF'd
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  # Drain task went :DOWN. Normal completion would match the {ref, result}
  # clause above, so here we expect an abnormal reason (crash, :killed, etc.)
  # — log a warning so a drain crash does not silently stop draining.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if ref in [state.drain_ref, state.stderr_drain_ref] and reason != :normal do
      require Logger

      Logger.warning("[NetRunner.Daemon] drain task crashed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Graceful shutdown: SIGTERM → wait → SIGKILL
    if Proc.alive?(state.proc) do
      Proc.kill(state.proc, :sigterm)

      case safe_await_exit(state.proc, @sigterm_grace_ms) do
        {:ok, _} ->
          :ok

        _ ->
          Proc.kill(state.proc, :sigkill)
          safe_await_exit(state.proc, @sigkill_grace_ms)
          :ok
      end
    end
  catch
    :exit, _ -> :ok
  end

  # Proc.await_exit/2 is a GenServer.call, so exhausting the grace exits the
  # caller. Trap that here rather than in terminate/2, where it would unwind
  # past the SIGKILL escalation and make it unreachable.
  defp safe_await_exit(proc, timeout) do
    Proc.await_exit(proc, timeout)
  catch
    :exit, _ -> :timeout
  end

  defp start_drain(proc, pipe, on_output) do
    reader = if pipe == :stdout, do: &Proc.read/1, else: &Proc.read_stderr/1

    # async_nolink (not async): the drain task is unlinked from the Daemon,
    # so a task crash cannot take the Daemon down. Completion arrives as
    # {ref, result} and abnormal exit as {:DOWN, ref, ...}, both handled in
    # handle_info/2.
    task =
      Task.Supervisor.async_nolink(NetRunner.TaskSupervisor, fn ->
        drain_loop(reader, proc, on_output)
      end)

    task.ref
  end

  defp drain_loop(reader, proc, :log), do: log_drain_loop(reader, proc, [], 0)

  defp drain_loop(reader, proc, on_output) do
    case safe_read(reader, proc) do
      {:ok, data} ->
        safe_handle_output(on_output, data)
        drain_loop(reader, proc, on_output)

      _stop ->
        # :eof, {:error, _}, or :error from safe_read/2.
        :ok
    end
  end

  # Same loop, plus batching. Kept separate so the callback and :discard paths
  # pay nothing for it, and so the self-call below stays in tail position.
  defp log_drain_loop(reader, proc, batch, size) do
    started = System.monotonic_time(:microsecond)

    case safe_read(reader, proc) do
      {:ok, data} ->
        blocked? = System.monotonic_time(:microsecond) - started > @log_read_idle_us
        size = size + byte_size(data)

        if blocked? or size >= @log_flush_bytes do
          flush_log([batch, data])
          log_drain_loop(reader, proc, [], 0)
        else
          log_drain_loop(reader, proc, [batch, data], size)
        end

      _stop ->
        flush_log(batch)
        :ok
    end
  end

  defp flush_log([]), do: :ok
  defp flush_log(batch), do: safe_handle_output(:log, batch)

  # Defensive: if reader.() blows up (e.g. Proc already terminated while we were
  # mid-call), stop draining without bringing down the Daemon. This lives in its
  # own function because a rescue/catch on drain_loop/3 wraps its whole body in a
  # try, which takes the self-call above out of tail position — every drained
  # chunk then leaks a stack frame that is only popped at EOF.
  defp safe_read(reader, proc) do
    reader.(proc)
  rescue
    e ->
      require Logger
      Logger.warning("[NetRunner.Daemon] drain exception: #{inspect(e)}")
      :error
  catch
    :exit, _ -> :error
  end

  defp safe_handle_output(on_output, data) do
    handle_output(on_output, data)
  rescue
    e ->
      require Logger
      Logger.warning("[NetRunner.Daemon] on_output raised: #{inspect(e)}")
      :ok
  end

  defp handle_output(:discard, _data), do: :ok

  defp handle_output(:log, data) do
    require Logger
    Logger.info(["[NetRunner.Daemon] ", data])
  end

  defp handle_output(fun, data) when is_function(fun, 1), do: fun.(data)
end
