defmodule NetRunner.Process.Exec do
  @moduledoc false

  alias NetRunner.Process.{Nif, Pipe, State}

  @accept_timeout 10_000
  @msg_child_started 0x80
  @msg_child_exited 0x81
  @msg_error 0x82
  @uds_base_dir_key {__MODULE__, :uds_base_dir}
  # Upper bound on the retained stderr tail. Above this the "bounded
  # diagnostic tail" turns into an unbounded-ish per-process buffer.
  @stderr_tail_bytes_max 1_048_576

  @doc """
  Spawns a new OS process via the shepherd binary.

  1. Creates a UDS listener with a temp path
  2. Opens the shepherd via Port.open with :nouse_stdio
  3. Accepts the shepherd's UDS connection
  4. Receives pipe FDs via SCM_RIGHTS
  5. Receives MSG_CHILD_STARTED with the OS pid
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
           :ok <- validate_stderr_mode(Keyword.get(opts, :stderr, :consume), pty_mode),
           :ok <- validate_stderr_tail_bytes(Keyword.get(opts, :stderr_tail_bytes, 8_192)),
           :ok <- validate_cgroup_path(Keyword.get(opts, :cgroup_path, nil)),
           :ok <- validate_env(Keyword.get(opts, :env, nil)),
           {:ok, listen_socket} <- create_uds_listener(uds_path),
           {:ok, shepherd_port} <- open_shepherd(uds_path, token, cmd, args, opts),
           {:ok, conn_socket} <-
             accept_authenticated(listen_socket, shepherd_port, token, accept_deadline()),
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
  defp accept_authenticated(listen_socket, shepherd_port, token, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, conn_socket} <- :socket.accept(listen_socket, remaining) do
      case authenticate_shepherd(conn_socket, token, deadline) do
        :ok ->
          {:ok, conn_socket}

        {:error, _} ->
          # Impostor (or a stalling peer): its socket is closed by
          # authenticate_shepherd; keep listening for the real shepherd.
          accept_authenticated(listen_socket, shepherd_port, token, deadline)
      end
    else
      false ->
        fail_accept(listen_socket, shepherd_port, :shepherd_connect_timeout)

      {:error, :timeout} ->
        fail_accept(listen_socket, shepherd_port, :shepherd_connect_timeout)

      {:error, reason} ->
        fail_accept(listen_socket, shepherd_port, reason)
    end
  end

  defp fail_accept(listen_socket, shepherd_port, reason) do
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
    case extract_child_started(conn_socket, iov_rest) do
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

  # In PTY mode stderr is folded into the bidirectional master FD, so the
  # :stderr option is ignored. In pipe mode only :consume (drained internally
  # to avoid blocking the child on a full pipe) and :disabled are supported.
  defp validate_stderr_mode(_mode, true), do: :ok
  defp validate_stderr_mode(mode, false) when mode in [:consume, :disabled], do: :ok

  defp validate_stderr_mode(mode, false) do
    {:error, {:invalid_stderr, "must be :consume or :disabled, got: #{inspect(mode)}"}}
  end

  # The bounded stderr tail cap. 0 disables retention (drain-and-drop) while
  # still draining the pipe so the child never blocks. Capped above so callers
  # cannot turn the diagnostic tail into an unbounded buffer.
  defp validate_stderr_tail_bytes(bytes)
       when is_integer(bytes) and bytes >= 0 and bytes <= @stderr_tail_bytes_max,
       do: :ok

  defp validate_stderr_tail_bytes(bytes) do
    {:error,
     {:invalid_stderr_tail_bytes,
      "must be an integer in 0..#{@stderr_tail_bytes_max}, got: #{inspect(bytes)}"}}
  end

  # Optional :env map: name => value sets, name => nil unsets. Names/values
  # travel through Port.open's env: option as charlists; reject shapes that
  # would corrupt the environment block.
  defp validate_env(nil), do: :ok

  defp validate_env(env) when is_map(env) do
    Enum.find_value(env, :ok, fn
      {k, v} when is_binary(k) and (is_binary(v) or is_nil(v)) ->
        cond do
          k == "" or String.contains?(k, ["=", <<0>>]) ->
            {:error, {:invalid_env, "invalid variable name: #{inspect(k)}"}}

          is_binary(v) and String.contains?(v, <<0>>) ->
            {:error, {:invalid_env, "value for #{k} must not contain NUL bytes"}}

          true ->
            nil
        end

      {k, _v} ->
        {:error, {:invalid_env, "entry #{inspect(k)} must map a binary name to a binary or nil"}}
    end)
  end

  defp validate_env(env) do
    {:error, {:invalid_env, "must be a map of names to binaries or nil, got: #{inspect(env)}"}}
  end

  defp validate_cgroup_path(nil), do: :ok

  defp validate_cgroup_path(path) do
    path_str = to_string(path)

    cond do
      String.starts_with?(path_str, "/") ->
        {:error, {:invalid_cgroup_path, "must be relative, got: #{path_str}"}}

      String.contains?(path_str, "..") ->
        {:error, {:invalid_cgroup_path, "cannot contain '..', got: #{path_str}"}}

      byte_size(path_str) >= 256 ->
        {:error, {:invalid_cgroup_path, "must be under 256 bytes"}}

      not String.starts_with?(path_str, "net_runner/") or path_str == "net_runner/" ->
        {:error,
         {:invalid_cgroup_path, "must sit under the net_runner/ prefix, got: #{path_str}"}}

      true ->
        :ok
    end
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
    dir = Path.join(System.tmp_dir!(), "net_runner_#{random}")

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
    kill_timeout = Keyword.get(opts, :kill_timeout, 5000)
    pty_mode = Keyword.get(opts, :pty, false)

    cgroup_path = Keyword.get(opts, :cgroup_path, nil)

    # --token-fd, not --token <hex>: argv is world-readable via
    # /proc/<pid>/cmdline (Linux) and same-uid readable via KERN_PROCARGS2
    # (macOS), which is exactly the attacker the token exists to stop. The
    # token travels over the private fd-3 port channel instead.
    shepherd_flags = ["--kill-timeout", to_string(kill_timeout), "--token-fd"]
    shepherd_flags = if pty_mode, do: shepherd_flags ++ ["--pty"], else: shepherd_flags

    shepherd_flags =
      if cgroup_path,
        do: shepherd_flags ++ ["--cgroup-path", to_string(cgroup_path)],
        else: shepherd_flags

    port_args = [uds_path | shepherd_flags] ++ [cmd | args]

    port_opts = [
      :nouse_stdio,
      :exit_status,
      :binary,
      args: port_args
    ]

    port_opts =
      case Keyword.get(opts, :env, nil) do
        nil -> port_opts
        env -> [{:env, format_env(env)} | port_opts]
      end

    # Port.open raises (e.g. shepherd binary missing from priv). Convert to a
    # value so spawn_process's error path still reclaims the listener and the
    # bound socket file.
    port = Port.open({:spawn_executable, shepherd}, port_opts)
    send_token(port, token)
    {:ok, port}
  rescue
    e -> {:error, {:shepherd_spawn_failed, Exception.message(e)}}
  end

  defp send_token(port, token) do
    Port.command(port, token)
    :ok
  catch
    # Port already dead (spawn raced its own failure) — the accept deadline
    # and token verification fail the spawn cleanly downstream.
    :error, :badarg -> :ok
  end

  # Environment entries as raw byte lists: execve consumes bytes, and
  # String.to_charlist/1 would (a) raise UnicodeConversionError on non-UTF-8
  # values validate_env accepted and (b) transcode UTF-8 bytes to codepoints.
  defp format_env(env) do
    Enum.map(env, fn
      {name, nil} -> {:binary.bin_to_list(name), false}
      {name, value} -> {:binary.bin_to_list(name), :binary.bin_to_list(value)}
    end)
  end

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

        expected = if pty_mode, do: 1, else: 3

        if length(fds) == expected do
          {:ok, fds, iov_rest}
        else
          # Whatever arrived is unusable but real — close it or it leaks.
          Enum.each(fds, &Nif.nif_close_fd/1)
          {:error, {:unexpected_fd_count, length(fds)}}
        end

      {:error, reason} ->
        {:error, {:recvmsg_failed, reason}}
    end
  end

  # On any failure every fd handed in is released: wrapped ones through their
  # NIF resource, unwrapped ones via nif_close_fd. nif_create_fd's contract is
  # that on error the caller retains ownership of the raw fd.
  defp wrap_fds([stdin_fd, stdout_fd, stderr_fd], owner, false) do
    with {:ok, stdin} <- wrap_or_close(stdin_fd, owner, [], [stdout_fd, stderr_fd]),
         {:ok, stdout} <- wrap_or_close(stdout_fd, owner, [stdin], [stderr_fd]),
         {:ok, stderr} <- wrap_or_close(stderr_fd, owner, [stdin, stdout], []) do
      {:ok, %{stdin: stdin, stdout: stdout, stderr: stderr}}
    end
  end

  defp wrap_fds([master_fd], owner, true) do
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
  # wrap_fds's on-error contract (no fd survives) holds at every step.
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

  @doc """
  Extracts MSG_CHILD_STARTED from `iov_rest`, or reads it from the socket.

  Returns `{:ok, os_pid, carry}`, where `carry` is whatever followed the
  MSG_CHILD_STARTED frame. The UDS is a byte stream, so the shepherd's three
  writes (the 1-byte SCM_RIGHTS filler, MSG_CHILD_STARTED and later
  MSG_CHILD_EXITED) can coalesce into a single `recvmsg`. A child that exits
  before the BEAM reads therefore delivers its exit status *inside* this
  buffer; discarding the tail loses it permanently and strands the caller on
  the force-exit timeout with a synthetic status.
  """
  def extract_child_started(socket, iov_rest) do
    case iov_rest do
      <<@msg_child_started, pid::big-unsigned-32, rest::binary>> ->
        {:ok, pid, rest}

      <<@msg_error, len::big-unsigned-16, msg::binary-size(len), _::binary>> ->
        {:error, {:shepherd_error, msg}}

      <<@msg_child_exited, status::big-unsigned-32, _::binary>> ->
        {:error, {:child_exited_immediately, status}}

      _ ->
        # MSG_CHILD_STARTED wasn't in the iov_rest, read from socket
        read_child_started_from_socket(socket)
    end
  end

  defp read_child_started_from_socket(socket) do
    case :socket.recv(socket, 5, [], @accept_timeout) do
      {:ok, <<@msg_child_started, pid::big-unsigned-32>>} ->
        {:ok, pid, <<>>}

      {:ok, <<@msg_error, rest::binary>>} ->
        {:error, {:shepherd_error, rest}}

      {:ok, <<@msg_child_exited, status::big-unsigned-32>>} ->
        {:error, {:child_exited_immediately, status}}

      {:ok, other} ->
        {:error, {:unexpected_message, other}}

      {:error, reason} ->
        {:error, {:recv_failed, reason}}
    end
  end

  @doc """
  Parses a single frame out of a buffer without touching the socket.

  Returns `{:ok, result, rest}`, `:incomplete` when more bytes are needed, or
  `{:error, {:unknown_message, byte}}` for an unrecognised opcode.
  """
  def parse_uds_message(<<@msg_child_exited, status::big-unsigned-32, rest::binary>>) do
    {:ok, {:child_exited, status}, rest}
  end

  def parse_uds_message(<<@msg_error, len::big-unsigned-16, msg::binary-size(len), rest::binary>>) do
    {:ok, {:shepherd_error, msg}, rest}
  end

  # A second MSG_CHILD_STARTED should never arrive, but skipping it keeps the
  # parser making progress instead of stalling on a byte it will never consume.
  def parse_uds_message(<<@msg_child_started, _pid::big-unsigned-32, rest::binary>>) do
    parse_uds_message(rest)
  end

  def parse_uds_message(<<byte, _::binary>>)
      when byte not in [@msg_child_started, @msg_child_exited, @msg_error] do
    {:error, {:unknown_message, byte}}
  end

  def parse_uds_message(_partial), do: :incomplete
end
