defmodule NetRunner.BackpressurePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias NetRunner.Process, as: Proc

  # Pipe capacity is 64 KiB (macOS) / 1 MiB (Linux, grown by the shepherd).
  # Chunk sizes range from empty up to ~3x the 64 KiB capacity so runs cross
  # every interesting boundary: sub-chunk, exactly-full pipe, and multi-pass
  # writes that must park and resume without duplicating or dropping bytes.
  @max_chunk 196_608

  property "arbitrary chunk sequences round-trip through cat byte-for-byte" do
    check all(
            chunks <-
              StreamData.list_of(StreamData.binary(min_length: 0, max_length: @max_chunk),
                max_length: 8
              ),
            max_runs: 25
          ) do
      expected = IO.iodata_to_binary(chunks)

      assert {output, 0} = NetRunner.run(~w(cat), input: chunks, timeout: 30_000)
      assert output == expected
    end
  end

  # Same round-trip through the stream!/2 consumer, which is batch-backed:
  # each resource step may emit several chunks. Ordering and byte identity
  # must hold regardless of how the batches split.
  property "arbitrary chunk sequences round-trip through cat via stream!/2" do
    check all(
            chunks <-
              StreamData.list_of(StreamData.binary(min_length: 0, max_length: @max_chunk),
                max_length: 8
              ),
            max_runs: 25
          ) do
      expected = IO.iodata_to_binary(chunks)

      output =
        NetRunner.stream!(~w(cat), input: chunks)
        |> Enum.into(<<>>)

      assert output == expected
    end
  end

  # Many tiny elements exercise the eager-list coalescing path in
  # InputWriter. cat can only observe the byte stream, so the property
  # proves byte identity (no loss, duplication, or reordering) across
  # whatever batching list_batches chose.
  property "many tiny chunks round-trip through cat byte-for-byte" do
    check all(
            chunks <-
              StreamData.list_of(StreamData.binary(min_length: 1, max_length: 8),
                max_length: 2_000
              ),
            max_runs: 10
          ) do
      expected = IO.iodata_to_binary(chunks)

      assert {output, 0} = NetRunner.run(~w(cat), input: chunks, timeout: 30_000)
      assert output == expected
    end
  end

  # Lazy twin: random element sizes AND a random :input_buffer hit
  # write_coalesced/3's chunk boundaries — an element that crosses the
  # limit closes its batch, oversized elements go out alone, and the
  # chunk_while after-fun must flush the partial batch.
  property "lazy chunk sequences round-trip under any input_buffer" do
    check all(
            chunks <-
              StreamData.list_of(StreamData.binary(min_length: 1, max_length: 4_096),
                max_length: 200
              ),
            buffer <- StreamData.integer(1..131_072),
            max_runs: 15
          ) do
      expected = IO.iodata_to_binary(chunks)
      lazy = Stream.map(chunks, & &1)

      assert {output, 0} =
               NetRunner.run(~w(cat), input: lazy, input_buffer: buffer, timeout: 30_000)

      assert output == expected
    end
  end

  # Proc-level twin: drives the write path with *iodata* elements (nested
  # lists of binaries, not just flat binaries — write/2 accepts iodata) and
  # cross-checks the stats ledger against the bytes that round-tripped. Byte
  # identity alone would pass a Process whose accounting drifted.
  #
  # Totals stay under ~64 KiB: all writes complete before any read, so the
  # payload must fit in the stdin pipe + cat's stdout pipe (>= 128 KiB on
  # every platform) or the unread output would park the writer forever.
  property "iodata writes round-trip and the stats ledger balances" do
    check all(
            chunks <-
              StreamData.list_of(
                StreamData.list_of(StreamData.binary(min_length: 0, max_length: 2_048),
                  max_length: 4
                ),
                max_length: 8
              ),
            max_runs: 15
          ) do
      expected = IO.iodata_to_binary(chunks)

      {:ok, pid} = Proc.start("cat", [])

      Enum.each(chunks, fn iodata -> assert :ok = Proc.write(pid, iodata) end)
      :ok = Proc.close_stdin(pid)

      assert read_all(pid, []) == expected
      assert {:ok, 0} = Proc.await_exit(pid, 30_000)

      stats = Proc.stats(pid)
      assert stats.bytes_in == byte_size(expected)
      assert stats.bytes_out == byte_size(expected)

      GenServer.stop(pid)
    end
  end

  defp read_all(pid, acc) do
    case Proc.read_batch(pid) do
      {:ok, chunks} -> read_all(pid, [acc | chunks])
      _eof_or_exited -> IO.iodata_to_binary(acc)
    end
  end
end
