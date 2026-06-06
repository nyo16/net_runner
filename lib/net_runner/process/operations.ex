defmodule NetRunner.Process.Operations do
  @moduledoc false

  @type op_type :: :read | :write | {:read, :stdout | :stderr}
  @type pending_op :: {op_type(), GenServer.from(), term()}

  defstruct pending: %{}, monitors: %{}, op_monitors: %{}

  @type t :: %__MODULE__{
          pending: %{reference() => pending_op()},
          monitors: %{reference() => reference()},
          op_monitors: %{reference() => reference()}
        }

  @doc """
  Parks a caller that received :eagain. Monitors the caller so the entry
  can be reclaimed if the caller crashes or times out before the GenServer
  can reply. Returns updated ops and a ref for matching.
  """
  def park(%__MODULE__{} = ops, type, from, context \\ nil) do
    ref = make_ref()
    op = {type, from, context}

    {caller_pid, _} = from
    mref = Process.monitor(caller_pid)

    new_ops = %{
      ops
      | pending: Map.put(ops.pending, ref, op),
        monitors: Map.put(ops.monitors, mref, ref),
        op_monitors: Map.put(ops.op_monitors, ref, mref)
    }

    {new_ops, ref}
  end

  @doc """
  Retrieves and removes a pending operation by ref. Demonitors the caller
  we established in park/4.
  """
  def pop(%__MODULE__{pending: pending} = ops, ref) do
    case Map.pop(pending, ref) do
      {nil, _} ->
        {nil, ops}

      {op, rest} ->
        ops = demonitor_for_op(%{ops | pending: rest}, ref)
        {op, ops}
    end
  end

  @doc """
  Removes the pending op whose caller-monitor ref matches `mref` (invoked
  from the GenServer's :DOWN handler). Returns {op_or_nil, new_ops}.
  """
  def pop_by_monitor(
        %__MODULE__{pending: pending, monitors: monitors, op_monitors: op_monitors} = ops,
        mref
      ) do
    case Map.pop(monitors, mref) do
      {nil, _} ->
        {nil, ops}

      {op_ref, monitors_rest} ->
        {op, pending_rest} = Map.pop(pending, op_ref)

        {op,
         %{
           ops
           | pending: pending_rest,
             monitors: monitors_rest,
             op_monitors: Map.delete(op_monitors, op_ref)
         }}
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
  Demonitors all caller monitors along the way.
  """
  def reply_all(%__MODULE__{pending: pending, monitors: monitors} = ops, response) do
    Enum.each(pending, fn {_ref, {_type, from, _ctx}} ->
      GenServer.reply(from, response)
    end)

    Enum.each(monitors, fn {mref, _op_ref} -> Process.demonitor(mref, [:flush]) end)

    %{ops | pending: %{}, monitors: %{}, op_monitors: %{}}
  end

  def empty?(%__MODULE__{pending: pending}), do: map_size(pending) == 0

  # O(1) demonitor via the op_ref -> mref reverse index.
  defp demonitor_for_op(%__MODULE__{monitors: monitors, op_monitors: op_monitors} = ops, op_ref) do
    case Map.pop(op_monitors, op_ref) do
      {nil, _} ->
        ops

      {mref, op_monitors_rest} ->
        Process.demonitor(mref, [:flush])
        %{ops | monitors: Map.delete(monitors, mref), op_monitors: op_monitors_rest}
    end
  end
end
