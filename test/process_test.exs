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

  defp read_all(pid) do
    case Proc.read(pid) do
      {:ok, data} -> data <> read_all(pid)
      :eof -> ""
      {:error, _} -> ""
    end
  end
end
