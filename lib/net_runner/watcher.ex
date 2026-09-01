defmodule NetRunner.Watcher do
  @moduledoc false

  use GenServer

  alias NetRunner.Process.Nif
  alias NetRunner.Signal

  def start_link(genserver_pid, os_pid) do
    GenServer.start_link(__MODULE__, {genserver_pid, os_pid})
  end

  @doc """
  Starts a watcher under the WatcherSupervisor for the given process.
  """
  def watch(genserver_pid, os_pid) do
    DynamicSupervisor.start_child(
      NetRunner.WatcherSupervisor,
      {__MODULE__, {genserver_pid, os_pid}}
    )
  end

  @doc """
  Tells the watcher its process's exit status was delivered: the child is
  reaped, so any later signal would race OS pid reuse. The watcher simply
  stops. Safe on an already-stopped watcher.
  """
  def stand_down(watcher) when is_pid(watcher) do
    GenServer.cast(watcher, :stand_down)
  end

  def child_spec({genserver_pid, os_pid}) do
    %{
      id: {__MODULE__, genserver_pid},
      start: {__MODULE__, :start_link, [genserver_pid, os_pid]},
      restart: :temporary
    }
  end

  @impl true
  def init({genserver_pid, os_pid}) do
    ref = Process.monitor(genserver_pid)
    {:ok, %{genserver_pid: genserver_pid, os_pid: os_pid, monitor_ref: ref}}
  end

  @impl true
  def handle_cast(:stand_down, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    # GenServer crashed without delivering an exit status. Send one immediate
    # SIGTERM probe and stop. There is deliberately NO timed SIGKILL
    # escalation here: five seconds after a crash the shepherd has usually
    # seen POLLHUP, run its own SIGTERM→SIGKILL ladder and *reaped* the child
    # — a later alive?→kill from this process (which has no reap authority)
    # is a check-then-act race against OS pid reuse and can SIGKILL an
    # innocent process. Escalation is the shepherd's job; this probe only
    # covers a shepherd that died before its ladder ran, where the orphaned
    # child's pid stays occupied (unreaped) and the probe window is narrow.
    case Nif.nif_is_os_pid_alive(state.os_pid) do
      true ->
        {:ok, sigterm} = Signal.resolve(:sigterm)
        Nif.nif_kill(state.os_pid, sigterm)

      false ->
        :ok
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
