defmodule NetRunnerTest do
  use ExUnit.Case, async: true

  describe "run/2" do
    test "simple echo" do
      {output, status} = NetRunner.run(~w(echo hello))
      assert output == "hello\n"
      assert status == 0
    end

    test "with input" do
      {output, status} = NetRunner.run(~w(cat), input: "from stdin")
      assert output == "from stdin"
      assert status == 0
    end

    test "nonzero exit" do
      {_output, status} = NetRunner.run(~w(false))
      assert status == 1
    end

    test "multi-word output" do
      {output, 0} = NetRunner.run(["sh", "-c", "printf hello; printf world"])
      assert output == "helloworld"
    end
  end

  describe "stream!/2" do
    test "streams stdout" do
      chunks =
        NetRunner.stream!(~w(echo hello))
        |> Enum.to_list()

      assert Enum.join(chunks) == "hello\n"
    end

    test "streams with input" do
      output =
        NetRunner.stream!(~w(cat), input: "streamed input")
        |> Enum.join()

      assert output == "streamed input"
    end

    test "handles large-ish data" do
      data = String.duplicate("x", 100_000)

      output =
        NetRunner.stream!(~w(cat), input: data)
        |> Enum.join()

      assert byte_size(output) == 100_000
    end
  end

  describe "stream/2" do
    test "returns {:ok, stream}" do
      assert {:ok, stream} = NetRunner.stream(~w(echo hello))
      output = Enum.join(stream)
      assert output == "hello\n"
    end
  end

  describe "input validation" do
    # Regression: run/2 used to pattern-match {:ok, pid} on Proc.start
    # which raised MatchError when validation failed. Now it returns the
    # error tuple directly.
    test "run surfaces NUL-byte validation error cleanly" do
      assert {:error, {:invalid_args, _}} = NetRunner.run(["echo", "bad\0arg"])
    end

    test "stream surfaces NUL-byte validation error cleanly" do
      assert {:error, {:invalid_args, _}} = NetRunner.stream(["echo", "bad\0arg"])
    end

    test "run rejects empty executable" do
      assert {:error, {:invalid_cmd, _}} = NetRunner.run([""])
    end
  end

  describe "timeout path cleanup" do
    # Regression / sanity: on timeout, the OS process must be killed and
    # the GenServer stopped — no zombies left behind.
    test "timeout returns :timeout and cleans up" do
      start_count = count_sleep_processes()

      for _ <- 1..5 do
        assert {:error, :timeout} =
                 NetRunner.run(["sleep", "30"], timeout: 100)
      end

      # Give the shepherd + watcher a moment to reap
      Process.sleep(300)

      end_count = count_sleep_processes()
      # Allow a tolerance for concurrent tests spawning sleeps
      assert end_count <= start_count + 1,
             "expected sleeps to be reaped; start=#{start_count} end=#{end_count}"
    end
  end

  defp count_sleep_processes do
    case System.cmd("pgrep", ["-x", "sleep"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end
end
