defmodule NetRunner.TestHelpersTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  describe "eventually/2 and blocking calls" do
    # A suspended GenServer never answers, so every polled call exits with
    # :timeout after its full call timeout.
    setup do
      {:ok, server} = Agent.start_link(fn -> :ok end)
      :ok = :sys.suspend(server)
      {:ok, server: server}
    end

    test "a timed-out call is not re-polled when another one cannot fit", %{server: server} do
      attempts = :counters.new(1, [])

      # The first attempt blocks 300 ms, leaving < 300 ms of the 500 ms
      # budget: a second attempt would overshoot the deadline by ~400 ms.
      assert {:timeout, _} =
               catch_exit(
                 eventually(
                   fn ->
                     :counters.add(attempts, 1, 1)
                     Agent.get(server, & &1, 300)
                   end,
                   500
                 )
               )

      assert :counters.get(attempts, 1) == 1
    end

    test "a timed-out call is still re-polled while another one fits", %{server: server} do
      attempts = :counters.new(1, [])

      result =
        eventually(
          fn ->
            # Resume after the first timeout so a later attempt succeeds.
            if :counters.get(attempts, 1) == 1, do: :sys.resume(server)
            :counters.add(attempts, 1, 1)
            Agent.get(server, & &1, 50)
          end,
          2_000
        )

      assert result == :ok
      assert :counters.get(attempts, 1) == 2
    end
  end
end
