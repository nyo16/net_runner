defmodule NetRunner.Process.Exec do
  @moduledoc false

  # Spawn mechanics: the private UDS listener, the shepherd Port, accept and
  # token authentication, and the SCM_RIGHTS fd hand-off. Option validation
  # lives in NetRunner.Process.Options; the wire format (frames and the
  # shepherd argv grammar) in NetRunner.Process.Protocol.

  alias NetRunner.Nif
  alias NetRunner.Process.{Cgroup, Pipe, Protocol, State}

  @accept_timeout 10_000
  # Per-connection bound on the token read; see verify_token/3.
  @token_recv_timeout_ms 2_000
  @uds_base_dir_key {__MODULE__, :uds_base_dir}

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
  # cost only that connection, not the whole spawn — each connection gets at
  # most @token_recv_timeout_ms to present the token (verify_token/3), and the
  # real shepherd's queued connect is still served on the next accept. On
  # final failure the
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
  @doc false
  # Public only for the handshake tests (over a local socket pair).
  # `conn_timeout` exists for tests (a short silent-peer bound); the accept
  # loop always uses @token_recv_timeout_ms.
  def authenticate_shepherd(conn_socket, token, deadline, conn_timeout \\ @token_recv_timeout_ms) do
    with :ok <- verify_peer_uid(conn_socket),
         :ok <- verify_token(conn_socket, token, deadline, conn_timeout) do
      :ok
    else
      {:error, _} = error ->
        safe_close_socket(conn_socket)
        error
    end
  end

  defp verify_token(conn_socket, token, deadline, conn_timeout) do
    # Bounded twice: by the overall accept deadline, so a stalling peer cannot
    # extend the spawn beyond @accept_timeout, and per connection, so a
    # same-uid peer that connects and stays silent costs the real shepherd
    # (queued behind it) at most @token_recv_timeout_ms, not the whole
    # deadline. The bound is generous on purpose: the BEAM accepts as soon as
    # connect() completes, before the shepherd writes the token, so the REAL
    # shepherd must also fit in it while descheduled (a CPU-throttled
    # container). 250 ms dropped real spawns under throttling.
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case :socket.recv(conn_socket, byte_size(token), [], min(remaining, conn_timeout)) do
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
      pty_mode: pty_mode,
      stderr_mode: stderr_mode,
      stderr_tail_bytes: Keyword.get(opts, :stderr_tail_bytes, 8_192),
      cgroup: Cgroup.identify(Keyword.get(opts, :cgroup_path)),
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
    {port_args, port_environment} = Protocol.shepherd_argv(uds_path, cmd, args, opts)

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

  # Linux can mark received fds close-on-exec atomically (MSG_CMSG_CLOEXEC),
  # so a concurrent fork (os:cmd, another port) never inherits them between
  # recvmsg and nif_create_fd. Elsewhere nif_create_fd sets FD_CLOEXEC.
  defp recvmsg_flags do
    case :os.type() do
      {:unix, :linux} -> [:cmsg_cloexec]
      _ -> []
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
    case :socket.recvmsg(socket, 0, 0, recvmsg_flags(), @accept_timeout) do
      {:ok, %{ctrl: ctrl, iov: iov}} ->
        fds = extract_fds_from_ctrl(ctrl)
        iov_data = IO.iodata_to_binary(iov)

        iov_rest =
          if byte_size(iov_data) > 0,
            do: binary_part(iov_data, 1, byte_size(iov_data) - 1),
            else: <<>>

        base = Protocol.io_fd_count(pty_mode)

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
    case Enum.split(fds, Protocol.io_fd_count(pty_mode)) do
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
      {:ok, %{stdin: stdin, stdout: %{stdout | eio_is_eof: true}, stderr: nil}}
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
