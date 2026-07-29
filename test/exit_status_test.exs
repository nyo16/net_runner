defmodule NetRunner.ExitStatusTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process, as: Proc
  alias NetRunner.Process.Exec

  # The shepherd writes three separate segments into a SOCK_STREAM: the 1-byte
  # SCM_RIGHTS filler, MSG_CHILD_STARTED, and later MSG_CHILD_EXITED. A child
  # that exits before the BEAM's recvmsg gets all three coalesced into one
  # read, so the exit status arrives *inside* the spawn handshake. Dropping
  # that tail used to strand every fast command on the 5 s force-exit timeout
  # and report a synthetic 137 instead of the real status.
  describe "fast-exiting children (coalesced MSG_CHILD_EXITED)" do
    test "reports the real exit status, not a synthetic 137" do
      assert {"hi\n", 0} = NetRunner.run(["/bin/echo", "hi"])
    end

    test "preserves a non-zero status" do
      assert {"", 3} = NetRunner.run(["/bin/sh", "-c", "exit 3"])
    end

    test "does not wait for the force-exit backstop" do
      # The backstop is 5 s. Anything near it means the status came from the
      # timeout rather than from the shepherd.
      {us, {"hi\n", 0}} = :timer.tc(fn -> NetRunner.run(["/bin/echo", "hi"]) end)
      assert us < 1_000_000
    end

    test "a slow child still reports correctly" do
      assert {"hi\n", 0} = NetRunner.run(["/bin/sh", "-c", "sleep 0.2; echo hi"])
      assert {"", 3} = NetRunner.run(["/bin/sh", "-c", "sleep 0.2; exit 3"])
    end

    test "output is complete even though the child already exited" do
      payload = String.duplicate("x", 40_000)
      assert {^payload, 0} = NetRunner.run(["/bin/sh", "-c", "printf %s #{payload}"])
    end
  end

  # Unit-level guard on the framing itself: these are the shapes a stream
  # socket can hand us, and every one of them has to be handled without
  # losing bytes.
  describe "parse_uds_message/1" do
    @started 0x80
    @exited 0x81
    @error 0x82

    test "parses a lone MSG_CHILD_EXITED" do
      assert {:ok, {:child_exited, 7}, <<>>} =
               Exec.parse_uds_message(<<@exited, 7::big-unsigned-32>>)
    end

    test "parses MSG_CHILD_EXITED coalesced behind MSG_CHILD_STARTED" do
      buffer = <<@started, 4242::big-unsigned-32, @exited, 0::big-unsigned-32>>
      assert {:ok, {:child_exited, 0}, <<>>} = Exec.parse_uds_message(buffer)
    end

    test "returns the unconsumed remainder so a second frame is not lost" do
      buffer = <<@exited, 1::big-unsigned-32, @exited, 2::big-unsigned-32>>
      assert {:ok, {:child_exited, 1}, rest} = Exec.parse_uds_message(buffer)
      assert {:ok, {:child_exited, 2}, <<>>} = Exec.parse_uds_message(rest)
    end

    test "parses a length-prefixed MSG_ERROR" do
      assert {:ok, {:shepherd_error, "boom"}, <<>>} =
               Exec.parse_uds_message(<<@error, 4::big-unsigned-16, "boom">>)
    end

    test "reports :incomplete for a truncated frame instead of consuming it" do
      assert :incomplete = Exec.parse_uds_message(<<>>)
      assert :incomplete = Exec.parse_uds_message(<<@exited>>)
      assert :incomplete = Exec.parse_uds_message(<<@exited, 0, 0>>)
      assert :incomplete = Exec.parse_uds_message(<<@error, 4::big-unsigned-16, "bo">>)
      assert :incomplete = Exec.parse_uds_message(<<@started, 0, 0>>)
    end

    test "rejects an unknown opcode rather than stalling" do
      assert {:error, {:unknown_message, 0x42}} = Exec.parse_uds_message(<<0x42, 0, 0>>)
    end
  end

  describe "set_owner/2" do
    test "replaces the previous owner monitor instead of stacking on it" do
      first = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, pid} = Proc.start("/bin/sh", ["-c", "sleep 5"], owner: first)

      # Hand ownership to a second process, then kill the original owner. The
      # OS process must survive: only the *current* owner's death tears it down.
      second = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Proc.set_owner(pid, second)

      Process.exit(first, :kill)
      Process.sleep(150)
      assert Process.alive?(pid)
      assert Proc.alive?(pid)

      # The new owner dying does stop it.
      ref = Process.monitor(pid)
      Process.exit(second, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end
  end
end
