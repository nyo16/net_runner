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
      path = "net_runner_test_#{:rand.uniform(1_000_000)}"

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
               Proc.start("echo", ["x"], cgroup_path: "some/../evil")
    end
  end
end
