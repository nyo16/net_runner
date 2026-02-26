defmodule NetRunner.CgroupTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process, as: Proc

  describe "cgroup support" do
    @tag :linux_only
    test "cgroup_path option is passed to shepherd" do
      # On macOS this is a no-op — shepherd ignores --cgroup-path on non-Linux.
      # On Linux with cgroup v2, the child would be moved into the cgroup.
      {:ok, pid} =
        Proc.start("echo", ["hello"], cgroup_path: "net_runner/test_#{:rand.uniform(10000)}")

      {:ok, data} = Proc.read(pid)
      assert data =~ "hello"
      {:ok, status} = Proc.await_exit(pid)
      assert status == 0
    end

    test "cgroup_path nil (default) works normally" do
      {:ok, pid} = Proc.start("echo", ["no cgroup"])
      {:ok, data} = Proc.read(pid)
      assert data =~ "no cgroup"
      {:ok, 0} = Proc.await_exit(pid)
    end
  end
end
