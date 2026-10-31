defmodule NetRunner.CgroupTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

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
          # degrade silently.
          assert match?({:shepherd_error, _}, reason),
                 "expected a shepherd MSG_ERROR, got: #{inspect(reason)}"

          degraded("cgroup plumbing test ran the fail-closed path: #{inspect(reason)}")
      end
    end

    @tag :linux_only
    test "creates missing ancestor cgroups and tears down only the leaf (issue #24)" do
      # CI delegates a pre-created net_runner/ (the hosted runner's cgroup
      # root is not writable even after chown), so a fresh intermediate
      # parent stands in for a fresh hierarchy: same ancestor-creation path.
      parent = "net_runner/parent_#{:rand.uniform(1_000_000)}"
      path = parent <> "/leaf"
      on_exit(fn -> File.rmdir("/sys/fs/cgroup/#{parent}") end)

      case Proc.start("echo", ["hello"], cgroup_path: path) do
        {:ok, pid} ->
          {:ok, data} = Proc.read(pid)
          assert data =~ "hello"
          assert {:ok, 0} = Proc.await_exit(pid)

          eventually(fn -> not File.exists?("/sys/fs/cgroup/#{path}") end)
          assert File.dir?("/sys/fs/cgroup/#{parent}"), "shared ancestor was removed"

        {:error, reason} ->
          assert match?({:shepherd_error, _}, reason)
          degraded("cgroup ancestor test ran the fail-closed path: #{inspect(reason)}")
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
          degraded("cgroup fail-closed test skipped: mkdir #{full}: #{inspect(reason)}")
      end
    end

    # A cgroup positive path that silently stops executing would leave a green
    # build with zero cgroup coverage. CI sets NR_CGROUP_DELEGATED=1 on the leg
    # that delegates /sys/fs/cgroup/net_runner, so there the degraded branch is
    # a hard failure; elsewhere it is a logged, expected downgrade.
    defp degraded(message) do
      if System.get_env("NR_CGROUP_DELEGATED") == "1" do
        flunk("cgroup positive path did not run on a delegated CI leg: " <> message)
      else
        require Logger
        Logger.warning("[degraded] " <> message)
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

    test "places an unprefixed path under net_runner/ with a one-time deprecation warning" do
      # 1.3.x accepted unprefixed paths; 1.4.0 raised on them inside a minor
      # release (issue #24). Until 2.0 they are prefixed instead. This is the
      # only test in the suite that passes an unprefixed path, so the
      # once-per-VM warning is still pending when it runs.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Proc.validate_opts!(cgroup_path: "legacy_job")[:cgroup_path] ==
                   "net_runner/legacy_job"

          assert Proc.validate_opts!(cgroup_path: "system.slice/x")[:cgroup_path] ==
                   "net_runner/system.slice/x"
        end)

      assert length(String.split(log, "deprecated")) == 2,
             "expected exactly one deprecation warning, got: #{log}"

      assert Proc.validate_opts!(cgroup_path: "net_runner/job")[:cgroup_path] ==
               "net_runner/job"
    end

    test "still rejects paths that name no cgroup or escape after prefixing" do
      assert_raise ArgumentError, ~r/under net_runner\//, fn ->
        Proc.start("echo", ["x"], cgroup_path: "net_runner/")
      end

      assert_raise ArgumentError, ~r/cannot contain '\.\.'/, fn ->
        Proc.start("echo", ["x"], cgroup_path: "../evil")
      end

      assert_raise ArgumentError, ~r/256/, fn ->
        Proc.start("echo", ["x"], cgroup_path: String.duplicate("a", 250))
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

    test "rejects NUL bytes and non-binary paths before they reach the shepherd argv" do
      assert_raise ArgumentError, ~r/NUL/, fn ->
        Proc.start("echo", ["x"], cgroup_path: "net_runner/a\0b")
      end

      assert_raise ArgumentError, ~r/must be a binary/, fn ->
        Proc.start("echo", ["x"], cgroup_path: :"net_runner/atom")
      end
    end
  end
end
