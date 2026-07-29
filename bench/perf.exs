# Prod-mode performance probe for NetRunner.
#
#     MIX_ENV=prod mix run bench/perf.exs
#
# Reports wall-clock and, where relevant, per-op cost for the four paths that
# dominate real usage: spawn latency, stdout throughput, stdin throughput, and
# concurrent spawn scaling (which exercises the Watcher DynamicSupervisor).

defmodule Bench do
  def time(label, fun) do
    {us, result} = :timer.tc(fun)
    IO.puts("#{String.pad_trailing(label, 46)} #{fmt(us)}")
    {us, result}
  end

  def time(label, n, fun) do
    {us, result} = :timer.tc(fun)
    per = us / n
    IO.puts("#{String.pad_trailing(label, 46)} #{fmt(us)}  (#{Float.round(per, 1)} us/op)")
    {us, result}
  end

  def throughput(label, bytes, fun) do
    {us, result} = :timer.tc(fun)
    mbs = bytes / 1_048_576 / (us / 1_000_000)
    IO.puts("#{String.pad_trailing(label, 46)} #{fmt(us)}  (#{Float.round(mbs, 1)} MB/s)")
    {us, result}
  end

  defp fmt(us) when us < 10_000, do: "#{String.pad_leading(to_string(us), 8)} us"
  defp fmt(us), do: "#{String.pad_leading(to_string(div(us, 1000)), 8)} ms"

  def scheduler_snapshot do
    :erlang.system_flag(:scheduler_wall_time, true)
    :erlang.statistics(:scheduler_wall_time)
  end

  def scheduler_delta(before) do
    now = :erlang.statistics(:scheduler_wall_time)
    a = Enum.sort(before)
    b = Enum.sort(now)

    Enum.zip(a, b)
    |> Enum.map(fn {{i, a_active, a_total}, {i, b_active, b_total}} ->
      total = b_total - a_total
      pct = if total > 0, do: (b_active - a_active) / total * 100, else: 0.0
      {i, Float.round(pct, 1)}
    end)
  end
end

IO.puts("\n=== NetRunner perf probe (#{Mix.env()}) ===")
IO.puts("schedulers: #{System.schedulers_online()}  dirty_io: #{:erlang.system_info(:dirty_io_schedulers)}\n")

# Warm the code paths and the per-VM UDS base dir so it is not charged to run 1.
NetRunner.run(~w(true))

# --- 1. Spawn latency: trivial child, no I/O ---
n = 200
Bench.time("spawn+reap /usr/bin/true x#{n}", n, fn ->
  for _ <- 1..n, do: NetRunner.run(["/usr/bin/true"])
end)

# --- 2. Sequential spawn with tiny output ---
Bench.time("run echo hello x#{n}", n, fn ->
  for _ <- 1..n, do: NetRunner.run(~w(echo hello))
end)

# --- 3. stdout throughput ---
mb = 64
bytes = mb * 1_048_576

Bench.throughput("read #{mb}MB from dd (run/2)", bytes, fn ->
  {out, 0} = NetRunner.run(["dd", "if=/dev/zero", "bs=1048576", "count=#{mb}", "status=none"])
  ^bytes = byte_size(out)
end)

Bench.throughput("read #{mb}MB from dd (stream!/2)", bytes, fn ->
  total =
    NetRunner.stream!(["dd", "if=/dev/zero", "bs=1048576", "count=#{mb}", "status=none"])
    |> Enum.reduce(0, fn chunk, acc -> acc + byte_size(chunk) end)

  ^bytes = total
end)

# --- 4. stdin throughput (cat round trip) ---
# Both entry points write from a background Task, so both survive a payload
# larger than stdin_buffer + stdout_buffer. Before v1.4 `run/2` wrote to
# completion first and deadlocked above ~128 KiB; the two 16 MB rows below
# must now land within ~2x of each other.
payload = :binary.copy(<<0>>, 16 * 1_048_576)
psize = byte_size(payload)

Bench.throughput("write+read 16MB through cat (stream!)", psize, fn ->
  total =
    NetRunner.stream!(~w(cat), input: payload)
    |> Enum.reduce(0, fn c, acc -> acc + byte_size(c) end)

  ^psize = total
end)

Bench.throughput("write+read 16MB through cat (run/2)", psize, fn ->
  {out, 0} = NetRunner.run(~w(cat), input: payload)
  ^psize = byte_size(out)
end)

# Spawn-dominated by construction: 128 KiB moves in well under a millisecond
# and one spawn costs ~5 ms, so this row is a latency datapoint, not a
# throughput one. Do not read its MB/s figure as I/O speed.
Bench.throughput("write+read 128KB through cat (run/2, spawn-bound)", 131_072, fn ->
  {out, 0} = NetRunner.run(~w(cat), input: :binary.copy(<<0>>, 131_072))
  131_072 = byte_size(out)
end)

# --- 5. stderr consume path (bounded tail) ---
Bench.throughput("drain 16MB stderr (tail 8KB)", 16 * 1_048_576, fn ->
  {_out, 0} =
    NetRunner.run(["sh", "-c", "dd if=/dev/zero bs=1048576 count=16 status=none >&2"])
end)

# --- 6. Concurrent spawn scaling: exercises the Watcher DynamicSupervisor ---
for conc <- [1, 8, 32, 128] do
  sched = Bench.scheduler_snapshot()

  Bench.time("#{String.pad_leading(to_string(conc), 3)} concurrent run(true)", conc, fn ->
    1..conc
    |> Task.async_stream(fn _ -> NetRunner.run(["/usr/bin/true"]) end,
      max_concurrency: conc,
      timeout: 60_000
    )
    |> Stream.run()
  end)

  if conc == 128 do
    IO.puts("    scheduler utilisation: #{inspect(Bench.scheduler_delta(sched))}")
  end
end

IO.puts("")
