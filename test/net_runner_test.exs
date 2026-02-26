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
end
