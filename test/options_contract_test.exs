defmodule NetRunner.OptionsContractTest do
  # Limits the BEAM validates are re-checked by the shepherd's own argv
  # parser (c_src/shepherd.c parse_args). Drift between the two turns a
  # readable ArgumentError into a bare {:shepherd_spawn_failed, ...} with the
  # reason only on the VM's stderr, so each limit is pinned against the real
  # shepherd binary at its boundary and boundary + 1.
  use ExUnit.Case, async: true

  alias NetRunner.Process.Options

  # Runs the shepherd with `flags` and no token channel, returning everything
  # it printed. argv is validated before anything touches fd 3, so a rejected
  # flag prints its error; an accepted one gets as far as the token read and
  # gives up there (--token-timeout keeps that short). System.cmd rather than
  # a :nouse_stdio Port: Port.open rejects :stderr_to_stdout with it.
  defp shepherd_output(flags) do
    shepherd = Path.join(to_string(:code.priv_dir(:net_runner)), "shepherd")
    socket = Path.join(System.tmp_dir!(), "nr_contract_#{System.unique_integer([:positive])}")
    args = [socket, "--token-fd", "--token-timeout", "50" | flags] ++ ["--", "/bin/true"]

    {output, _status} = System.cmd(shepherd, args, stderr_to_stdout: true)
    output
  end

  test "the :kill_timeout maximum matches the shepherd's --kill-timeout check" do
    max = Options.kill_timeout_max()

    refute shepherd_output(["--kill-timeout", "#{max}"]) =~ "--kill-timeout must be"
    assert shepherd_output(["--kill-timeout", "#{max + 1}"]) =~ "--kill-timeout must be"

    assert Options.validate!(kill_timeout: max)[:kill_timeout] == max

    assert_raise ArgumentError, ~r/:kill_timeout must be/, fn ->
      Options.validate!(kill_timeout: max + 1)
    end
  end

  test "the :cgroup_path length cap matches the shepherd's CGROUP_PATH_MAX" do
    max = Options.cgroup_path_max_bytes()
    at_max = "net_runner/" <> String.duplicate("a", max - byte_size("net_runner/"))
    over = at_max <> "a"

    refute shepherd_output(["--cgroup-path", at_max]) =~ "cgroup path too long"
    assert shepherd_output(["--cgroup-path", over]) =~ "cgroup path too long"

    # At the cap the shape check passes (off Linux it then fails on the
    # platform check instead); one byte more fails the shape check.
    try do
      Options.validate!(cgroup_path: at_max)
    rescue
      e in ArgumentError -> assert e.message =~ "requires Linux"
    end

    assert_raise ArgumentError, ~r/must be under #{max + 1} bytes/, fn ->
      Options.validate!(cgroup_path: over)
    end
  end
end
