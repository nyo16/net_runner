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
  """
  def eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline)
  end

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
  end

  defp retry_or_flunk(fun, deadline, on_expiry) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      poll(fun, deadline)
    else
      on_expiry.()
    end
  end

  @doc """
  True when the OS process `os_pid` still exists (signal 0 probe).
  """
  def os_pid_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
