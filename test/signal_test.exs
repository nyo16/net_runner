defmodule NetRunner.SignalTest do
  use ExUnit.Case, async: true

  alias NetRunner.Signal

  describe "resolve/1" do
    test "resolves known signal atoms via the NIF" do
      assert {:ok, num} = Signal.resolve(:sigterm)
      assert is_integer(num) and num > 0
    end

    test "passes through valid integers in the POSIX 1..31 range" do
      assert {:ok, 9} = Signal.resolve(9)
      assert {:ok, 15} = Signal.resolve(15)
    end

    test "rejects integers outside 1..31" do
      assert {:error, :unknown_signal} = Signal.resolve(0)
      assert {:error, :unknown_signal} = Signal.resolve(-1)
      assert {:error, :unknown_signal} = Signal.resolve(32)
      assert {:error, :unknown_signal} = Signal.resolve(9999)
    end

    test "rejects unknown atoms" do
      assert {:error, :unknown_signal} = Signal.resolve(:siggibberish)
    end

    test "rejects non-atom, non-integer values" do
      assert {:error, :unknown_signal} = Signal.resolve("sigterm")
      assert {:error, :unknown_signal} = Signal.resolve(nil)
      assert {:error, :unknown_signal} = Signal.resolve([])
    end
  end

  describe "resolve!/1" do
    test "returns the number for valid signals" do
      assert is_integer(Signal.resolve!(:sigkill))
    end

    test "raises for invalid signals" do
      assert_raise ArgumentError, fn -> Signal.resolve!(:bogus) end
      assert_raise ArgumentError, fn -> Signal.resolve!(99) end
    end
  end
end
