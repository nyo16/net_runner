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

    test "a crashing on_output callback does not bring the Daemon down" do
      # The drain task runs under Task.Supervisor.async_nolink, so an
      # uncaught error in the callback must not take the Daemon with it.
      {:ok, daemon} =
        Daemon.start_link(cmd: "cat", args: [], on_output: fn _ -> raise "boom" end)

      assert :ok = Daemon.write(daemon, "trigger\n")

      # Give the drain task time to read the chunk and raise.
      Process.sleep(200)

      assert Process.alive?(daemon)
      assert Daemon.alive?(daemon)

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

    # Proc.write/2 is an :infinity GenServer.call. Performed inside the
    # Daemon's own handle_call it wedged every other control call for as long
    # as the child refused to drain stdin — including the Proc.alive?/1 in
    # terminate/2, which then burned the supervisor's 5_000 ms shutdown budget
    # before the SIGTERM/SIGKILL escalation could run.
    test "control calls stay responsive while the child refuses to read stdin" do
      # `sleep` never reads stdin, so 4 MiB overflows any pipe buffer
      # (including the shepherd's 1 MiB F_SETPIPE_SZ on Linux) and the write
      # parks in the Process GenServer for the whole test.
      {:ok, daemon} = Daemon.start_link(cmd: "sleep", args: ["100"])
      writer = Task.async(fn -> Daemon.write(daemon, :binary.copy(<<0>>, 4_194_304)) end)

      # Let the write get as far as the pipe allows before probing.
      Process.sleep(100)
      refute Task.yield(writer, 0), "the write completed; the child drained stdin after all"

      {us, os_pid} = :timer.tc(fn -> Daemon.os_pid(daemon) end)
      assert is_integer(os_pid) and os_pid > 0
      assert us < 100_000, "os_pid/1 took #{us} us behind a stalled write"

      {us_alive, true} = :timer.tc(fn -> Daemon.alive?(daemon) end)
      assert us_alive < 100_000, "alive?/1 took #{us_alive} us behind a stalled write"

      # And terminate/2 still finishes well inside the shutdown budget.
      {us_stop, :ok} = :timer.tc(fn -> GenServer.stop(daemon) end)
      assert us_stop < 5_000_000, "shutdown took #{us_stop} us"

      Task.shutdown(writer, :brutal_kill)
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
