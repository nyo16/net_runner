defmodule NetRunner.LeakTest do
  use ExUnit.Case, async: false

  alias NetRunner.Process, as: Proc

  describe "FD leak prevention" do
    # Runs on Linux via /proc/self/fd and on macOS via lsof -p.
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

  describe "GenServer lifecycle" do
    # Neither entry point hands the Process pid to the caller, so nothing else
    # can ever stop it. Before Proc.stop/1 was wired into run_with_pid/4 and
    # the stream after-fun, every call leaked a Process GenServer, a Watcher,
    # a UDS socket and three pipe FDs until the *caller* died — unbounded for
    # a long-lived caller such as a GenServer or LiveView.
    test "run/2 does not leak processes" do
      baseline = length(Process.list())

      for _ <- 1..20, do: assert({"hi\n", 0} = NetRunner.run(~w(echo hi)))

      assert settled_process_count(baseline)
    end

    test "a fully consumed stream does not leak processes" do
      baseline = length(Process.list())

      for _ <- 1..20 do
        assert ["hi\n"] == NetRunner.stream!(~w(echo hi)) |> Enum.to_list()
      end

      assert settled_process_count(baseline)
    end

    test "a stream halted early does not leak processes" do
      baseline = length(Process.list())

      for _ <- 1..20 do
        assert [_] = NetRunner.stream!(["sh", "-c", "yes"]) |> Enum.take(1)
      end

      assert settled_process_count(baseline)
    end
  end

  # Teardown is asynchronous (shepherd reap, Watcher stop), so poll rather
  # than sample once.
  defp settled_process_count(baseline, attempts \\ 100) do
    now = length(Process.list())

    cond do
      now <= baseline -> true
      attempts == 0 -> flunk("leaked #{now - baseline} processes")
      true -> Process.sleep(20) && settled_process_count(baseline, attempts - 1)
    end
  end

  # Counts this BEAM's open FDs: /proc/self/fd on Linux, lsof -p on macOS
  # (which has no procfs).
  defp count_open_fds do
    case File.ls("/proc/self/fd") do
      {:ok, entries} ->
        length(entries)

      {:error, _} ->
        {out, _status} = System.cmd("lsof", ["-p", System.pid()], stderr_to_stdout: true)
        out |> String.split("\n", trim: true) |> length()
    end
  end
end
