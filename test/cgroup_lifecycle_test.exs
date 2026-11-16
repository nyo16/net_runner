defmodule NetRunner.CgroupLifecycleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import NetRunner.TestHelpers

  alias NetRunner.Process, as: Proc

  @root "/sys/fs/cgroup/"

  defp leaf(prefix) do
    path = "net_runner/#{prefix}_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = File.rmdir(@root <> path <> "/b")
      _ = File.rmdir(@root <> path)
    end)

    path
  end

  describe "isolation options off Linux (S-05)" do
    @tag :non_linux
    test "cgroup_path and no_new_privs: true raise instead of running unconfined" do
      assert_raise ArgumentError, ~r/:cgroup_path requires Linux/, fn ->
        Proc.start("echo", ["x"], cgroup_path: "net_runner/x")
      end

      assert_raise ArgumentError, ~r/:cgroup_path requires Linux/, fn ->
        NetRunner.run(["echo", "x"], cgroup_path: "net_runner/x")
      end

      assert_raise ArgumentError, ~r/no_new_privs: true requires Linux/, fn ->
        NetRunner.run(["echo", "x"], no_new_privs: true)
      end

      assert_raise ArgumentError, ~r/no_new_privs: true requires Linux/, fn ->
        NetRunner.Daemon.start_link(cmd: "sleep", args: ["1"], process_opts: [no_new_privs: true])
      end

      # Shape errors still win, so they read the same on every platform.
      assert_raise ArgumentError, ~r/cannot contain '\.\.'/, fn ->
        Proc.start("echo", ["x"], cgroup_path: "net_runner/a/../b")
      end

      # Not asking for isolation is fine everywhere.
      assert {"x\n", 0} = NetRunner.run(["echo", "x"], no_new_privs: false)
    end
  end

  describe "shepherd death with a cgroup (S-06)" do
    @tag :linux_only
    test "the BEAM removes the orphaned leaf, so the path can be reused" do
      path = leaf("orphan")

      case Proc.start("sleep", ["100"], cgroup_path: path) do
        {:ok, pid} ->
          os_pid = Proc.os_pid(pid)

          capture_log(fn ->
            System.cmd("kill", ["-KILL", to_string(parent_pid!(os_pid))])
            assert {:ok, 137} = Proc.await_exit(pid, 5_000)
          end)

          refute File.exists?(@root <> path), "orphaned leaf was left behind"
          assert {"again\n", 0} = NetRunner.run(["echo", "again"], cgroup_path: path)
          Proc.stop(pid)

        {:error, reason} ->
          assert match?({:shepherd_error, _}, reason)
          degraded("S-06 cgroup test ran the fail-closed path: #{inspect(reason)}")
      end
    end
  end

  describe "nested cgroup_path (S-14)" do
    @tag :linux_only
    test "a path under another spawn's live leaf is refused; that spawn is unaffected" do
      outer = leaf("nest")

      case Proc.start("sleep", ["100"], cgroup_path: outer) do
        {:ok, pid} ->
          assert {:error, {:shepherd_error, msg}} =
                   Proc.start("echo", ["x"], cgroup_path: outer <> "/b")

          assert msg =~ "has live processes"
          refute File.exists?(@root <> outer <> "/b")
          assert Proc.alive?(pid)
          # The exit frame follows the shepherd's cgroup cleanup, so on_exit's
          # rmdir cannot race it.
          :ok = Proc.kill(pid, :sigkill)
          assert {:ok, 137} = Proc.await_exit(pid, 5_000)
          refute File.exists?(@root <> outer)
          Proc.stop(pid)

        {:error, reason} ->
          assert match?({:shepherd_error, _}, reason)
          degraded("S-14 cgroup test ran the fail-closed path: #{inspect(reason)}")
      end
    end
  end

  describe "orphaned-leaf cleanup identity (S-17)" do
    alias NetRunner.Process.Cgroup

    # Cleanup after a shepherd crash must only touch the leaf this spawn
    # created. A path that was removed and re-created (by another spawn) has
    # a new inode and is left alone; a path already gone is fine.
    @tag :linux_only
    test "removes only the recorded leaf, never a re-created one" do
      path = leaf("inode")
      full = @root <> path

      case File.mkdir_p(full) do
        :ok ->
          recorded = Cgroup.identify(path)
          assert {^path, _inode} = recorded

          :ok = File.rmdir(full)
          assert :ok = Cgroup.remove_orphaned_leaf(recorded)

          :ok = File.mkdir(full)
          assert :not_ours = Cgroup.remove_orphaned_leaf(recorded)
          assert File.dir?(full), "a re-created leaf was removed"

          assert :ok = Cgroup.remove_orphaned_leaf(Cgroup.identify(path))
          refute File.exists?(full)

        {:error, reason} ->
          degraded("S-17 cgroup test skipped: mkdir #{full}: #{inspect(reason)}")
      end
    end
  end
end
