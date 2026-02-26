defmodule NetRunner.Process.Exec do
  @moduledoc false

  alias NetRunner.Process.{Pipe, State}

  @accept_timeout 10_000
  @msg_child_started 0x80
  @msg_child_exited 0x81
  @msg_error 0x82

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

    with {:ok, listen_socket} <- create_uds_listener(uds_path),
         shepherd_port <- open_shepherd(uds_path, cmd, args),
         {:ok, conn_socket} <- accept_connection(listen_socket),
         :ok <- cleanup_listener(listen_socket, uds_path),
         {:ok, {stdin_fd, stdout_fd, stderr_fd}, iov_rest} <- receive_fds(conn_socket),
         {:ok, os_pid} <- extract_child_started(conn_socket, iov_rest),
         {:ok, stdin} <- Pipe.new(stdin_fd, owner, :stdin),
         {:ok, stdout} <- Pipe.new(stdout_fd, owner, :stdout),
         {:ok, stderr} <- Pipe.new(stderr_fd, owner, :stderr) do
      stderr_mode = Keyword.get(opts, :stderr, :consume)

      {:ok,
       %State{
         shepherd_port: shepherd_port,
         uds_socket: conn_socket,
         stdin: stdin,
         stdout: stdout,
         stderr: stderr,
         os_pid: os_pid,
         cmd: cmd,
         args: args,
         stderr_mode: stderr_mode,
         status: :running
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp uds_socket_path do
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Path.join(System.tmp_dir!(), "net_runner_#{random}.sock")
  end

  defp create_uds_listener(path) do
    with {:ok, socket} <- :socket.open(:local, :stream, :default) do
      addr = %{family: :local, path: path}

      case :socket.bind(socket, addr) do
        :ok ->
          case :socket.listen(socket) do
            :ok ->
              {:ok, socket}

            error ->
              :socket.close(socket)
              error
          end

        error ->
          :socket.close(socket)
          error
      end
    end
  end

  defp open_shepherd(uds_path, cmd, args) do
    shepherd = shepherd_executable()
    port_args = [uds_path, cmd | args]

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
    File.rm(path)
    :ok
  end

  @doc """
  Receives 3 file descriptors (stdin_w, stdout_r, stderr_r) via SCM_RIGHTS.

  Returns `{:ok, {stdin_fd, stdout_fd, stderr_fd}, iov_rest}` where `iov_rest`
  is any protocol data that arrived in the same recvmsg (e.g. MSG_CHILD_STARTED).
  """
  def receive_fds(socket) do
    case :socket.recvmsg(socket, 0, 0, [], @accept_timeout) do
      {:ok, %{ctrl: ctrl, iov: iov}} ->
        fds = extract_fds_from_ctrl(ctrl)
        # iov contains the dummy byte from sendmsg, plus any protocol data
        # that was queued before we read. Strip the leading dummy byte.
        iov_data = IO.iodata_to_binary(iov)

        iov_rest =
          if byte_size(iov_data) > 0,
            do: binary_part(iov_data, 1, byte_size(iov_data) - 1),
            else: <<>>

        case fds do
          [stdin_fd, stdout_fd, stderr_fd] ->
            {:ok, {stdin_fd, stdout_fd, stderr_fd}, iov_rest}

          _ ->
            {:error, {:unexpected_fd_count, length(fds)}}
        end

      {:error, reason} ->
        {:error, {:recvmsg_failed, reason}}
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
  Extracts MSG_CHILD_STARTED from iov_rest, or reads from socket if needed.
  """
  def extract_child_started(socket, iov_rest) do
    case iov_rest do
      <<@msg_child_started, pid::big-unsigned-32, _rest::binary>> ->
        {:ok, pid}

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
        {:ok, pid}

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
  Reads a protocol message from the UDS. Used for ongoing communication.
  """
  def read_uds_message(socket) do
    case :socket.recv(socket, 0, [:peek], 0) do
      {:ok, <<@msg_child_exited, _::binary>>} ->
        case :socket.recv(socket, 5, [], 100) do
          {:ok, <<@msg_child_exited, status::big-unsigned-32>>} ->
            {:child_exited, status}

          other ->
            {:error, {:unexpected, other}}
        end

      {:ok, <<@msg_error, _::binary>>} ->
        case :socket.recv(socket, 0, [], 100) do
          {:ok, <<@msg_error, len::big-unsigned-16, msg::binary-size(len)>>} ->
            {:shepherd_error, msg}

          other ->
            {:error, {:unexpected, other}}
        end

      {:ok, _other} ->
        {:error, :unknown_message}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
