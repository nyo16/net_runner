defmodule NetRunner.Process.Protocol do
  @moduledoc false

  alias NetRunner.Process.Options

  # Single Elixir-side owner of the shepherd <-> BEAM wire protocol. The C
  # counterpart is c_src/protocol.h — any frame change must touch both files
  # and nowhere else. Mirror of protocol.h's frame table:
  #
  #   Direction: BEAM -> Shepherd
  #     CMD_KILL          [0x01] [signal_number: 1 byte]
  #     CMD_CLOSE_STDIN   [0x02] (no payload)
  #     CMD_SET_WINSIZE   [0x03] [rows: 2 bytes] [cols: 2 bytes] (big-endian)
  #
  #   Direction: Shepherd -> BEAM
  #     MSG_CHILD_STARTED [0x80] [pid: 4 bytes, big-endian]
  #     MSG_CHILD_EXITED  [0x81] [status: 4 bytes, big-endian]
  #     MSG_ERROR         [0x82] [length: 2 bytes, big-endian] [message: N bytes]

  @msg_child_started 0x80
  @msg_child_exited 0x81
  @msg_error 0x82

  @cmd_kill 0x01
  @cmd_close_stdin 0x02
  @cmd_set_winsize 0x03

  # --- BEAM -> shepherd command encoders ---

  @doc """
  Encodes CMD_KILL for a resolved signal number (one byte on the wire).
  Limited to 1..31, the range the shepherd honours (`handle_command`), so an
  out-of-range signal fails here instead of being silently dropped there.
  """
  def kill(sig_num) when is_integer(sig_num) and sig_num in 1..31 do
    <<@cmd_kill, sig_num::8>>
  end

  @doc "Encodes CMD_CLOSE_STDIN."
  def close_stdin, do: <<@cmd_close_stdin>>

  @doc "Encodes CMD_SET_WINSIZE. Rows/cols must fit the 2-byte fields."
  def set_winsize(rows, cols) when rows in 0..65_535 and cols in 0..65_535 do
    <<@cmd_set_winsize, rows::big-16, cols::big-16>>
  end

  # --- shepherd -> BEAM frame parsing ---

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

  @doc """
  Extracts MSG_CHILD_STARTED from `buffer` (the bytes that followed the
  SCM_RIGHTS filler), reading more from the socket while the frame is
  incomplete.

  Returns `{:ok, os_pid, carry}`, where `carry` is whatever followed the
  MSG_CHILD_STARTED frame. The UDS is a byte stream, so the shepherd's three
  writes (the 1-byte SCM_RIGHTS filler, MSG_CHILD_STARTED and later
  MSG_CHILD_EXITED) can coalesce into a single `recvmsg`. A child that exits
  before the BEAM reads therefore delivers its exit status *inside* this
  buffer; discarding the tail loses it permanently, and the caller gets a
  synthetic 137 once the shepherd exits instead of the real status.

  The same stream can also split a frame: a partial prefix in `buffer` is
  kept and completed, never discarded in favour of 5 fresh bytes (which
  would misread the frame's tail as an opcode).
  """
  def extract_child_started(socket, buffer, timeout) do
    case buffer do
      <<@msg_child_started, pid::big-unsigned-32, rest::binary>> ->
        {:ok, pid, rest}

      <<@msg_error, _::binary>> ->
        complete_shepherd_error(socket, buffer, timeout)

      <<@msg_child_exited, status::big-unsigned-32, _::binary>> ->
        {:error, {:child_exited_immediately, status}}

      <<byte, _::binary>> when byte not in [@msg_child_started, @msg_child_exited] ->
        {:error, {:unexpected_message, buffer}}

      _incomplete ->
        case :socket.recv(socket, 0, [], timeout) do
          {:ok, more} -> extract_child_started(socket, buffer <> more, timeout)
          {:error, reason} -> {:error, {:recv_failed, reason}}
        end
    end
  end

  # A complete frame is returned without touching the socket; a split one is
  # completed so the shepherd's diagnostic is delivered whole, not garbled.
  defp complete_shepherd_error(socket, buffer, timeout) do
    case recv_shepherd_error(socket, buffer, timeout) do
      {:ok, msg} -> {:error, {:shepherd_error, msg}}
      :no_error -> {:error, {:unexpected_message, buffer}}
    end
  end

  @doc """
  Completes an MSG_ERROR frame whose start is already in `buffer`.

  Every pre-`send_fds` shepherd failure ("cgroup setup failed", "fork
  failed", ...) arrives as a bare MSG_ERROR frame in place of the expected
  SCM_RIGHTS payload; this recovers the message even when the frame is split
  across reads. Returns `{:ok, msg}`, or `:no_error` when `buffer` does not
  start an MSG_ERROR frame (including a split frame whose remainder never
  arrives).
  """
  def recv_shepherd_error(
        _socket,
        <<@msg_error, len::big-unsigned-16, msg::binary-size(len), _::binary>>,
        _timeout
      ) do
    {:ok, msg}
  end

  def recv_shepherd_error(socket, <<@msg_error, _::binary>> = partial, timeout) do
    case :socket.recv(socket, 0, [], timeout) do
      {:ok, more} -> recv_shepherd_error(socket, partial <> more, timeout)
      {:error, _reason} -> :no_error
    end
  end

  def recv_shepherd_error(_socket, _buffer, _timeout), do: :no_error

  # --- BEAM -> shepherd process launch: argv and fd layout ---

  @doc """
  The SCM_RIGHTS fds that carry the child's I/O: 3 in pipe mode (stdin_w,
  stdout_r, stderr_r), 1 in PTY mode (the master). On Linux a pidfd may
  follow as one more, trailing fd.
  """
  def io_fd_count(true = _pty_mode), do: 1
  def io_fd_count(false), do: 3

  @doc """
  Builds the shepherd's argv (after the executable) and the port
  environment for validated spawn `opts`. Mirrors `parse_args` in
  c_src/shepherd.c. Returns `{argv, port_env}`, `port_env` being `nil` when
  the BEAM's environment is inherited unchanged.
  """
  def shepherd_argv(uds_path, cmd, args, opts) do
    kill_timeout = Keyword.get(opts, :kill_timeout, Options.default_kill_timeout())

    # --token-fd, not --token <hex>: argv is world-readable via
    # /proc/<pid>/cmdline (Linux) and same-uid readable via KERN_PROCARGS2
    # (macOS), which is exactly the attacker the token exists to stop. The
    # token travels over the private fd-3 port channel instead.
    flags =
      ["--kill-timeout", to_string(kill_timeout), "--token-fd"] ++
        flag_if(Keyword.get(opts, :pty, false), ["--pty"]) ++
        value_flag("--cgroup-path", Keyword.get(opts, :cgroup_path)) ++
        value_flag("--cwd", Keyword.get(opts, :cwd)) ++
        flag_if(Keyword.get(opts, :no_new_privs, false), ["--no-new-privs"]) ++
        flag_if(Keyword.get(opts, :pipe_size, :grown) == :default, ["--default-pipe-size"])

    {environment_flags, port_environment} = environment_options(Keyword.get(opts, :env, nil))

    # "--" ends shepherd option parsing: a cmd beginning with "-" must reach
    # execvp verbatim, never be read as a shepherd flag (--cgroup-path,
    # --kill-timeout, --pty, --cwd, --replace-env, --no-new-privs).
    {[uds_path | flags ++ environment_flags] ++ ["--", cmd | args], port_environment}
  end

  defp flag_if(true, flags), do: flags
  defp flag_if(_, _flags), do: []

  defp value_flag(_flag, nil), do: []
  defp value_flag(flag, value), do: [flag, value]

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
end
