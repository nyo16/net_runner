defmodule NetRunner.InputWriter do
  @moduledoc false

  # Single owner of the `:input` writer lifecycle for both entry points,
  # `NetRunner.run/2` and `NetRunner.Stream`.
  #
  # They must agree on which input shapes are accepted and on how a live writer
  # is reaped. When they did not, `run/2` wrote its input to completion before
  # reading a byte and deadlocked on any filter command whose input exceeded
  # stdin_buffer + stdout_buffer, while `stream!/2` — writing from a Task —
  # was immune. Two conventions for the same subsystem, only one of them
  # correct.

  alias NetRunner.Process, as: Proc

  # Grace for joining a writer once the reader has reached :eof. By then the
  # child has closed stdout, so the writer has either finished or is about to
  # fail its next write; longer than this means something is wedged and killing
  # it is the right answer.
  @reap_grace_ms 5_000

  # Batch size for coalescing an eager list's elements into iodata writes.
  # A list is fully realised, so write-through granularity is unobservable
  # from the outside — batching only changes how many GenServer round trips
  # the same bytes take (~13 µs each; 200k tiny elements = seconds of pure
  # messaging overhead without this). 1 MiB (not 64 KiB): each Proc.write
  # round trip is a writer→server→reply latency bubble during which the pipe
  # sits idle, so batches want to be a multiple of the pipe capacity — 64 KiB
  # batches measured 3.0× a single-binary write, 1 MiB batches close it.
  @list_coalesce_bytes 1_048_576

  @doc """
  Starts the stdin writer for `input`. Returns the `Task`, or `nil` when there
  is no input to write.

  Accepts a binary or any `Enumerable` of iodata chunks (a list, a `Stream`,
  a `File.stream!`, ...) — every element must itself be iodata, so an
  enumerable of bare integers (a `Range`, a charlist) is rejected at write
  time. `nil` closes stdin immediately and starts no task. Every clause
  closes stdin exactly once, after the last chunk.

  `buffer` (bytes) controls coalescing for *lazy* enumerables: `0` (the
  default) keeps today's element-granular write-through — interactive stdin
  (PTY REPLs) depends on it — while a positive value batches elements into
  iodata writes of up to that many bytes, trading stdin latency for
  throughput. Eager lists always coalesce: they are fully realised, so the
  granularity is unobservable.
  """
  @spec start(pid(), binary() | Enumerable.t() | nil, non_neg_integer()) :: Task.t() | nil
  def start(pid, input, buffer \\ 0)

  def start(pid, nil, _buffer) do
    Proc.close_stdin(pid)
    nil
  end

  def start(pid, input, _buffer) when is_binary(input) do
    Task.async(fn ->
      Proc.write(pid, input)
      Proc.close_stdin(pid)
    end)
  end

  def start(pid, list, _buffer) when is_list(list) do
    # Coalesce (and flatten) in the CALLER, before Task.async: the writer
    # closure otherwise captures the raw list, and spawning copies its entire
    # structure into the task heap — 200k tiny elements is ~3.4 MB of conses
    # plus a refc bump per binary, which measured ~20 ms alone. A handful of
    # flat batch binaries cross the boundary for free.
    batches = list_batches(list, @list_coalesce_bytes)

    Task.async(fn ->
      Enum.each(batches, &Proc.write(pid, &1))
      Proc.close_stdin(pid)
    end)
  end

  def start(pid, enumerable, 0) do
    Task.async(fn ->
      Enum.each(enumerable, &Proc.write(pid, &1))
      Proc.close_stdin(pid)
    end)
  end

  def start(pid, enumerable, buffer) when is_integer(buffer) and buffer > 0 do
    Task.async(fn ->
      write_coalesced(pid, enumerable, buffer)
      Proc.close_stdin(pid)
    end)
  end

  @doc """
  Pre-coalesces an eager list input into flat batch binaries; every other
  input shape passes through untouched.

  `run/2` calls this in the *caller's* process before spawning its I/O task:
  every `Task.async` closure that captures a raw list copies the whole list
  structure into the task heap, and the input crosses two task boundaries on
  the run path. Already-coalesced input re-entering `start/3` is a cheap
  no-op-shaped pass (one batch per oversized element).
  """
  @spec prepare(term()) :: term()
  def prepare(list) when is_list(list), do: list_batches(list, @list_coalesce_bytes)
  def prepare(other), do: other

  @doc """
  Validates an `:input_buffer` option value, raising `ArgumentError` on a
  malformed one. Returns the value.

  Shared by both entry points (`NetRunner.run/2` and `NetRunner.Stream`) so
  the accepted shapes and the error message cannot drift apart.
  """
  @spec validate_buffer!(term()) :: non_neg_integer()
  def validate_buffer!(bytes) when is_integer(bytes) and bytes >= 0, do: bytes

  def validate_buffer!(other) do
    raise ArgumentError,
          ":input_buffer must be a non-negative integer (bytes), got: #{inspect(other)}"
  end

  # Chunks the enumerable's iodata elements into batches of up to `limit`
  # bytes (soft limit: the element that crosses it is included, so a batch
  # can reach `limit - 1 + element_size`; elements are never split) and
  # writes each batch once (`IO.iodata_to_binary/1` happens at the
  # Proc.write boundary anyway).
  defp write_coalesced(pid, enumerable, limit) do
    enumerable
    |> Stream.chunk_while(
      {[], 0},
      fn el, {acc, n} ->
        size = IO.iodata_length(el)

        if n + size >= limit do
          {:cont, Enum.reverse([el | acc]), {[], 0}}
        else
          {:cont, {[el | acc], n + size}}
        end
      end,
      fn
        {[], _n} -> {:cont, {[], 0}}
        {acc, _n} -> {:cont, Enum.reverse(acc), {[], 0}}
      end
    )
    |> Enum.each(&Proc.write(pid, &1))
  end

  # Eager twin of write_coalesced/3 for lists: batches the elements into flat
  # binaries of up to `limit` bytes (soft limit, as above; elements are never
  # split). Returns the batches in write order.
  defp list_batches(list, limit) do
    {batches, acc, _n} =
      Enum.reduce(list, {[], [], 0}, fn el, {batches, acc, n} ->
        size = IO.iodata_length(el)

        if n + size >= limit do
          {[flush_batch(Enum.reverse([el | acc])) | batches], [], 0}
        else
          {batches, [el | acc], n + size}
        end
      end)

    batches =
      if acc == [],
        do: batches,
        else: [flush_batch(Enum.reverse(acc)) | batches]

    Enum.reverse(batches)
  end

  # A single-element batch that is already a binary passes through untouched:
  # `:erlang.iolist_to_binary/1` fast-paths a bare binary but memcpy's a
  # single-binary LIST, and this is what makes re-entering `list_batches/2`
  # with already-prepared input (run/2 calls prepare/1, then start/3's list
  # clause coalesces again) a true no-op instead of a full second copy.
  defp flush_batch([bin]) when is_binary(bin), do: bin
  defp flush_batch(batch), do: IO.iodata_to_binary(batch)

  @doc """
  Reaps a writer started by `start/2`. Must run in the process that called
  `start/2`.

  `Task.async` links, so an *abnormal* writer exit has already torn the caller
  down before this runs — the reap exists to stop a *live* writer leaking,
  which a `:normal` exit signal from the caller would not do.

    * `:done` — the reader reached :eof. Join, then kill if wedged.
    * `:halted` — the reader stopped early and the child is being killed
      anyway. There is nothing left to write, so do not wait for it.
  """
  @spec reap(Task.t() | nil, :done | :halted) :: :ok
  def reap(nil, _mode), do: :ok

  def reap(writer, :done) do
    Task.yield(writer, @reap_grace_ms) || Task.shutdown(writer, :brutal_kill)
    :ok
  end

  def reap(writer, :halted) do
    Task.shutdown(writer, :brutal_kill)
    :ok
  end
end
