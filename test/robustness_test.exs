defmodule NetRunner.RobustnessTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  alias NetRunner.Process, as: Proc

  describe "shepherd crash (TEST-1)" do
    test "a SIGKILLed shepherd surfaces a synthetic exit and the child does not leak" do
      # The shepherd is the child's parent; kill -9 it out from under a live
      # child. The BEAM must (a) unblock await_exit with the synthetic 137
      # after the force-exit backstop, and (b) not leak the child: closing
      # our pipe ends on stop gives the writing child EPIPE and it dies.
      {:ok, pid} = Proc.start("yes", [])
      os_pid = Proc.os_pid(pid)

      {shepherd_pid_out, 0} = System.cmd("ps", ["-o", "ppid=", "-p", to_string(os_pid)])
      shepherd_pid = shepherd_pid_out |> String.trim() |> String.to_integer()
      assert shepherd_pid > 1

      System.cmd("kill", ["-KILL", to_string(shepherd_pid)])

      # No real status can arrive; the @force_exit_timeout (5s) backstop
      # synthesises 137.
      assert {:ok, 137} = Proc.await_exit(pid, 10_000)

      Proc.stop(pid)
      eventually(fn -> not os_pid_alive?(os_pid) end, 5_000)
    end
  end

  describe "brutal Process kill does not leak the child (TEST-3)" do
    test "a TERM-ignoring child still dies after the Process dies brutally" do
      Process.flag(:trap_exit, true)
      ready = Path.join(System.tmp_dir!(), "nr_watch_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(ready) end)

      # Short shepherd kill_timeout so its SIGTERM->SIGKILL ladder (the
      # POLLHUP path) resolves quickly. The Watcher deliberately no longer
      # SIGKILL-escalates — a timed alive?->kill from a process with no reap
      # authority races OS pid reuse (SEC-4 class) — so the shepherd's ladder
      # is what must kill a TERM-ignoring child here.
      {:ok, pid} =
        Proc.start(
          "sh",
          ["-c", "trap '' TERM; : > #{ready}; while :; do sleep 0.2; done"],
          kill_timeout: 500
        )

      os_pid = Proc.os_pid(pid)
      # Wait for the trap to be installed, or SIGTERM would kill the shell
      # before it starts ignoring TERM (vacuous pass).
      eventually(fn -> File.exists?(ready) end)
      assert os_pid_alive?(os_pid)

      # Brutal kill: terminate/2 never runs. The Watcher sends its immediate
      # SIGTERM probe; the shepherd sees POLLHUP and escalates to SIGKILL.
      Process.exit(pid, :kill)

      eventually(fn -> not os_pid_alive?(os_pid) end, 8_000)
    end
  end

  describe "stream!/2 raises NetRunner.Error (TEST-8)" do
    test "on spawn failure" do
      e =
        assert_raise NetRunner.Error, fn ->
          NetRunner.stream!(["bad\0cmd"]) |> Enum.to_list()
        end

      assert {:spawn_failed, {:invalid_cmd, _}} = e.reason
    end

    test "on an empty command" do
      e = assert_raise NetRunner.Error, fn -> NetRunner.stream!([]) end
      assert {:invalid_cmd, _} = e.reason
    end
  end

  describe "kill/2 edge cases (TEST-9)" do
    test "accepts a raw integer signal" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert :ok = Proc.kill(pid, 9)
      assert {:ok, 137} = Proc.await_exit(pid)
      GenServer.stop(pid)
    end

    test "unknown signal returns {:error, :unknown_signal} through the GenServer" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert {:error, :unknown_signal} = Proc.kill(pid, :sigbogus)
      assert {:error, :unknown_signal} = Proc.kill(pid, 99)
      assert Proc.alive?(pid)

      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
      GenServer.stop(pid)
    end

    test "non-terminating signals do not flip the state to :exiting" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert :ok = Proc.kill(pid, :sigcont)
      assert Proc.alive?(pid)
      assert %{status: :running} = :sys.get_state(pid)

      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
      GenServer.stop(pid)
    end
  end

  describe "read_stderr in :consume mode (TEST-10)" do
    test "an external read_stderr races the internal drain without crashing or hanging" do
      {:ok, pid} = Proc.start("sh", ["-c", "printf abcd >&2; sleep 0.1"], stderr: :consume)

      task = Task.async(fn -> Proc.read_stderr(pid) end)

      assert {:ok, 0} = Proc.await_exit(pid, 5_000)

      # The external reader either won a chunk from the internal drain or got
      # a terminal answer once the process exited; every outcome is a value.
      case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, data}} when is_binary(data) ->
          :ok

        {:ok, other} ->
          assert other in [:eof, {:error, :process_exited}, {:error, :closed}]

        nil ->
          flunk("read_stderr neither returned nor failed")
      end

      # bytes_err counts every stderr byte read — by the internal drain or an
      # external reader — so the full 4 bytes are accounted for exactly once.
      assert Proc.stats(pid).bytes_err == 4
      GenServer.stop(pid)
    end

    test "read_stderr_batch races the internal drain without crashing or hanging" do
      {:ok, pid} = Proc.start("sh", ["-c", "printf abcd >&2; sleep 0.1"], stderr: :consume)

      task = Task.async(fn -> Proc.read_stderr_batch(pid) end)

      assert {:ok, 0} = Proc.await_exit(pid, 5_000)

      case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, chunks}} when is_list(chunks) ->
          # printf writes the 4 bytes in one write(2), so a data-winning
          # reader gets exactly them; anything else is corruption.
          assert IO.iodata_to_binary(chunks) == "abcd"

        {:ok, other} ->
          assert other in [:eof, {:error, :process_exited}, {:error, :closed}]

        nil ->
          flunk("read_stderr_batch neither returned nor failed")
      end

      assert Proc.stats(pid).bytes_err == 4
      GenServer.stop(pid)
    end
  end
end
