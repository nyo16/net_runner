defmodule NetRunner.Process.Exec do
  @moduledoc false

  require Logger

  alias NetRunner.Nif
  alias NetRunner.Process.{Pipe, Protocol, State}

  @accept_timeout 10_000
  @uds_base_dir_key {__MODULE__, :uds_base_dir}
  # Upper bound on the retained stderr tail. Above this the "bounded
  # diagnostic tail" turns into an unbounded-ish per-process buffer.
  @stderr_tail_bytes_max 1_048_576

  # SIGTERM->SIGKILL escalation window forwarded to the shepherd as
  # --kill-timeout; the max mirrors shepherd.c's argv check.
  @default_kill_timeout_ms 5_000
  @kill_timeout_max_ms 60_000

  # Every NetRunner cgroup lives under this shared parent, which the shepherd
  # creates on demand and never tears down.
  @cgroup_prefix "net_runner/"
  @cgroup_prefix_warned_key {__MODULE__, :cgroup_prefix_warned}

  @doc """
  Spawns a new OS process via the shepherd binary.

  1. Creates a UDS listener with a temp path
  2. Opens the shepherd via Port.open with :nouse_stdio
  3. Accepts the shepherd's UDS connection
  4. Receives pipe FDs (plus, on Linux, the child's pidfd) via SCM_RIGHTS
  5. Receives MSG_CHILD_STARTED with the OS pid (the shepherd lets the child
     exec only after sending both)
  6. Wraps FDs in NIF resources

  Returns `{:ok, state}` or `{:error, reason}`.
  """
  def spawn_process(cmd, args, opts) do
    owner = self()
    uds_path = uds_socket_path()
    pty_mode = Keyword.get(opts, :pty, false)
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    result =
      with :ok <- validate_cmd_and_args(cmd, args),
           {:ok, listen_socket} <- create_uds_listener(uds_path),
           {:ok, shepherd_port} <- open_shepherd(uds_path, token, cmd, args, opts),
           shepherd_monitor = :erlang.monitor(:port, shepherd_port),
           {:ok, conn_socket} <-
             accept_authenticated(
               listen_socket,
               shepherd_port,
               shepherd_monitor,
               token,
               accept_deadline()
             ),
           :ok <- cleanup_listener(listen_socket, uds_path) do
        # conn_socket and shepherd_port are now live — clean up on any failure
        setup_after_connection(conn_socket, shepherd_port, owner, cmd, args, opts, pty_mode)
      end

    # On the happy path cleanup_listener removed the socket file. On any
    # failure (validation, accept timeout, ...) it may still exist — remove it
    # so spawns don't leak socket files in the shared base dir.
    case result do
      {:ok, _} = ok -> ok
      {:error, _} = err -> cleanup_uds_dir_passthrough(uds_path, err)
    end
  end

  defp accept_deadline, do: System.monotonic_time(:millisecond) + @accept_timeout

  # Accepts connections until one authenticates or the deadline expires. The
  # listener stays open across failed attempts: a rogue same-uid connect must
  # cost only that connection, not the whole spawn — the real shepherd's
  # queued connect is still served on the next accept. On final failure the
  # shepherd port is closed (the listener is closed by spawn_process's error
  # path via cleanup_listener never running — close it here too).
  defp accept_authenticated(listen_socket, shepherd_port, shepherd_monitor, token, deadline) do
    case accept_or_shepherd_exit(listen_socket, shepherd_port, shepherd_monitor, deadline) do
      {:ok, conn_socket} ->
        case authenticate_shepherd(conn_socket, token, deadline) do
          :ok ->
            Process.demonitor(shepherd_monitor, [:flush])
            {:ok, conn_socket}

          {:error, _} ->
            # Impostor (or a stalling peer): its socket is closed by
            # authenticate_shepherd; keep listening for the real shepherd.
            accept_authenticated(
              listen_socket,
              shepherd_port,
              shepherd_monitor,
              token,
              deadline
            )
        end

      {:error, reason} ->
        fail_accept(listen_socket, shepherd_port, shepherd_monitor, reason)
    end
  end

  # Use an asynchronous accept so socket readiness and port exit share one wait.
  defp accept_or_shepherd_exit(listen_socket, port, port_monitor, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :shepherd_connect_timeout}
    else
      case :socket.accept(listen_socket, :nowait) do
        {:ok, _conn} = ok ->
          ok

        {:select, select_info} ->
          await_connection(listen_socket, port, port_monitor, deadline, select_info)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp await_connection(listen_socket, port, port_monitor, deadline, select_info) do
    {:select_info, _tag, handle} = select_info
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:"$socket", ^listen_socket, :select, ^handle} ->
        accept_or_shepherd_exit(listen_socket, port, port_monitor, deadline)

      {:"$socket", ^listen_socket, :abort, {^handle, reason}} ->
        {:error, {:accept_aborted, reason}}

      {^port, {:exit_status, status}} ->
        cancel_select(listen_socket, select_info)

        shepherd_stopped(
          listen_socket,
          {port, {:exit_status, status}},
          {:exit_status, status}
        )

      {:DOWN, ^port_monitor, :port, ^port, reason} ->
        cancel_select(listen_socket, select_info)
        shepherd_stopped(listen_socket, nil, reason)
    after
      timeout ->
        cancel_select(listen_socket, select_info)
        {:error, :shepherd_connect_timeout}
    end
  end

  # Port exit and socket readiness come from different senders and can arrive
  # out of order. Check the listener before reporting a spawn failure. Requeue
  # the exit status if a connection is pending so Process can handle it.
  defp shepherd_stopped(listen_socket, pending_message, reason) do
    case :socket.accept(listen_socket, :nowait) do
      {:ok, _conn} = ok ->
        if pending_message, do: send(self(), pending_message)
        ok

      {:select, select_info} ->
        cancel_select(listen_socket, select_info)
        {:error, {:shepherd_spawn_failed, reason}}

      {:error, _reason} ->
        {:error, {:shepherd_spawn_failed, reason}}
    end
  end

  defp cancel_select(listen_socket, select_info) do
    :socket.cancel(listen_socket, select_info)
  catch
    _kind, _reason -> :ok
  end

  defp fail_accept(listen_socket, shepherd_port, shepherd_monitor, reason) do
    Process.demonitor(shepherd_monitor, [:flush])
    safe_close_socket(listen_socket)
    safe_port_close(shepherd_port)
    {:error, reason}
  end

  # The shepherd proves it is our spawnee (and not a same-uid process that
  # won the accept race) by echoing the per-spawn random token — delivered to
  # it over the private fd-3 port channel, never argv — as its very first
  # frame. Where the platform exposes peer credentials we additionally assert
  # the peer uid. Closes the connection on failure; the caller keeps
  # listening.
  defp authenticate_shepherd(conn_socket, token, deadline) do
    with :ok <- verify_peer_uid(conn_socket),
         :ok <- verify_token(conn_socket, token, deadline) do
      :ok
    else
      {:error, _} = error ->
        safe_close_socket(conn_socket)
        error
    end
  end

  defp verify_token(conn_socket, token, deadline) do
    # Bounded by the overall accept deadline: a peer that connects and then
    # stalls must not extend the spawn beyond @accept_timeout.
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case :socket.recv(conn_socket, byte_size(token), [], remaining) do
      {:ok, ^token} -> :ok
      {:ok, _other} -> {:error, :shepherd_auth_failed}
      {:error, reason} -> {:error, {:shepherd_auth_failed, reason}}
    end
  end

  # Best-effort: SO_PEERCRED (Linux) / equivalents are not uniformly exposed
  # by :socket, so an unsupported lookup passes — the token check above is the
  # load-bearing control on every platform.
  defp verify_peer_uid(conn_socket) do
    case peer_uid(conn_socket) do
      {:ok, uid} ->
        if uid == self_uid(),
          do: :ok,
          else: {:error, {:shepherd_auth_failed, {:peer_uid, uid}}}

      :unsupported ->
        :ok
    end
  end

  defp peer_uid(conn_socket) do
    case :socket.getopt(conn_socket, {:socket, :peercred}) do
      {:ok, %{uid: uid}} when is_integer(uid) -> {:ok, uid}
      _ -> :unsupported
    end
  catch
    _, _ -> :unsupported
  end

  defp cleanup_uds_dir(uds_path) do
    _ = File.rm(uds_path)
    :ok
  end

  defp cleanup_uds_dir_passthrough(uds_path, err) do
    cleanup_uds_dir(uds_path)
    err
  end

  # Reject NUL bytes in cmd/args early; passing them through Port.open's
  # args: option is undefined and could truncate a cmd string on the C side.
  defp validate_cmd_and_args(cmd, args) do
    cond do
      not is_binary(cmd) ->
        {:error, {:invalid_cmd, "must be a binary"}}

      cmd == "" ->
        {:error, {:invalid_cmd, "must not be empty"}}

      String.contains?(cmd, <<0>>) ->
        {:error, {:invalid_cmd, "must not contain NUL bytes"}}

      not is_list(args) ->
        {:error, {:invalid_args, "must be a list of binaries"}}

      Enum.any?(args, fn a -> not is_binary(a) or String.contains?(a, <<0>>) end) ->
        {:error, {:invalid_args, "each arg must be a binary without NUL bytes"}}

      true ->
        :ok
    end
  end

  defp setup_after_connection(conn_socket, shepherd_port, owner, cmd, args, opts, pty_mode) do
    case handshake(conn_socket, owner, pty_mode) do
      {:ok, os_pid, pipes, carry} ->
        {:ok,
         build_state(
           {conn_socket, shepherd_port},
           pipes,
           os_pid,
           carry,
           {cmd, args, opts, pty_mode}
         )}

      {:error, reason} ->
        safe_close_socket(conn_socket)
        safe_port_close(shepherd_port)
        {:error, reason}
    end
  end

  # Receives FDs, reads MSG_CHILD_STARTED and wraps the FDs in NIF resources.
  # Every step owns its cleanup: on failure no fd survives unwrapped.
  defp handshake(conn_socket, owner, pty_mode) do
    with {:ok, fds, iov_rest} <- receive_fds(conn_socket, pty_mode),
         {:ok, os_pid, carry} <- extract_started_or_close(conn_socket, iov_rest, fds),
         {:ok, pipes} <- wrap_fds(fds, owner, pty_mode) do
      {:ok, os_pid, pipes, carry}
    end
  end

  defp extract_started_or_close(conn_socket, iov_rest, fds) do
    case Protocol.extract_child_started(conn_socket, iov_rest, @accept_timeout) do
      {:ok, _os_pid, _carry} = ok ->
        ok

      {:error, _} = error ->
        # FDs were received but never wrapped — close them or they leak for
        # the lifetime of the VM.
        Enum.each(fds, &Nif.nif_close_fd/1)
        error
    end
  end

  defp build_state(
         {conn_socket, shepherd_port},
         pipes,
         os_pid,
         carry,
         {cmd, args, opts, pty_mode}
       ) do
    stderr_mode = if pty_mode, do: :disabled, else: Keyword.get(opts, :stderr, :consume)

    %State{
      shepherd_port: shepherd_port,
      uds_socket: conn_socket,
      stdin: pipes.stdin,
      stdout: pipes.stdout,
      stderr: pipes.stderr,
      pidfd: pipes.pidfd,
      os_pid: os_pid,
      cmd: cmd,
      args: args,
      stderr_mode: stderr_mode,
      stderr_tail_bytes: Keyword.get(opts, :stderr_tail_bytes, 8_192),
      uds_carry: carry,
      status: :running
    }
  end

  defp safe_port_close(port) when is_port(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  defp safe_close_socket(socket) do
    :socket.close(socket)
  catch
    _, _ -> :ok
  end

  @doc """
  Validates spawn option *values*, raising `ArgumentError` on any malformed
  one. Returns normalized `opts`: an unprefixed `:cgroup_path` is placed under
  `net_runner/` (deprecated until 2.0, when it will raise) and `:env` is put
  in its canonical list form.

  Called on the client by `NetRunner.Process.start/3` / `start_link/3`, so
  every entry point (`NetRunner.run/2`, `stream!/2`, `Daemon`, direct
  `Process.start/3`) shares one convention: malformed options are programmer
  errors and raise in the caller; `{:error, reason}` is reserved for runtime
  spawn failures.
  """
  @spec validate_opts!(keyword()) :: keyword()
  def validate_opts!(opts) do
    pty_mode = Keyword.get(opts, :pty, false)
    requested_cgroup_path = Keyword.get(opts, :cgroup_path, nil)
    opts = normalize_cgroup_path(opts)
    validate_stderr_mode!(Keyword.get(opts, :stderr, :consume), pty_mode)
    validate_stderr_tail_bytes!(Keyword.get(opts, :stderr_tail_bytes, 8_192))
    validate_cgroup_path!(Keyword.get(opts, :cgroup_path, nil))
    validate_kill_timeout!(Keyword.get(opts, :kill_timeout, @default_kill_timeout_ms))
    validate_cwd!(Keyword.get(opts, :cwd, nil))
    validate_no_new_privs!(Keyword.get(opts, :no_new_privs, false))
    environment = normalize_env!(Keyword.get(opts, :env, nil))
    warn_if_prefixed(requested_cgroup_path, Keyword.get(opts, :cgroup_path, nil))

    case environment do
      nil -> Keyword.delete(opts, :env)
      environment -> Keyword.put(opts, :env, environment)
    end
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

      byte_size(path) >= 256 ->
        raise ArgumentError, ":cgroup_path must be under 256 bytes"

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

  # Place the socket inside a 0700 directory so only the current user can
  # traverse to it. Without this the socket lives directly in the
  # world-traversable tmp dir, and a same-host attacker who wins the accept
  # race against the real shepherd would receive the child's pipe FDs via
  # SCM_RIGHTS. The 0700 dir reduces the threat to same-uid processes (which
  # are already inside our trust domain).
  #
  # The directory is created once per VM, not once per spawn. mkdir, chmod and
  # the matching rmdir are file syscalls on a dirty IO scheduler; paying them
  # per spawn accounted for roughly half of the measured spawn latency. Do NOT
  # "simplify" this by chmod-ing the socket file instead of using a directory —
  # that reopens a bind->chmod window in which the socket is world-accessible.
  defp uds_socket_path do
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Path.join(uds_base_dir(), "#{random}.sock")
  end

  defp uds_base_dir do
    case :persistent_term.get(@uds_base_dir_key, nil) do
      {dir, uid} when is_binary(dir) ->
        # A tmp reaper can remove the directory under a long-lived VM (and an
        # attacker could recreate it), so the memoised path is re-verified —
        # right owner, right mode, a real directory — rather than trusted.
        if private_dir?(dir, uid), do: dir, else: create_uds_base_dir()

      nil ->
        create_uds_base_dir()
    end
  end

  # Raw mkdir(dir, 0700) via NIF: the directory is never observable with
  # wider permissions (File.mkdir_p! + File.chmod! left a window), and a
  # pre-existing directory — whoever owns it — is never adopted (:eexist
  # retries under a fresh random name).
  defp create_uds_base_dir(attempts \\ 3)

  defp create_uds_base_dir(0) do
    raise "NetRunner: could not create a private UDS base directory in #{System.tmp_dir!()}"
  end

  defp create_uds_base_dir(attempts) do
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    # Expanded: a relative TMPDIR would yield a relative socket path, which
    # the shepherd rejects (it must connect to an absolute uds_path).
    dir = Path.join(Path.expand(System.tmp_dir!()), "net_runner_#{random}")

    case Nif.nif_mkdir_private(dir) do
      :ok ->
        case File.lstat(dir) do
          {:ok, %File.Stat{type: :directory, mode: mode, uid: uid}}
          when Bitwise.band(mode, 0o7777) == 0o700 ->
            # Two concurrent first spawns can both create a directory; the
            # loser's is left empty and harmless. Writing here once per VM
            # keeps the persistent_term global GC off the spawn path. The uid
            # is ours by construction (we just created the dir) and doubles as
            # the reference for peer-credential checks.
            :persistent_term.put(@uds_base_dir_key, {dir, uid})
            dir

          _ ->
            create_uds_base_dir(attempts - 1)
        end

      {:error, :eexist} ->
        create_uds_base_dir(attempts - 1)

      {:error, reason} ->
        raise "NetRunner: failed to create UDS base dir #{dir}: #{inspect(reason)}"
    end
  end

  defp private_dir?(dir, uid) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode, uid: ^uid}} ->
        Bitwise.band(mode, 0o7777) == 0o700

      _ ->
        false
    end
  end

  defp self_uid do
    {_dir, uid} = :persistent_term.get(@uds_base_dir_key)
    uid
  end

  defp create_uds_listener(path) do
    addr = %{family: :local, path: path}

    with {:ok, socket} <- :socket.open(:local, :stream, :default),
         :ok <- :socket.bind(socket, addr),
         :ok <- :socket.listen(socket) do
      {:ok, socket}
    else
      {:error, _} = error ->
        error
    end
  end

  defp open_shepherd(uds_path, token, cmd, args, opts) do
    shepherd = shepherd_executable()
    kill_timeout = Keyword.get(opts, :kill_timeout, @default_kill_timeout_ms)
    pty_mode = Keyword.get(opts, :pty, false)

    cgroup_path = Keyword.get(opts, :cgroup_path, nil)
    cwd = Keyword.get(opts, :cwd, nil)

    # --token-fd, not --token <hex>: argv is world-readable via
    # /proc/<pid>/cmdline (Linux) and same-uid readable via KERN_PROCARGS2
    # (macOS), which is exactly the attacker the token exists to stop. The
    # token travels over the private fd-3 port channel instead.
    shepherd_flags = ["--kill-timeout", to_string(kill_timeout), "--token-fd"]
    shepherd_flags = if pty_mode, do: shepherd_flags ++ ["--pty"], else: shepherd_flags

    shepherd_flags =
      if cgroup_path,
        do: shepherd_flags ++ ["--cgroup-path", cgroup_path],
        else: shepherd_flags

    shepherd_flags = if cwd, do: shepherd_flags ++ ["--cwd", cwd], else: shepherd_flags

    # Linux-only in the shepherd (prctl(PR_SET_NO_NEW_PRIVS) before exec);
    # accepted and ignored on other platforms.
    shepherd_flags =
      if Keyword.get(opts, :no_new_privs, false),
        do: shepherd_flags ++ ["--no-new-privs"],
        else: shepherd_flags

    {environment_flags, port_environment} =
      environment_options(Keyword.get(opts, :env, nil))

    # "--" ends shepherd option parsing: a cmd beginning with "-" must reach
    # execvp verbatim, never be read as a shepherd flag (--cgroup-path,
    # --kill-timeout, --pty, --cwd, --replace-env, --no-new-privs).
    port_args = [uds_path | shepherd_flags ++ environment_flags] ++ ["--", cmd | args]

    port_opts = [
      :nouse_stdio,
      :exit_status,
      :binary,
      args: port_args
    ]

    port_opts = if port_environment, do: [{:env, port_environment} | port_opts], else: port_opts

    # Port.open raises (e.g. shepherd binary missing from priv). Convert to a
    # value so spawn_process's error path still reclaims the listener and the
    # bound socket file.
    port = Port.open({:spawn_executable, shepherd}, port_opts)

    # The token write races a shepherd that failed to exec: the port then dies
    # with :epipe, and as a linked exit signal that would kill this
    # (non-trapping) process. So the port stays unlinked. If this process is
    # killed, the shepherd sees its UDS hang up and tears down; if it is
    # killed before the token is written, the shepherd's bounded token read
    # (TOKEN_READ_TIMEOUT_MS) makes it exit instead of blocking on fd 3.
    Process.unlink(port)
    send_token(port, token)
    {:ok, port}
  rescue
    e -> {:error, {:shepherd_spawn_failed, Exception.message(e)}}
  end

  defp send_token(port, token) do
    Port.command(port, token)
    :ok
  catch
    # Port already dead (spawn raced its own failure): the port monitor in
    # accept_or_shepherd_exit/4 reports {:shepherd_spawn_failed, _} promptly.
    :error, :badarg -> :ok
  end

  # The port interprets env charlists in the VM's native filename encoding:
  # under :utf8 each element is a codepoint, under :latin1 each element is one
  # byte. Byte lists on a UTF-8 VM double-encode non-ASCII text (`é` arrives as
  # c3 83 c2 a9); codepoint lists on a latin1 VM corrupt it (`é` arrives as
  # e9) or raise above U+00FF. Either way the child gets the binary's bytes.
  defp format_env(env) do
    Enum.map(env, fn
      {name, nil} -> {env_chars(name), false}
      {name, value} -> {env_chars(name), env_chars(value)}
    end)
  end

  defp env_chars(binary) do
    case :file.native_name_encoding() do
      :utf8 -> String.to_charlist(binary)
      :latin1 -> :binary.bin_to_list(binary)
    end
  end

  defp environment_options(nil), do: {[], nil}

  # Replacement mode uses two layers. The shepherd's --replace-env allowlist
  # is authoritative for the child: it drops every name outside the selection
  # just before fork, so the result does not depend on timing. In addition,
  # every variable in an :os.env/0 snapshot that the caller did not select is
  # unset (`false`) in the port environment, so the shepherd itself normally
  # never holds ambient values such as RELEASE_COOKIE. A variable put into the
  # BEAM environment between the snapshot and Port.open reaches the shepherd
  # but is still filtered out of the child.
  defp environment_options({:replace, environment}) do
    selected = format_env(environment)
    selected_names = MapSet.new(selected, fn {name, _value} -> name end)

    unset =
      for {name, _value} <- :os.env(), not MapSet.member?(selected_names, name), do: {name, false}

    kept_names = for {name, value} <- environment, value != nil, do: name
    flags = ["--replace-env", Integer.to_string(length(kept_names)) | kept_names]
    {flags, unset ++ selected}
  end

  defp environment_options(environment), do: {[], format_env(environment)}

  defp shepherd_executable do
    app_dir = :code.priv_dir(:net_runner)
    Path.join(to_string(app_dir), "shepherd")
  end

  defp cleanup_listener(listen_socket, path) do
    :socket.close(listen_socket)

    case File.rm(path) do
      result when result in [:ok, {:error, :enoent}] ->
        :ok

      {:error, reason} ->
        {:error, {:uds_path_cleanup_failed, reason}}
    end
  end

  @doc """
  Receives file descriptors via SCM_RIGHTS.

  In pipe mode: 3 FDs (stdin_w, stdout_r, stderr_r).
  In PTY mode: 1 FD (bidirectional master).

  On Linux the shepherd appends the child's pidfd as an optional trailing
  fd, so 4 (pipe) or 2 (PTY) are accepted as well.

  Returns `{:ok, fds, iov_rest}`.
  """
  def receive_fds(socket, pty_mode \\ false) do
    case :socket.recvmsg(socket, 0, 0, [], @accept_timeout) do
      {:ok, %{ctrl: ctrl, iov: iov}} ->
        fds = extract_fds_from_ctrl(ctrl)
        iov_data = IO.iodata_to_binary(iov)

        iov_rest =
          if byte_size(iov_data) > 0,
            do: binary_part(iov_data, 1, byte_size(iov_data) - 1),
            else: <<>>

        base = io_fd_count(pty_mode)

        if length(fds) in [base, base + 1] do
          {:ok, fds, iov_rest}
        else
          handle_fd_count_mismatch(socket, fds, iov_data)
        end

      {:error, reason} ->
        {:error, {:recvmsg_failed, reason}}
    end
  end

  # Whatever arrived is unusable but real — close it or it leaks. Every
  # pre-send_fds shepherd failure ("cgroup setup failed", "fork failed", ...)
  # sends a bare MSG_ERROR frame in place of the SCM_RIGHTS filler byte, so
  # the raw iov starts the frame. Surface that diagnostic instead of a
  # misleading fd-count mismatch.
  defp handle_fd_count_mismatch(socket, fds, iov_data) do
    Enum.each(fds, &Nif.nif_close_fd/1)

    case Protocol.recv_shepherd_error(socket, iov_data, @accept_timeout) do
      {:ok, msg} -> {:error, {:shepherd_error, msg}}
      :no_error -> {:error, {:unexpected_fd_count, length(fds)}}
    end
  end

  defp io_fd_count(true), do: 1
  defp io_fd_count(false), do: 3

  # On any failure every fd handed in is released: wrapped ones through their
  # NIF resource, unwrapped ones via nif_close_fd. nif_create_fd's contract is
  # that on error the caller retains ownership of the raw fd.
  defp wrap_fds(fds, owner, pty_mode) do
    {io_fds, pidfd_fd} = split_pidfd(fds, pty_mode)

    case wrap_io_fds(io_fds, owner, pty_mode) do
      {:ok, pipes} ->
        {:ok, Map.put(pipes, :pidfd, wrap_pidfd(pidfd_fd, owner))}

      {:error, _} = error ->
        if pidfd_fd, do: Nif.nif_close_fd(pidfd_fd)
        error
    end
  end

  # The pidfd, when present, is always the last fd of the SCM_RIGHTS message.
  defp split_pidfd(fds, pty_mode) do
    case Enum.split(fds, io_fd_count(pty_mode)) do
      {io_fds, [pidfd_fd]} -> {io_fds, pidfd_fd}
      {io_fds, []} -> {io_fds, nil}
    end
  end

  # The pidfd is an optimisation (race-free direct kill), not a requirement:
  # if it cannot be wrapped, close it and carry on without one.
  defp wrap_pidfd(nil, _owner), do: nil

  defp wrap_pidfd(fd, owner) do
    case Pipe.new(fd, owner) do
      {:ok, pipe} ->
        pipe

      {:error, _} ->
        Nif.nif_close_fd(fd)
        nil
    end
  end

  defp wrap_io_fds([stdin_fd, stdout_fd, stderr_fd], owner, false) do
    with {:ok, stdin} <- wrap_or_close(stdin_fd, owner, [], [stdout_fd, stderr_fd]),
         {:ok, stdout} <- wrap_or_close(stdout_fd, owner, [stdin], [stderr_fd]),
         {:ok, stderr} <- wrap_or_close(stderr_fd, owner, [stdin, stdout], []) do
      {:ok, %{stdin: stdin, stdout: stdout, stderr: stderr}}
    end
  end

  defp wrap_io_fds([master_fd], owner, true) do
    # PTY: single bidirectional FD. Dup it so stdin and stdout
    # have independent NIF resources that can be closed separately.
    with {:ok, write_fd} <- dup_or_close(master_fd),
         {:ok, stdout} <- wrap_or_close(master_fd, owner, [], [write_fd]),
         {:ok, stdin} <- wrap_or_close(write_fd, owner, [stdout], []) do
      {:ok, %{stdin: stdin, stdout: stdout, stderr: nil}}
    end
  end

  # Wraps `fd`; on failure releases *everything* — already-wrapped pipes via
  # their NIF resource, `fd` and the still-raw fds via nif_close_fd — so
  # wrap_io_fds's on-error contract (no fd survives) holds at every step.
  # nif_create_fd's contract is that on error the caller retains ownership
  # of the raw fd.
  defp wrap_or_close(fd, owner, wrapped_pipes, raw_fds) do
    case Pipe.new(fd, owner) do
      {:ok, _pipe} = ok ->
        ok

      {:error, _} = error ->
        Enum.each(wrapped_pipes, &Pipe.close/1)
        Enum.each([fd | raw_fds], &Nif.nif_close_fd/1)
        error
    end
  end

  defp dup_or_close(master_fd) do
    case Nif.nif_dup_fd(master_fd) do
      {:ok, _write_fd} = ok ->
        ok

      {:error, _} = error ->
        Nif.nif_close_fd(master_fd)
        error
    end
  end

  # FDs come as raw binary: native-endian 32-bit ints
  defp extract_fds_from_ctrl(ctrl_msgs) do
    Enum.flat_map(ctrl_msgs, fn
      %{type: :rights, data: fds} when is_list(fds) ->
        fds

      %{type: :rights, data: bin} when is_binary(bin) ->
        decode_native_int32s(bin)

      _ ->
        []
    end)
  end

  defp decode_native_int32s(<<fd::native-signed-32, rest::binary>>) do
    [fd | decode_native_int32s(rest)]
  end

  defp decode_native_int32s(<<>>), do: []
end
