defmodule NetRunner.ZombieTest do
  use ExUnit.Case, async: false

  import NetRunner.TestHelpers

  alias NetRunner.Process, as: Proc
  alias NetRunner.Process.Nif

  describe "zombie prevention" do
    test "OS process dies when GenServer is killed" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      os_pid = Proc.os_pid(pid)

      # Verify OS process is alive
      assert Nif.nif_is_os_pid_alive(os_pid) == true

      # Kill the GenServer (not graceful)
      Process.exit(pid, :kill)

      # Watcher: SIGTERM immediately; sleep dies on it.
      eventually(fn -> Nif.nif_is_os_pid_alive(os_pid) == false end, 5_000)
    end

    test "OS process dies on normal GenServer exit" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      os_pid = Proc.os_pid(pid)

      # Stop GenServer normally
      GenServer.stop(pid, :normal)

      eventually(fn -> Nif.nif_is_os_pid_alive(os_pid) == false end, 5_000)
    end

    test "no zombie after process finishes normally" do
      {:ok, pid} = Proc.start("echo", ["done"])
      os_pid = Proc.os_pid(pid)

      {:ok, 0} = Proc.await_exit(pid)

      # OS process should be fully reaped
      eventually(fn -> Nif.nif_is_os_pid_alive(os_pid) == false end)
    end
  end
end
