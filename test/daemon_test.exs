defmodule NetRunner.DaemonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import NetRunner.TestHelpers

  alias NetRunner.Daemon
  alias NetRunner.Process.Operations

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
      test_pid = self()

      {:ok, daemon} =
        Daemon.start_link(cmd: "cat", args: [], on_output: &send(test_pid, {:output, &1}))

      assert :ok = Daemon.write(daemon, "hello\n")
      # cat echoes its stdin, so the bytes surfacing on stdout prove the write
      # reached the child rather than only being accepted by the Daemon.
      assert_receive {:output, "hello\n"}, 2_000
      GenServer.stop(daemon)
    end

    test "malformed :process_opts raise ArgumentError in the caller, not inside init/1" do
      # Without client-side validation the raise happens in init/1, which
      # surfaces as {:error, {%ArgumentError{}, _}} plus an exit signal into
      # the linked caller — the shape every other entry point avoids.
      assert_raise ArgumentError, ~r/stderr_tail_bytes/, fn ->
        Daemon.start_link(cmd: "sleep", args: ["100"], process_opts: [stderr_tail_bytes: -1])
      end

      assert_raise ArgumentError, ~r/:bogus/, fn ->
        Daemon.start_link(cmd: "sleep", args: ["100"], process_opts: [bogus: 1])
      end

      refute_receive {:EXIT, _, _}, 50
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
      # The callback runs inside the Daemon's drain task; safe_handle_output
      # must contain the raise. Synchronize on the callback actually having
      # fired — a fixed sleep could elapse before the drain even delivered
      # the chunk, leaving the daemon trivially alive and the crash path
      # never exercised (vacuous pass on loaded CI).
      test_pid = self()

      {:ok, daemon} =
        Daemon.start_link(
          cmd: "cat",
          args: [],
          on_output: fn _ ->
            send(test_pid, :callback_ran)
            raise "boom"
          end
        )

      capture_log(fn ->
        assert :ok = Daemon.write(daemon, "one\n")
        assert_receive :callback_ran, 2_000

        # A second chunk proves the drain task survived the first raise —
        # a dead stdout drain would disable draining AND stop-on-child-exit.
        assert :ok = Daemon.write(daemon, "two\n")
        assert_receive :callback_ran, 2_000

        assert Process.alive?(daemon)
        assert Daemon.alive?(daemon)

        GenServer.stop(daemon)
      end)
    end

    test "a dead stdin forwarder stops the Daemon instead of stranding writers" do
      # daemon.ex handles {:DOWN, forwarder_ref, ...}: every future write
      # would be a fire-and-forget send to a dead pid whose caller hangs
      # forever on an :infinity call, so the Daemon must stop with
      # :forwarder_down (and log why) rather than linger looking healthy.
      {:ok, daemon} = Daemon.start_link(cmd: "cat", args: [])
      %{forwarder: forwarder} = :sys.get_state(daemon)

      log =
        capture_log(fn ->
          Process.exit(forwarder, :kill)
          assert_receive {:EXIT, ^daemon, {:shutdown, :forwarder_down}}, 5_000
        end)

      assert log =~ "stdin forwarder died"
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
      log =
        capture_log(fn ->
          {:ok, daemon} =
            Daemon.start_link(
              cmd: "sh",
              args: ["-c", "echo one; sleep 0.1; exit 3"],
              on_output: fn _ -> exit(:callback_boom) end
            )

          # The drain survived the exit and still observed the child's status.
          assert_receive {:EXIT, ^daemon, {:shutdown, {:exit_status, 3}}}, 5_000
        end)

      # The callback really ran and its exit was contained, not skipped.
      assert log =~ "on_output exit: :callback_boom"
    end

    test "a crashed drain task stops the Daemon with :drain_crashed" do
      # A dead stdout drain means nothing observes the child exit and stdout
      # eventually wedges the child on a full pipe, so the Daemon must stop
      # (and say why) rather than linger looking healthy.
      {:ok, daemon} = Daemon.start_link(cmd: "sleep", args: ["100"])
      %{forwarder: forwarder} = :sys.get_state(daemon)
      os_pid = Daemon.os_pid(daemon)

      # The Daemon monitors its two drain tasks and its stdin forwarder.
      {:monitors, monitors} = Process.info(daemon, :monitors)
      drains = for {:process, pid} <- monitors, is_pid(pid), pid != forwarder, do: pid
      assert [drain | _] = drains

      log =
        capture_log(fn ->
          Process.exit(drain, :kill)
          assert_receive {:EXIT, ^daemon, {:shutdown, :drain_crashed}}, 5_000
        end)

      assert log =~ "drain task crashed: :killed"
      eventually(fn -> not os_pid_alive?(os_pid) end, 5_000)
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, fn ->
        Daemon.start_link(cmd: "cat", args: [], on_ouptut: :log)
      end
    end

    test "a supervisor shutdown honours process_opts[:kill_timeout]" do
      # Sized from the grace so the supervisor never brutal-kills the Daemon
      # mid-ladder: 30 s SIGTERM grace + 1 s SIGKILL grace + 1 s margin.
      assert %{shutdown: 32_000} =
               Daemon.child_spec(cmd: "x", process_opts: [kill_timeout: 30_000])

      assert %{shutdown: 5_000} = Daemon.child_spec(cmd: "x")

      ready = Path.join(System.tmp_dir!(), "nr_daemon_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(ready) end)

      {:ok, sup} =
        Supervisor.start_link(
          [
            {Daemon,
             cmd: "sh",
             args: ["-c", "trap '' TERM; : > #{ready}; while :; do sleep 0.2; done"],
             process_opts: [kill_timeout: 300]}
          ],
          strategy: :one_for_one
        )

      [{Daemon, daemon, :worker, _}] = Supervisor.which_children(sup)
      os_pid = Daemon.os_pid(daemon)
      eventually(fn -> File.exists?(ready) end)

      {us, :ok} = :timer.tc(fn -> Supervisor.stop(sup) end)

      assert us < 1_500_000, "supervisor shutdown took #{div(us, 1000)}ms"
      eventually(fn -> not os_pid_alive?(os_pid) end)
    end

    # Proc.write/2 is an :infinity GenServer.call. Performed inside the
    # Daemon's own handle_call it wedged every other control call for as long
    # as the child refused to drain stdin — including the Proc.alive?/1 in
    # terminate/2, which then burned the supervisor's 5_000 ms shutdown budget
    # before the SIGTERM/SIGKILL escalation could run.
    test "control calls stay responsive while the child refuses to read stdin" do
      # `sleep` never reads stdin, so 4 MiB overflows any pipe buffer
      # (including the shepherd's 256 KiB F_SETPIPE_SZ stdin on Linux) and the
      # write parks in the Process GenServer for the whole test.
      {:ok, daemon} = Daemon.start_link(cmd: "sleep", args: ["100"])
      {:ok, quiet} = Daemon.start_link(cmd: "sleep", args: ["100"])
      writer = Task.async(fn -> Daemon.write(daemon, :binary.copy(<<0>>, 4_194_304)) end)

      # Probe only once the write is parked on the full pipe.
      proc = :sys.get_state(daemon).proc

      eventually(fn ->
        assert [_] = Operations.pending_by_type(:sys.get_state(proc).operations, :write)
      end)

      os_pid = Daemon.os_pid(daemon)
      assert is_integer(os_pid) and os_pid > 0

      # Same calls against a quiet twin, measured now, carry the ambient load
      # of sibling async tests; a control call queued behind the stalled
      # write would block until the write finished (never, here). 20x the
      # twin, floored at the old absolute bound.
      for {name, call} <- [os_pid: &Daemon.os_pid/1, alive?: &Daemon.alive?/1] do
        quiet_us = median_us(fn -> call.(quiet) end)
        stalled_us = median_us(fn -> call.(daemon) end)
        bound = max(quiet_us * 20, 100_000)

        assert stalled_us < bound,
               "#{name} took #{stalled_us} us behind a stalled write (quiet twin #{quiet_us} us)"
      end

      GenServer.stop(quiet)

      # And terminate/2 still finishes well inside the shutdown budget.
      {us_stop, :ok} = :timer.tc(fn -> GenServer.stop(daemon) end)
      assert us_stop < 5_000_000, "shutdown took #{us_stop} us"

      Task.shutdown(writer, :brutal_kill)
      eventually(fn -> not os_pid_alive?(os_pid) end)
    end
  end

  describe "output flush latency (PERF-3)" do
    test "a small quiet burst reaches on_output promptly, not held for the next read" do
      test_pid = self()

      {:ok, daemon} =
        Daemon.start_link(
          cmd: "sh",
          args: ["-c", "echo prompt-marker; sleep 100"],
          on_output: &send(test_pid, {:output, &1})
        )

      # Far below the old 16 KiB flush threshold and the child stays quiet
      # for 100 s: the marker must be handed over without waiting for more
      # output or EOF.
      assert_receive {:output, "prompt-marker\n"}, 5_000
      GenServer.stop(daemon)
    end
  end
end
