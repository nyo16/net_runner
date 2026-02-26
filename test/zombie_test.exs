defmodule NetRunner.ZombieTest do
  use ExUnit.Case, async: false

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

      # Wait for watcher to clean up
      Process.sleep(1_000)

      # OS process should be dead
      assert Nif.nif_is_os_pid_alive(os_pid) == false
    end

    test "OS process dies on normal GenServer exit" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      os_pid = Proc.os_pid(pid)

      # Stop GenServer normally
      GenServer.stop(pid, :normal)

      # Wait briefly
      Process.sleep(500)

      # OS process should be dead
      assert Nif.nif_is_os_pid_alive(os_pid) == false
    end

    test "no zombie after process finishes normally" do
      {:ok, pid} = Proc.start("echo", ["done"])
      os_pid = Proc.os_pid(pid)

      {:ok, 0} = Proc.await_exit(pid)

      # Short wait
      Process.sleep(200)

      # OS process should be fully reaped
      assert Nif.nif_is_os_pid_alive(os_pid) == false
    end
  end
end
