defmodule NetRunner.CgroupDeprecationTest do
  # The unprefixed-path warning is logged once per VM, gated by a global
  # :persistent_term flag that any test passing an unprefixed path flips.
  # async: false so no concurrent test can flip it mid-test; the flag is
  # reset around the test so reruns in the same VM still see the warning.
  use ExUnit.Case, async: false

  alias NetRunner.Process, as: Proc

  @warned_key {NetRunner.Process.Exec, :cgroup_prefix_warned}

  setup do
    :persistent_term.erase(@warned_key)
    on_exit(fn -> :persistent_term.erase(@warned_key) end)
  end

  # cgroup_path is Linux-only: validation raises for it on other platforms.
  @tag :linux_only
  test "places an unprefixed path under net_runner/ with a one-time deprecation warning" do
    # 1.3.x accepted unprefixed paths; 1.4.0 raised on them inside a minor
    # release (issue #24). Until 2.0 they are prefixed instead.
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
end
