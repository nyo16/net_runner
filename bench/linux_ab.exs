# Linux-only A/B probe for the two Linux tables the docs publish:
#
#   1. cgroup exit latency (ADR-14 addendum, bench/LINUX_VERIFICATION.md):
#      `sh -c 'sleep 60 & exit 0'` with and without `cgroup_path:`,
#      100 sequential runs per variant, 3 runs; p50 / p90 / mean / count ≥ 50 ms.
#   2. `pipe_size: :grown` vs `:default` throughput (docs/backpressure.md):
#      64 MiB dd via stream!/2, 16 MiB through cat via run/2, 16 MiB stderr
#      drain; median of 5 samples per row, 3 runs.
#
#     MIX_ENV=prod mix run bench/linux_ab.exs
#
# Off Linux it prints why and exits: `pipe_size:` has no effect there and
# `cgroup_path:` raises ArgumentError. Part 1 needs a writable cgroup v2
# (root, or a delegated `/sys/fs/cgroup/net_runner`); when the probe spawn
# fails, only that part is skipped, with the shepherd's reason.
#
# Same discipline as bench/perf.exs (CLAUDE.md): ≥3 runs, compare medians,
# ~11% run-to-run spread is the noise floor, and A/B on the same machine state
# (the variants are interleaved within each run for that reason).

defmodule LinuxAB do
  @runs 3
  @exits_per_run 100
  @slow_us 50_000
  @samples 5

  @orphan_cmd ["sh", "-c", "sleep 60 & exit 0"]

  def main do
    case :os.type() do
      {:unix, :linux} ->
        IO.puts("\n=== NetRunner Linux A/B (#{Mix.env()}) ===")
        IO.puts("schedulers: #{System.schedulers_online()}  runs: #{@runs}\n")
        # Warm the code paths and the per-VM UDS base dir.
        {_, 0} = NetRunner.run(~w(true))
        cgroup_latency()
        pipe_size_throughput()

      other ->
        IO.puts(
          "bench/linux_ab.exs is Linux-only (got #{inspect(other)}): " <>
            "pipe_size: has no effect and cgroup_path: raises off Linux. Nothing to measure."
        )
    end
  end

  # --- 1. cgroup exit latency ---

  defp cgroup_latency do
    IO.puts("--- cgroup exit latency: #{Enum.join(@orphan_cmd, " ")} ---")

    case cgroup_probe() do
      :ok ->
        IO.puts(
          "#{@exits_per_run} sequential exits per variant per run; slow = ≥ #{div(@slow_us, 1000)} ms\n"
        )

        IO.puts(
          pad("run / variant", 22) <>
            pad("p50", 10) <> pad("p90", 10) <> pad("mean", 10) <> "slow/#{@exits_per_run}"
        )

        for run <- 1..@runs do
          report_latency("#{run} no cgroup", exit_latencies(fn _i -> [] end))

          report_latency(
            "#{run} cgroup_path",
            exit_latencies(fn i -> [cgroup_path: leaf("lat_#{run}_#{i}")] end)
          )
        end

      {:skip, reason} ->
        IO.puts("SKIPPED: cgroup v2 is not writable here (#{reason}).")

        IO.puts(
          "Run as root, or delegate a subtree: sudo mkdir -p /sys/fs/cgroup/net_runner && " <>
            "sudo chown -R \"$USER\" /sys/fs/cgroup/net_runner"
        )
    end

    IO.puts("")
  end

  defp cgroup_probe do
    if File.exists?("/sys/fs/cgroup/cgroup.controllers") do
      case NetRunner.run(["true"], cgroup_path: leaf("probe")) do
        {_out, 0} -> :ok
        other -> {:skip, inspect(other)}
      end
    else
      {:skip, "/sys/fs/cgroup is not a cgroup v2 mount"}
    end
  end

  # A unique leaf per call: each spawn creates its own and the shepherd
  # removes it before reporting the exit (ADR-14), so nothing is left behind.
  defp leaf(name), do: "net_runner/linux_ab_#{System.pid()}_#{name}"

  defp exit_latencies(opts_fun) do
    for i <- 1..@exits_per_run do
      {us, {_out, 0}} = :timer.tc(fn -> NetRunner.run(@orphan_cmd, opts_fun.(i)) end)
      us
    end
    |> Enum.sort()
  end

  defp report_latency(label, sorted) do
    n = length(sorted)
    p50 = Enum.at(sorted, div(n * 50, 100))
    p90 = Enum.at(sorted, div(n * 90, 100))
    mean = Enum.sum(sorted) / n
    slow = Enum.count(sorted, &(&1 >= @slow_us))

    IO.puts(
      pad(label, 22) <> pad(ms(p50), 10) <> pad(ms(p90), 10) <> pad(ms(mean), 10) <> "#{slow}"
    )
  end

  # --- 2. pipe_size: :grown vs :default ---

  defp pipe_size_throughput do
    IO.puts("--- pipe_size: :grown vs :default (MB/s, median of #{@samples}) ---")
    IO.puts(pad("run / row", 40) <> pad(":grown", 12) <> ":default")

    for run <- 1..@runs, {label, bytes, fun} <- throughput_rows() do
      grown = mbs(bytes, median_us(fn -> fun.(:grown) end))
      default = mbs(bytes, median_us(fn -> fun.(:default) end))
      IO.puts(pad("#{run} #{label}", 40) <> pad(grown, 12) <> default)
    end

    IO.puts("")
  end

  defp throughput_rows do
    dd_bytes = 64 * 1_048_576
    dd = ["dd", "if=/dev/zero", "bs=1048576", "count=64", "status=none"]

    payload = :binary.copy(<<0>>, 16 * 1_048_576)
    cat_bytes = byte_size(payload)

    err_bytes = 16 * 1_048_576
    err_cmd = ["sh", "-c", "dd if=/dev/zero bs=1048576 count=16 status=none >&2"]

    [
      {"64 MiB dd via stream!/2", dd_bytes,
       fn size ->
         total =
           NetRunner.stream!(dd, pipe_size: size)
           |> Enum.reduce(0, fn chunk, acc -> acc + byte_size(chunk) end)

         ^dd_bytes = total
       end},
      {"16 MiB through cat via run/2", cat_bytes,
       fn size ->
         {out, 0} = NetRunner.run(~w(cat), input: payload, pipe_size: size)
         ^cat_bytes = byte_size(out)
       end},
      {"16 MiB stderr drain", err_bytes,
       fn size ->
         {_out, 0} = NetRunner.run(err_cmd, pipe_size: size)
       end}
    ]
  end

  defp median_us(fun) do
    sorted =
      for _ <- 1..@samples do
        {us, _} = :timer.tc(fun)
        us
      end
      |> Enum.sort()

    Enum.at(sorted, div(@samples, 2))
  end

  defp mbs(bytes, us), do: "#{Float.round(bytes / 1_048_576 / (us / 1_000_000), 1)}"
  defp ms(us), do: "#{Float.round(us / 1000, 2)} ms"
  defp pad(text, width), do: String.pad_trailing(text, width)
end

LinuxAB.main()
