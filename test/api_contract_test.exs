defmodule NetRunner.ApiContractTest do
  use ExUnit.Case, async: true

  alias NetRunner.Daemon
  alias NetRunner.Process, as: Proc

  describe "Daemon option contract (A-3)" do
    test "a missing :cmd raises in the caller, not inside init/1" do
      assert_raise ArgumentError, ~r/requires :cmd/, fn -> Daemon.start_link(args: ["1"]) end

      assert_raise ArgumentError, ~r/:cmd must be a binary/, fn ->
        Daemon.start_link(cmd: 'sleep')
      end
    end

    test "an invalid :on_output raises once instead of failing on every chunk" do
      for bad <- ["log", :stdout, fn _a, _b -> :ok end] do
        assert_raise ArgumentError, ~r/:on_output must be/, fn ->
          Daemon.start_link(cmd: "true", on_output: bad)
        end
      end
    end

    test "on_output: nil means the default (:discard)" do
      Process.flag(:trap_exit, true)
      {:ok, daemon} = Daemon.start_link(cmd: "sh", args: ["-c", "echo hi"], on_output: nil)
      assert_receive {:EXIT, ^daemon, {:shutdown, {:exit_status, 0}}}, 5_000
    end
  end

  describe "Daemon.write/2 (N-7)" do
    test "accepts iodata like Process.write/2" do
      parent = self()
      {:ok, daemon} = Daemon.start_link(cmd: "cat", on_output: &send(parent, {:out, &1}))

      assert :ok = Daemon.write(daemon, ["he", [?l, "lo"], "\n"])
      assert_receive {:out, "hello\n"}, 2_000
      GenServer.stop(daemon)
    end
  end

  describe "PTY contracts (A-4)" do
    test "set_window_size/3 on a pipe-mode process is an error, not a silent :ok" do
      {:ok, pid} = Proc.start("sleep", ["100"])
      on_exit(fn -> Proc.stop(pid) end)
      assert {:error, :not_pty} = Proc.set_window_size(pid, 40, 120)
    end

    test "run/2 rejects :input with pty: true (a PTY has no stdin EOF)" do
      assert_raise ArgumentError, ~r/:input is not supported with pty: true/, fn ->
        NetRunner.run(["cat"], pty: true, input: "x")
      end

      # Without :input a PTY run is fine.
      assert {out, 0} = NetRunner.run(["echo", "hi"], pty: true)
      assert out =~ "hi"
    end

    # Linux reports a hung-up PTY slave as EIO on the master; callers must see
    # the same :eof as in pipe mode.
    test "the end of PTY output is :eof, not {:error, :eio}" do
      {:ok, pid} = Proc.start("sh", ["-c", "echo done"], pty: true)
      on_exit(fn -> Proc.stop(pid) end)
      # Read first: a BSD tty close drains unread output, so the child cannot
      # finish exiting until the master is read.
      assert read_to_end(pid, "") =~ "done"
      assert {:ok, 0} = Proc.await_exit(pid, 5_000)
    end
  end

  defp read_to_end(pid, acc) do
    case Proc.read(pid) do
      {:ok, data} -> read_to_end(pid, acc <> data)
      :eof -> acc
      other -> flunk("expected :eof at the end of PTY output, got #{inspect(other)}")
    end
  end
end
