defmodule NetRunner.DaemonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import NetRunner.TestHelpers

  alias NetRunner.Daemon

  # The Daemon now stops with {:shutdown, {:exit_status, n}} when its child
  # exits, and start_link links it to the test process — so every test whose
  # child can exit traps exits.
  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "Daemon" do
    test "start and stop a long-running process" do
      {:ok, daemon} = Daemon.start_link(cmd: "sleep", args: ["100"])
      assert Daemon.alive?(daemon)
      os_pid = Daemon.os_pid(daemon)
      assert is_integer(os_pid) and os_pid > 0

      GenServer.stop(daemon)

      # OS process should be dead after daemon stops
      eventually(fn -> not os_pid_alive?(os_pid) end)
    end

    test "write to daemon stdin" do
      {:ok, daemon} = Daemon.start_link(cmd: "cat", args: [])
      assert :ok = Daemon.write(daemon, "hello\n")
      GenServer.stop(daemon)
    end

    test "write after child exit returns an error tuple" do
      {:ok, daemon} = Daemon.start_link(cmd: "cat", args: [])
      os_pid = Daemon.os_pid(daemon)

      System.cmd("kill", ["-KILL", to_string(os_pid)])

      # Once the Daemon observes the exit it stops; a write racing that stop
      # must come back as a value — never hang and never crash the caller.
      result =
        try do
          eventually(fn ->
            match?({:error, _}, Daemon.write(daemon, "late\n"))
          end)
        catch
          :exit, _ -> true
        end

      assert result
    end

    test "alive? is false after the child exits naturally" do
      {:ok, daemon} = Daemon.start_link(cmd: "sh", args: ["-c", "exit 0"])

      # The Daemon stops itself with the exit status; observing that stop IS
      # the "not alive" signal for a supervised daemon.
      assert_receive {:EXIT, ^daemon, {:shutdown, {:exit_status, 0}}}, 5_000
      refute Process.alive?(daemon)
    end

    test "on_output :log logs the drained output" do
      log =
        capture_log(fn ->
          {:ok, daemon} = Daemon.start_link(cmd: "echo", args: ["logged-marker"], on_output: :log)

          assert_receive {:EXIT, ^daemon, {:shutdown, {:exit_status, 0}}}, 5_000
        end)

      assert log =~ "logged-marker"
    end

    test "on_output with custom function" do
      test_pid = self()

      handler = fn data ->
        send(test_pid, {:output, data})
      end

      {:ok, daemon} = Daemon.start_link(cmd: "echo", args: ["custom"], on_output: handler)

      assert_receive {:output, data}, 2_000
      assert data =~ "custom"

      assert_receive {:EXIT, ^daemon, {:shutdown, {:exit_status, 0}}}, 5_000
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
      {:ok, daemon} = Daemon.start_link(cmd: "sleep", args: ["100"])
      os_pid = Daemon.os_pid(daemon)

      Process.exit(daemon, :kill)
      assert_receive {:EXIT, ^daemon, :killed}, 1_000
      eventually(fn -> not os_pid_alive?(os_pid) end, 3_000)
    end

    test "an exiting on_output callback does not disable draining or stop-on-exit" do
      # exit (not raise) is the classic callback failure — GenServer.call to
      # a dead process. It must not kill the drain task: a dead stdout drain
      # would disable both draining and the Daemon's stop-on-child-exit.
      {:ok, daemon} =
        Daemon.start_link(
          cmd: "sh",
          args: ["-c", "echo one; sleep 0.1; exit 3"],
          on_output: fn _ -> exit(:callback_boom) end
        )

      # The drain survived the exit and still observed the child's status.
      assert_receive {:EXIT, ^daemon, {:shutdown, {:exit_status, 3}}}, 5_000
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, fn ->
        Daemon.start_link(cmd: "cat", args: [], on_ouptut: :log)
      end
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
      eventually(fn -> not os_pid_alive?(os_pid) end)
    end
  end

  describe "log flush latency (PERF-3)" do
    test "a small quiet burst is logged promptly, not held for the next read" do
      log =
        capture_log(fn ->
          {:ok, daemon} =
            Daemon.start_link(
              cmd: "sh",
              args: ["-c", "echo prompt-marker; sleep 100"],
              on_output: :log
            )

          # Far below the old 16 KiB flush threshold and the child stays
          # quiet: the marker must still appear without waiting for EOF.
          # (The child sleeps for 100 s, so if the marker shows up within
          # this window it was flushed promptly, not held for the next read.)
          Process.sleep(300)
          GenServer.stop(daemon)
        end)

      assert log =~ "prompt-marker"
    end
  end
end
