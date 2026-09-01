defmodule NetRunner.Error do
  @moduledoc """
  Exception raised by the bang variants of the NetRunner API.

  `stream!/2` raises it on spawn failure and on a mid-stream read error; the
  original error term is preserved in `:reason` so callers can rescue and
  branch on it:

      try do
        NetRunner.stream!(~w(nonexistent-cmd)) |> Enum.to_list()
      rescue
        e in NetRunner.Error -> e.reason
      end
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: term()}

  @impl true
  def message(%__MODULE__{reason: reason}), do: "NetRunner error: #{inspect(reason)}"
end
