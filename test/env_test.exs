defmodule NetRunner.EnvTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  @sh "/bin/sh"

  # The `+` form distinguishes an unset variable from an empty value.
  @report "echo \"[$PROBE_ONE][${PROBE_ONE+set}][$PROBE_TWO][${PROBE_TWO+set}]\""

  # The inherited probe is HOME, which the BEAM already has: System.put_env
  # in an async module would change the environment every concurrently
  # spawned child inherits.
  setup do
    home = System.get_env("HOME")
    if home in [nil, ""], do: flunk("these tests need a non-empty HOME in the BEAM's environment")
    {:ok, inherited: "HOME", value: home}
  end

  describe "env:" do
    test "accepts a map" do
      assert {"[one][set][two][set]\n", 0} =
               NetRunner.run([@sh, "-c", @report],
                 env: %{"PROBE_ONE" => "one", "PROBE_TWO" => "two"}
               )
    end

    test "an empty value removes the variable rather than emptying it", %{
      inherited: name,
      value: value
    } do
      # A Port cannot set an empty value, so `""` and `nil` both remove it.
      empty = NetRunner.run([@sh, "-c", "echo [${#{name}-absent}]"], env: [{name, ""}])
      removed = NetRunner.run([@sh, "-c", "echo [${#{name}-absent}]"], env: [{name, nil}])

      assert {"[absent]\n", 0} = empty
      assert empty == removed
      assert System.get_env(name) == value
    end

    test "the rest of the BEAM's environment still reaches the child", %{
      inherited: name,
      value: value
    } do
      assert {output, 0} =
               NetRunner.run([@sh, "-c", "printf %s \"$#{name}\""], env: [{"PROBE_ONE", "one"}])

      assert output == value
    end

    test "a name given twice takes the last value" do
      assert {"[last][set][][]\n", 0} =
               NetRunner.run([@sh, "-c", @report],
                 env: [{"PROBE_ONE", "first"}, {"PROBE_ONE", "last"}]
               )
    end

    test "overrides one the BEAM already set", %{inherited: name} do
      assert {"mine\n", 0} =
               NetRunner.run([@sh, "-c", "echo $#{name}"], env: [{name, "mine"}])
    end

    test "the child's own PATH is the one its command is looked up in", %{inherited: _} do
      dir = tmp_dir("net_runner_env")
      script = Path.join(dir, "probe_only_here")
      File.write!(script, "#!/bin/sh\necho found\n")
      File.chmod!(script, 0o755)

      assert {"found\n", 0} = NetRunner.run(["probe_only_here"], env: [{"PATH", dir}])
    end

    test "an environment too large to exec is reported as a spawn failure" do
      # :shepherd_spawn_failed (not :shepherd_connect_timeout) is what proves
      # the failure was reported without waiting out the accept deadline.
      assert {:error, {:shepherd_spawn_failed, _reason}} =
               NetRunner.run([@sh, "-c", "echo hi"],
                 env: [{"BIG", String.duplicate("x", 2_000_000)}]
               )
    end
  end

  describe "an env that is not an environment" do
    test "is refused before anything is spawned" do
      for bad <- [
            "PROBE_ONE=one",
            [{"PROBE_ONE", "one", "extra"}],
            [{~c"PROBE_ONE", "one"}],
            [{"PROBE_ONE", ~c"one"}],
            [{"", "one"}],
            [{"PROBE=ONE", "one"}],
            [{"PROBE_ONE", 1}],
            [{<<"PROBE", 0, "ONE">>, "one"}],
            [{"PROBE_ONE", <<"one", 0>>}],
            [{"PROBE_ONE", "one"} | :improper],
            %URI{}
          ] do
        assert_raise ArgumentError, fn -> NetRunner.run([@sh, "-c", "echo hi"], env: bad) end
      end
    end

    test "a refusal names what was wrong with it" do
      assert_raise ArgumentError, ~r/invalid variable name/, fn ->
        NetRunner.run([@sh, "-c", "echo hi"], env: [{"PROBE=ONE", "one"}])
      end
    end
  end

  describe "UTF-8 environment entries" do
    test "a non-ASCII UTF-8 value reaches the child unchanged" do
      assert {"héllo", 0} =
               NetRunner.run([@sh, "-c", "printf %s \"$PROBE_ONE\""],
                 env: [{"PROBE_ONE", "héllo"}]
               )
    end

    test "a non-ASCII UTF-8 name reaches the child unchanged" do
      # POSIX variable syntax does not permit this name, so inspect it with env.
      env = System.find_executable("env") || flunk("this test needs `env` as an executable")

      assert {output, 0} = NetRunner.run([env], env: [{"PRÖBE", "x"}])
      assert output =~ "PRÖBE=x"
    end

    test "names and values that are not UTF-8 are refused" do
      assert_raise ArgumentError, ~r/UTF-8/, fn ->
        NetRunner.run([@sh, "-c", "echo hi"], env: [{<<0xFF, 0xFE>>, "one"}])
      end

      assert_raise ArgumentError, ~r/UTF-8/, fn ->
        NetRunner.run([@sh, "-c", "echo hi"], env: [{"PROBE_ONE", <<0xFF, 0xFE>>}])
      end
    end
  end
end
