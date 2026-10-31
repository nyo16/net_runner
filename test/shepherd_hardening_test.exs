defmodule NetRunner.ShepherdHardeningTest do
  # Regression tests for the shepherd hardening audit
  # (.claude/audit/shepherd/SUMMARY.md). Each describe names the finding it
  # pins. H10 (an fd hand-off failure must leave the command un-run) needs
  # the shepherd's sendmsg to fail after fork, which the public API cannot
  # provoke; it was verified with an LD_PRELOAD/DYLD_INSERT_LIBRARIES harness
  # outside this suite (0/10 commands ran vs 10/10 before). A cgroup-setup
  # failure does not exercise it: that path was already gated before.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import NetRunner.TestHelpers

  alias NetRunner.{Daemon, Nif, Signal}
  alias NetRunner.Process, as: Proc
  alias NetRunner.Process.Pipe

  # A leader that dies on SIGTERM plus a group member that ignores it. The
  # member is `sleep <marker>` with SIGTERM ignored (SIG_IGN survives exec),
  # so only a group SIGKILL can end it.
  defp term_ignoring_member(marker) do
    ~s|(trap "" TERM; exec sleep #{marker}) & exec sleep 100|
  end

  # Anchored: the wrapping `sh -c` (and its forked subshell, until it execs)
  # carries the marker in its cmdline too. Only the exec'd `sleep <marker>` —
  # which by then has SIGTERM ignored — may count as "the member is up".
  defp pgrep(marker) do
    case System.cmd("pgrep", ["-f", "^sleep #{marker}$"]) do
      {out, 0} -> String.split(out, "\n", trim: true)
      {_, _} -> []
    end
  end

  # A failed assertion must not leave the marker running for the VM's
  # lifetime (it would also poison later pgrep-based tests).
  defp reap_marker_on_exit(marker) do
    on_exit(fn -> System.cmd("pkill", ["-KILL", "-f", "^sleep #{marker}$"]) end)
  end

  # Process group of `os_pid`. /proc on Linux (busybox ps has no -p); BSD ps
  # on macOS.
  defp pgid!(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        # comm may contain spaces/parens; fields resume after the LAST ")".
        [_state, _ppid, pgrp | _] =
          stat |> String.split(")") |> List.last() |> String.split()

        String.to_integer(pgrp)

      {:error, _} ->
        {out, 0} = System.cmd("ps", ["-o", "pgid=", "-p", to_string(os_pid)])
        out |> String.trim() |> String.to_integer()
    end
  end

  defp status_field(status, field) do
    [_, value] = Regex.run(~r/^#{field}:\s+(\S+)$/m, status)
    value
  end

  # Mirrors cgroup_test.exs: on the CI leg that delegates
  # /sys/fs/cgroup/net_runner (NR_CGROUP_DELEGATED=1) a cgroup positive path
  # that cannot run is a hard failure; elsewhere a logged downgrade.
  defp degraded(message) do
    if System.get_env("NR_CGROUP_DELEGATED") == "1" do
      flunk("cgroup positive path did not run on a delegated CI leg: " <> message)
    else
      degraded_note(message)
    end
  end

  defp degraded_note(message) do
    require Logger
    Logger.warning("[degraded] " <> message)
  end

  defp cgroup_leaf(prefix) do
    path = "net_runner/#{prefix}_#{:rand.uniform(1_000_000)}"
    full = "/sys/fs/cgroup/" <> path

    on_exit(fn ->
      _ = File.rmdir(full <> "/sub")
      _ = File.rmdir(full)
    end)

    {path, full}
  end

  describe "H1/S-01: teardown SIGKILLs the group even when the leader died on SIGTERM" do
    test "Proc.stop" do
      marker = sleep_marker()
      reap_marker_on_exit(marker)

      {:ok, pid} = Proc.start("sh", ["-c", term_ignoring_member(marker)], kill_timeout: 300)
      eventually(fn -> pgrep(marker) != [] end)

      Proc.stop(pid)

      eventually(fn -> pgrep(marker) == [] end, 3_000)
    end

    test "owner death" do
      marker = sleep_marker()
      reap_marker_on_exit(marker)
      owner = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, pid} =
        Proc.start("sh", ["-c", term_ignoring_member(marker)], kill_timeout: 300, owner: owner)

      eventually(fn -> pgrep(marker) != [] end)
      ref = Process.monitor(pid)

      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      eventually(fn -> pgrep(marker) == [] end, 3_000)
    end

    test "run/2 timeout" do
      marker = sleep_marker()
      reap_marker_on_exit(marker)

      # The member holds stdout open, so run/2 can only end by its timeout.
      assert {:error, :timeout} =
               NetRunner.run(["sh", "-c", term_ignoring_member(marker)],
                 timeout: 300,
                 kill_timeout: 300
               )

      eventually(fn -> pgrep(marker) == [] end, 3_000)
    end
  end

  describe "H2: a leader's normal exit sweeps its process group" do
    test "run/2 returns the leader's status and no background member survives" do
      marker = sleep_marker()
      reap_marker_on_exit(marker)

      # Before the fix the backgrounded sleep kept stdout open and run/2 never
      # saw EOF; now the shepherd SIGKILLs the group when the leader exits.
      assert {"", 0} = NetRunner.run(["sh", "-c", "sleep #{marker} & exit 0"], timeout: 5_000)

      eventually(fn -> pgrep(marker) == [] end)
    end
  end

  describe "H3: commands queued before the UDS hangs up are honoured" do
    test "a SIGKILL sent right before stop is not replaced by the SIGTERM ladder" do
      ready = Path.join(System.tmp_dir!(), "nr_h3_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(ready) end)

      # TERM-ignoring child; a 30 s kill_timeout makes the ladder path
      # unmistakable against the ~1 s budget below.
      {:ok, pid} =
        Proc.start("sh", ["-c", "trap '' TERM; : > #{ready}; exec sleep 100"],
          kill_timeout: 30_000
        )

      os_pid = Proc.os_pid(pid)
      eventually(fn -> File.exists?(ready) end)

      assert :ok = Proc.kill(pid, :sigkill)
      GenServer.stop(pid)

      eventually(fn -> not os_pid_alive?(os_pid) end, 1_500)
    end
  end

  describe "H4: termination signals to the shepherd run the teardown ladder" do
    test "SIGTERM to the shepherd delivers the child's real exit status" do
      {:ok, pid} = Proc.start("sleep", ["100"], kill_timeout: 1_000)
      os_pid = Proc.os_pid(pid)
      shepherd = parent_pid!(os_pid)

      log =
        capture_log(fn ->
          System.cmd("kill", ["-TERM", to_string(shepherd)])
          # Default-action death reported nothing and the BEAM synthesised
          # 137 (finish_orphaned); the ladder SIGTERMs sleep → 128 + 15.
          assert {:ok, 143} = Proc.await_exit(pid, 5_000)
        end)

      refute log =~ "without reporting the child's exit"
      eventually(fn -> not os_pid_alive?(os_pid) end)
      Proc.stop(pid)
    end

    @tag :linux_only
    test "SIGTERM to the shepherd removes the cgroup leaf before the exit frame" do
      {path, full} = cgroup_leaf("h4")

      case Proc.start("sleep", ["100"], cgroup_path: path, kill_timeout: 1_000) do
        {:ok, pid} ->
          shepherd = parent_pid!(Proc.os_pid(pid))
          System.cmd("kill", ["-TERM", to_string(shepherd)])

          assert {:ok, 143} = Proc.await_exit(pid, 5_000)
          refute File.exists?(full), "cgroup leaf leaked after shepherd SIGTERM"
          Proc.stop(pid)

        {:error, reason} ->
          assert match?({:shepherd_error, _}, reason)
          degraded("H4 cgroup test ran the fail-closed path: #{inspect(reason)}")
      end
    end
  end

  describe "H5/H6: cgroup leaf cleanup" do
    @tag :linux_only
    test "a child-created sub-cgroup cannot pin the leaf; same-path respawn succeeds" do
      {path, full} = cgroup_leaf("h5")

      # The child creates a sub-cgroup inside its leaf; the shepherd must
      # remove it recursively, so the leaf is gone either way.
      case NetRunner.run(["sh", "-c", "mkdir #{full}/sub 2>/dev/null; echo ran"],
             cgroup_path: path
           ) do
        {"ran\n", 0} ->
          # H6: run/2 returns after MSG_CHILD_EXITED, which now follows
          # cgroup_cleanup — no polling.
          refute File.exists?(full), "cgroup leaf survived the child's exit"

          assert {"again\n", 0} = NetRunner.run(["echo", "again"], cgroup_path: path)
          refute File.exists?(full)

        {:error, reason} ->
          assert match?({:shepherd_error, _}, reason)
          degraded("H5 cgroup test ran the fail-closed path: #{inspect(reason)}")
      end
    end
  end

  describe "H7: the child leads its process group before start returns" do
    for pty <- [false, true] do
      test "pty: #{pty}" do
        {:ok, pid} = Proc.start("sleep", ["30"], pty: unquote(pty))
        os_pid = Proc.os_pid(pid)

        assert pgid!(os_pid) == os_pid

        Proc.stop(pid)
      end
    end
  end

  describe "H8: the child starts with a clean signal state" do
    @tag :linux_only
    test "no ignored and no blocked signals survive into the exec'd command" do
      # erts runs ports with SIGFPE (and a realtime signal) ignored; nohup/+Bi
      # add SIGINT/SIGHUP. None of that may leak into the child.
      {status, 0} = NetRunner.run(["cat", "/proc/self/status"])

      for field <- ["SigIgn", "SigBlk"] do
        mask = status_field(status, field)
        assert mask =~ ~r/^0+$/, "#{field} is #{mask}"
      end
    end
  end

  describe "H9: the shepherd is not dumpable" do
    @tag :linux_only
    test "same-uid processes cannot read the shepherd's /proc entries" do
      {:ok, pid} = Proc.start("sleep", ["30"])
      shepherd = parent_pid!(Proc.os_pid(pid))
      {uid, 0} = System.cmd("id", ["-u"])

      if String.trim(uid) == "0" do
        # Root owns a non-dumpable process's /proc entries anyway and passes
        # the ptrace check: nothing distinguishes dumpability here.
        degraded_note("H9 not observable as root")
      else
        # PR_SET_DUMPABLE(0) hands /proc/<pid>/* to root and fails the
        # PTRACE_MODE_READ check for the same uid.
        assert {:ok, %File.Stat{uid: 0}} = File.stat("/proc/#{shepherd}/status")
        assert {:error, :eacces} = File.read("/proc/#{shepherd}/environ")
      end

      Proc.stop(pid)
    end
  end

  describe "pidfd" do
    test "handed over on Linux only, closed on exit; kill works either way" do
      {:ok, pid} = Proc.start("sleep", ["30"])
      %{pidfd: pidfd} = :sys.get_state(pid)

      if match?({:unix, :linux}, :os.type()) do
        assert %Pipe{resource: resource} = pidfd
        {:ok, sigcont} = Signal.resolve(:sigcont)
        assert :ok = Nif.nif_pidfd_send_signal(resource, sigcont)
      else
        assert pidfd == nil
      end

      assert :ok = Proc.kill(pid, :sigkill)
      assert {:ok, 137} = Proc.await_exit(pid)
      assert :sys.get_state(pid).pidfd == nil
      assert {:error, :not_running} = Proc.kill(pid, :sigkill)
      Proc.stop(pid)
    end

    @tag :linux_only
    test "a pidfd for a reaped child reports :esrch instead of hitting a reused pid" do
      {:ok, pid} = Proc.start("sleep", ["30"])
      %Pipe{resource: resource} = :sys.get_state(pid).pidfd
      # Detach the pidfd from the server so finish_exit does not close it.
      :sys.replace_state(pid, &%{&1 | pidfd: nil})

      assert :ok = Proc.kill(pid, :sigkill)
      assert {:ok, 137} = Proc.await_exit(pid)

      {:ok, sigcont} = Signal.resolve(:sigcont)
      assert {:error, :esrch} = Nif.nif_pidfd_send_signal(resource, sigcont)

      Nif.nif_close(resource)
      Proc.stop(pid)
    end
  end

  describe ":no_new_privs" do
    @tag :linux_only
    test "sets NoNewPrivs in the child only when asked" do
      beam = status_field(File.read!("/proc/self/status"), "NoNewPrivs")

      {with_nnp, 0} = NetRunner.run(["cat", "/proc/self/status"], no_new_privs: true)
      assert status_field(with_nnp, "NoNewPrivs") == "1"

      # Without the option the child inherits whatever the BEAM has (0 unless
      # the VM itself runs under no_new_privs, e.g. systemd NoNewPrivileges=).
      {without, 0} = NetRunner.run(["cat", "/proc/self/status"])
      assert status_field(without, "NoNewPrivs") == beam
    end

    test "is accepted on every platform" do
      assert {"hi\n", 0} = NetRunner.run(["echo", "hi"], no_new_privs: true)
      assert {"hi\n", 0} = NetRunner.run(["echo", "hi"], no_new_privs: false)
    end

    test "rejects non-booleans at every entry point" do
      for bad <- ["yes", 1, nil] do
        assert_raise ArgumentError, ~r/:no_new_privs must be a boolean/, fn ->
          NetRunner.run(["echo"], no_new_privs: bad)
        end

        assert_raise ArgumentError, ~r/:no_new_privs/, fn ->
          NetRunner.stream!(["echo"], no_new_privs: bad)
        end

        assert_raise ArgumentError, ~r/:no_new_privs/, fn ->
          NetRunner.stream(["echo"], no_new_privs: bad)
        end

        assert_raise ArgumentError, ~r/:no_new_privs/, fn ->
          Proc.start("echo", [], no_new_privs: bad)
        end

        assert_raise ArgumentError, ~r/:no_new_privs/, fn ->
          Daemon.start_link(cmd: "sleep", args: ["100"], process_opts: [no_new_privs: bad])
        end
      end
    end
  end

  describe "exec failure exit codes" do
    test "a nonexistent command exits 127 and names the errno" do
      assert {"", 127, stderr} =
               NetRunner.run(["nonexistent_command_nr_xyz"], stderr: :capture)

      assert stderr =~ "execvp: nonexistent_command_nr_xyz: No such file or directory"
    end

    test "a non-executable file exits 126" do
      dir = tmp_dir("nr_noexec")
      file = Path.join(dir, "not_executable")
      File.write!(file, "#!/bin/sh\necho ran\n")
      File.chmod!(file, 0o644)

      assert {"", 126, stderr} = NetRunner.run([file], stderr: :capture)
      assert stderr =~ "Permission denied"
    end
  end
end
