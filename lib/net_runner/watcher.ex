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
  Stops the watcher once its process records an exit status.

  The stored PID is not a safe child identity after a synthetic status.
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

  # This is the only signal outside the shepherd that uses a numeric PID.
  # Probe once, and only after the shepherd has stopped, to limit the reuse race.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
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
