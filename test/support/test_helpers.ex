defmodule NetRunner.TestHelpers do
  @moduledoc """
  Shared helpers for the NetRunner test suite.

  `eventually/2` replaces sleep-then-assert: it polls the assertion until it
  passes or the deadline expires, so tests wait exactly as long as the system
  needs instead of a guessed fixed interval (fast machines waste time, slow
  CI flakes).
  """

  @doc """
  Polls `fun` until it returns a truthy value or passes its assertions,
  re-raising the last failure once `timeout_ms` (default 2_000) expires.

  Besides `ExUnit.AssertionError`, transient exits are retried too: a polled
  `GenServer.call` racing a Process mid-teardown exits with `:noproc` (or
  `:timeout` while the server is briefly wedged) — exactly the in-between
  states this helper exists to ride out. Any other exit propagates.
  """
  def eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline)
  end

  # The on_expiry closures passed to retry_or_flunk/3 deliberately never
  # return (flunk/reraise/exit); dialyzer flags the closure creation site.
  @dialyzer {:nowarn_function, poll: 2}
  defp poll(fun, deadline) do
    result = fun.()

    if result do
      result
    else
      retry_or_flunk(fun, deadline, fn ->
        ExUnit.Assertions.flunk("eventually/2: condition still falsy after deadline")
      end)
    end
  rescue
    e in [ExUnit.AssertionError] ->
      retry_or_flunk(fun, deadline, fn -> reraise e, __STACKTRACE__ end)
  catch
    :exit, reason ->
      if transient_exit?(reason) do
        retry_or_flunk(fun, deadline, fn -> exit(reason) end)
      else
        exit(reason)
      end
  end

  defp transient_exit?(:noproc), do: true
  defp transient_exit?(:timeout), do: true
  defp transient_exit?({:noproc, _}), do: true
  defp transient_exit?({:timeout, _}), do: true
  defp transient_exit?(_), do: false

  defp retry_or_flunk(fun, deadline, on_expiry) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      poll(fun, deadline)
    else
      on_expiry.()
    end
  end

  @doc """
  True when the OS process `os_pid` still exists AND is not a zombie.

  `kill -0` alone is wrong in containerized CI: an orphan whose new parent
  (a shell as PID 1) never reaps it stays a signalable zombie forever, so
  "the child died" tests would hang on the probe. A zombie has already
  exited — for every "did it die" question this helper answers, it is dead.
  """
  def os_pid_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> not zombie?(os_pid)
      _ -> false
    end
  end

  @doc """
  Parent pid of `os_pid`. Works on busybox too: Alpine's `ps` supports
  neither `-p` nor `ppid=`, but /proc is always there on Linux; macOS has
  no /proc and a full BSD ps.
  """
  def parent_pid!(os_pid) do
    case File.read("/proc/#{os_pid}/status") do
      {:ok, status} ->
        [_, ppid] = Regex.run(~r/^PPid:\s+(\d+)$/m, status)
        String.to_integer(ppid)

      {:error, _} ->
        {out, 0} = System.cmd("ps", ["-o", "ppid=", "-p", to_string(os_pid)])
        out |> String.trim() |> String.to_integer()
    end
  end

  @doc """
  A high-entropy `sleep` duration that `pgrep -f "sleep <marker>"` can match
  without colliding with other tests or host processes.

  Kept below 2^31-1: macOS `/bin/sleep` rejects larger durations with a usage
  error and exit 1, which made timeout tests fail as `{"", 1}` late in a
  full-suite run once `System.unique_integer/1` grew past five digits.
  """
  def sleep_marker do
    "86400#{rem(System.unique_integer([:positive]), 10_000)}"
  end

  # /proc/<pid>/stat field 3 is the state character; "Z" is a zombie. macOS
  # has no /proc, but also reaps orphans via launchd, so absence => not a
  # zombie concern.
  defp zombie?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        # comm can contain spaces/parens; the state follows the LAST ")".
        stat
        |> String.split(")")
        |> List.last()
        |> String.trim_leading()
        |> String.starts_with?("Z")

      {:error, _} ->
        false
    end
  end

  @doc """
  Creates a fresh directory under the system temp dir, removed on test exit.

  The name is random and `File.mkdir/1` refuses an existing path, so a
  directory pre-created by another local user (who could plant scripts the
  test then runs) is never adopted.
  """
  def tmp_dir(prefix) do
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{random}")
    :ok = File.mkdir(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc """
  Number of live `sleep <marker>` processes (see `sleep_marker/0`).

  Anchored to the exact argv: the wrapping `sh -c` (and a forked subshell,
  until it execs) carries the marker in its own cmdline, so an unanchored
  `pgrep -f` counts the shell as "the sleep is up" before it exists.
  """
  def pgrep_count(marker) do
    case System.cmd("pgrep", ["-f", "^sleep #{marker}$"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  @doc """
  Reports a positive-path test that could not run (no cgroup delegation,
  missing helper binary, ...). On the CI leg that delegates
  `/sys/fs/cgroup/net_runner` (`NR_CGROUP_DELEGATED=1`) it is a hard failure,
  so the positive path cannot silently stop executing; elsewhere it is a
  logged, expected downgrade.
  """
  def degraded(message) do
    if System.get_env("NR_CGROUP_DELEGATED") == "1" do
      ExUnit.Assertions.flunk("positive path did not run on a delegated CI leg: " <> message)
    else
      degraded_note(message)
    end
  end

  @doc "Logs a `[degraded]` note without ever failing the test."
  def degraded_note(message) do
    require Logger
    Logger.warning("[degraded] " <> message)
  end

  @doc """
  A connected pair of local stream sockets, `{server, client}`, closed on
  test exit. Stands in for the BEAM <-> shepherd UDS in parser and handshake
  tests.
  """
  def uds_pair do
    path = Path.join(System.tmp_dir!(), "nr_test_#{System.unique_integer([:positive])}.sock")

    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)

    {:ok, client} = :socket.open(:local, :stream)
    :ok = :socket.connect(client, %{family: :local, path: path})
    {:ok, server} = :socket.accept(listener, 5_000)

    :socket.close(listener)
    File.rm(path)

    ExUnit.Callbacks.on_exit(fn ->
      :socket.close(client)
      :socket.close(server)
    end)

    {server, client}
  end
end
