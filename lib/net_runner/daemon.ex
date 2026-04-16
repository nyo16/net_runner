defmodule NetRunner.Daemon do
  @moduledoc """
  A supervised long-running OS process.

  Wraps `NetRunner.Process` for integration into a supervision tree.
  Automatically drains stdout/stderr to prevent pipe blocking.

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

  def start_link(opts) do
    {gen_opts, daemon_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, daemon_opts, gen_opts)
  end

  def os_pid(daemon), do: GenServer.call(daemon, :os_pid)
  def alive?(daemon), do: GenServer.call(daemon, :alive?)
  def write(daemon, data), do: GenServer.call(daemon, {:write, data}, :infinity)

  @impl true
  def init(opts) do
    cmd = Keyword.fetch!(opts, :cmd)
    args = Keyword.get(opts, :args, [])
    on_output = Keyword.get(opts, :on_output, :discard)
    process_opts = Keyword.get(opts, :process_opts, [])

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

  def handle_call({:write, data}, _from, state) do
    {:reply, Proc.write(state.proc, data), state}
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

      case Proc.await_exit(state.proc, 5_000) do
        {:ok, _} -> :ok
        _ -> Proc.kill(state.proc, :sigkill)
      end
    end
  catch
    :exit, _ -> :ok
  end

  defp start_drain(proc, pipe, on_output) do
    reader = if pipe == :stdout, do: &Proc.read/1, else: &Proc.read_stderr/1

    task =
      Task.async(fn ->
        drain_loop(reader, proc, on_output)
      end)

    task.ref
  end

  defp drain_loop(reader, proc, on_output) do
    case reader.(proc) do
      {:ok, data} ->
        safe_handle_output(on_output, data)
        drain_loop(reader, proc, on_output)

      :eof ->
        :ok

      {:error, _} ->
        :ok
    end
  rescue
    # Defensive: if reader.() or caller pattern blows up (e.g. Proc already
    # terminated while we were mid-call), stop draining without bringing
    # down the Daemon through the linked Task.
    e ->
      require Logger
      Logger.warning("[NetRunner.Daemon] drain exception: #{inspect(e)}")
      :ok
  catch
    :exit, _ -> :ok
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
    Logger.info("[NetRunner.Daemon] #{data}")
  end

  defp handle_output(fun, data) when is_function(fun, 1), do: fun.(data)
end
