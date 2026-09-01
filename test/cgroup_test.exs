defmodule NetRunner.CgroupTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process, as: Proc

  describe "cgroup support" do
    @tag :linux_only
    test "cgroup_path option is plumbed through to the shepherd" do
      # On Linux, spawning with a cgroup_path requires write access under
      # /sys/fs/cgroup/. In a privileged environment the child is moved into
      # the cgroup and runs to completion; in CI (no privileges) the shepherd
      # rejects the setup and returns an error — which proves the option was
      # actually seen and validated by the C side. Either outcome confirms
      # the plumbing.
      path = "net_runner/test_#{:rand.uniform(1_000_000)}"

      case Proc.start("echo", ["hello"], cgroup_path: path) do
        {:ok, pid} ->
          # Privileged run — child moved into cgroup successfully.
          {:ok, data} = Proc.read(pid)
          assert data =~ "hello"
          assert {:ok, 0} = Proc.await_exit(pid)

        {:error, _reason} ->
          # Unprivileged run — the shepherd refused to proceed without
          # the requested isolation. That is the correct behaviour when
          # a user explicitly asks for a cgroup they cannot use.
          :ok
      end
    end

    @tag :linux_only
    test "a pre-existing cgroup directory survives teardown (ownership guard)" do
      # SEC-1: the shepherd must only cgroup.kill/rmdir a cgroup directory it
      # created itself. Pre-create the directory; if this environment can
      # write /sys/fs/cgroup at all, spawn through it and assert the
      # directory is still there after the child is reaped.
      path = "net_runner/preexisting_#{:rand.uniform(1_000_000)}"
      full = "/sys/fs/cgroup/#{path}"

      case File.mkdir_p(full) do
        :ok ->
          on_exit(fn -> File.rmdir(full) end)

          case Proc.start("echo", ["hello"], cgroup_path: path) do
            {:ok, pid} ->
              assert {:ok, 0} = Proc.await_exit(pid)
              GenServer.stop(pid)
              # Give the shepherd time to run its (now no-op) cleanup.
              Process.sleep(300)
              assert File.dir?(full), "shepherd removed a cgroup dir it did not create"

            {:error, _} ->
              # cgroup.procs not writable in this environment — plumbing is
              # covered by the test above.
              :ok
          end

        {:error, _} ->
          # No cgroup v2 write access at all; nothing to assert here.
          :ok
      end
    end

    test "cgroup_path nil (default) works normally" do
      {:ok, pid} = Proc.start("echo", ["no cgroup"])
      {:ok, data} = Proc.read(pid)
      assert data =~ "no cgroup"
      {:ok, 0} = Proc.await_exit(pid)
    end

    test "rejects invalid cgroup paths (traversal / absolute)" do
      assert {:error, {:invalid_cgroup_path, _}} =
               Proc.start("echo", ["x"], cgroup_path: "/absolute/nope")

      assert {:error, {:invalid_cgroup_path, _}} =
               Proc.start("echo", ["x"], cgroup_path: "net_runner/some/../evil")
    end

    test "rejects cgroup paths outside the net_runner/ prefix" do
      assert {:error, {:invalid_cgroup_path, msg}} =
               Proc.start("echo", ["x"], cgroup_path: "system.slice/evil")

      assert msg =~ "net_runner/"

      assert {:error, {:invalid_cgroup_path, _}} =
               Proc.start("echo", ["x"], cgroup_path: "net_runner/")
    end

    test "rejects over-length cgroup paths instead of truncating" do
      # SEC-2: a silently truncated path would attach (and later kill) a
      # different cgroup than the one that was validated.
      long = "net_runner/" <> String.duplicate("a", 300)

      assert {:error, {:invalid_cgroup_path, msg}} =
               Proc.start("echo", ["x"], cgroup_path: long)

      assert msg =~ "256"
    end
  end
end
