defmodule NetRunner.IOPipeliningTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process, as: Proc

  # A regression must fail by timeout, never by hanging the suite. `run/2`'s
  # default `:timeout` is nil (:infinity), which is exactly what turned the
  # writer/reader serialisation bug into a permanent wedge.
  @hang_guard_ms 15_000

  describe "run/2 with :input larger than the pipe buffers" do
    # The bug: run_io/3 wrote all of :input before starting to read, so `cat`
    # filled its 64 KiB stdout pipe, blocked in write(2), stopped draining
    # stdin, and we blocked filling stdin. Deadlock for any input above
    # stdin_buffer + stdout_buffer (~128 KiB), forever.
    for size <- [262_144, 1_048_576, 4_194_304] do
      test "round-trips #{size} bytes through cat" do
        payload = :crypto.strong_rand_bytes(unquote(size))
        task = Task.async(fn -> NetRunner.run(~w(cat), input: payload) end)

        case Task.yield(task, @hang_guard_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, status}} ->
            assert status == 0
            assert output == payload

          nil ->
            flunk("run/2 did not return within #{@hang_guard_ms}ms for #{unquote(size)} B input")
        end
      end
    end

    test "a list of chunks round-trips too" do
      chunks = for _ <- 1..64, do: :crypto.strong_rand_bytes(65_536)
      expected = IO.iodata_to_binary(chunks)

      task = Task.async(fn -> NetRunner.run(~w(cat), input: chunks) end)

      assert {:ok, {^expected, 0}} =
               Task.yield(task, @hang_guard_ms) || Task.shutdown(task, :brutal_kill)
    end

    test "a Stream round-trips too" do
      chunk = :binary.copy(<<?s>>, 65_536)
      input = Stream.repeatedly(fn -> chunk end) |> Stream.take(64)
      expected = :binary.copy(chunk, 64)

      task = Task.async(fn -> NetRunner.run(~w(cat), input: input) end)

      assert {:ok, {^expected, 0}} =
               Task.yield(task, @hang_guard_ms) || Task.shutdown(task, :brutal_kill)
    end
  end

  describe "run/2 :timeout with :input" do
    # The escape hatch must survive the concurrent writer: the writer task is
    # now live on the timeout branch and has to be torn down with the reader.
    test "still returns {:error, :timeout} and reaps the OS process" do
      marker = "313"
      payload = :binary.copy(<<?x>>, 4_194_304)

      # Drains stdin fully (so the writer finishes) and then refuses to exit.
      assert {:error, :timeout} =
               NetRunner.run(["sh", "-c", "cat >/dev/null; sleep #{marker}"],
                 input: payload,
                 timeout: 300
               )

      Process.sleep(300)
      assert count_matching("sleep #{marker}") == 0
    end

    test "times out even while the writer is still blocked on a full stdin pipe" do
      marker = "317"
      payload = :binary.copy(<<?x>>, 4_194_304)

      # Never reads stdin, so the writer parks in Proc.write for the whole run.
      assert {:error, :timeout} =
               NetRunner.run(["sh", "-c", "sleep #{marker}"], input: payload, timeout: 300)

      Process.sleep(300)
      assert count_matching("sleep #{marker}") == 0
    end
  end

  describe "read sizing" do
    # @default_read_size must equal pipe capacity, not capacity - 1. At 65_535
    # a saturated pipe leaves exactly one byte behind and that byte costs a
    # whole extra GenServer round trip: measured +56-73% chunk count and +42%
    # wall time on a 64 MiB read. Guards against "tidying" it back to 65_535.
    test "a saturated stdout read returns full-capacity chunks" do
      mb = 16
      pid = start_proc("dd", ["if=/dev/zero", "bs=1048576", "count=#{mb}", "status=none"])
      Proc.close_stdin(pid)

      chunks = read_all_chunks(pid, [])
      assert Enum.sum(Enum.map(chunks, &byte_size/1)) == mb * 1_048_576

      # The last chunk may legitimately be short; nothing before it should be.
      mid = Enum.drop(chunks, -1)
      assert mid != []

      tiny = Enum.filter(mid, &(byte_size(&1) <= 16))
      assert tiny == [], "#{length(tiny)} tiny chunks — read size is under pipe capacity"

      full = Enum.count(chunks, &(byte_size(&1) == 65_536))

      assert full > div(length(chunks), 2),
             "only #{full}/#{length(chunks)} chunks were a full 65_536 bytes"
    end
  end

  describe "stderr drain bounding" do
    # consume_stderr/1 recurses inside handle_info; unbounded, every concurrent
    # handle_call queues behind the whole drain. The bound caps a pass at
    # @stderr_drain_chunks and resumes from the mailbox — which only works if
    # the :consume_stderr_more clause sits ABOVE the catch-all. If it does not,
    # the message is dropped, stderr stops draining, and the child deadlocks on
    # a full stderr pipe: this test then fails on await_exit, not on latency.
    test "a concurrent handle_call stays responsive during a 64 MB stderr flood" do
      pid = start_proc("sh", ["-c", "dd if=/dev/zero bs=1048576 count=64 status=none >&2"])
      parent = self()

      spawn_link(fn ->
        worst =
          Enum.reduce(1..200, 0, fn _, acc ->
            {us, _} = :timer.tc(fn -> Proc.os_pid(pid) end)
            Process.sleep(1)
            max(acc, us)
          end)

        send(parent, {:worst, worst})
      end)

      assert {:ok, 0} = Proc.await_exit(pid, 60_000)

      worst =
        receive do
          {:worst, us} -> us
        after
          30_000 -> flunk("latency probe never finished")
        end

      # Measured worst case is ~30 us against a jitter floor of the same order;
      # 50 ms is far above that and far below an unbounded drain.
      assert worst < 50_000, "worst concurrent handle_call was #{worst} us"

      # And the flood really was drained, not abandoned.
      assert Proc.stats(pid).bytes_err == 64 * 1_048_576
    end

    # The bound only engages when a single pass runs past @stderr_drain_chunks,
    # and a 64 KiB pipe rarely refills that fast on its own. A large retained
    # tail makes every drained chunk expensive (the tail is rebuilt at `cap`
    # bytes per chunk), so the producer outruns the drain and the budget is
    # exhausted for real. That is the ONLY path that schedules
    # :consume_stderr_more. If that clause is ever moved below the catch-all in
    # handle_info/2 the message is silently dropped, enif_select is not armed
    # (the pass stopped short of EAGAIN), draining stops dead and the child
    # blocks forever on a full stderr pipe — so this fails on await_exit, which
    # is a far worse regression than the latency bound above.
    test "draining resumes after a pass exhausts its chunk budget" do
      mb = 8
      total = mb * 1_048_576

      pid =
        start_proc("sh", ["-c", "dd if=/dev/zero bs=1048576 count=#{mb} status=none >&2"],
          stderr_tail_bytes: 1_048_576
        )

      assert {:ok, 0} = Proc.await_exit(pid, 30_000)
      assert wait_until(fn -> Proc.stats(pid).bytes_err == total end), "stderr drain stalled"
      assert byte_size(Proc.stderr_tail(pid)) == 1_048_576
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  defp read_all_chunks(pid, acc) do
    case Proc.read(pid) do
      {:ok, data} -> read_all_chunks(pid, [data | acc])
      _stop -> Enum.reverse(acc)
    end
  end

  defp start_proc(cmd, args, opts \\ []) do
    {:ok, pid} = Proc.start(cmd, args, opts)
    on_exit(fn -> Proc.stop(pid) end)
    pid
  end

  defp count_matching(pattern) do
    case System.cmd("pgrep", ["-f", pattern], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end
end
