defmodule NetRunner.SpawnFailureTest do
  use ExUnit.Case, async: true

  @sh "/bin/sh"

  # Exceeds Linux MAX_ARG_STRLEN and macOS ARG_MAX.
  @unexecable_arg String.duplicate("a", 2_000_000)

  describe "a shepherd that cannot start" do
    test "is reported as a spawn failure, not a connect timeout" do
      {us, result} = :timer.tc(fn -> NetRunner.run([@sh, "-c", @unexecable_arg]) end)

      assert {:error, {:shepherd_spawn_failed, _reason}} = result
      assert us < 2_000_000
    end
  end

  describe "a shepherd that starts" do
    test "an immediate child exit is not reported as a spawn failure" do
      results =
        1..100
        |> Task.async_stream(fn _ -> NetRunner.run([@sh, "-c", "exit 3"]) end,
          max_concurrency: 8,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({"", 3}, &1)), "got: #{inspect(Enum.uniq(results))}"
    end
  end
end
