defmodule NetRunner.CwdTest do
  use ExUnit.Case, async: true

  import NetRunner.TestHelpers

  # A shell builtin can report the inherited $PWD instead of the actual path.
  @pwd System.find_executable("pwd") ||
         raise("these tests need `pwd` as an executable, not just a shell builtin")

  setup do
    dir = tmp_dir("net_runner_cwd")
    {:ok, dir: dir, physical: physical_path(dir)}
  end

  describe "cwd:" do
    test "runs the child in the requested directory", %{dir: dir, physical: physical} do
      assert {output, 0} = NetRunner.run([@pwd], cwd: dir)
      assert String.trim(output) == physical
    end

    test "without it the child runs where the BEAM does" do
      assert {output, 0} = NetRunner.run([@pwd])
      assert String.trim(output) == physical_path(File.cwd!())
    end

    test "a relative directory resolves against the BEAM's directory" do
      assert {output, 0} = NetRunner.run([@pwd], cwd: "test")
      assert String.trim(output) == physical_path(Path.join(File.cwd!(), "test"))
    end

    test "the child's own relative paths are resolved there", %{dir: dir} do
      File.write!(Path.join(dir, "marker"), "found\n")

      assert {"found\n", 0} = NetRunner.run(["/bin/sh", "-c", "cat marker"], cwd: dir)
    end

    test "a relative executable resolves there too", %{dir: dir} do
      script = Path.join(dir, "say")
      File.write!(script, "#!/bin/sh\necho said\n")
      File.chmod!(script, 0o755)

      assert {"said\n", 0} = NetRunner.run(["./say"], cwd: dir)
    end

    @tag :linux_only
    test "a directory whose name is not UTF-8 is still a directory", %{dir: dir} do
      raw = Path.join(dir, <<0xFF, 0xFE>>)
      File.mkdir_p!(raw)

      assert {output, 0} = NetRunner.run([@pwd], cwd: raw)
      assert String.trim_trailing(output, "\n") == physical_path(dir) <> "/" <> <<0xFF, 0xFE>>
    end

    test "each child gets its own directory", %{dir: dir, physical: physical} do
      other = Path.join(dir, "other")
      File.mkdir_p!(other)

      results =
        [dir, other, dir]
        |> Task.async_stream(fn d -> NetRunner.run([@pwd], cwd: d) end)
        |> Enum.map(fn {:ok, {output, 0}} -> String.trim(output) end)

      assert results == [physical, Path.join(physical, "other"), physical]
    end
  end

  describe "a directory the child cannot be started in" do
    test "reports what the shepherd could not do", %{dir: dir} do
      missing = Path.join(dir, "absent")

      assert {:error, {:shepherd_error, message}} = NetRunner.run([@pwd], cwd: missing)
      assert message =~ "chdir failed"
      assert message =~ "No such file or directory"
    end
  end

  describe "a cwd that is not a path" do
    test "is refused before anything is spawned" do
      assert_raise ArgumentError, ~r/:cwd/, fn -> NetRunner.run([@pwd], cwd: "") end

      assert_raise ArgumentError, ~r/:cwd/, fn ->
        NetRunner.run([@pwd], cwd: <<"/tmp", 0, "x">>)
      end

      assert_raise ArgumentError, ~r/:cwd/, fn -> NetRunner.run([@pwd], cwd: :tmp) end
      assert_raise ArgumentError, ~r/:cwd/, fn -> NetRunner.run([@pwd], cwd: ~c"/tmp") end
    end
  end

  # /tmp is a symlink on macOS, so compare the path reported by `pwd`.
  defp physical_path(dir) do
    {output, 0} = System.cmd(@pwd, [], cd: dir)
    String.trim(output)
  end
end
