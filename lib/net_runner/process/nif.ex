defmodule NetRunner.Process.Nif do
  @moduledoc false
  @on_load :load_nifs

  def load_nifs do
    path = :filename.join(:code.priv_dir(:net_runner), ~c"net_runner_nif")
    :erlang.load_nif(path, 0)
  end

  def nif_create_fd(_fd, _owner_pid), do: :erlang.nif_error(:not_loaded)
  def nif_read(_resource, _max_bytes), do: :erlang.nif_error(:not_loaded)
  def nif_write(_resource, _data), do: :erlang.nif_error(:not_loaded)
  def nif_close(_resource), do: :erlang.nif_error(:not_loaded)
  def nif_kill(_os_pid, _signal), do: :erlang.nif_error(:not_loaded)
  def nif_is_os_pid_alive(_os_pid), do: :erlang.nif_error(:not_loaded)
  def nif_signal_number(_signal_atom), do: :erlang.nif_error(:not_loaded)
end
