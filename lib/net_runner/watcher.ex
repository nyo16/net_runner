defmodule NetRunner.Watcher do
  @moduledoc false

  use GenServer

  alias NetRunner.Nif
  alias NetRunner.Signal

  def start_link(genserver_pid, os_pid, shepherd_port) do
    GenServer.start_link(__MODULE__, {genserver_pid, os_pid, shepherd_port})
  end

  @doc """
  Starts a watcher under the WatcherSupervisor for the given process.

  `shepherd_port` lets the probe stand down while the shepherd is alive:
  the shepherd holds the child as a zombie until it reaps, so the OS pid is
  not recyclable while it lives — and the shepherd, not this process, owns
  signalling for that window.
  """
  def watch(genserver_pid, os_pid, shepherd_port \\ nil) do
    DynamicSupervisor.start_child(
      NetRunner.WatcherSupervisor,
      {__MODULE__, {genserver_pid, os_pid, shepherd_port}}
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

  def child_spec({genserver_pid, os_pid, shepherd_port}) do
    %{
      id: {__MODULE__, genserver_pid},
      start: {__MODULE__, :start_link, [genserver_pid, os_pid, shepherd_port]},
      restart: :temporary
    }
  end

  @impl true
  def init({genserver_pid, os_pid, shepherd_port}) do
    ref = Process.monitor(genserver_pid)

    {:ok,
     %{
       genserver_pid: genserver_pid,
       os_pid: os_pid,
       shepherd_port: shepherd_port,
       monitor_ref: ref
     }}
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
    #
    # While the shepherd port is still alive the probe is skipped entirely:
    # the shepherd holds the child as a zombie until it reaps, so the pid is
    # not recyclable and the shepherd's own POLLHUP ladder covers teardown —
    # an alive?→kill from here would be the exact check-then-act race the
    # missing escalation avoids.
    unless shepherd_alive?(state.shepherd_port) do
      case Nif.nif_is_os_pid_alive(state.os_pid) do
        true ->
          {:ok, sigterm} = Signal.resolve(:sigterm)
          Nif.nif_kill(state.os_pid, sigterm)

        false ->
          :ok
      end
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp shepherd_alive?(port), do: is_port(port) and Port.info(port) != nil
end
