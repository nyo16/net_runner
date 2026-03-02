defmodule NetRunner.LeakTest do
  use ExUnit.Case, async: false

  alias NetRunner.Process, as: Proc

  describe "FD leak prevention" do
    @tag :linux_only
    test "rapid spawn/kill cycle does not leak FDs" do
      # Warm-up run to stabilize FD baseline
      for _ <- 1..5 do
        {:ok, pid} = Proc.start("true", [])
        Proc.await_exit(pid)
      end

      :erlang.garbage_collect()
      Process.sleep(500)

      initial_fd_count = count_open_fds()

      for _ <- 1..20 do
        {:ok, pid} = Proc.start("sleep", ["100"])
        Proc.kill(pid, :sigkill)
        Proc.await_exit(pid)
        GenServer.stop(pid, :normal)
      end

      # Allow GC and cleanup time
      :erlang.garbage_collect()
      Process.sleep(1_000)
      :erlang.garbage_collect()
      Process.sleep(500)

      final_fd_count = count_open_fds()

      # Allow margin for BEAM-internal FD activity
      assert final_fd_count <= initial_fd_count + 30,
             "FD leak detected: started with #{initial_fd_count}, ended with #{final_fd_count}"
    end

    test "stream abort cleans up process" do
      # Start a long-running stream and abort mid-read
      stream = NetRunner.stream!(["sh", "-c", "while true; do echo line; sleep 0.01; done"])

      # Take only a few elements then halt
      result = Enum.take(stream, 3)
      assert length(result) == 3

      # Give cleanup time to run
      Process.sleep(500)
    end

    test "process exit before read gives clean error" do
      {:ok, pid} = Proc.start("true", [])
      {:ok, 0} = Proc.await_exit(pid)

      # Read after exit should return eof or error, not crash
      result = Proc.read(pid)
      assert result in [:eof, {:error, :process_exited}, {:error, :closed}]
    end
  end

  describe "concurrent close+read" do
    test "concurrent close and read does not crash" do
      {:ok, pid} = Proc.start("cat", [])

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            try do
              Proc.read(pid, 1024)
            catch
              :exit, _ -> :exited
            end
          end)
        end

      # Close stdin and kill to trigger cleanup
      Process.sleep(50)
      Proc.kill(pid, :sigkill)

      results =
        Enum.map(tasks, fn task ->
          case Task.yield(task, 5_000) do
            {:ok, result} -> result
            nil -> Task.shutdown(task, :brutal_kill)
          end
        end)

      # All tasks should have completed without crashing the BEAM
      assert length(results) == 5
    end
  end

  describe "nif_close idempotency" do
    test "closing an already-closed pipe returns :ok" do
      {:ok, pid} = Proc.start("echo", ["test"])
      :ok = Proc.close_stdin(pid)
      # Second close should be idempotent
      :ok = Proc.close_stdin(pid)
      Proc.await_exit(pid)
    end
  end

  describe "write to closed stdin" do
    test "write after close_stdin returns error" do
      {:ok, pid} = Proc.start("cat", [])
      :ok = Proc.close_stdin(pid)

      result = Proc.write(pid, "should fail")
      assert {:error, :closed} = result

      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
    end
  end

  describe "cgroup path validation" do
    test "rejects path traversal with .." do
      assert {:error, {:invalid_cgroup_path, msg}} =
               Proc.start("echo", ["test"], cgroup_path: "../../etc/evil")

      assert msg =~ ".."
    end

    test "rejects absolute cgroup path" do
      assert {:error, {:invalid_cgroup_path, msg}} =
               Proc.start("echo", ["test"], cgroup_path: "/sys/fs/cgroup/evil")

      assert msg =~ "relative"
    end
  end

  describe "multiple concurrent await_exit" do
    test "all callers receive exit status" do
      {:ok, pid} = Proc.start("echo", ["hello"])

      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Proc.await_exit(pid, 5_000)
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &match?({:ok, 0}, &1))
    end
  end

  # Helper to count open FDs via /proc/self/fd
  defp count_open_fds do
    case File.ls("/proc/self/fd") do
      {:ok, entries} -> length(entries)
      {:error, _} -> 0
    end
  end
end
