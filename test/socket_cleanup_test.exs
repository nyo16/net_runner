defmodule NetRunner.SocketCleanupTest do
  # Socket paths share one directory. Serial execution makes each listing exact.
  use ExUnit.Case, async: false

  @true_cmd System.find_executable("true") ||
              raise("these tests require `true`")

  setup do
    # The shared directory is lazy. Initialize it before recording its contents.
    assert {_output, 0} = NetRunner.run([@true_cmd])
    {:ok, sockets: socket_files()}
  end

  describe "the shared socket directory" do
    test "a shepherd that never started leaves no socket behind", %{sockets: before} do
      unexecable = String.duplicate("a", 2_000_000)

      assert {:error, {:shepherd_spawn_failed, _reason}} =
               NetRunner.run([@true_cmd, unexecable])

      assert socket_files() == before
    end

    test "a successful spawn leaves no socket behind", %{sockets: before} do
      assert {_output, 0} = NetRunner.run([@true_cmd])
      assert socket_files() == before
    end
  end

  defp socket_files do
    {dir, _uid} = :persistent_term.get({NetRunner.Process.Exec, :uds_base_dir})
    dir |> Path.join("*.sock") |> Path.wildcard() |> Enum.sort()
  end
end
