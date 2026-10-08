defmodule NetRunner.Process.ProtocolTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process.Protocol

  # The encoders are the single Elixir-side source of truth for the
  # BEAM -> shepherd frames in c_src/protocol.h. Pin the byte layout so a
  # drifted opcode or field width fails here, not as a silently ignored
  # command in the shepherd's event loop.
  describe "command encoders match c_src/protocol.h" do
    test "CMD_KILL is opcode 0x01 followed by one signal byte" do
      assert Protocol.kill(15) == <<0x01, 15>>
      assert Protocol.kill(9) == <<0x01, 9>>
      assert Protocol.kill(255) == <<0x01, 255>>
    end

    test "CMD_KILL refuses signals that would not survive the 8-bit field" do
      assert_raise FunctionClauseError, fn -> Protocol.kill(256) end
      assert_raise FunctionClauseError, fn -> Protocol.kill(0) end
      assert_raise FunctionClauseError, fn -> Protocol.kill(-1) end
    end

    test "CMD_CLOSE_STDIN is the bare opcode 0x02" do
      assert Protocol.close_stdin() == <<0x02>>
    end

    test "CMD_SET_WINSIZE is opcode 0x03 with big-endian 16-bit rows then cols" do
      assert Protocol.set_winsize(40, 120) == <<0x03, 0, 40, 0, 120>>
      assert Protocol.set_winsize(65_535, 0) == <<0x03, 0xFF, 0xFF, 0, 0>>
      assert_raise FunctionClauseError, fn -> Protocol.set_winsize(-1, 80) end
      assert_raise FunctionClauseError, fn -> Protocol.set_winsize(24, 65_536) end
    end
  end
end
