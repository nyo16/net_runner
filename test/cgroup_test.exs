defmodule NetRunner.CgroupTest do
  use ExUnit.Case, async: true

  alias NetRunner.Process, as: Proc

  describe "cgroup support" do
    @tag :linux_only
    test "cgroup_path option is plumbed through to the shepherd" do
      # On Linux, spawning with a cgroup_path requires write access under
      # /sys/fs/cgroup/. In a privileged environment (CI delegates
      # /sys/fs/cgroup/net_runner) the child is moved into the cgroup and runs
      # to completion; unprivileged, the shepherd fails the spawn closed with
      # its MSG_ERROR diagnostic — which still proves the option was seen and
      # acted on by the C side.
      path = "net_runner/test_#{:rand.uniform(1_000_000)}"

      case Proc.start("echo", ["hello"], cgroup_path: path) do
        {:ok, pid} ->
          # Privileged run — child moved into cgroup successfully.
          {:ok, data} = Proc.read(pid)
          assert data =~ "hello"
          assert {:ok, 0} = Proc.await_exit(pid)

        {:error, reason} ->
          # Fail-closed contract: a cgroup the caller asked for but cannot
          # have must fail the spawn with the shepherd's diagnostic, never
          # degrade silently. Visible marker so a CI leg where the positive
          # path silently stopped executing can be spotted in the log.
          assert match?({:shepherd_error, _}, reason),
                 "expected a shepherd MSG_ERROR, got: #{inspect(reason)}"

          IO.puts("[degraded] cgroup plumbing test ran fail-closed path: #{inspect(reason)}")
      end
    end

    @tag :linux_only
    test "a pre-existing cgroup leaf dir fails the spawn closed and survives (ownership guard)" do
      # SEC-1: the shepherd only cgroup.kill/rmdir a directory it created
      # itself, so a pre-existing leaf is fatal — adopting it would mean a
      # teardown it does not own, and silently degrading containment the
      # caller explicitly requested is worse than failing the spawn.
      path = "net_runner/preexisting_#{:rand.uniform(1_000_000)}"
      full = "/sys/fs/cgroup/#{path}"

      case File.mkdir_p(full) do
        :ok ->
          on_exit(fn -> File.rmdir(full) end)

          # mkdir(2) reports EEXIST regardless of privileges once the leaf is
          # there, so with the dir created above this branch asserts hard.
          assert {:error, {:shepherd_error, msg}} =
                   Proc.start("echo", ["hello"], cgroup_path: path)

          assert msg =~ "already exists"
          assert File.dir?(full), "shepherd removed a cgroup dir it did not create"

        {:error, reason} ->
          # No cgroup v2 write access at all in this environment; the
          # validation plumbing is covered by the test above.
          IO.puts("[degraded] cgroup fail-closed test skipped: mkdir #{full}: #{inspect(reason)}")
      end
    end

    test "cgroup_path nil (default) works normally" do
      {:ok, pid} = Proc.start("echo", ["no cgroup"])
      {:ok, data} = Proc.read(pid)
      assert data =~ "no cgroup"
      {:ok, 0} = Proc.await_exit(pid)
    end

    test "rejects invalid cgroup paths (traversal / absolute)" do
      assert_raise ArgumentError, ~r/must be relative/, fn ->
        Proc.start("echo", ["x"], cgroup_path: "/absolute/nope")
      end

      assert_raise ArgumentError, ~r/cannot contain '\.\.'/, fn ->
        Proc.start("echo", ["x"], cgroup_path: "net_runner/some/../evil")
      end
    end

    test "rejects cgroup paths outside the net_runner/ prefix" do
      assert_raise ArgumentError, ~r/net_runner\//, fn ->
        Proc.start("echo", ["x"], cgroup_path: "system.slice/evil")
      end

      assert_raise ArgumentError, ~r/net_runner\//, fn ->
        Proc.start("echo", ["x"], cgroup_path: "net_runner/")
      end
    end

    test "rejects over-length cgroup paths instead of truncating" do
      # SEC-2: a silently truncated path would attach (and later kill) a
      # different cgroup than the one that was validated.
      long = "net_runner/" <> String.duplicate("a", 300)

      assert_raise ArgumentError, ~r/256/, fn ->
        Proc.start("echo", ["x"], cgroup_path: long)
      end
    end
  end
end
