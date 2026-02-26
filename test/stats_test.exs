defmodule NetRunner.StatsTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process, as: Proc
  alias NetRunner.Process.Stats

  describe "Stats tracking" do
    test "tracks bytes written and read" do
      {:ok, pid} = Proc.start("cat", [])
      :ok = Proc.write(pid, "hello world")
      Proc.close_stdin(pid)

      {:ok, data} = Proc.read(pid)
      assert data == "hello world"

      {:ok, _status} = Proc.await_exit(pid)
      stats = Proc.stats(pid)

      assert %Stats{} = stats
      assert stats.bytes_in == 11
      assert stats.bytes_out == 11
      assert stats.write_count >= 1
      assert stats.read_count >= 1
    end

    test "tracks exit status and duration" do
      {:ok, pid} = Proc.start("true", [])
      {:ok, 0} = Proc.await_exit(pid)
      stats = Proc.stats(pid)

      assert stats.exit_status == 0
      assert is_integer(stats.duration_ms)
      assert stats.duration_ms >= 0
    end

    test "started_at is set on creation" do
      {:ok, pid} = Proc.start("echo", ["hi"])
      stats = Proc.stats(pid)
      assert is_integer(stats.started_at)
      Proc.await_exit(pid)
    end

    test "Stats.new/0 initializes correctly" do
      stats = Stats.new()
      assert stats.bytes_in == 0
      assert stats.bytes_out == 0
      assert stats.bytes_err == 0
      assert stats.read_count == 0
      assert stats.write_count == 0
      assert stats.exit_status == nil
      assert stats.duration_ms == nil
      assert is_integer(stats.started_at)
    end

    test "Stats.record_read/2 increments correctly" do
      stats = Stats.new() |> Stats.record_read(100) |> Stats.record_read(200)
      assert stats.bytes_out == 300
      assert stats.read_count == 2
    end

    test "Stats.record_write/2 increments correctly" do
      stats = Stats.new() |> Stats.record_write(50) |> Stats.record_write(75)
      assert stats.bytes_in == 125
      assert stats.write_count == 2
    end

    test "Stats.finalize/2 sets exit status and duration" do
      stats = Stats.new()
      Process.sleep(10)
      final = Stats.finalize(stats, 0)
      assert final.exit_status == 0
      assert final.duration_ms >= 10
    end
  end
end
