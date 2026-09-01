defmodule NetRunner.TeardownTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  alias NetRunner.Daemon
  alias NetRunner.Nif
  alias NetRunner.Process, as: Proc

  describe "Daemon drain loop" do
    # `rescue`/`catch` clauses on a `def` wrap the whole body in a try, which
    # takes the recursive call out of tail position. The drain loop then
    # retained one stack frame per chunk for the daemon's whole lifetime —
    # measured at ~64 KB/s of stack growth per drain task. The bound below is
    # generous: a tail-recursive loop sits at a few dozen words regardless of
    # how much it has drained.
    test "stack stays bounded no matter how much output is drained" do
      # Unbounded producer so the drain task is guaranteed to still be running
      # when we sample it.
      {:ok, daemon} =
        Daemon.start_link(
          cmd: "sh",
          args: ["-c", "yes drainme 2>/dev/null"],
          on_output: :discard
        )

      # Poll until the stdout drain has moved a few MB — thousands of chunks,
      # each of which used to retain a stack frame — instead of guessing a
      # settle sleep.
      proc = :sys.get_state(daemon).proc
      eventually(fn -> assert Proc.stats(proc).bytes_out > 5_000_000 end, 10_000)

      # Sample only the tasks THIS daemon owns (its monitors: two drain tasks
      # and the stdin forwarder). Enumerating all of the globally shared
      # NetRunner.TaskSupervisor under async: true asserted on sibling tests'
      # tasks — and `stacks != []` could pass on a sibling's task even with
      # this daemon's drain dead.
      {:monitors, monitors} = Process.info(daemon, :monitors)

      stacks =
        Enum.flat_map(monitors, fn {:process, pid} ->
          case Process.info(pid, :stack_size) do
            {:stack_size, size} -> [size]
            nil -> []
          end
        end)

      assert stacks != [], "expected at least one live drain task"
      assert Enum.max(stacks) < 5_000, "drain task stack grew to #{Enum.max(stacks)} words"

      GenServer.stop(daemon)
    end

    test "terminate escalates to SIGKILL inside the supervisor shutdown budget" do
      # `use GenServer` gives the Daemon a 5_000 ms shutdown budget. If
      # terminate/2 spends all of it waiting for a SIGTERM the child ignores,
      # the supervisor brutal-kills the Daemon before the SIGKILL is ever sent.
      # The ready-file sync matters: signalling before the trap is installed
      # kills the shell with the default TERM disposition and the escalation
      # path is never exercised (vacuous pass). The loop (vs a single sleep)
      # matters too: the group SIGTERM kills the inner sleep, but the
      # TERM-ignoring shell keeps looping until SIGKILL.
      ready = Path.join(System.tmp_dir!(), "nr_teardown_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(ready) end)

      {:ok, daemon} =
        Daemon.start_link(
          cmd: "sh",
          args: ["-c", "trap '' TERM; : > #{ready}; while :; do sleep 0.2; done"]
        )

      os_pid = Daemon.os_pid(daemon)
      eventually(fn -> File.exists?(ready) end)

      {us, :ok} = :timer.tc(fn -> GenServer.stop(daemon) end)

      assert us < 5_000_000, "terminate took #{div(us, 1000)}ms, over the 5s budget"

      eventually(fn -> not os_pid_alive?(os_pid) end)
    end
  end

  describe "stream teardown" do
    test "an early-halted stream tears down promptly" do
      # `yes` ignores stdin closure, so waiting for a graceful exit is a pure
      # stall. Halting the stream must escalate instead of waiting out the
      # natural-EOF grace.
      {us, [_first]} =
        :timer.tc(fn ->
          ["yes"] |> NetRunner.stream!() |> Enum.take(1)
        end)

      assert us < 1_500_000, "early-halted stream took #{div(us, 1000)}ms to tear down"
    end

    test "a normally-exiting command still yields its full output" do
      payload = String.duplicate("y", 50_000)

      collected =
        ["/bin/sh", "-c", "printf %s #{payload}"]
        |> NetRunner.stream!()
        |> Enum.join()

      assert collected == payload
    end
  end

  describe "partial writes" do
    # A write larger than the pipe buffer completes across several readiness
    # events. The parked operation has to carry forward the *remaining* bytes;
    # keeping the original payload restarts the write at offset 0 every time,
    # so the child receives the same bytes repeatedly and the write never
    # finishes. The exact-byte-count assertion is the point of this test — a
    # size-only check on the output would pass while megabytes of duplicates
    # were being pushed through.
    test "a large write sends every byte exactly once" do
      payload = :binary.copy("x", 1_000_000)
      # A sink, not an echo: writing 1 MB into `cat` without concurrently
      # draining stdout deadlocks by design, which is the backpressure working.
      {:ok, pid} = Proc.start("/bin/sh", ["-c", "cat > /dev/null"], [])

      assert :ok = Proc.write(pid, payload)
      assert :ok = Proc.close_stdin(pid)
      assert {:ok, 0} = Proc.await_exit(pid, 10_000)

      # The exact count is the whole point: a size-only check on the child's
      # output would pass while megabytes of duplicates were pushed through.
      assert Proc.stats(pid).bytes_in == byte_size(payload)

      GenServer.stop(pid)
    end

    test "a large streamed write does not duplicate data" do
      payload = :binary.copy("y", 1_000_000)

      collected =
        ["/bin/cat"]
        |> NetRunner.stream!(input: payload)
        |> Enum.join()

      assert collected == payload
    end
  end

  describe "nif_create_fd fd-type guard" do
    # read/write now run on normal schedulers, which is only safe while every
    # fd honours O_NONBLOCK. The guard turns that invariant from a comment
    # into an enforced precondition — a regular-file fd would block a
    # scheduler rather than return EAGAIN.
    test "rejects an fd that does not exist" do
      assert {:error, :invalid_fd} = Nif.nif_create_fd(999_999, self())
    end

    test "accepts a pipe fd" do
      # Every spawned process wraps three pipe fds, so a successful spawn is
      # the positive case for the guard.
      {:ok, pid} = Proc.start("/bin/sh", ["-c", "sleep 1"], [])
      assert is_integer(Proc.os_pid(pid))
      Proc.kill(pid, :sigkill)
    end
  end
end
