defmodule NetRunner.Nif do
  @moduledoc false

  # Library-wide native substrate (signals, liveness probes, fd ops) — not a
  # public API. These functions take unscoped raw descriptors and OS pids
  # with no ownership check; misuse silently corrupts unrelated VM state
  # (e.g. closing a live BEAM fd). Only NetRunner internals may call them.

  @on_load :load_nifs

  def load_nifs do
    path = :filename.join(:code.priv_dir(:net_runner), ~c"net_runner_nif")
    :erlang.load_nif(path, 0)
  end

  def nif_create_fd(_fd, _owner_pid), do: :erlang.nif_error(:not_loaded)
  def nif_read(_resource, _max_bytes), do: :erlang.nif_error(:not_loaded)
  def nif_write(_resource, _data), do: :erlang.nif_error(:not_loaded)
  def nif_close(_resource), do: :erlang.nif_error(:not_loaded)
  def nif_close_fd(_fd), do: :erlang.nif_error(:not_loaded)
  def nif_mkdir_private(_path), do: :erlang.nif_error(:not_loaded)
  def nif_kill(_os_pid, _signal), do: :erlang.nif_error(:not_loaded)
  def nif_is_os_pid_alive(_os_pid), do: :erlang.nif_error(:not_loaded)
  def nif_dup_fd(_fd), do: :erlang.nif_error(:not_loaded)
  def nif_signal_number(_signal_atom), do: :erlang.nif_error(:not_loaded)
end
