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

  def tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
