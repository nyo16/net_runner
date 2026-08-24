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

  @doc """
  Starts the stdin writer for `input`. Returns the `Task`, or `nil` when there
  is no input to write.

  Accepts a binary, a list of binaries, or a `Stream`. `nil` closes stdin
  immediately and starts no task. Every clause closes stdin exactly once,
  after the last chunk.
  """
  @spec start(pid(), binary() | list() | Enumerable.t() | nil) :: Task.t() | nil
  def start(pid, nil) do
    Proc.close_stdin(pid)
    nil
  end

  def start(pid, input) when is_binary(input) do
    Task.async(fn ->
      Proc.write(pid, input)
      Proc.close_stdin(pid)
    end)
  end

  def start(pid, %Stream{} = input), do: start(pid, {:enumerable, input})

  def start(pid, input) when is_list(input), do: start(pid, {:enumerable, input})

  def start(pid, {:enumerable, enumerable}) do
    Task.async(fn ->
      Enum.each(enumerable, &Proc.write(pid, &1))
      Proc.close_stdin(pid)
    end)
  end

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
