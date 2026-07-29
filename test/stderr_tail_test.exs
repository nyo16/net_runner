defmodule NetRunner.StderrTailTest do
  use ExUnit.Case, async: true

  alias NetRunner.Daemon
  alias NetRunner.Process, as: Proc

  # "errline\n" is 8 bytes; 100_000 / 8 = 12_500 whole lines, and the 8 KB
  # default cap is 1_024 whole lines — so the tail aligns cleanly and we can
  # assert exact contents.
  @line "errline\n"
  @total_bytes 100_000

  describe "bounded stderr tail (:consume mode)" do
    test "retains only the most-recent stderr_tail_bytes (default 8 KB)" do
      pid = start_proc("sh", ["-c", "yes errline 2>/dev/null | head -c #{@total_bytes} 1>&2"])

      assert {:ok, _status} = Proc.await_exit(pid)
      wait_until_drained(pid, @total_bytes)

      tail = Proc.stderr_tail(pid)
      assert byte_size(tail) == 8_192
      # The tail is exactly the last 1_024 lines.
      assert tail == String.duplicate(@line, 1_024)

      # Stats still count every byte that was drained, not just the retained tail.
      assert Proc.stats(pid).bytes_err == @total_bytes
    end

    # Every read is ~64 KiB, far larger than the 1 KiB cap, so this is the
    # "one chunk crosses the cap on its own" branch: the incoming chunk is
    # sliced and the old tail is never concatenated.
    test "honors a custom :stderr_tail_bytes cap" do
      pid =
        start_proc("sh", ["-c", "yes errline 2>/dev/null | head -c #{@total_bytes} 1>&2"],
          stderr_tail_bytes: 1_024
        )

      assert {:ok, _status} = Proc.await_exit(pid)
      wait_until_drained(pid, @total_bytes)

      tail = Proc.stderr_tail(pid)
      assert byte_size(tail) == 1_024
      assert tail == String.duplicate(@line, 128)
      assert Proc.stats(pid).bytes_err == @total_bytes
    end

    # The steady-state branch: the cap is larger than a single read, so once
    # the tail is full every chunk must splice `cap - size` retained bytes onto
    # the new chunk. This is the branch Phase 4 rewrote to build the result at
    # exactly `cap` in one pass instead of concatenating then re-slicing.
    test "retains exactly the last cap bytes when the cap exceeds one read" do
      total = 500_000
      cap = 200_000

      pid =
        start_proc("sh", ["-c", "yes errline 2>/dev/null | head -c #{total} 1>&2"],
          stderr_tail_bytes: cap
        )

      assert {:ok, _status} = Proc.await_exit(pid)
      wait_until_drained(pid, total)

      tail = Proc.stderr_tail(pid)
      assert byte_size(tail) == cap
      # cap / 8 = 25_000 whole lines, so the boundary lands cleanly.
      assert tail == String.duplicate(@line, div(cap, byte_size(@line)))
      assert Proc.stats(pid).bytes_err == total
    end

    # Same boundary, crossed by many small chunks instead of one big one: the
    # writes are spaced so each readiness event yields a single 8-byte read.
    # The tail therefore fills byte-by-byte (the "still under cap" branch) and
    # then crosses into the steady-state branch mid-line.
    test "crosses the cap correctly across many small chunks" do
      lines = 50
      cap = 100
      expected_full = String.duplicate(@line, lines)
      total = byte_size(expected_full)

      pid =
        start_proc(
          "sh",
          [
            "-c",
            "i=0; while [ $i -lt #{lines} ]; do printf 'errline\\n' >&2; sleep 0.01; " <>
              "i=$((i+1)); done"
          ],
          stderr_tail_bytes: cap
        )

      assert {:ok, _status} = Proc.await_exit(pid)
      wait_until_drained(pid, total)

      tail = Proc.stderr_tail(pid)
      assert byte_size(tail) == cap
      # Starts mid-line — the cap is not a multiple of the line length.
      assert tail == binary_part(expected_full, total - cap, cap)
      assert Proc.stats(pid).bytes_err == total
    end

    test ":stderr_tail_bytes of 0 retains nothing but still drains the pipe" do
      pid =
        start_proc("sh", ["-c", "yes errline 2>/dev/null | head -c #{@total_bytes} 1>&2"],
          stderr_tail_bytes: 0
        )

      assert {:ok, _status} = Proc.await_exit(pid)
      wait_until_drained(pid, @total_bytes)

      assert Proc.stderr_tail(pid) == ""
      # Draining still happened (the child did not block on a full pipe).
      assert Proc.stats(pid).bytes_err == @total_bytes
    end

    test "retention is bounded while throughput is not (no leak)" do
      pid = start_proc("sh", ["-c", "yes errline 2>/dev/null | head -c 200000 1>&2"])

      assert {:ok, _status} = Proc.await_exit(pid)
      wait_until_drained(pid, 200_000)

      # The whole point: O(1) retention vs O(n) throughput.
      assert Proc.stats(pid).bytes_err == 200_000
      assert byte_size(Proc.stderr_tail(pid)) == 8_192
    end
  end

  describe "validation" do
    test "rejects a negative :stderr_tail_bytes at start" do
      assert {:error, {:invalid_stderr_tail_bytes, _}} =
               Proc.start("echo", ["hi"], stderr_tail_bytes: -1)
    end

    test "rejects a non-integer :stderr_tail_bytes at start" do
      assert {:error, {:invalid_stderr_tail_bytes, _}} =
               Proc.start("echo", ["hi"], stderr_tail_bytes: :lots)
    end
  end

  describe ":disabled mode" do
    test "stderr_tail is empty and explicit read_stderr still works" do
      pid = start_proc("sh", ["-c", "echo err 1>&2"], stderr: :disabled)

      assert {:ok, "err\n"} = Proc.read_stderr(pid)
      assert {:ok, _status} = Proc.await_exit(pid)
      assert Proc.stderr_tail(pid) == ""
    end
  end

  describe "Daemon stderr ownership" do
    test "on_output receives the full stderr stream, in order" do
      test_pid = self()
      handler = fn data -> send(test_pid, {:out, data}) end

      {:ok, daemon} =
        Daemon.start_link(
          cmd: "sh",
          args: ["-c", "echo a 1>&2; echo b 1>&2; echo c 1>&2"],
          on_output: handler
        )

      # The Daemon's drain task is the sole stderr reader, so nothing is lost
      # to an internal consumer racing it.
      assert collect_output("a\nb\nc\n") == "a\nb\nc\n"

      GenServer.stop(daemon)
    end
  end

  # Starts a process and registers cleanup so the GenServer (and its NIF FDs)
  # don't linger past the test — Proc.start/3 is unlinked, so without this the
  # async suite would leak a GenServer per test.
  defp start_proc(cmd, args, opts \\ []) do
    {:ok, pid} = Proc.start(cmd, args, opts)

    on_exit(fn ->
      # :ok if alive; exits with :noproc if already gone — both fine.
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  # Polls until at least `expected` stderr bytes have been drained, so the
  # retained tail is final before we assert on it (avoids racing the
  # select-driven consumer against the OS process exit notification).
  defp wait_until_drained(pid, expected, attempts \\ 100) do
    if Proc.stats(pid).bytes_err >= expected do
      :ok
    else
      if attempts == 0 do
        flunk("stderr not fully drained: #{Proc.stats(pid).bytes_err}/#{expected}")
      else
        Process.sleep(20)
        wait_until_drained(pid, expected, attempts - 1)
      end
    end
  end

  # Accumulates chunks until `expected` is fully received (chunking is
  # arbitrary), then returns. Falls back to a timeout so a regression that
  # drops stderr fails the assertion instead of hanging.
  defp collect_output(expected, acc \\ "") do
    if acc == expected do
      acc
    else
      receive do
        {:out, data} -> collect_output(expected, acc <> data)
      after
        2_000 -> acc
      end
    end
  end
end
