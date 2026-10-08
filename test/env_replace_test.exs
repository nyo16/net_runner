defmodule NetRunner.EnvReplaceTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  @sh "/bin/sh"

  # The `+` form distinguishes an unset variable from an empty value.
  @report "echo \"[$PROBE_ONE][${PROBE_ONE+set}][$PROBE_TWO][${PROBE_TWO+set}]\""

  setup do
    name = "PROBE_AMBIENT_#{:erlang.unique_integer([:positive])}"
    System.put_env(name, "from the BEAM")
    on_exit(fn -> System.delete_env(name) end)
    {:ok, ambient: name}
  end

  describe "env: {:replace, environment}" do
    test "gives the child the selection and nothing ambient", %{ambient: name} do
      script = "#{@report}; echo [${#{name}-absent}]"

      assert {"[one][set][two][set]\n[absent]\n", 0} =
               NetRunner.run([@sh, "-c", script],
                 env: {:replace, %{"PROBE_ONE" => "one", "PROBE_TWO" => "two"}}
               )
    end

    test "takes a list of pairs as readily as a map", %{ambient: name} do
      script = "#{@report}; echo [${#{name}-absent}]"

      assert {"[one][set][two][set]\n[absent]\n", 0} =
               NetRunner.run([@sh, "-c", script],
                 env: {:replace, [{"PROBE_ONE", "one"}, {"PROBE_TWO", "two"}]}
               )
    end

    test "an empty replacement leaves the child nothing the caller did not select" do
      env = System.find_executable("env") || flunk("this test needs `env` as an executable")

      for empty <- [%{}, []] do
        assert {"", 0} = NetRunner.run([env], env: {:replace, empty})
      end

      assert {"PROBE_ONE=one\n", 0} =
               NetRunner.run([env], env: {:replace, %{"PROBE_ONE" => "one"}})
    end

    test "the shepherd removes an unselected variable from its inherited environment" do
      dir = tmp_dir("net_runner_allowlist")
      socket_path = Path.join(dir, "shepherd.sock")
      result_path = Path.join(dir, "result")
      shepherd = Path.join(to_string(:code.priv_dir(:net_runner)), "shepherd")
      token = String.duplicate("0", 32)

      {:ok, listener} = :socket.open(:local, :stream)
      :ok = :socket.bind(listener, %{family: :local, path: socket_path})
      :ok = :socket.listen(listener)

      script = "printf %s \"${NET_RUNNER_LATE_VARIABLE-absent}\" > #{result_path}"

      port =
        Port.open(
          {:spawn_executable, shepherd},
          [
            :nouse_stdio,
            :exit_status,
            :binary,
            args: [socket_path, "--token-fd", "--replace-env", "0", @sh, "-c", script],
            env: [{~c"NET_RUNNER_LATE_VARIABLE", ~c"leaked"}]
          ]
        )

      true = Port.command(port, token)
      {:ok, connection} = :socket.accept(listener, 5_000)

      assert_receive {^port, {:exit_status, 0}}, 5_000
      assert File.read!(result_path) == "absent"

      :socket.close(connection)
      :socket.close(listener)
    end

    test "a non-ASCII UTF-8 value survives the replacement" do
      assert {"héllo", 0} =
               NetRunner.run([@sh, "-c", "printf %s \"$PROBE_ONE\""],
                 env: {:replace, %{"PROBE_ONE" => "héllo"}}
               )
    end

    test "a selected name that is also ambient takes the selected value", %{ambient: name} do
      assert {"mine\n", 0} =
               NetRunner.run([@sh, "-c", "echo $#{name}"], env: {:replace, %{name => "mine"}})
    end

    test "the command is looked up in the replacement's PATH and nothing else" do
      dir = tmp_dir("net_runner_replace")
      script = Path.join(dir, "probe_only_here")
      File.write!(script, "#!/bin/sh\necho found\n")
      File.chmod!(script, 0o755)

      assert {"found\n", 0} =
               NetRunner.run(["probe_only_here"], env: {:replace, %{"PATH" => dir}})

      assert {"", 127} =
               NetRunner.run(["probe_only_here"], env: {:replace, %{"PROBE_ONE" => "one"}})

      assert {"", 127} = NetRunner.run(["sh", "-c", "echo found"], env: {:replace, %{}})
    end
  end

  describe "a replacement that is not an environment" do
    test "is refused before anything is spawned" do
      assert_raise ArgumentError, fn ->
        NetRunner.run([@sh, "-c", "echo hi"], env: {:replace, nil})
      end
    end

    test "an unknown tag is refused rather than treated as an overlay", %{ambient: name} do
      assert_raise ArgumentError, ~r/:overlay.*\{:replace, environment\}/s, fn ->
        NetRunner.run([@sh, "-c", "echo $#{name}"], env: {:overlay, %{"PROBE_ONE" => "one"}})
      end
    end
  end
end
