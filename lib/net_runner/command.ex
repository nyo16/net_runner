defmodule NetRunner.Command do
  @moduledoc """
  Reusable command templates with default arguments and options.

  Define commands once, reuse them everywhere:

      defmodule MyApp.Commands do
        use NetRunner.Command

        defcommand :curl, "curl",
          args: ["-s", "--compressed", "-L"],
          timeout: 10_000

        defcommand :rg, "rg",
          args: ["--no-heading", "--color=never"],
          stderr: :consume
      end

      # Returns a %Command{} struct:
      cmd = MyApp.Commands.curl(["https://example.com"])

      # Pass to NetRunner API:
      NetRunner.run(cmd)
      NetRunner.run(cmd, timeout: 30_000)
      NetRunner.stream!(cmd)

      # Introspection:
      MyApp.Commands.__commands__()
      #=> [:curl, :rg]

  Commands can also be built at runtime without macros:

      cmd = NetRunner.Command.new("echo", ["hello"], timeout: 5_000)
      NetRunner.run(cmd)
  """

  @enforce_keys [:executable]
  defstruct [:executable, args: [], opts: []]

  @type t :: %__MODULE__{
          executable: String.t(),
          args: [String.t()],
          opts: keyword()
        }

  @doc """
  Creates a new command struct.

  ## Examples

      iex> NetRunner.Command.new("echo", ["hello"])
      %NetRunner.Command{executable: "echo", args: ["hello"], opts: []}

      iex> NetRunner.Command.new("curl", ["-s"], timeout: 10_000)
      %NetRunner.Command{executable: "curl", args: ["-s"], opts: [timeout: 10_000]}
  """
  @spec new(String.t(), [String.t()], keyword()) :: t()
  def new(executable, args \\ [], opts \\ []) do
    unless is_binary(executable) do
      raise ArgumentError, "executable must be a string, got: #{inspect(executable)}"
    end

    unless is_list(args) do
      raise ArgumentError, "args must be a list, got: #{inspect(args)}"
    end

    %__MODULE__{executable: executable, args: args, opts: opts}
  end

  @doc """
  Decomposes a command struct into `{executable, args, opts}`.

  Runtime `override_opts` are merged on top of the command's default opts,
  so callers can override specific options per invocation.

  ## Examples

      iex> cmd = NetRunner.Command.new("echo", ["hello"], timeout: 5_000)
      iex> NetRunner.Command.to_cmd_args_opts(cmd)
      {"echo", ["hello"], [timeout: 5_000]}

      iex> cmd = NetRunner.Command.new("echo", ["hello"], timeout: 5_000)
      iex> NetRunner.Command.to_cmd_args_opts(cmd, timeout: 30_000)
      {"echo", ["hello"], [timeout: 30_000]}
  """
  @spec to_cmd_args_opts(t(), keyword()) :: {String.t(), [String.t()], keyword()}
  def to_cmd_args_opts(%__MODULE__{} = command, override_opts \\ []) do
    {command.executable, command.args, Keyword.merge(command.opts, override_opts)}
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import NetRunner.Command, only: [defcommand: 2, defcommand: 3]
      Module.register_attribute(__MODULE__, :net_runner_commands, accumulate: true)
      @before_compile NetRunner.Command
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    commands = Module.get_attribute(env.module, :net_runner_commands) |> Enum.reverse()

    quote do
      @doc "Returns the list of command names defined in this module."
      @spec __commands__() :: [atom()]
      def __commands__, do: unquote(commands)
    end
  end

  @doc """
  Defines a reusable command template.

  Generates a function with the given `name` that returns a `%NetRunner.Command{}` struct.

  ## Options

    * `:args` - default arguments prepended to any extra args at call time
    * All other options (`:timeout`, `:stderr`, `:pty`, etc.) become default
      process options, overridable when passed to `NetRunner.run/2` et al.

  ## Examples

      defcommand :echo, "echo"

      defcommand :curl, "curl",
        args: ["-s", "--compressed"],
        timeout: 10_000

  The above generates:

      def curl(extra_args \\\\ [])

  So that:

      curl(["https://example.com"])
      #=> %NetRunner.Command{
      #=>   executable: "curl",
      #=>   args: ["-s", "--compressed", "https://example.com"],
      #=>   opts: [timeout: 10_000]
      #=> }
  """
  defmacro defcommand(name, executable, definition_opts \\ []) do
    quote bind_quoted: [name: name, executable: executable, definition_opts: definition_opts] do
      unless is_binary(executable) do
        raise ArgumentError,
              "defcommand executable must be a string, got: #{inspect(executable)}"
      end

      default_args = Keyword.get(definition_opts, :args, [])

      unless is_list(default_args) do
        raise ArgumentError, "defcommand :args must be a list, got: #{inspect(default_args)}"
      end

      default_opts = Keyword.drop(definition_opts, [:args])

      @net_runner_commands name

      @doc "Builds a `%NetRunner.Command{}` for `#{executable}` with optional extra args."
      @spec unquote(name)([String.t()]) :: NetRunner.Command.t()
      def unquote(name)(extra_args \\ []) do
        %NetRunner.Command{
          executable: unquote(executable),
          args: unquote(default_args) ++ extra_args,
          opts: unquote(Macro.escape(default_opts))
        }
      end
    end
  end
end
