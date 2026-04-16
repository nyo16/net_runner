defmodule NetRunner.Watcher do
  @moduledoc false

  use GenServer

  alias NetRunner.Process.Nif
  alias NetRunner.Signal

  @kill_timeout 5_000

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
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    # GenServer crashed — kill the OS process, then schedule a SIGKILL
    # escalation check instead of Process.sleep (which would wedge this
    # GenServer unresponsive to any other messages for 5 seconds).
    case Nif.nif_is_os_pid_alive(state.os_pid) do
      true ->
        {:ok, sigterm} = Signal.resolve(:sigterm)
        Nif.nif_kill(state.os_pid, sigterm)
        Process.send_after(self(), :escalate_to_sigkill, @kill_timeout)
        {:noreply, state}

      false ->
        {:stop, :normal, state}
    end
  end

  def handle_info(:escalate_to_sigkill, state) do
    case Nif.nif_is_os_pid_alive(state.os_pid) do
      true ->
        {:ok, sigkill} = Signal.resolve(:sigkill)
        Nif.nif_kill(state.os_pid, sigkill)

      false ->
        :ok
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
