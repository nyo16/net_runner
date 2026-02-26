defmodule NetRunner.DaemonTest do
  use ExUnit.Case, async: true

  alias NetRunner.Daemon

  describe "Daemon" do
    test "start and stop a long-running process" do
      {:ok, daemon} = Daemon.start_link(cmd: "sleep", args: ["100"])
      assert Daemon.alive?(daemon)
      os_pid = Daemon.os_pid(daemon)
      assert is_integer(os_pid) and os_pid > 0

      GenServer.stop(daemon)
      Process.sleep(100)

      # OS process should be dead after daemon stops
      refute os_pid_alive?(os_pid)
    end

    test "write to daemon stdin" do
      {:ok, daemon} = Daemon.start_link(cmd: "cat", args: [])
      assert :ok = Daemon.write(daemon, "hello\n")
      GenServer.stop(daemon)
    end

    test "on_output :log works" do
      {:ok, daemon} = Daemon.start_link(cmd: "echo", args: ["logged"], on_output: :log)
      Process.sleep(200)
      GenServer.stop(daemon)
    end

    test "on_output with custom function" do
      test_pid = self()

      handler = fn data ->
        send(test_pid, {:output, data})
      end

      {:ok, daemon} = Daemon.start_link(cmd: "echo", args: ["custom"], on_output: handler)

      assert_receive {:output, data}, 2_000
      assert data =~ "custom"

      GenServer.stop(daemon)
    end

    test "daemon cleans up on crash" do
      Process.flag(:trap_exit, true)
      {:ok, daemon} = Daemon.start_link(cmd: "sleep", args: ["100"])
      os_pid = Daemon.os_pid(daemon)

      Process.exit(daemon, :kill)
      assert_receive {:EXIT, ^daemon, :killed}, 1_000
      Process.sleep(500)

      refute os_pid_alive?(os_pid)
    end
  end

  defp os_pid_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
