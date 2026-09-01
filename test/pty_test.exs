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
      # tty prints device path and exits immediately
      {:ok, pid} = Proc.start("tty", [], pty: true)
      {:ok, data} = Proc.read(pid)
      refute data =~ "not a tty"
      assert data =~ "/dev/"
      {:ok, _status} = Proc.await_exit(pid, 5_000)
    end

    test "set_window_size does not crash" do
      {:ok, pid} = Proc.start("sleep", ["100"], pty: true)
      assert :ok = Proc.set_window_size(pid, 40, 120)
      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid, 5_000)
    end

    test "the child observes a set_window_size resize (TIOCSWINSZ)" do
      # `stty size` asks the pty slave for its winsize, so the child polling
      # its own terminal is ground truth that the resize actually landed — a
      # shepherd that dropped the CMD_SET_WINSIZE frame would still pass a
      # "does not crash" check. The child polls (bounded) rather than
      # sampling once so the test never races the resize against the exec;
      # openpty starts the terminal at 0x0, so the loop cannot pass vacuously.
      script = ~S"""
      i=0
      while [ "$(stty size)" != "40 120" ]; do
        i=$((i + 1))
        [ "$i" -gt 100 ] && { echo "NEVER RESIZED: $(stty size)"; exit 1; }
        sleep 0.05
      done
      echo RESIZED
      """

      {:ok, pid} = Proc.start("sh", ["-c", script], pty: true)
      assert :ok = Proc.set_window_size(pid, 40, 120)

      output = read_until_eof(pid, "")
      assert output =~ "RESIZED", "child never saw 40x120: #{inspect(output)}"
      assert {:ok, 0} = Proc.await_exit(pid, 10_000)
    end

    test "kill PTY process" do
      {:ok, pid} = Proc.start("sleep", ["100"], pty: true)
      :ok = Proc.kill(pid, :sigkill)
      {:ok, status} = Proc.await_exit(pid)
      assert status == 137
    end
  end

  # Proc.read/1 parks on EAGAIN (no busy loop) and the script always exits,
  # so this terminates: accumulate until the pty master reports EOF/exit.
  defp read_until_eof(pid, acc) do
    case Proc.read(pid) do
      {:ok, data} -> read_until_eof(pid, acc <> data)
      _eof_or_exited -> acc
    end
  end
end
