defmodule NetRunner.SecurityTest do
  use ExUnit.Case, async: true

  import Bitwise
  import NetRunner.TestHelpers

  alias NetRunner.Process, as: Proc

  describe "port FD hygiene (SEC-3)" do
    test "the child does not inherit the BEAM port FDs 3/4" do
      # With :nouse_stdio the shepherd talks to the BEAM over fds 3/4. Those
      # must be CLOEXEC so the child cannot read from or scribble into the
      # port protocol. A write to a closed fd fails and the shell exits
      # non-zero; without the fix fd 4 is the port's input pipe and the
      # write would succeed.
      {_out, status3} = NetRunner.run(["sh", "-c", "echo x >&3 2>/dev/null"])
      assert status3 != 0, "fd 3 leaked into the child"

      {_out, status4} = NetRunner.run(["sh", "-c", "echo x >&4 2>/dev/null"])
      assert status4 != 0, "fd 4 leaked into the child"
    end
  end

  describe ":env option (SEC-9)" do
    test "malformed env raises at Proc.start, before anything is spawned" do
      for bad <- [
            %{"A=B" => "x"},
            %{"" => "x"},
            %{"OK" => "a\0b"},
            %{"OK" => <<0xFF>>},
            {:merge, %{"OK" => "x"}}
          ] do
        assert_raise ArgumentError, ~r/:env/, fn ->
          Proc.start("echo", ["x"], env: bad)
        end
      end
    end
  end

  describe "set_window_size validation (SEC-10)" do
    test "rejects values outside the 2-byte protocol range" do
      {:ok, pid} = Proc.start("cat", [], pty: true)

      assert {:error, :invalid_window_size} = Proc.set_window_size(pid, -1, 80)
      assert {:error, :invalid_window_size} = Proc.set_window_size(pid, 24, 70_000)
      assert {:error, :invalid_window_size} = Proc.set_window_size(pid, :rows, 80)

      assert :ok = Proc.set_window_size(pid, 24, 80)

      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
    end
  end

  describe ":stderr_tail_bytes cap (SEC-11)" do
    test "rejects a tail above 1 MiB" do
      assert_raise ArgumentError, ~r/1048576/, fn ->
        Proc.start("echo", ["x"], stderr_tail_bytes: 1_048_577)
      end

      # The maximum itself is accepted.
      {:ok, pid} = Proc.start("echo", ["x"], stderr_tail_bytes: 1_048_576)
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe ":kill_timeout validation" do
    test "rejects values the shepherd would refuse, in the caller" do
      # Out-of-range or non-integer values make the shepherd exit before
      # connecting, with the reason only on the VM's stderr.
      for bad <- [0, 60_001, 5000.0, "5000", nil] do
        assert_raise ArgumentError, ~r/:kill_timeout/, fn ->
          Proc.start("echo", ["x"], kill_timeout: bad)
        end
      end

      {:ok, pid} = Proc.start("echo", ["x"], kill_timeout: 60_000)
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe "shepherd argv terminator" do
    test "a command whose name starts with '-' is never parsed as a shepherd flag" do
      # Before the "--" terminator, cmd: "--kill-timeout" consumed the next
      # argv entry as a shepherd option and exec'd whatever followed. Now the
      # shepherd must try to exec the literal flag name and fail (127).
      for {flag, rest} <- [
            {"--kill-timeout", ["1"]},
            {"--cwd", ["/"]},
            {"--replace-env", ["0"]},
            {"--cgroup-path", ["net_runner/x"]},
            {"--pty", []},
            {"--token-fd", []},
            {"--", []}
          ] do
        assert {"", 127, stderr} =
                 NetRunner.run([flag | rest] ++ ["sh", "-c", "echo pwned"], stderr: :capture)

        assert stderr =~ flag
        refute stderr =~ "pwned"
      end
    end
  end

  describe "shepherd token read" do
    # The BEAM unlinks the port for the token write, so a spawner that dies
    # before writing does not necessarily close fd 3. The shepherd must not
    # wait for the token forever.
    test "a shepherd that never receives its token gives up" do
      port = open_tokenless_shepherd()
      assert_receive {^port, {:exit_status, 1}}, 15_000
    end

    test "a shepherd whose token channel closes early exits promptly" do
      port = open_tokenless_shepherd()
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      true = Port.command(port, "00000")
      Port.close(port)

      eventually(fn -> not os_pid_alive?(os_pid) end, 3_000)
    end
  end

  describe "UDS base directory (SEC-5)" do
    test "lives in a 0700 directory owned by us" do
      # Force at least one spawn so the base dir exists.
      assert {"x\n", 0} = NetRunner.run(~w(echo x))

      {dir, uid} = :persistent_term.get({NetRunner.Process.Exec, :uds_base_dir})
      assert %File.Stat{type: :directory, mode: mode, uid: ^uid} = File.lstat!(dir)
      assert band(mode, 0o7777) == 0o700
    end
  end

  defp open_tokenless_shepherd do
    shepherd = Path.join(to_string(:code.priv_dir(:net_runner)), "shepherd")
    socket_path = Path.join(System.tmp_dir!(), "nr_unused_#{System.unique_integer([:positive])}")

    Port.open(
      {:spawn_executable, shepherd},
      [:nouse_stdio, :exit_status, :binary, args: [socket_path, "--token-fd", "--", "/bin/true"]]
    )
  end
end
