defmodule NetRunner.SecurityTest do
  use ExUnit.Case, async: true

  import Bitwise

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
    test "sets a variable for the child" do
      assert {"bar\n", 0} =
               NetRunner.run(["sh", "-c", "echo $NR_ENV_SET"], env: %{"NR_ENV_SET" => "bar"})
    end

    test "nil unsets an inherited variable" do
      System.put_env("NR_ENV_UNSET_ME", "inherited")
      on_exit(fn -> System.delete_env("NR_ENV_UNSET_ME") end)

      # Default: the child inherits the BEAM's environment.
      assert {"inherited\n", 0} = NetRunner.run(["sh", "-c", "echo $NR_ENV_UNSET_ME"])

      # nil value: explicitly unset for this spawn only.
      assert {"\n", 0} =
               NetRunner.run(["sh", "-c", "echo $NR_ENV_UNSET_ME"],
                 env: %{"NR_ENV_UNSET_ME" => nil}
               )

      # And the unset did not leak back into the BEAM's own environment.
      assert System.get_env("NR_ENV_UNSET_ME") == "inherited"
    end

    test "rejects malformed env maps" do
      assert_raise ArgumentError, ~r/:env/, fn ->
        Proc.start("echo", ["x"], env: %{"A=B" => "x"})
      end

      assert_raise ArgumentError, ~r/:env/, fn ->
        Proc.start("echo", ["x"], env: %{"" => "x"})
      end

      assert_raise ArgumentError, ~r/:env/, fn ->
        Proc.start("echo", ["x"], env: %{"OK" => "a\0b"})
      end

      assert_raise ArgumentError, ~r/:env/, fn ->
        Proc.start("echo", ["x"], env: [{"OK", "x"}])
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

  describe "UDS base directory (SEC-5)" do
    test "lives in a 0700 directory owned by us" do
      # Force at least one spawn so the base dir exists.
      assert {"x\n", 0} = NetRunner.run(~w(echo x))

      {dir, uid} = :persistent_term.get({NetRunner.Process.Exec, :uds_base_dir})
      assert %File.Stat{type: :directory, mode: mode, uid: ^uid} = File.lstat!(dir)
      assert band(mode, 0o7777) == 0o700
    end
  end
end
