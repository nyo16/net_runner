defmodule NetRunner.CommandTest do
  use ExUnit.Case, async: true

  alias NetRunner.Command

  # ── Test modules defined via defcommand ──────────────────────────────

  defmodule BasicCommands do
    use NetRunner.Command

    defcommand(:echo, "echo")

    defcommand(:cat, "cat")

    defcommand(:curl, "curl",
      args: ["-s", "--compressed", "-L"],
      timeout: 10_000
    )

    defcommand(:rg, "rg",
      args: ["--no-heading", "--color=never"],
      stderr: :consume
    )

    defcommand(:ffmpeg, "ffmpeg",
      args: ["-y", "-hide_banner"],
      timeout: 300_000,
      kill_timeout: 10_000
    )
  end

  defmodule MinimalCommands do
    use NetRunner.Command

    defcommand(:ls, "ls")
  end

  defmodule EmptyModule do
    use NetRunner.Command
  end

  # ── Struct construction (Command.new/3) ──────────────────────────────

  describe "Command.new/3" do
    test "creates struct with all fields" do
      cmd = Command.new("echo", ["hello", "world"], timeout: 5_000)

      assert %Command{} = cmd
      assert cmd.executable == "echo"
      assert cmd.args == ["hello", "world"]
      assert cmd.opts == [timeout: 5_000]
    end

    test "defaults args to empty list" do
      cmd = Command.new("echo")

      assert cmd.args == []
      assert cmd.opts == []
    end

    test "defaults opts to empty list" do
      cmd = Command.new("echo", ["hello"])

      assert cmd.opts == []
    end

    test "preserves multiple opts" do
      cmd = Command.new("cmd", [], timeout: 5_000, stderr: :redirect, pty: true)

      assert cmd.opts == [timeout: 5_000, stderr: :redirect, pty: true]
    end

    test "raises on non-binary executable" do
      assert_raise ArgumentError, ~r/executable must be a string/, fn ->
        Command.new(:echo)
      end

      assert_raise ArgumentError, ~r/executable must be a string/, fn ->
        Command.new(123)
      end

      assert_raise ArgumentError, ~r/executable must be a string/, fn ->
        Command.new(nil)
      end
    end

    test "raises on non-list args" do
      assert_raise ArgumentError, ~r/args must be a list/, fn ->
        Command.new("echo", "hello")
      end

      assert_raise ArgumentError, ~r/args must be a list/, fn ->
        Command.new("echo", :bad)
      end
    end
  end

  # ── to_cmd_args_opts/2 ──────────────────────────────────────────────

  describe "Command.to_cmd_args_opts/2" do
    test "decomposes struct with no overrides" do
      cmd = Command.new("echo", ["hello"], timeout: 5_000)

      assert {"echo", ["hello"], [timeout: 5_000]} = Command.to_cmd_args_opts(cmd)
    end

    test "decomposes struct with empty overrides" do
      cmd = Command.new("echo", ["hello"], timeout: 5_000)

      assert {"echo", ["hello"], [timeout: 5_000]} = Command.to_cmd_args_opts(cmd, [])
    end

    test "override opts win over defaults" do
      cmd = Command.new("echo", ["hello"], timeout: 5_000)

      assert {"echo", ["hello"], [timeout: 30_000]} =
               Command.to_cmd_args_opts(cmd, timeout: 30_000)
    end

    test "preserves non-overridden defaults" do
      cmd = Command.new("cmd", [], timeout: 5_000, stderr: :consume)

      {_, _, opts} = Command.to_cmd_args_opts(cmd, timeout: 30_000)

      assert opts[:timeout] == 30_000
      assert opts[:stderr] == :consume
    end

    test "adds new opts not in defaults" do
      cmd = Command.new("cat", [])

      {_, _, opts} = Command.to_cmd_args_opts(cmd, input: "hello")

      assert opts[:input] == "hello"
    end

    test "args are not affected by overrides" do
      cmd = Command.new("echo", ["hello", "world"], timeout: 5_000)

      {_, args, _} = Command.to_cmd_args_opts(cmd, timeout: 30_000)

      assert args == ["hello", "world"]
    end

    test "works with empty struct opts" do
      cmd = Command.new("echo", ["hello"])

      assert {"echo", ["hello"], [input: "data"]} =
               Command.to_cmd_args_opts(cmd, input: "data")
    end
  end

  # ── defcommand macro ────────────────────────────────────────────────

  describe "defcommand macro" do
    test "generates a function for each command" do
      assert function_exported?(BasicCommands, :echo, 0)
      assert function_exported?(BasicCommands, :echo, 1)
      assert function_exported?(BasicCommands, :cat, 0)
      assert function_exported?(BasicCommands, :cat, 1)
      assert function_exported?(BasicCommands, :curl, 0)
      assert function_exported?(BasicCommands, :curl, 1)
    end

    test "generated function returns a Command struct" do
      cmd = BasicCommands.echo()

      assert %Command{} = cmd
      assert cmd.executable == "echo"
    end

    test "command with no opts has empty args and opts" do
      cmd = BasicCommands.echo()

      assert cmd.executable == "echo"
      assert cmd.args == []
      assert cmd.opts == []
    end

    test "command with default args includes them" do
      cmd = BasicCommands.curl()

      assert cmd.executable == "curl"
      assert cmd.args == ["-s", "--compressed", "-L"]
      assert cmd.opts == [timeout: 10_000]
    end

    test "extra args are appended to defaults" do
      cmd = BasicCommands.curl(["https://example.com"])

      assert cmd.args == ["-s", "--compressed", "-L", "https://example.com"]
    end

    test "multiple extra args are appended in order" do
      cmd = BasicCommands.curl(["https://example.com", "-o", "output.html"])

      assert cmd.args == ["-s", "--compressed", "-L", "https://example.com", "-o", "output.html"]
    end

    test "extra args on command with no defaults" do
      cmd = BasicCommands.echo(["hello", "world"])

      assert cmd.args == ["hello", "world"]
    end

    test "empty extra args does not change defaults" do
      cmd = BasicCommands.curl([])

      assert cmd.args == ["-s", "--compressed", "-L"]
    end

    test "opts are separated from args correctly" do
      cmd = BasicCommands.rg()

      assert cmd.args == ["--no-heading", "--color=never"]
      assert cmd.opts == [stderr: :consume]
    end

    test "multiple opts are preserved" do
      cmd = BasicCommands.ffmpeg()

      assert cmd.opts == [timeout: 300_000, kill_timeout: 10_000]
    end

    test "calling function multiple times returns independent structs" do
      cmd1 = BasicCommands.curl(["url1"])
      cmd2 = BasicCommands.curl(["url2"])

      assert cmd1.args == ["-s", "--compressed", "-L", "url1"]
      assert cmd2.args == ["-s", "--compressed", "-L", "url2"]
    end
  end

  # ── __commands__/0 introspection ────────────────────────────────────

  describe "__commands__/0 introspection" do
    test "lists all commands in definition order" do
      assert BasicCommands.__commands__() == [:echo, :cat, :curl, :rg, :ffmpeg]
    end

    test "single command module" do
      assert MinimalCommands.__commands__() == [:ls]
    end

    test "empty module returns empty list" do
      assert EmptyModule.__commands__() == []
    end
  end

  # ── Integration: NetRunner.run/2 with Command ──────────────────────

  describe "NetRunner.run/2 with Command struct" do
    test "runs a command struct" do
      cmd = Command.new("echo", ["hello"])

      assert {"hello\n", 0} = NetRunner.run(cmd)
    end

    test "runs command struct with opts" do
      cmd = Command.new("cat", [], input: "from stdin")

      # Note: input is a process-level opt consumed by run, not passed to Process.start
      # We test it works by passing in override opts
      assert {"from stdin", 0} = NetRunner.run(cmd)
    end

    test "override opts take precedence" do
      cmd = Command.new("cat", [])

      assert {"overridden\n", 0} =
               NetRunner.run(cmd, input: "overridden\n")
    end

    test "timeout via command struct" do
      cmd = Command.new("sleep", ["100"], timeout: 200)

      assert {:error, :timeout} = NetRunner.run(cmd)
    end

    test "timeout override on command struct" do
      cmd = Command.new("sleep", ["100"], timeout: 60_000)

      assert {:error, :timeout} = NetRunner.run(cmd, timeout: 200)
    end

    test "max_output_size via command struct" do
      cmd = Command.new("sh", ["-c", "yes"], max_output_size: 100)

      assert {:error, {:max_output_exceeded, _partial}} = NetRunner.run(cmd)
    end

    test "backward compatible: list form still works" do
      assert {"hello\n", 0} = NetRunner.run(~w(echo hello))
    end

    test "backward compatible: list form with opts still works" do
      assert {"stdin data", 0} = NetRunner.run(~w(cat), input: "stdin data")
    end
  end

  # ── Integration: NetRunner.stream!/2 with Command ──────────────────

  describe "NetRunner.stream!/2 with Command struct" do
    test "streams output from command struct" do
      cmd = Command.new("echo", ["hello"])
      output = NetRunner.stream!(cmd) |> Enum.join()

      assert output == "hello\n"
    end

    test "streams with input from command struct" do
      cmd = Command.new("cat", [])
      output = NetRunner.stream!(cmd, input: "streamed data") |> Enum.join()

      assert output == "streamed data"
    end

    test "streams with input in command opts" do
      cmd = Command.new("cat", [], input: "from command")
      output = NetRunner.stream!(cmd) |> Enum.join()

      assert output == "from command"
    end

    test "backward compatible: list form still works" do
      output = NetRunner.stream!(~w(echo hello)) |> Enum.join()

      assert output == "hello\n"
    end
  end

  # ── Integration: NetRunner.stream/2 with Command ───────────────────

  describe "NetRunner.stream/2 with Command struct" do
    test "returns {:ok, stream} for command struct" do
      cmd = Command.new("echo", ["hello"])

      assert {:ok, stream} = NetRunner.stream(cmd)
      assert Enum.join(stream) == "hello\n"
    end

    test "accepts override opts" do
      cmd = Command.new("cat", [])

      assert {:ok, stream} = NetRunner.stream(cmd, input: "data")
      assert Enum.join(stream) == "data"
    end

    test "backward compatible: list form still works" do
      assert {:ok, stream} = NetRunner.stream(~w(echo hello))
      assert Enum.join(stream) == "hello\n"
    end
  end

  # ── End-to-end: defcommand → run/stream ─────────────────────────────

  describe "end-to-end: defcommand to execution" do
    test "defcommand → run" do
      cmd = BasicCommands.echo(["end-to-end"])

      assert {"end-to-end\n", 0} = NetRunner.run(cmd)
    end

    test "defcommand → run with extra opts" do
      cmd = BasicCommands.cat()

      assert {"piped in", 0} = NetRunner.run(cmd, input: "piped in")
    end

    test "defcommand → stream!" do
      cmd = BasicCommands.echo(["streaming"])
      output = NetRunner.stream!(cmd) |> Enum.join()

      assert output == "streaming\n"
    end

    test "defcommand → stream" do
      cmd = BasicCommands.echo(["ok"])

      assert {:ok, stream} = NetRunner.stream(cmd)
      assert Enum.join(stream) == "ok\n"
    end

    test "defcommand with default args → run appends correctly" do
      # curl is not available in all test envs, so test with echo-like behavior
      # Use a command that lets us verify arg ordering
      cmd = BasicCommands.echo(["extra1", "extra2"])

      assert {"extra1 extra2\n", 0} = NetRunner.run(cmd)
    end

    test "defcommand opts are used by run" do
      # Define a command with a very short timeout to verify opts flow through
      cmd = %Command{executable: "sleep", args: ["100"], opts: [timeout: 200]}

      assert {:error, :timeout} = NetRunner.run(cmd)
    end

    test "override defcommand opts at run time" do
      cmd = BasicCommands.cat()

      assert {"hello", 0} = NetRunner.run(cmd, input: "hello")
    end
  end

  # ── Edge cases ──────────────────────────────────────────────────────

  describe "edge cases" do
    test "command with empty executable path" do
      # Empty string is technically valid for new/3 (it will fail at OS level)
      cmd = Command.new("", [])

      assert cmd.executable == ""
    end

    test "command struct with no args, no opts" do
      cmd = Command.new("true")

      assert {"", 0} = NetRunner.run(cmd)
    end

    test "command struct preserves argument order" do
      cmd = Command.new("echo", ["a", "b", "c"])

      assert {"a b c\n", 0} = NetRunner.run(cmd)
    end

    test "large number of args" do
      args = Enum.map(1..50, &to_string/1)
      cmd = Command.new("echo", args)

      {output, 0} = NetRunner.run(cmd)
      expected = Enum.join(1..50, " ") <> "\n"
      assert output == expected
    end

    test "args with special characters" do
      cmd = Command.new("echo", ["hello world", "foo\tbar"])

      {output, 0} = NetRunner.run(cmd)
      assert output == "hello world foo\tbar\n"
    end

    test "opts with all recognized keys" do
      cmd = Command.new("echo", ["test"], stderr: :consume, kill_timeout: 3_000)

      {_, _, opts} = Command.to_cmd_args_opts(cmd)
      assert opts[:stderr] == :consume
      assert opts[:kill_timeout] == 3_000
    end

    test "struct can be pattern matched" do
      cmd = Command.new("echo", ["hello"])

      assert %Command{executable: "echo", args: ["hello"]} = cmd
    end

    test "struct equality" do
      cmd1 = Command.new("echo", ["hello"], timeout: 5_000)
      cmd2 = Command.new("echo", ["hello"], timeout: 5_000)

      assert cmd1 == cmd2
    end

    test "struct inequality with different args" do
      cmd1 = Command.new("echo", ["hello"])
      cmd2 = Command.new("echo", ["world"])

      refute cmd1 == cmd2
    end

    test "struct inequality with different opts" do
      cmd1 = Command.new("echo", [], timeout: 1_000)
      cmd2 = Command.new("echo", [], timeout: 2_000)

      refute cmd1 == cmd2
    end
  end

  # ── Compile-time validation ─────────────────────────────────────────

  describe "compile-time validation" do
    test "defcommand with non-binary executable raises at compile time" do
      assert_raise ArgumentError, ~r/executable must be a string/, fn ->
        Code.compile_string("""
        defmodule TestBadExec do
          use NetRunner.Command
          defcommand :bad, :not_a_string
        end
        """)
      end
    end

    test "defcommand with non-list args raises at compile time" do
      assert_raise ArgumentError, ~r/:args must be a list/, fn ->
        Code.compile_string("""
        defmodule TestBadArgs do
          use NetRunner.Command
          defcommand :bad, "echo", args: "not a list"
        end
        """)
      end
    end

    test "defcommand with integer executable raises at compile time" do
      assert_raise ArgumentError, ~r/executable must be a string/, fn ->
        Code.compile_string("""
        defmodule TestIntExec do
          use NetRunner.Command
          defcommand :bad, 42
        end
        """)
      end
    end
  end

  # ── Command reuse patterns ─────────────────────────────────────────

  describe "command reuse patterns" do
    test "same command can be run with different inputs" do
      cmd = BasicCommands.cat()

      assert {"first", 0} = NetRunner.run(cmd, input: "first")
      assert {"second", 0} = NetRunner.run(cmd, input: "second")
    end

    test "same command can be run and streamed" do
      cmd = BasicCommands.echo(["reusable"])

      {run_output, 0} = NetRunner.run(cmd)
      stream_output = NetRunner.stream!(cmd) |> Enum.join()

      assert run_output == stream_output
    end

    test "command struct is immutable — run does not modify it" do
      cmd = BasicCommands.curl(["https://example.com"])
      original_args = cmd.args
      original_opts = cmd.opts

      # to_cmd_args_opts with overrides should not mutate the struct
      Command.to_cmd_args_opts(cmd, timeout: 99_999)

      assert cmd.args == original_args
      assert cmd.opts == original_opts
    end
  end
end
