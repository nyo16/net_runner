defmodule NetRunner.Error do
  @moduledoc """
  Exception raised by the bang variants of the NetRunner API.

  `stream!/2` raises it on spawn failure (an invalid command, a shepherd
  error) and on a mid-stream read error; the original error term is preserved
  in `:reason` so callers can rescue and branch on it:

      try do
        NetRunner.stream!(["echo", "he\\0llo"]) |> Enum.to_list()
      rescue
        e in NetRunner.Error -> e.reason
      end
      # => {:spawn_failed, {:invalid_args, _}}

  A missing executable is not a spawn failure: the child exits `127` (and
  `126` when it cannot be executed), like a shell.
  """

  defexception [:reason]

  @type t :: %__MODULE__{reason: term()}

  @impl true
  def message(%__MODULE__{reason: reason}), do: "NetRunner error: #{inspect(reason)}"
end
