defmodule NetRunner.Process.Protocol do
  @moduledoc false

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

  @doc "Encodes CMD_KILL for a resolved signal number."
  def kill(sig_num) when is_integer(sig_num), do: <<@cmd_kill, sig_num::8>>

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
  Extracts MSG_CHILD_STARTED from `iov_rest`, or reads it from the socket.

  Returns `{:ok, os_pid, carry}`, where `carry` is whatever followed the
  MSG_CHILD_STARTED frame. The UDS is a byte stream, so the shepherd's three
  writes (the 1-byte SCM_RIGHTS filler, MSG_CHILD_STARTED and later
  MSG_CHILD_EXITED) can coalesce into a single `recvmsg`. A child that exits
  before the BEAM reads therefore delivers its exit status *inside* this
  buffer; discarding the tail loses it permanently and strands the caller on
  the force-exit timeout with a synthetic status.
  """
  def extract_child_started(socket, iov_rest, timeout) do
    case iov_rest do
      <<@msg_child_started, pid::big-unsigned-32, rest::binary>> ->
        {:ok, pid, rest}

      <<@msg_error, len::big-unsigned-16, msg::binary-size(len), _::binary>> ->
        {:error, {:shepherd_error, msg}}

      <<@msg_child_exited, status::big-unsigned-32, _::binary>> ->
        {:error, {:child_exited_immediately, status}}

      _ ->
        # MSG_CHILD_STARTED wasn't in the iov_rest, read from socket
        read_child_started_from_socket(socket, timeout)
    end
  end

  defp read_child_started_from_socket(socket, timeout) do
    case :socket.recv(socket, 5, [], timeout) do
      {:ok, <<@msg_child_started, pid::big-unsigned-32>>} ->
        {:ok, pid, <<>>}

      {:ok, <<@msg_error, _::binary>> = partial} ->
        # An MSG_ERROR frame is [0x82][len:2][msg:len] — 5 bytes covers the
        # header plus at most the first 2 message bytes. Read the rest so the
        # shepherd's diagnostic is delivered whole, not garbled.
        case recv_shepherd_error(socket, partial, timeout) do
          {:ok, msg} -> {:error, {:shepherd_error, msg}}
          :no_error -> {:error, {:unexpected_message, partial}}
        end

      {:ok, <<@msg_child_exited, status::big-unsigned-32>>} ->
        {:error, {:child_exited_immediately, status}}

      {:ok, other} ->
        {:error, {:unexpected_message, other}}

      {:error, reason} ->
        {:error, {:recv_failed, reason}}
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
end
