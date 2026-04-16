defmodule NetRunner.Signal do
  @moduledoc false

  alias NetRunner.Process.Nif

  @signals ~w(sigterm sigkill sigint sighup sigusr1 sigusr2 sigstop sigcont sigquit sigpipe)a

  @doc """
  Resolves a signal atom to its platform-specific number.
  """
  def resolve(signal) when signal in @signals do
    Nif.nif_signal_number(signal)
  end

  def resolve(signal) when is_integer(signal) and signal >= 1 and signal <= 31,
    do: {:ok, signal}

  def resolve(_signal), do: {:error, :unknown_signal}

  @doc """
  Resolves a signal, raising on failure.
  """
  def resolve!(signal) do
    case resolve(signal) do
      {:ok, num} -> num
      {:error, reason} -> raise ArgumentError, "unknown signal: #{inspect(signal)} (#{reason})"
    end
  end
end
