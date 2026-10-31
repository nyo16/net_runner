defmodule NetRunner.ZombieTest do
  use ExUnit.Case, async: false

  import NetRunner.TestHelpers

  alias NetRunner.Nif
  alias NetRunner.Process, as: Proc

  describe "zombie prevention" do
    test "OS process dies when GenServer is killed" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      os_pid = Proc.os_pid(pid)

      # Verify OS process is alive
      assert Nif.nif_is_os_pid_alive(os_pid) == true

      # Kill the GenServer (not graceful)
      Process.exit(pid, :kill)

      # Either the shepherd's POLLHUP ladder or the Watcher probe (once the
      # Port is gone) kills sleep; this test cannot tell which.
      eventually(fn -> Nif.nif_is_os_pid_alive(os_pid) == false end, 5_000)
    end

    test "the Watcher SIGTERMs an orphan when the GenServer crashes after the shepherd" do
      # Remove the shepherd first so its POLLHUP ladder cannot be the thing
      # that kills the child. The crashed GenServer closes its pipes, but
      # `sleep` never reads stdin, so only the Watcher's probe can end it.
      {:ok, pid} = Proc.start("sleep", ["100"])
      os_pid = Proc.os_pid(pid)
      %{watcher: watcher} = :sys.get_state(pid)

      System.cmd("kill", ["-KILL", to_string(parent_pid!(os_pid))])
      eventually(fn -> Port.info(:sys.get_state(pid).shepherd_port) == nil end)
      assert os_pid_alive?(os_pid)

      Process.exit(pid, :kill)

      eventually(fn -> not os_pid_alive?(os_pid) end, 5_000)
      eventually(fn -> not Process.alive?(watcher) end)
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
