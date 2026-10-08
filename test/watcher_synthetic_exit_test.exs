defmodule NetRunner.WatcherSyntheticExitTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  alias NetRunner.Process, as: Proc

  describe "when the shepherd dies before the child" do
    test "a synthetic exit stops the watcher without signaling the child" do
      {:ok, process} = Proc.start("/bin/sh", ["-c", "read line"])
      on_exit(fn -> Proc.stop(process) end)

      os_pid = Proc.os_pid(process)
      %{shepherd_port: port, watcher: watcher} = :sys.get_state(process)
      {:os_pid, shepherd} = Port.info(port, :os_pid)

      {_output, 0} = System.cmd("kill", ["-9", Integer.to_string(shepherd)])
      eventually(fn -> Port.info(port) == nil end)

      assert {:error, :transport_closed} = Proc.kill(process, :sigkill)
      assert Process.alive?(watcher)

      send(process, :force_exit_timeout)

      assert {:ok, 137} = Proc.await_exit(process, 2_000)
      eventually(fn -> not Process.alive?(watcher) end)
      assert os_pid_alive?(os_pid)

      :ok = Proc.close_stdin(process)
      eventually(fn -> not os_pid_alive?(os_pid) end, 5_000)
    end
  end
end
