defmodule NetRunner.PtyTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process, as: Proc

  describe "PTY mode" do
    test "basic I/O through PTY" do
      {:ok, pid} = Proc.start("cat", [], pty: true)

      :ok = Proc.write(pid, "hello\n")
      # PTY echoes input, then cat echoes it
      {:ok, data} = Proc.read(pid)
      assert data =~ "hello"

      # PTY doesn't support independent stdin close — kill to finish
      :ok = Proc.kill(pid, :sigkill)
      {:ok, _status} = Proc.await_exit(pid)
    end

    test "PTY provides terminal-like behavior" do
      # tty should report a device path, not "not a tty"
      {:ok, pid} = Proc.start("tty", [], pty: true)
      {:ok, data} = Proc.read(pid)
      refute data =~ "not a tty"
      assert data =~ "/dev/"
      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid, 5_000)
    end

    test "set_window_size does not crash" do
      {:ok, pid} = Proc.start("sleep", ["100"], pty: true)
      assert :ok = Proc.set_window_size(pid, 40, 120)
      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid, 5_000)
    end

    test "kill PTY process" do
      {:ok, pid} = Proc.start("sleep", ["100"], pty: true)
      :ok = Proc.kill(pid, :sigkill)
      {:ok, status} = Proc.await_exit(pid)
      assert status == 137
    end
  end
end
