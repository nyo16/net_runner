# Verifies the two remaining analysis claims by measurement rather than reading.
#
#     MIX_ENV=prod mix run bench/claims.exs
#
# A. consume_stderr/1 used to recurse without a bound inside handle_info, so a
#    child flooding stderr should starve concurrent callers of the same
#    GenServer. Measured as the worst-case latency of an `os_pid/1` call (a
#    trivial handle_call) issued while stderr is being drained. It is now
#    capped at @stderr_drain_chunks per pass; expect the idle jitter floor.
#
# B. @default_read_size must equal pipe capacity exactly. At 65_535 a saturated
#    pipe leaves 1 byte behind and that byte costs an extra round trip.
#    Measured as the chunk-count difference at 65_535 vs 65_536 — both are
#    passed explicitly, so this stays a valid guard whatever the default is.

alias NetRunner.Process, as: Proc

IO.puts("\n=== A. GenServer starvation during stderr drain ===\n")

measure_starvation = fn mb ->
  {:ok, pid} =
    Proc.start("sh", ["-c", "dd if=/dev/zero bs=1048576 count=#{mb} status=none >&2"], [])

  # Hammer a trivial handle_call from another process and record the worst
  # round trip. Any latency here is time the GenServer spent inside
  # consume_stderr/1 rather than in receive.
  parent = self()

  probe =
    spawn(fn ->
      worst =
        Enum.reduce(1..400, 0, fn _, acc ->
          {us, _} = :timer.tc(fn -> Proc.os_pid(pid) end)
          Process.sleep(1)
          max(acc, us)
        end)

      send(parent, {:worst, worst})
    end)

  Proc.await_exit(pid, 60_000)

  worst =
    receive do
      {:worst, w} -> w
    after
      30_000 ->
        Process.exit(probe, :kill)
        :timeout
    end

  GenServer.stop(pid, :normal, 5_000)
  worst
end

# Baseline: same probe against a child that writes nothing to stderr.
{:ok, idle} = Proc.start("sleep", ["1"], [])

idle_worst =
  Enum.reduce(1..200, 0, fn _, acc ->
    {us, _} = :timer.tc(fn -> Proc.os_pid(idle) end)
    Process.sleep(1)
    max(acc, us)
  end)

Proc.await_exit(idle, 10_000)
GenServer.stop(idle, :normal, 5_000)
IO.puts("  worst os_pid/1 latency, idle child          #{idle_worst} us")

for mb <- [16, 64, 256] do
  w = measure_starvation.(mb)
  IO.puts("  worst os_pid/1 latency, #{String.pad_leading(to_string(mb), 3)}MB stderr flood  #{w} us")
end

IO.puts("\n=== B. read size 65_535 vs 65_536 ===\n")

count_chunks = fn size, mb ->
  {:ok, pid} =
    Proc.start("dd", ["if=/dev/zero", "bs=1048576", "count=#{mb}", "status=none"], [])

  Proc.close_stdin(pid)

  {us, {chunks, tiny, total}} =
    :timer.tc(fn ->
      Enum.reduce_while(Stream.cycle([:go]), {0, 0, 0}, fn _, {c, t, b} ->
        case Proc.read(pid, size) do
          {:ok, data} ->
            bs = byte_size(data)
            {:cont, {c + 1, t + if(bs <= 16, do: 1, else: 0), b + bs}}

          :eof ->
            {:halt, {c, t, b}}

          {:error, _} ->
            {:halt, {c, t, b}}
        end
      end)
    end)

  GenServer.stop(pid, :normal, 5_000)
  {chunks, tiny, total, us}
end

for size <- [65_535, 65_536] do
  {chunks, tiny, total, us} = count_chunks.(size, 64)

  IO.puts(
    "  max_bytes=#{size}: #{chunks} chunks (#{tiny} of <=16 B), " <>
      "#{total} B in #{div(us, 1000)} ms"
  )
end

IO.puts("")
