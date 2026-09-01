defmodule NetRunner.Process.Operations do
  @moduledoc false

  @type op_type :: :write | {:read, :stdout | :stderr}
  @type pending_op :: {op_type(), GenServer.from(), term(), reference()}

  defstruct pending: %{}, owners: %{}

  @type t :: %__MODULE__{
          pending: %{reference() => pending_op()},
          owners: %{pid() => {reference(), pos_integer()}}
        }

  @doc """
  Parks a caller that received `:eagain`. Monitors the caller so the entry can
  be reclaimed if the caller crashes or times out before the GenServer can
  reply. Returns updated ops and a ref for matching.

  The monitor is refcounted per caller pid, not per operation, so a caller
  with several ops in flight holds a single monitor. A strictly sequential
  parker (one op at a time) still pays a monitor/demonitor pair per op —
  the refcount only ever reaches 1 — so this is a correctness structure for
  overlapping ops, not a per-chunk optimisation.

  The caller's monitor ref rides inside the pending entry itself; `pending`
  plus the `owners` refcount map is the whole structure (the former
  `op_pids`/`monitor_pids` reverse indices were three-map bookkeeping for a
  structure that holds single-digit entries in practice).
  """
  def park(%__MODULE__{} = ops, type, from, context \\ nil) do
    ref = make_ref()
    {caller_pid, _} = from

    {ops, mref} = monitor_caller(ops, caller_pid)
    {%{ops | pending: Map.put(ops.pending, ref, {type, from, context, mref})}, ref}
  end

  @doc """
  Retrieves and removes a pending operation by ref, releasing the caller's
  monitor refcount.
  """
  def pop(%__MODULE__{pending: pending} = ops, ref) do
    case Map.pop(pending, ref) do
      {nil, _} ->
        {nil, ops}

      {{_type, from, _ctx, mref} = op, rest} ->
        {caller_pid, _} = from
        {op, release_caller(%{ops | pending: rest}, caller_pid, mref)}
    end
  end

  @doc """
  Removes every pending op belonging to the caller whose monitor ref is `mref`
  (invoked from the GenServer's `:DOWN` handler).

  Returns `{removed_ops, new_ops}` with `removed_ops` a possibly-empty list.
  A dead caller can never be replied to, so all of its operations go at once
  rather than one per `:DOWN` — there is only ever one `:DOWN` per monitor.
  Walks `pending`, which is bounded by the parked-op count (single digits in
  practice). No demonitor: the monitor just fired.
  """
  def pop_by_monitor(%__MODULE__{pending: pending, owners: owners} = ops, mref) do
    case Enum.split_with(pending, fn {_ref, {_t, _f, _c, op_mref}} -> op_mref == mref end) do
      {[], _} ->
        {[], ops}

      {matched, kept} ->
        [{_ref, {_t, {caller_pid, _}, _c, _mref}} | _] = matched
        removed = Enum.map(matched, fn {_ref, op} -> op end)

        {removed, %{ops | pending: Map.new(kept), owners: Map.delete(owners, caller_pid)}}
    end
  end

  @doc """
  Returns all pending operations matching a type.
  """
  def pending_by_type(%__MODULE__{pending: pending}, type) do
    Enum.filter(pending, fn {_ref, {op_type, _from, _ctx, _mref}} -> op_type == type end)
  end

  @doc """
  Replaces a pending operation's context, keeping its type, caller and monitor.

  A partially-completed write must record how much is left; without this the
  parked op keeps its original payload and every readiness event rewrites it
  from the beginning, so the child receives duplicate bytes and the write never
  finishes. No-op if the ref is already gone.
  """
  def update_context(%__MODULE__{pending: pending} = ops, ref, context) do
    case Map.fetch(pending, ref) do
      {:ok, {type, from, _old, mref}} ->
        %{ops | pending: Map.put(pending, ref, {type, from, context, mref})}

      :error ->
        ops
    end
  end

  @doc """
  Replies to all pending operations with the given response and clears them.
  Demonitors every caller along the way.
  """
  def reply_all(%__MODULE__{pending: pending, owners: owners} = ops, response) do
    Enum.each(pending, fn {_ref, {_type, from, _ctx, _mref}} ->
      GenServer.reply(from, response)
    end)

    Enum.each(owners, fn {_pid, {mref, _count}} -> Process.demonitor(mref, [:flush]) end)

    %{ops | pending: %{}, owners: %{}}
  end

  def empty?(%__MODULE__{pending: pending}), do: map_size(pending) == 0

  defp monitor_caller(%__MODULE__{owners: owners} = ops, pid) do
    case Map.get(owners, pid) do
      {mref, count} ->
        {%{ops | owners: Map.put(owners, pid, {mref, count + 1})}, mref}

      nil ->
        mref = Process.monitor(pid)
        {%{ops | owners: Map.put(owners, pid, {mref, 1})}, mref}
    end
  end

  # Decrements the caller's monitor refcount, demonitoring once it has no ops
  # left.
  defp release_caller(%__MODULE__{owners: owners} = ops, pid, mref) do
    case Map.get(owners, pid) do
      {^mref, 1} ->
        Process.demonitor(mref, [:flush])
        %{ops | owners: Map.delete(owners, pid)}

      {^mref, count} ->
        %{ops | owners: Map.put(owners, pid, {mref, count - 1})}

      _ ->
        ops
    end
  end
end
