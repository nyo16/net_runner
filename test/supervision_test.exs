defmodule NetRunner.SupervisionTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  alias NetRunner.Daemon
  alias NetRunner.Process, as: Proc

  describe "Daemon under a supervisor (ARCH-H1)" do
    test "Supervisor.stop runs terminate/2 and the child receives SIGTERM" do
      # Without trap_exit the supervisor's :shutdown exit bypasses
      # terminate/2 entirely, the escalation never runs, and the child only
      # dies via the shepherd's POLLHUP path — never seeing SIGTERM.
      base = Path.join(System.tmp_dir!(), "nr_term_#{System.unique_integer([:positive])}")
      marker = base <> ".marker"
      ready = base <> ".ready"
      on_exit(fn -> Enum.each([marker, ready], &File.rm/1) end)

      # The ready file is written only after the trap is installed —
      # signalling earlier races trap installation and kills the shell with
      # the default TERM disposition.
      script =
        "trap 'echo got-term > #{marker}; exit 0' TERM; " <>
          ": > #{ready}; while :; do sleep 0.1; done"

      {:ok, sup} =
        Supervisor.start_link(
          [{Daemon, cmd: "sh", args: ["-c", script]}],
          strategy: :one_for_one
        )

      [{_, daemon, _, _}] = Supervisor.which_children(sup)
      os_pid = Daemon.os_pid(daemon)
      assert is_integer(os_pid)
      eventually(fn -> File.exists?(ready) end)

      :ok = Supervisor.stop(sup)

      eventually(fn -> File.exists?(marker) end)
      assert File.read!(marker) =~ "got-term"
      eventually(fn -> not os_pid_alive?(os_pid) end)
    end
  end

  describe "Daemon observes child exit (ARCH-H2)" do
    test "Daemon stops with the child's exit status" do
      Process.flag(:trap_exit, true)
      {:ok, daemon} = Daemon.start_link(cmd: "sh", args: ["-c", "exit 7"])

      assert_receive {:EXIT, ^daemon, {:shutdown, {:exit_status, 7}}}, 5_000
    end

    test "a permanent supervised Daemon is restarted after child exit" do
      {:ok, sup} =
        Supervisor.start_link(
          [
            Supervisor.child_spec({Daemon, cmd: "sh", args: ["-c", "sleep 0.2; exit 1"]},
              restart: :permanent
            )
          ],
          strategy: :one_for_one,
          max_restarts: 20,
          max_seconds: 5
        )

      [{_, first, _, _}] = Supervisor.which_children(sup)

      # After the child exits the Daemon stops abnormally ({:shutdown, ...})
      # and :permanent restarts it — a fresh pid appears.
      eventually(
        fn ->
          case Supervisor.which_children(sup) do
            [{_, pid, _, _}] when is_pid(pid) and pid != first -> true
            _ -> false
          end
        end,
        3_000
      )

      Supervisor.stop(sup)
    end
  end

  describe "no signalling after reap (SEC-4 / ARCH-M1)" do
    test "kill/2 after exit returns {:error, :not_running}" do
      {:ok, pid} = Proc.start("true", [])
      assert {:ok, 0} = Proc.await_exit(pid)

      # The OS pid may already belong to a brand-new process; signalling it
      # would be a cross-process kill.
      assert {:error, :not_running} = Proc.kill(pid, :sigterm)
      assert {:error, :not_running} = Proc.kill(pid, :sigkill)

      GenServer.stop(pid)
    end

    test "the Watcher stands down once the exit status is delivered" do
      {:ok, pid} = Proc.start("true", [])
      %{watcher: watcher} = :sys.get_state(pid)
      assert is_pid(watcher)

      assert {:ok, 0} = Proc.await_exit(pid)

      # Exit status in hand -> stand_down cast -> the Watcher stops, so a
      # later Process crash can never trigger a probe of a reused OS pid.
      eventually(fn -> not Process.alive?(watcher) end)

      GenServer.stop(pid)
    end
  end

  describe "Proc.shutdown/3 (ARCH-M4)" do
    test "SIGTERM path returns the exit status" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert {:ok, 143} = Proc.shutdown(pid, 5_000, 0)
      GenServer.stop(pid)
    end

    test "escalates to SIGKILL when SIGTERM is ignored" do
      ready = Path.join(System.tmp_dir!(), "nr_esc_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(ready) end)

      # The loop (not a single long sleep) matters: the group SIGTERM kills
      # the inner sleep, but the TERM-ignoring shell keeps looping, so only
      # the SIGKILL escalation can end it.
      {:ok, pid} =
        Proc.start("sh", ["-c", "trap '' TERM; : > #{ready}; while :; do sleep 0.2; done"])

      eventually(fn -> File.exists?(ready) end)
      assert {:ok, 137} = Proc.shutdown(pid, 300, 5_000)
      GenServer.stop(pid)
    end

    test "is safe on a dead server" do
      {:ok, pid} = Proc.start("true", [])
      {:ok, 0} = Proc.await_exit(pid)
      GenServer.stop(pid)

      assert :timeout = Proc.shutdown(pid, 50, 0)
    end
  end
end
