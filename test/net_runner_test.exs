defmodule NetRunnerTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

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

    test "a command that finishes inside :timeout is not cut short" do
      assert {"fast\n", 0} = NetRunner.run(~w(echo fast), timeout: 5_000)
    end

    test "output under :max_output_size is returned whole" do
      assert {"hello\n", 0} = NetRunner.run(~w(echo hello), max_output_size: 1_000)
    end

    test "a truncated partial pins only its own bytes (PERF-5)" do
      for max <- [1, 1_000, 100_000] do
        assert {:error, {:max_output_exceeded, partial}} =
                 NetRunner.run(["yes"], max_output_size: max)

        assert byte_size(partial) == max

        # Only a refc binary (> 64 bytes) can pin a read buffer. OTP 27
        # reports a heap binary's referenced size in bits (1 byte -> 8).
        if max > 64, do: assert(:binary.referenced_byte_size(partial) == max)
      end
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

  describe ":input coalescing and :input_buffer" do
    test "large list input round-trips byte-identical through cat" do
      chunk = :binary.copy(<<7>>, 65_536)
      chunks = List.duplicate(chunk, 64)
      expected = IO.iodata_to_binary(chunks)

      assert {output, 0} = NetRunner.run(~w(cat), input: chunks, timeout: 30_000)
      assert output == expected
    end

    test "200k tiny list elements round-trip byte-identical through cat" do
      # The regression target: per-element writes cost a GenServer round trip
      # each; coalescing must not lose, duplicate, or reorder a single byte.
      chunks = for i <- 1..200_000, do: <<rem(i, 256)>>
      expected = IO.iodata_to_binary(chunks)

      assert {output, 0} = NetRunner.run(~w(cat), input: chunks, timeout: 60_000)
      assert output == expected
    end

    test "input_buffer: 65_536 with a File.stream!-shaped line stream round-trips" do
      line = String.duplicate("a", 79) <> "\n"
      count = 10_000
      expected = :binary.copy(line, count)

      lazy = Stream.map(1..count, fn _ -> line end)

      assert {output, 0} =
               NetRunner.run(~w(cat), input: lazy, input_buffer: 65_536, timeout: 30_000)

      assert output == expected
    end

    test "input_buffer: 0 preserves per-element writes; coalescing collapses them" do
      alias NetRunner.{InputWriter, Process}
      elements = List.duplicate("ab", 100)

      drain = fn drain, pid ->
        case Process.read(pid) do
          {:ok, data} -> data <> drain.(drain, pid)
          :eof -> ""
          {:error, reason} -> flunk("mid-drain read error: #{inspect(reason)}")
        end
      end

      write_count = fn input, buffer ->
        {:ok, pid} = Process.start("cat", [])
        writer = InputWriter.start(pid, input, buffer)
        output = drain.(drain, pid)
        assert output == :binary.copy("ab", 100)
        InputWriter.reap(writer, :done)
        {:ok, 0} = Process.await_exit(pid)
        count = Process.stats(pid).write_count
        GenServer.stop(pid)
        count
      end

      # Lazy + buffer 0: one write(2) per element, write_count >= element count.
      assert write_count.(Stream.map(1..100, fn _ -> "ab" end), 0) >= 100

      # Lazy + buffer: 200 bytes ≪ 64 KiB coalesces into ONE write; <= 3
      # leaves headroom only for partial-write retries at the pipe.
      assert write_count.(Stream.map(1..100, fn _ -> "ab" end), 65_536) <= 3

      # Eager list coalesces unconditionally (200 bytes ≪ the 1 MiB batch).
      assert write_count.(elements, 0) <= 3
    end

    test "rejects invalid :input_buffer" do
      assert_raise ArgumentError, fn -> NetRunner.run(~w(cat), input_buffer: -1) end
      assert_raise ArgumentError, fn -> NetRunner.run(~w(cat), input_buffer: :big) end
      assert_raise ArgumentError, fn -> NetRunner.stream!(~w(cat), input_buffer: -1) end
      assert_raise ArgumentError, fn -> NetRunner.stream!(~w(cat), input_buffer: :big) end
    end
  end

  describe "output: :iodata" do
    test "iodata result flattens byte-identical to the default binary result" do
      payload = :binary.copy(<<3>>, 2 * 1_048_576)

      assert {bin, 0} = NetRunner.run(~w(cat), input: payload)
      assert {iodata, 0} = NetRunner.run(~w(cat), input: payload, output: :iodata)

      assert IO.iodata_to_binary(iodata) == bin
    end

    test "iodata shape with stderr: :capture" do
      assert {out, 1, stderr} =
               NetRunner.run(["sh", "-c", "printf hi; printf err >&2; exit 1"],
                 stderr: :capture,
                 output: :iodata
               )

      assert IO.iodata_to_binary(out) == "hi"
      assert stderr == "err"
    end

    test "default :binary result is unchanged" do
      assert {"hello\n", 0} = NetRunner.run(~w(echo hello))
      assert {"hello\n", 0} = NetRunner.run(~w(echo hello), output: :binary)
    end

    test "max_output_exceeded partial is a binary even with output: :iodata" do
      assert {:error, {:max_output_exceeded, partial}} =
               NetRunner.run(["sh", "-c", "yes"], max_output_size: 100, output: :iodata)

      assert is_binary(partial)
      assert byte_size(partial) == 100
    end

    test "rejects unknown :output values" do
      assert_raise ArgumentError, fn -> NetRunner.run(~w(cat), output: :charlist) end
      assert_raise ArgumentError, fn -> NetRunner.stream!(~w(cat), output: :iodata) end
    end
  end

  describe "timeout path cleanup" do
    # Regression / sanity: on timeout, the OS process must be killed and
    # the GenServer stopped — no zombies left behind.
    test "timeout returns :timeout and cleans up" do
      # High-entropy marker (still a valid sleep duration on every platform)
      # so pgrep -f can never collide with another test's `sleep` argv or an
      # unrelated process on the host.
      marker = sleep_marker()

      for _ <- 1..5 do
        assert {:error, :timeout} =
                 NetRunner.run(["sleep", marker], timeout: 100)
      end

      # Shepherd + watcher reap asynchronously.
      eventually(fn -> pgrep_count(marker) == 0 end, 3_000)
    end

    # Issue #28: run/2's own timeout path hard-coded a 5 s SIGTERM grace, so a
    # TERM-ignoring child always returned at timeout + 5 s whatever
    # :kill_timeout said.
    test "a TERM-ignoring child is SIGKILLed after :kill_timeout, not a fixed 5 s" do
      marker = sleep_marker()

      {us, result} =
        :timer.tc(fn ->
          NetRunner.run(["sh", "-c", "trap '' TERM; exec sleep #{marker}"],
            timeout: 300,
            kill_timeout: 200
          )
        end)

      assert result == {:error, :timeout}
      # timeout + kill_timeout = 0.5 s; the old fixed grace made it >= 5.3 s.
      assert us < 3_000_000, "run/2 returned after #{div(us, 1000)} ms"
      eventually(fn -> pgrep_count(marker) == 0 end, 3_000)
    end
  end
end
