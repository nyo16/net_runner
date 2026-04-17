defmodule NetRunner.ProcessTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process, as: Proc

  describe "basic I/O" do
    test "read stdout from echo" do
      {:ok, pid} = Proc.start("echo", ["hello"])
      assert {:ok, "hello\n"} = Proc.read(pid)
      assert :eof = Proc.read(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "write to stdin and read from stdout via cat" do
      {:ok, pid} = Proc.start("cat", [])
      assert :ok = Proc.write(pid, "hello world")
      assert :ok = Proc.close_stdin(pid)
      assert {:ok, "hello world"} = Proc.read(pid)
      assert :eof = Proc.read(pid)
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "multiple writes" do
      {:ok, pid} = Proc.start("cat", [])
      assert :ok = Proc.write(pid, "one")
      assert :ok = Proc.write(pid, "two")
      assert :ok = Proc.write(pid, "three")
      assert :ok = Proc.close_stdin(pid)

      output = read_all(pid)
      assert output == "onetwothree"
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe "close_stdin" do
    test "close_stdin triggers EOF in child" do
      # `wc -c` counts bytes and outputs when stdin closes
      {:ok, pid} = Proc.start("wc", ["-c"])
      assert :ok = Proc.write(pid, "12345")
      assert :ok = Proc.close_stdin(pid)

      output = read_all(pid) |> String.trim()
      assert output == "5"
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe "exit status" do
    test "successful exit" do
      {:ok, pid} = Proc.start("true", [])
      assert {:ok, 0} = Proc.await_exit(pid)
    end

    test "failure exit" do
      {:ok, pid} = Proc.start("false", [])
      assert {:ok, 1} = Proc.await_exit(pid)
    end

    test "exit code from sh -c" do
      {:ok, pid} = Proc.start("sh", ["-c", "exit 42"])
      assert {:ok, 42} = Proc.await_exit(pid)
    end
  end

  describe "kill" do
    test "kill with SIGTERM" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert :ok = Proc.kill(pid, :sigterm)
      assert {:ok, status} = Proc.await_exit(pid)
      # 128 + SIGTERM(15) = 143
      assert status == 143
    end

    test "kill with SIGKILL" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert :ok = Proc.kill(pid, :sigkill)
      assert {:ok, status} = Proc.await_exit(pid)
      # 128 + SIGKILL(9) = 137
      assert status == 137
    end
  end

  describe "binary data" do
    test "round-trips output containing NUL bytes" do
      {:ok, pid} = Proc.start("sh", ["-c", ~S|printf 'a\0b\0c'|], [])

      data = read_all(pid)
      assert data == "a\0b\0c"
      assert byte_size(data) == 5
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe "os_pid" do
    test "returns the OS pid" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      os_pid = Proc.os_pid(pid)
      assert is_integer(os_pid)
      assert os_pid > 0
      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
    end
  end

  describe "alive?" do
    test "returns true while running" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      assert Proc.alive?(pid) == true
      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
    end
  end

  describe "command not found" do
    test "returns error for nonexistent command" do
      {:ok, pid} = Proc.start("nonexistent_command_xyz", [])
      assert {:ok, 127} = Proc.await_exit(pid)
    end
  end

  describe "input validation" do
    # Regression: NUL bytes in cmd/args used to be passed through to
    # Port.open's args:, which is undefined behaviour on the C side.
    test "rejects NUL byte in cmd" do
      assert {:error, {:invalid_cmd, _}} = Proc.start("ec\0ho", ["hi"])
    end

    test "rejects NUL byte in args" do
      assert {:error, {:invalid_args, _}} = Proc.start("echo", ["he\0llo"])
    end

    test "rejects empty cmd" do
      assert {:error, {:invalid_cmd, _}} = Proc.start("", [])
    end

    test "NetRunner.run surfaces validation error instead of crashing" do
      assert {:error, {:invalid_args, _}} =
               NetRunner.run(["echo", "he\0llo"])
    end
  end

  describe "stderr capture for fast-exiting processes" do
    # Regression: the initial stderr chunk was sent to self() via
    # {:stderr_data, _} but no handle_info matched, so the first (often
    # only) chunk was dropped for fast-exiting commands.
    test "stderr-only command exits cleanly with default :consume" do
      assert {"", 0} = NetRunner.run(["sh", "-c", "echo err >&2"])
    end

    test "stats reflect stderr bytes read for :consume mode" do
      {:ok, pid} = Proc.start("sh", ["-c", "echo hello-stderr >&2"], stderr: :consume)
      assert {:ok, 0} = Proc.await_exit(pid, 5_000)
      stats = Proc.stats(pid)
      # "hello-stderr\n" = 13 bytes; tolerate >0 in case the shell adds extras.
      assert stats.bytes_err >= 13
    end
  end

  describe "owner monitor cleanup" do
    # Regression: if the stream consumer (or any :owner process) crashes
    # mid-iteration, Stream.resource's after callback is never run.
    # Before the :owner-monitor fix, NetRunner.Process and its OS child
    # lived on. Now the GenServer SIGKILLs and stops.
    test "Process SIGKILLs OS process when :owner dies" do
      parent = self()

      consumer =
        spawn(fn ->
          {:ok, pid} = Proc.start("sleep", ["30"], owner: self())
          os_pid = Proc.os_pid(pid)
          send(parent, {:os_pid, os_pid, pid})
          exit(:boom)
        end)

      {os_pid, proc_pid} =
        receive do
          {:os_pid, op, pp} -> {op, pp}
        after
          2_000 -> flunk("did not receive os_pid from consumer")
        end

      _ = consumer

      # Wait for the Process GenServer to detect the DOWN, SIGKILL the
      # child, reap it, and stop.
      Process.sleep(500)

      refute Process.alive?(proc_pid), "Process GenServer should have stopped"
      refute os_pid_alive?(os_pid), "OS process should be killed"
    end
  end

  defp os_pid_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp read_all(pid) do
    case Proc.read(pid) do
      {:ok, data} -> data <> read_all(pid)
      :eof -> ""
      {:error, _} -> ""
    end
  end
end
