# Prod-mode performance probe for NetRunner.
#
#     MIX_ENV=prod mix run bench/perf.exs
#     NR_BENCH_SAMPLES=7 MIX_ENV=prod mix run bench/perf.exs
#
# Every row runs NR_BENCH_SAMPLES times (default 5, minimum 5) and reports the
# MEDIAN, with min..max beside it. Single samples were noise: run-to-run
# spread is ~11% (CLAUDE.md bench discipline), so compare medians across ≥3
# whole runs, and measure before a change lands.
#
# Rows: spawn latency, stdout throughput, stdin throughput, tiny-element and
# list-backed lazy input (PERF-2), stderr drain with the default and a 1 MiB
# tail (PERF-3), max_output_size truncation and what the partial pins
# (PERF-5), the read_batch batch-size histogram, and concurrent spawn
# scaling (which exercises the Watcher DynamicSupervisor).

defmodule Bench do
  @samples max(String.to_integer(System.get_env("NR_BENCH_SAMPLES", "5")), 5)

  def samples, do: @samples

  # Runs `fun` @samples times; returns the sorted list of wall times in µs.
  defp sample(fun) do
    for _ <- 1..@samples do
      {us, _} = :timer.tc(fun)
      us
    end
    |> Enum.sort()
  end

  defp median(sorted), do: Enum.at(sorted, div(length(sorted), 2))

  def time(label, fun) do
    s = sample(fun)
    IO.puts("#{pad(label)} #{fmt(median(s))}  [#{fmt_range(s)}]")
  end

  def time(label, n, fun) do
    s = sample(fun)
    per = median(s) / n
    IO.puts("#{pad(label)} #{fmt(median(s))}  (#{Float.round(per, 1)} us/op)  [#{fmt_range(s)}]")
  end

  def throughput(label, bytes, fun) do
    s = sample(fun)
    mbs = bytes / 1_048_576 / (median(s) / 1_000_000)
    IO.puts("#{pad(label)} #{fmt(median(s))}  (#{Float.round(mbs, 1)} MB/s)  [#{fmt_range(s)}]")
  end

  defp pad(label), do: String.pad_trailing(label, 56)
  defp fmt_range(s), do: "#{String.trim(fmt(List.first(s)))}..#{String.trim(fmt(List.last(s)))}"

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

  # Chunks per read_batch/3 call while draining `mb` MiB of stdout: the batch
  # cap is pipe_capacity / read_size (macOS: 1, Linux: up to 16). Probe this
  # before trusting any message-count projection.
  def batch_histogram(mb) do
    {:ok, pid} =
      NetRunner.Process.start("dd", ["if=/dev/zero", "bs=1048576", "count=#{mb}", "status=none"])

    hist = drain_batches(pid, %{})
    NetRunner.Process.stop(pid)
    hist |> Enum.sort() |> Enum.map_join(" ", fn {size, n} -> "#{size}:#{n}" end)
  end

  defp drain_batches(pid, hist) do
    case NetRunner.Process.read_batch(pid) do
      {:ok, chunks} -> drain_batches(pid, Map.update(hist, length(chunks), 1, &(&1 + 1)))
      _ -> hist
    end
  end
end

IO.puts("\n=== NetRunner perf probe (#{Mix.env()}, #{Bench.samples()} samples/row, median) ===")
IO.puts("schedulers: #{System.schedulers_online()}  dirty_io: #{:erlang.system_info(:dirty_io_schedulers)}\n")

# Warm the code paths and the per-VM UDS base dir so it is not charged to run 1.
NetRunner.run(~w(true))

# --- 1. Spawn latency: trivial child, no I/O ---
n = 200
true_bin = System.find_executable("true")

Bench.time("spawn+reap true x#{n}", n, fn ->
  for _ <- 1..n, do: NetRunner.run([true_bin])
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

IO.puts("    read_batch chunks/call histogram (#{mb}MB dd): #{Bench.batch_histogram(mb)}")

# --- 4. stdin throughput (cat round trip) ---
# Both entry points write from a background Task, so both survive a payload
# larger than stdin_buffer + stdout_buffer.
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

# Spawn-dominated by construction: 128 KiB moves in well under a millisecond,
# so this row is a latency datapoint, not a throughput one.
Bench.throughput("write+read 128KB through cat (run/2, spawn-bound)", 131_072, fn ->
  {out, 0} = NetRunner.run(~w(cat), input: :binary.copy(<<0>>, 131_072))
  131_072 = byte_size(out)
end)

# --- 4b. Tiny-element stdin: 16 MiB as ~80-byte lines ---
# Per-element writes cost one GenServer round trip each, so 200k elements
# are messaging-bound. Eager lists coalesce unconditionally; lazy
# enumerables only with :input_buffer.
line = String.duplicate("x", 79) <> "\n"
tiny_count = div(16 * 1_048_576, 80)
tiny_bytes = tiny_count * 80
tiny_list = List.duplicate(line, tiny_count)

Bench.throughput("write+read 16MB tiny lines through cat (list input)", tiny_bytes, fn ->
  {out, 0} = NetRunner.run(~w(cat), input: tiny_list)
  ^tiny_bytes = byte_size(out)
end)

Bench.throughput("write+read 16MB tiny lines (lazy, input_buffer: 64KiB)", tiny_bytes, fn ->
  lazy = Stream.map(1..tiny_count, fn _ -> line end)
  {out, 0} = NetRunner.run(~w(cat), input: lazy, input_buffer: 65_536)
  ^tiny_bytes = byte_size(out)
end)

Bench.throughput("write+read 16MB tiny lines (lazy, write-through default)", tiny_bytes, fn ->
  lazy = Stream.map(1..tiny_count, fn _ -> line end)
  {out, 0} = NetRunner.run(~w(cat), input: lazy)
  ^tiny_bytes = byte_size(out)
end)

# PERF-2: a lazy enumerable that captures a large list. Every process
# boundary the enumerable crosses copies the captured 200k-cons list.
Bench.throughput("write+read 16MB list-backed lazy (input_buffer: 64KiB)", tiny_bytes, fn ->
  lazy = Stream.map(tiny_list, & &1)
  {out, 0} = NetRunner.run(~w(cat), input: lazy, input_buffer: 65_536)
  ^tiny_bytes = byte_size(out)
end)

# --- 5. stderr consume path (bounded tail) ---
stderr_cmd = ["sh", "-c", "dd if=/dev/zero bs=1048576 count=16 status=none >&2"]

Bench.throughput("drain 16MB stderr (tail 8KB)", 16 * 1_048_576, fn ->
  {_out, 0} = NetRunner.run(stderr_cmd)
end)

# PERF-3: the tail append cost grows with the cap.
Bench.throughput("drain 16MB stderr (tail 1MiB)", 16 * 1_048_576, fn ->
  {_out, 0} = NetRunner.run(stderr_cmd, stderr_tail_bytes: 1_048_576)
end)

# --- 5b. PERF-5: max_output_size truncation ---
# The partial is a fresh binary of exactly max_output_size bytes (only those
# are flattened), so it should pin only itself; report what it keeps alive.
Bench.time("max_output_size 1MiB truncation of `yes`", fn ->
  {:error, {:max_output_exceeded, _}} =
    NetRunner.run(["yes"], max_output_size: 1_048_576 + 1)
end)

{:error, {:max_output_exceeded, partial}} = NetRunner.run(["yes"], max_output_size: 1_000)

IO.puts(
  "    max_output_size 1000: partial #{byte_size(partial)} B pins " <>
    "#{:binary.referenced_byte_size(partial)} B"
)

# --- 6. Concurrent spawn scaling: exercises the Watcher DynamicSupervisor ---
for conc <- [1, 8, 32, 128] do
  sched = Bench.scheduler_snapshot()

  Bench.time("#{String.pad_leading(to_string(conc), 3)} concurrent run(true)", conc, fn ->
    1..conc
    |> Task.async_stream(fn _ -> NetRunner.run([true_bin]) end,
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
