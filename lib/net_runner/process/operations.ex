defmodule NetRunner.Process.Operations do
  @moduledoc false

  @type op_type :: :read | :write
  @type pending_op :: {op_type(), GenServer.from(), term()}

  defstruct pending: %{}

  @type t :: %__MODULE__{
          pending: %{reference() => pending_op()}
        }

  @doc """
  Parks a caller that received :eagain. Returns updated ops and a ref for matching.
  """
  def park(%__MODULE__{pending: pending} = ops, type, from, context \\ nil) do
    ref = make_ref()
    op = {type, from, context}
    {%{ops | pending: Map.put(pending, ref, op)}, ref}
  end

  @doc """
  Retrieves and removes a pending operation by ref.
  """
  def pop(%__MODULE__{pending: pending} = ops, ref) do
    case Map.pop(pending, ref) do
      {nil, _} -> {nil, ops}
      {op, rest} -> {op, %{ops | pending: rest}}
    end
  end

  @doc """
  Returns all pending operations matching a type.
  """
  def pending_by_type(%__MODULE__{pending: pending}, type) do
    Enum.filter(pending, fn {_ref, {op_type, _from, _ctx}} -> op_type == type end)
  end

  @doc """
  Replies to all pending operations with the given response and clears them.
  """
  def reply_all(%__MODULE__{pending: pending} = ops, response) do
    Enum.each(pending, fn {_ref, {_type, from, _ctx}} ->
      GenServer.reply(from, response)
    end)

    %{ops | pending: %{}}
  end

  def empty?(%__MODULE__{pending: pending}), do: map_size(pending) == 0
end
