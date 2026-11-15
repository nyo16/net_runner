defmodule NetRunner.Process.Options do
  @moduledoc false

  # The spawn-option contract shared by every entry point (run/2, stream/2,
  # Daemon, Process.start/3): which keys exist, which values are valid, and
  # how :cgroup_path and :env are normalised. Validation raises ArgumentError
  # in the caller; {:error, reason} is reserved for runtime spawn failures.

  require Logger

  # Every option a spawned process understands. Unknown keys raise up front
  # (Keyword.validate!) instead of being silently ignored — a misspelt
  # :stderr_tail_byte or a run/2-level :timeout must not pass unnoticed.
  # :write_budget and :stderr_drain_chunks are test hooks (NetRunner.Process).
  @process_opts [
    :name,
    :owner,
    :pty,
    :stderr,
    :stderr_tail_bytes,
    :cgroup_path,
    :kill_timeout,
    :cwd,
    :env,
    :no_new_privs,
    :pipe_size,
    :write_budget,
    :stderr_drain_chunks
  ]

  # Upper bound on the retained stderr tail. Above this the "bounded
  # diagnostic tail" turns into an unbounded-ish per-process buffer.
  @stderr_tail_bytes_max 1_048_576

  # SIGTERM->SIGKILL escalation window forwarded to the shepherd as
  # --kill-timeout. The max mirrors shepherd.c's argv check; a contract test
  # pins it against the real shepherd (options_contract_test.exs).
  @default_kill_timeout_ms 5_000
  @kill_timeout_max_ms 60_000

  # cgroup paths are carried in a CGROUP_PATH_MAX (256) byte buffer in the
  # shepherd, NUL included; also pinned by the contract test.
  @cgroup_path_max_bytes 255

  # Every NetRunner cgroup lives under this shared parent, which the shepherd
  # creates on demand and never tears down.
  @cgroup_prefix "net_runner/"
  @cgroup_prefix_warned_key {__MODULE__, :cgroup_prefix_warned}

  @doc "The default `:kill_timeout`, in ms (also run/2's SIGTERM grace)."
  @spec default_kill_timeout() :: pos_integer()
  def default_kill_timeout, do: @default_kill_timeout_ms

  @doc false
  @spec kill_timeout_max() :: pos_integer()
  def kill_timeout_max, do: @kill_timeout_max_ms

  @doc false
  @spec cgroup_path_max_bytes() :: pos_integer()
  def cgroup_path_max_bytes, do: @cgroup_path_max_bytes

  @doc """
  Validates spawn option keys and values, raising `ArgumentError` on an
  unknown key or a malformed value. Returns normalized `opts`: an unprefixed
  `:cgroup_path` is placed under `net_runner/` (deprecated until 2.0, when it
  will raise) and `:env` is put in its canonical list form.
  """
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) do
    opts
    |> Keyword.validate!(@process_opts)
    |> validate_values!()
  end

  defp validate_values!(opts) do
    pty_mode = Keyword.get(opts, :pty, false)
    requested_cgroup_path = Keyword.get(opts, :cgroup_path, nil)
    opts = normalize_cgroup_path(opts)
    validate_stderr_mode!(Keyword.get(opts, :stderr, :consume), pty_mode)
    validate_stderr_tail_bytes!(Keyword.get(opts, :stderr_tail_bytes, 8_192))
    validate_cgroup_path!(Keyword.get(opts, :cgroup_path, nil))
    validate_kill_timeout!(Keyword.get(opts, :kill_timeout, @default_kill_timeout_ms))
    validate_cwd!(Keyword.get(opts, :cwd, nil))
    validate_no_new_privs!(Keyword.get(opts, :no_new_privs, false))
    validate_pipe_size!(Keyword.get(opts, :pipe_size, :grown))
    validate_budget!(:write_budget, Keyword.get(opts, :write_budget))
    validate_budget!(:stderr_drain_chunks, Keyword.get(opts, :stderr_drain_chunks))
    environment = normalize_env!(Keyword.get(opts, :env, nil))
    require_linux_for_isolation!(opts)
    warn_if_prefixed(requested_cgroup_path, Keyword.get(opts, :cgroup_path, nil))

    case environment do
      nil -> Keyword.delete(opts, :env)
      environment -> Keyword.put(opts, :env, environment)
    end
  end

  # Isolation the caller explicitly asked for must not silently degrade:
  # cgroups and PR_SET_NO_NEW_PRIVS exist only on Linux, and an unconfined
  # child is worse than a failed spawn (the shepherd's own policy for a
  # cgroup it cannot set up). Runs after every shape check, so a malformed
  # value reports the same error on every platform.
  defp require_linux_for_isolation!(opts) do
    if :os.type() != {:unix, :linux} do
      if Keyword.get(opts, :cgroup_path) do
        raise ArgumentError, ":cgroup_path requires Linux (cgroup v2); got #{inspect(:os.type())}"
      end

      if Keyword.get(opts, :no_new_privs, false) do
        raise ArgumentError, "no_new_privs: true requires Linux; got #{inspect(:os.type())}"
      end
    end

    :ok
  end

  # :grown (default) lets the shepherd grow the Linux pipes (stdout 1 MiB,
  # stdin/stderr 256 KiB: 384 pages of the uid's pipe budget for the pipes'
  # lifetime); :default keeps the kernel's 64 KiB. No effect off Linux.
  defp validate_pipe_size!(mode) when mode in [:grown, :default], do: :ok

  defp validate_pipe_size!(mode) do
    raise ArgumentError, ":pipe_size must be :grown or :default, got: #{inspect(mode)}"
  end

  # 1.3.x accepted any relative :cgroup_path; 1.4.0 started requiring the
  # net_runner/ prefix and raised otherwise, which broke callers within a
  # minor version. Until 2.0 an unprefixed path is placed under the prefix
  # instead. Absolute and empty paths are left alone so
  # validate_cgroup_path!/1 rejects them with the usual message.
  defp normalize_cgroup_path(opts) do
    case Keyword.get(opts, :cgroup_path) do
      path when is_binary(path) and path != "" ->
        if String.starts_with?(path, [@cgroup_prefix, "/"]),
          do: opts,
          else: Keyword.put(opts, :cgroup_path, @cgroup_prefix <> path)

      _ ->
        opts
    end
  end

  # Logged once per VM, and only for a path that passed validation, so an
  # options error never consumes the one deprecation notice.
  defp warn_if_prefixed(same, same), do: :ok

  defp warn_if_prefixed(requested, prefixed) do
    if not :persistent_term.get(@cgroup_prefix_warned_key, false) do
      :persistent_term.put(@cgroup_prefix_warned_key, true)

      Logger.warning(
        "[NetRunner] :cgroup_path #{inspect(requested)} has no #{@cgroup_prefix} prefix; " <>
          "using #{inspect(prefixed)}. Unprefixed paths are deprecated and will " <>
          "raise in 2.0. (Logged once per VM.)"
      )
    end
  end

  # Mirrors the shepherd's own --kill-timeout check (1..60000). Anything else
  # makes the shepherd exit before it ever connects; the caller would get a
  # bare {:shepherd_spawn_failed, {:exit_status, 1}} with the real reason only
  # on the VM's stderr — so reject it here with a message the caller can read.
  defp validate_kill_timeout!(ms) when is_integer(ms) and ms in 1..@kill_timeout_max_ms, do: :ok

  defp validate_kill_timeout!(ms) do
    raise ArgumentError,
          ":kill_timeout must be an integer in 1..#{@kill_timeout_max_ms} (ms), " <>
            "got: #{inspect(ms)}"
  end

  # In PTY mode stderr is folded into the bidirectional master FD, so the
  # :stderr option is ignored. In pipe mode only :consume (drained internally
  # to avoid blocking the child on a full pipe) and :disabled are supported.
  defp validate_stderr_mode!(_mode, true), do: :ok
  defp validate_stderr_mode!(mode, false) when mode in [:consume, :disabled], do: :ok

  defp validate_stderr_mode!(mode, false) do
    raise ArgumentError, ":stderr must be :consume or :disabled, got: #{inspect(mode)}"
  end

  # The bounded stderr tail cap. 0 disables retention (drain-and-drop) while
  # still draining the pipe so the child never blocks. Capped above so callers
  # cannot turn the diagnostic tail into an unbounded buffer.
  defp validate_stderr_tail_bytes!(bytes)
       when is_integer(bytes) and bytes >= 0 and bytes <= @stderr_tail_bytes_max,
       do: :ok

  defp validate_stderr_tail_bytes!(bytes) do
    raise ArgumentError,
          ":stderr_tail_bytes must be an integer in 0..#{@stderr_tail_bytes_max}, " <>
            "got: #{inspect(bytes)}"
  end

  defp normalize_env!(nil), do: nil

  defp normalize_env!({:replace, environment}) do
    {:replace, normalize_environment!(environment)}
  end

  defp normalize_env!({tag, _environment}) when is_atom(tag) do
    raise ArgumentError,
          ":env got #{inspect(tag)}, which is not an environment mode; " <>
            "the only tagged form is {:replace, environment}"
  end

  defp normalize_env!(env), do: normalize_environment!(env)

  defp normalize_environment!(environment)
       when is_map(environment) and not is_struct(environment) do
    normalize_env_entries!(Map.to_list(environment), %{})
  end

  defp normalize_environment!(environment) when is_list(environment) do
    normalize_env_entries!(environment, %{})
  end

  defp normalize_environment!(environment) do
    raise ArgumentError,
          ":env must be a map or a list of {name, value} pairs, got #{env_shape(environment)}"
  end

  defp normalize_env_entries!([], environment), do: Map.to_list(environment)

  defp normalize_env_entries!([{k, v} | rest], environment)
       when is_binary(k) and (is_binary(v) or is_nil(v)) do
    validate_env_name!(k)
    validate_env_value!(k, v)
    value = if v == "", do: nil, else: v
    normalize_env_entries!(rest, Map.put(environment, k, value))
  end

  defp normalize_env_entries!([{k, _v} | _rest], _environment) do
    raise ArgumentError,
          ":env entry #{inspect(k)} must map a binary name to a binary or nil"
  end

  defp normalize_env_entries!([other | _rest], _environment) do
    raise ArgumentError, ":env entry must be a {name, value} pair, got #{env_shape(other)}"
  end

  defp normalize_env_entries!(tail, _environment) do
    raise ArgumentError, ":env must be a proper list, got an improper tail: #{env_shape(tail)}"
  end

  # Describes a malformed :env term without echoing it. Environment values
  # are often secrets, and ArgumentError messages end up in logs and crash
  # reports; names are shown (via inspect) elsewhere, values never.
  defp env_shape(term) when is_struct(term), do: "a %#{inspect(term.__struct__)}{} struct"
  defp env_shape(term) when is_tuple(term), do: "a #{tuple_size(term)}-tuple"
  defp env_shape(term) when is_binary(term), do: "a binary"
  defp env_shape(term) when is_list(term), do: "a list"
  defp env_shape(term) when is_map(term), do: "a map"
  defp env_shape(term) when is_atom(term), do: inspect(term)
  defp env_shape(term) when is_number(term), do: "a number"
  defp env_shape(_term), do: "an unsupported term"

  defp validate_env_name!(name) do
    cond do
      name == "" or String.contains?(name, ["=", <<0>>]) ->
        raise ArgumentError, ":env has an invalid variable name: #{inspect(name)}"

      not String.valid?(name) ->
        raise ArgumentError, ":env variable name #{inspect(name)} must be UTF-8 text"

      true ->
        :ok
    end
  end

  defp validate_env_value!(_name, nil), do: :ok

  defp validate_env_value!(name, value) do
    cond do
      String.contains?(value, <<0>>) ->
        raise ArgumentError, ":env value for #{inspect(name)} must not contain NUL bytes"

      not String.valid?(value) ->
        raise ArgumentError, ":env value for #{inspect(name)} must be UTF-8 text"

      true ->
        :ok
    end
  end

  defp validate_cgroup_path!(nil), do: :ok

  defp validate_cgroup_path!(path) when is_binary(path) do
    cond do
      String.contains?(path, <<0>>) ->
        raise ArgumentError, ":cgroup_path must not contain NUL bytes"

      String.starts_with?(path, "/") ->
        raise ArgumentError, ":cgroup_path must be relative, got: #{path}"

      String.contains?(path, "..") ->
        raise ArgumentError, ":cgroup_path cannot contain '..', got: #{path}"

      byte_size(path) > @cgroup_path_max_bytes ->
        raise ArgumentError, ":cgroup_path must be under #{@cgroup_path_max_bytes + 1} bytes"

      not String.starts_with?(path, @cgroup_prefix) or path == @cgroup_prefix ->
        raise ArgumentError,
              ":cgroup_path must name a cgroup under #{@cgroup_prefix}, got: #{inspect(path)}"

      true ->
        :ok
    end
  end

  defp validate_cgroup_path!(path) do
    raise ArgumentError, ":cgroup_path must be a binary, got: #{inspect(path)}"
  end

  defp validate_no_new_privs!(value) when is_boolean(value), do: :ok

  defp validate_no_new_privs!(value) do
    raise ArgumentError, ":no_new_privs must be a boolean, got: #{inspect(value)}"
  end

  # Test hooks (:write_budget, :stderr_drain_chunks): a budget below 1 would
  # never make progress.
  defp validate_budget!(_key, nil), do: :ok
  defp validate_budget!(_key, n) when is_integer(n) and n >= 1, do: :ok

  defp validate_budget!(key, value) do
    raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_cwd!(nil), do: :ok

  defp validate_cwd!(cwd) when is_binary(cwd) do
    cond do
      cwd == "" ->
        raise ArgumentError, ":cwd must not be empty"

      String.contains?(cwd, <<0>>) ->
        raise ArgumentError, ":cwd must not contain NUL bytes"

      true ->
        :ok
    end
  end

  defp validate_cwd!(other) do
    raise ArgumentError, ":cwd must be a binary, got: #{inspect(other)}"
  end
end
