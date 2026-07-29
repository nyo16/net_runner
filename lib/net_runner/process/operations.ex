defmodule NetRunner.Process.Operations do
  @moduledoc false

  @type op_type :: :read | :write | {:read, :stdout | :stderr}
  @type pending_op :: {op_type(), GenServer.from(), term()}

  defstruct pending: %{}, owners: %{}, op_pids: %{}, monitor_pids: %{}

  @type t :: %__MODULE__{
          pending: %{reference() => pending_op()},
          owners: %{pid() => {reference(), pos_integer()}},
          op_pids: %{reference() => pid()},
          monitor_pids: %{reference() => pid()}
        }

  @doc """
  Parks a caller that received `:eagain`. Monitors the caller so the entry can
  be reclaimed if the caller crashes or times out before the GenServer can
  reply. Returns updated ops and a ref for matching.

  The monitor is refcounted per caller pid, not per operation. A streaming
  consumer parks once per chunk, so a monitor/demonitor pair per operation
  would be a per-chunk cost for what is normally a single long-lived caller;
  refcounting collapses that to one monitor for the caller's whole lifetime.
  """
  def park(%__MODULE__{} = ops, type, from, context \\ nil) do
    ref = make_ref()
    op = {type, from, context}
    {caller_pid, _} = from

    ops = monitor_caller(ops, caller_pid)

    new_ops = %{
      ops
      | pending: Map.put(ops.pending, ref, op),
        op_pids: Map.put(ops.op_pids, ref, caller_pid)
    }

    {new_ops, ref}
  end

  @doc """
  Retrieves and removes a pending operation by ref, releasing the caller's
  monitor refcount.
  """
  def pop(%__MODULE__{pending: pending} = ops, ref) do
    case Map.pop(pending, ref) do
      {nil, _} ->
        {nil, ops}

      {op, rest} ->
        {op, release_op(%{ops | pending: rest}, ref)}
    end
  end

  @doc """
  Removes every pending op belonging to the caller whose monitor ref is `mref`
  (invoked from the GenServer's `:DOWN` handler).

  Returns `{removed_ops, new_ops}` with `removed_ops` a possibly-empty list.
  A dead caller can never be replied to, so all of its operations go at once
  rather than one per `:DOWN` — there is only ever one `:DOWN` per monitor.
  """
  def pop_by_monitor(%__MODULE__{} = ops, mref) do
    case Map.pop(ops.monitor_pids, mref) do
      {nil, _} ->
        {[], ops}

      {pid, monitor_pids_rest} ->
        {op_refs, op_pids_rest} = split_ops_for_pid(ops.op_pids, pid)
        removed = Enum.map(op_refs, &Map.get(ops.pending, &1))

        {removed,
         %{
           ops
           | pending: Map.drop(ops.pending, op_refs),
             owners: Map.delete(ops.owners, pid),
             op_pids: op_pids_rest,
             monitor_pids: monitor_pids_rest
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
  Demonitors every caller along the way.
  """
  def reply_all(%__MODULE__{pending: pending, owners: owners} = ops, response) do
    Enum.each(pending, fn {_ref, {_type, from, _ctx}} ->
      GenServer.reply(from, response)
    end)

    Enum.each(owners, fn {_pid, {mref, _count}} -> Process.demonitor(mref, [:flush]) end)

    %{ops | pending: %{}, owners: %{}, op_pids: %{}, monitor_pids: %{}}
  end

  def empty?(%__MODULE__{pending: pending}), do: map_size(pending) == 0

  defp monitor_caller(%__MODULE__{owners: owners} = ops, pid) do
    case Map.get(owners, pid) do
      {mref, count} ->
        %{ops | owners: Map.put(owners, pid, {mref, count + 1})}

      nil ->
        mref = Process.monitor(pid)

        %{
          ops
          | owners: Map.put(owners, pid, {mref, 1}),
            monitor_pids: Map.put(ops.monitor_pids, mref, pid)
        }
    end
  end

  # Drops the op -> pid mapping and demonitors once the caller has no ops left.
  defp release_op(%__MODULE__{} = ops, op_ref) do
    case Map.pop(ops.op_pids, op_ref) do
      {nil, _} ->
        ops

      {pid, op_pids_rest} ->
        ops = %{ops | op_pids: op_pids_rest}

        case Map.get(ops.owners, pid) do
          {mref, 1} ->
            Process.demonitor(mref, [:flush])

            %{
              ops
              | owners: Map.delete(ops.owners, pid),
                monitor_pids: Map.delete(ops.monitor_pids, mref)
            }

          {mref, count} ->
            %{ops | owners: Map.put(ops.owners, pid, {mref, count - 1})}

          nil ->
            ops
        end
    end
  end

  defp split_ops_for_pid(op_pids, pid) do
    Enum.reduce(op_pids, {[], %{}}, fn
      {op_ref, ^pid}, {refs, keep} -> {[op_ref | refs], keep}
      {op_ref, other}, {refs, keep} -> {refs, Map.put(keep, op_ref, other)}
    end)
  end
end
