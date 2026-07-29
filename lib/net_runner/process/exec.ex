defmodule NetRunner.Process.Exec do
  @moduledoc false

  alias NetRunner.Process.{Nif, Pipe, State}

  @accept_timeout 10_000
  @msg_child_started 0x80
  @msg_child_exited 0x81
  @msg_error 0x82
  @uds_base_dir_key {__MODULE__, :uds_base_dir}

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

    result =
      with :ok <- validate_cmd_and_args(cmd, args),
           :ok <- validate_stderr_mode(Keyword.get(opts, :stderr, :consume), pty_mode),
           :ok <- validate_stderr_tail_bytes(Keyword.get(opts, :stderr_tail_bytes, 8_192)),
           :ok <- validate_cgroup_path(Keyword.get(opts, :cgroup_path, nil)),
           {:ok, listen_socket} <- create_uds_listener(uds_path),
           shepherd_port <- open_shepherd(uds_path, cmd, args, opts),
           {:ok, conn_socket} <- accept_connection(listen_socket),
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
    with {:ok, fds, iov_rest} <- receive_fds(conn_socket, pty_mode),
         {:ok, os_pid, carry} <- extract_child_started(conn_socket, iov_rest),
         {:ok, pipes} <- wrap_fds(fds, owner, pty_mode) do
      stderr_mode = if pty_mode, do: :disabled, else: Keyword.get(opts, :stderr, :consume)

      {:ok,
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
       }}
    else
      {:error, reason} ->
        safe_close_socket(conn_socket)
        safe_port_close(shepherd_port)
        {:error, reason}
    end
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
  # still draining the pipe so the child never blocks.
  defp validate_stderr_tail_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: :ok

  defp validate_stderr_tail_bytes(bytes) do
    {:error,
     {:invalid_stderr_tail_bytes, "must be a non-negative integer, got: #{inspect(bytes)}"}}
  end

  defp validate_cgroup_path(nil), do: :ok

  defp validate_cgroup_path(path) do
    path_str = to_string(path)

    cond do
      String.starts_with?(path_str, "/") ->
        {:error, {:invalid_cgroup_path, "must be relative, got: #{path_str}"}}

      String.contains?(path_str, "..") ->
        {:error, {:invalid_cgroup_path, "cannot contain '..', got: #{path_str}"}}

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
      dir when is_binary(dir) ->
        # A tmp reaper can remove the directory under a long-lived VM, so the
        # memoised path is verified rather than trusted.
        if File.dir?(dir), do: dir, else: create_uds_base_dir()

      nil ->
        create_uds_base_dir()
    end
  end

  defp create_uds_base_dir do
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    dir = Path.join(System.tmp_dir!(), "net_runner_#{random}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    # Two concurrent first spawns can both create a directory; the loser's is
    # left empty and harmless. Writing here once per VM keeps the
    # persistent_term global GC off the spawn path.
    :persistent_term.put(@uds_base_dir_key, dir)
    dir
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

  defp open_shepherd(uds_path, cmd, args, opts) do
    shepherd = shepherd_executable()
    kill_timeout = Keyword.get(opts, :kill_timeout, 5000)
    pty_mode = Keyword.get(opts, :pty, false)

    cgroup_path = Keyword.get(opts, :cgroup_path, nil)

    shepherd_flags = ["--kill-timeout", to_string(kill_timeout)]
    shepherd_flags = if pty_mode, do: shepherd_flags ++ ["--pty"], else: shepherd_flags

    shepherd_flags =
      if cgroup_path,
        do: shepherd_flags ++ ["--cgroup-path", to_string(cgroup_path)],
        else: shepherd_flags

    port_args = [uds_path | shepherd_flags] ++ [cmd | args]

    Port.open({:spawn_executable, shepherd}, [
      :nouse_stdio,
      :exit_status,
      :binary,
      args: port_args
    ])
  end

  defp shepherd_executable do
    app_dir = :code.priv_dir(:net_runner)
    Path.join(to_string(app_dir), "shepherd")
  end

  defp accept_connection(listen_socket) do
    case :socket.accept(listen_socket, @accept_timeout) do
      {:ok, _conn} = ok -> ok
      {:error, :timeout} -> {:error, :shepherd_connect_timeout}
      error -> error
    end
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
          {:error, {:unexpected_fd_count, length(fds)}}
        end

      {:error, reason} ->
        {:error, {:recvmsg_failed, reason}}
    end
  end

  defp wrap_fds([stdin_fd, stdout_fd, stderr_fd], owner, false) do
    with {:ok, stdin} <- Pipe.new(stdin_fd, owner, :stdin),
         {:ok, stdout} <- Pipe.new(stdout_fd, owner, :stdout),
         {:ok, stderr} <- Pipe.new(stderr_fd, owner, :stderr) do
      {:ok, %{stdin: stdin, stdout: stdout, stderr: stderr}}
    end
  end

  defp wrap_fds([master_fd], owner, true) do
    # PTY: single bidirectional FD. Dup it so stdin and stdout
    # have independent NIF resources that can be closed separately.
    with {:ok, write_fd} <- Nif.nif_dup_fd(master_fd),
         {:ok, stdout} <- Pipe.new(master_fd, owner, :stdout),
         {:ok, stdin} <- Pipe.new(write_fd, owner, :stdin) do
      {:ok, %{stdin: stdin, stdout: stdout, stderr: nil}}
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
