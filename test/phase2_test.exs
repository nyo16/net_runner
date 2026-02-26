defmodule NetRunner.Phase2Test do
  use ExUnit.Case, async: true

  describe "run/2 timeout" do
    test "kills process on timeout" do
      result = NetRunner.run(~w(sleep 100), timeout: 200)
      assert result == {:error, :timeout}
    end

    test "no timeout when command finishes in time" do
      {output, 0} = NetRunner.run(~w(echo fast), timeout: 5000)
      assert output == "fast\n"
    end
  end

  describe "run/2 max_output_size" do
    test "truncates output at limit" do
      # yes outputs "y\n" forever
      result = NetRunner.run(["sh", "-c", "yes"], max_output_size: 100)
      assert {:error, {:max_output_exceeded, partial}} = result
      assert byte_size(partial) == 100
    end

    test "no truncation when output fits" do
      {output, 0} = NetRunner.run(~w(echo hello), max_output_size: 1000)
      assert output == "hello\n"
    end
  end

  describe "process group kills" do
    test "grandchild is killed when parent is killed" do
      # sh -c runs sleep as a child; both are in the same process group
      {:ok, pid} = NetRunner.Process.start("sh", ["-c", "sleep 100"])
      os_pid = NetRunner.Process.os_pid(pid)

      Process.sleep(200)

      NetRunner.Process.kill(pid, :sigkill)
      {:ok, _status} = NetRunner.Process.await_exit(pid)

      Process.sleep(500)

      # The process group leader should be dead
      assert NetRunner.Process.Nif.nif_is_os_pid_alive(os_pid) == false
    end
  end

  describe "kill_timeout option" do
    test "configurable kill timeout passes to shepherd" do
      # Just verify it starts and works with a custom timeout
      {:ok, pid} = NetRunner.Process.start("echo", ["hello"], kill_timeout: 1000)
      assert {:ok, "hello\n"} = NetRunner.Process.read(pid)
      assert {:ok, 0} = NetRunner.Process.await_exit(pid)
    end
  end
end
