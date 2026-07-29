# Bisects the `run/2` `:input` size at which the writer/reader serialisation
# deadlock used to appear (OK below ~128 KiB, HUNG at and above 256 KiB),
# against a `stream!/2` control column that was always concurrent and so
# always OK. Post-fix both columns must be all-OK and within ~2x of each other.
#
#     MIX_ENV=prod mix run bench/deadlock_probe.exs

payload_sizes = [16_384, 65_536, 131_072, 262_144, 1_048_576, 4_194_304]

IO.puts("\n=== run/2 with :input through `cat` (writer concurrent since v1.4) ===")

for size <- payload_sizes do
  payload = :binary.copy(<<?a>>, size)

  parent = self()

  task =
    Task.async(fn ->
      {us, res} = :timer.tc(fn -> NetRunner.run(~w(cat), input: payload) end)
      send(parent, :done)
      {us, res}
    end)

  case Task.yield(task, 5_000) do
    {:ok, {us, {out, 0}}} when byte_size(out) == size ->
      IO.puts("  #{String.pad_leading(to_string(size), 9)} B  OK    #{div(us, 1000)} ms")

    {:ok, other} ->
      IO.puts("  #{String.pad_leading(to_string(size), 9)} B  ODD   #{inspect(other, limit: 3)}")

    nil ->
      Task.shutdown(task, :brutal_kill)
      IO.puts("  #{String.pad_leading(to_string(size), 9)} B  HUNG  (>5000 ms, killed)")
  end
end

IO.puts("\n=== same payloads via stream!/2 (control: always a concurrent Task) ===")

for size <- payload_sizes do
  payload = :binary.copy(<<?a>>, size)

  task =
    Task.async(fn ->
      :timer.tc(fn ->
        NetRunner.stream!(~w(cat), input: payload)
        |> Enum.reduce(0, fn c, acc -> acc + byte_size(c) end)
      end)
    end)

  case Task.yield(task, 5_000) do
    {:ok, {us, ^size}} ->
      IO.puts("  #{String.pad_leading(to_string(size), 9)} B  OK    #{div(us, 1000)} ms")

    {:ok, other} ->
      IO.puts("  #{String.pad_leading(to_string(size), 9)} B  ODD   #{inspect(other, limit: 3)}")

    nil ->
      Task.shutdown(task, :brutal_kill)
      IO.puts("  #{String.pad_leading(to_string(size), 9)} B  HUNG  (>5000 ms, killed)")
  end
end

IO.puts("")
