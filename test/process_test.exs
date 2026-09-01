defmodule NetRunner.ProcessTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  alias NetRunner.Process, as: Proc

  describe "basic I/O" do
    test "read stdout from echo" do
      {:ok, pid} = Proc.start("echo", ["hello"])
      assert {:ok, "hello\n"} = Proc.read(pid)
      assert :eof = Proc.read(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "write to stdin and read from stdout via cat" do
      {:ok, pid} = Proc.start("cat", [])
      assert :ok = Proc.write(pid, "hello world")
      assert :ok = Proc.close_stdin(pid)
      assert {:ok, "hello world"} = Proc.read(pid)
      assert :eof = Proc.read(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "multiple writes" do
      {:ok, pid} = Proc.start("cat", [])
      assert :ok = Proc.write(pid, "one")
      assert :ok = Proc.write(pid, "two")
      assert :ok = Proc.write(pid, "three")
      assert :ok = Proc.close_stdin(pid)

      output = read_all(pid)
      assert output == "onetwothree"
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe "read_batch" do
    test "returns at least one chunk and :eof after drain" do
      {:ok, pid} = Proc.start("cat", [])
      assert :ok = Proc.write(pid, "hello world")
      assert {:ok, chunks} = Proc.read_batch(pid)
      assert is_list(chunks) and chunks != []
      assert IO.iodata_to_binary(chunks) == "hello world"
      assert :ok = Proc.close_stdin(pid)
      assert :eof = Proc.read_batch(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "preserves byte order across a multi-chunk stream" do
      expected = Enum.map_join(1..20_000, "", &"#{&1}\n")
      {:ok, pid} = Proc.start("sh", ["-c", "seq 1 20000"])

      output = batch_read_all(pid, [])
      assert output == expected
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "a batch cut short by EOF delivers data first, :eof next" do
      # Deterministic: after await_exit the pipe holds both the data and the
      # EOF, so the first batch MUST take the deferred-EOF branch.
      {:ok, pid} = Proc.start("sh", ["-c", "printf abc"])
      assert {:ok, 0} = Proc.await_exit(pid)

      assert {:ok, chunks} = Proc.read_batch(pid)
      assert IO.iodata_to_binary(chunks) == "abc"
      assert :eof = Proc.read_batch(pid)
      GenServer.stop(pid)
    end

    test "max_bytes and max_chunks bound the batch" do
      {:ok, pid} = Proc.start("cat", [])
      assert :ok = Proc.write(pid, "abcdef")

      assert {:ok, ["ab", "cd"]} = Proc.read_batch(pid, 2, 2)
      assert {:ok, ["ef"]} = Proc.read_batch(pid, 2, 2)
      assert :ok = Proc.close_stdin(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "a parked batch read resumes as a batch when data arrives" do
      # No data until the child writes: the first read EAGAINs and the caller
      # parks; the readiness event must resume it as a batch, not a single
      # read. The park is ASSERTED (not assumed from timing) before the
      # child is allowed to produce, so the {:batch, _, _} retry clause is
      # guaranteed to run.
      {:ok, pid} = Proc.start("sh", ["-c", "sleep 0.5; printf abc"])

      task = Task.async(fn -> Proc.read_batch(pid) end)
      assert wait_until(fn -> map_size(:sys.get_state(pid).operations.pending) == 1 end)

      assert {:ok, chunks} = Task.await(task, 5_000)
      assert IO.iodata_to_binary(chunks) == "abc"
      assert :eof = Proc.read_batch(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "read_count reflects one count per underlying read" do
      {:ok, pid} = Proc.start("cat", [])
      assert :ok = Proc.write(pid, "abcdef")
      assert {:ok, chunks} = Proc.read_batch(pid)
      assert Proc.stats(pid).read_count == length(chunks)
      assert :ok = Proc.close_stdin(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  defp batch_read_all(pid, acc) do
    case Proc.read_batch(pid) do
      {:ok, chunks} ->
        batch_read_all(pid, [acc | chunks])

      :eof ->
        IO.iodata_to_binary(acc)

      # Normalized to EOF on purpose: the equality assert downstream still
      # catches byte loss; only a server that wrongly reports exit instead
      # of :eof would slip through, and the deferred-EOF test above pins
      # that ordering directly.
      {:error, :process_exited} ->
        IO.iodata_to_binary(acc)
    end
  end

  # Polls `fun` (~5ms period) until truthy or ~1s elapses; returns the last
  # result so callers can `assert wait_until(...)`.
  defp wait_until(fun, attempts \\ 200)
  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end

  describe "multi-writer fan-in" do
    test "4 concurrent writers complete with exact byte accounting" do
      # The child sleeps first so the writers EAGAIN-park behind a full
      # pipe, then drains: the resume pass services them under ONE shared
      # write budget and every byte must land exactly once. 4 MiB total —
      # well past Linux's 1 MiB shepherd-grown pipe, so parking happens on
      # every platform — and the park is asserted before the drain starts.
      {:ok, pid} = Proc.start("sh", ["-c", "sleep 0.5; exec cat > /dev/null"])
      payload = :binary.copy(<<1>>, 1_048_576)

      tasks = for _ <- 1..4, do: Task.async(fn -> Proc.write(pid, payload) end)
      assert wait_until(fn -> map_size(:sys.get_state(pid).operations.pending) > 0 end)

      results = Task.await_many(tasks, 15_000)

      assert results == [:ok, :ok, :ok, :ok]
      assert Proc.stats(pid).bytes_in == 4 * 1_048_576
      assert :ok = Proc.close_stdin(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
      GenServer.stop(pid)
    end

    test "kill/2 during a parked multi-writer fan-in replies promptly" do
      # Occupancy bound: with 4 parked 2 MiB writers the server must still
      # interleave a kill/2 call instead of spending 4 full write budgets
      # per resume pass. Each payload EXCEEDS every platform's pipe capacity
      # (macOS 64 KiB, Linux 1 MiB shepherd-grown) so no writer can complete
      # before parking — a 1 MiB payload fit the Linux pipe exactly and the
      # first writer sailed through, leaving only 3 parked (CI failure).
      {:ok, pid} = Proc.start("sleep", ["100"])
      payload = :binary.copy(<<1>>, 2 * 1_048_576)

      tasks = for _ <- 1..4, do: Task.async(fn -> Proc.write(pid, payload) end)

      # All four writers must actually be parked before the kill is issued,
      # or the occupancy bound below is a trivial pass.
      assert wait_until(fn ->
               :sys.get_state(pid).operations.pending
               |> Enum.count(fn {_ref, {type, _f, _c, _m}} -> type == :write end) == 4
             end)

      t0 = System.monotonic_time(:millisecond)
      assert :ok = Proc.kill(pid, :sigkill)
      assert System.monotonic_time(:millisecond) - t0 < 1_000

      for task <- tasks do
        assert Task.await(task, 5_000) in [
                 :ok,
                 {:error, :process_exited},
                 {:error, :closed},
                 {:error, :epipe}
               ]
      end

      assert {:ok, _} = Proc.await_exit(pid)
      GenServer.stop(pid)
    end
  end

  describe "close_stdin" do
    test "close_stdin triggers EOF in child" do
      # `wc -c` counts bytes and outputs when stdin closes
      {:ok, pid} = Proc.start("wc", ["-c"])
      assert :ok = Proc.write(pid, "12345")
      assert :ok = Proc.close_stdin(pid)

      output = read_all(pid) |> String.trim()
      assert output == "5"
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe "exit status" do
    test "successful exit" do
      {:ok, pid} = Proc.start("true", [])
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "failure exit" do
      {:ok, pid} = Proc.start("false", [])
      assert {:ok, 1} = Proc.await_exit(pid)
    end

    test "exit code from sh -c" do
      {:ok, pid} = Proc.start("sh", ["-c", "exit 42"])
      assert {:ok, 42} = Proc.await_exit(pid)
    end
  end

  describe "kill" do
    test "kill with SIGTERM" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert :ok = Proc.kill(pid, :sigterm)
      assert {:ok, status} = Proc.await_exit(pid)
      # 128 + SIGTERM(15) = 143
      assert status == 143
    end

    test "kill with SIGKILL" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert :ok = Proc.kill(pid, :sigkill)
      assert {:ok, status} = Proc.await_exit(pid)
      # 128 + SIGKILL(9) = 137
      assert status == 137
    end
  end

  describe "binary data" do
    test "round-trips output containing NUL bytes" do
      {:ok, pid} = Proc.start("sh", ["-c", ~S|printf 'a\0b\0c'|], [])

      data = read_all(pid)
      assert data == "a\0b\0c"
      assert byte_size(data) == 5
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe "os_pid" do
    test "returns the OS pid" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      os_pid = Proc.os_pid(pid)
      assert is_integer(os_pid)
      assert os_pid > 0
      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
    end
  end

  describe "alive?" do
    test "returns true while running" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert Proc.alive?(pid) == true
      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
    end
  end

  describe "command not found" do
    test "returns error for nonexistent command" do
      {:ok, pid} = Proc.start("nonexistent_command_xyz", [])
      assert {:ok, 127} = Proc.await_exit(pid)
    end
  end

  describe "input validation" do
    # Regression: NUL bytes in cmd/args used to be passed through to
    # Port.open's args:, which is undefined behaviour on the C side.
    test "rejects NUL byte in cmd" do
      assert {:error, {:invalid_cmd, _}} = Proc.start("ec\0ho", ["hi"])
    end

    test "rejects NUL byte in args" do
      assert {:error, {:invalid_args, _}} = Proc.start("echo", ["he\0llo"])
    end

    test "rejects empty cmd" do
      assert {:error, {:invalid_cmd, _}} = Proc.start("", [])
    end

    test "NetRunner.run surfaces validation error instead of crashing" do
      assert {:error, {:invalid_args, _}} =
               NetRunner.run(["echo", "he\0llo"])
    end
  end

  describe "stderr capture for fast-exiting processes" do
    # Regression: the initial stderr chunk was sent to self() via
    # {:stderr_data, _} but no handle_info matched, so the first (often
    # only) chunk was dropped for fast-exiting commands.
    test "stderr-only command exits cleanly with default :consume" do
      assert {"", 0} = NetRunner.run(["sh", "-c", "echo err >&2"])
    end

    test "stats reflect stderr bytes read for :consume mode" do
      {:ok, pid} = Proc.start("sh", ["-c", "echo hello-stderr >&2"], stderr: :consume)
      assert {:ok, 0} = Proc.await_exit(pid, 5_000)
      stats = Proc.stats(pid)
      # "hello-stderr\n" = 13 bytes; tolerate >0 in case the shell adds extras.
      assert stats.bytes_err >= 13
    end
  end

  describe "owner monitor cleanup" do
    # Regression: if the stream consumer (or any :owner process) crashes
    # mid-iteration, Stream.resource's after callback is never run.
    # Before the :owner-monitor fix, NetRunner.Process and its OS child
    # lived on. Now the GenServer SIGKILLs and stops.
    test "Process SIGKILLs OS process when :owner dies" do
      parent = self()

      consumer =
        spawn(fn ->
          {:ok, pid} = Proc.start("sleep", ["30"], owner: self())
          os_pid = Proc.os_pid(pid)
          send(parent, {:os_pid, os_pid, pid})
          exit(:boom)
        end)

      {os_pid, proc_pid} =
        receive do
          {:os_pid, op, pp} -> {op, pp}
        after
          2_000 -> flunk("did not receive os_pid from consumer")
        end

      _ = consumer

      # Poll until the Process GenServer detects the DOWN, SIGKILLs the
      # child, reaps it, and stops. Avoids a fixed sleep that flakes on
      # loaded CI runners.
      assert eventually(
               fn ->
                 not Process.alive?(proc_pid) and not os_pid_alive?(os_pid)
               end,
               3_000
             ),
             "Process GenServer should have stopped and OS process should be killed"
    end
  end

  defp read_all(pid) do
    case Proc.read(pid) do
      {:ok, data} -> data <> read_all(pid)
      :eof -> ""
      {:error, _} -> ""
    end
  end
end
