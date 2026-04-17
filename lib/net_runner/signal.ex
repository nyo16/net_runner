defmodule NetRunner.Signal do
  @moduledoc false

  alias NetRunner.Process.Nif

  @doc """
  Resolves a signal atom to its platform-specific number.

  The canonical list of supported signal atoms lives in the NIF
  (`nif_signal_number`); calling it directly keeps Elixir and C from
  drifting out of sync.
  """
  def resolve(signal) when is_atom(signal), do: Nif.nif_signal_number(signal)

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
