exclude =
  case :os.type() do
    {:unix, :linux} -> []
    _ -> [:linux_only]
  end

ExUnit.start(exclude: exclude)

# Clean up any stale UDS sockets left behind by previous test runs that
# crashed before cleanup_listener could remove them.
defmodule NetRunner.TestCleanup do
  def purge_stale_sockets do
    pattern = Path.join(System.tmp_dir!(), "net_runner_*.sock")
    pattern |> Path.wildcard() |> Enum.each(&File.rm/1)
  end
end

NetRunner.TestCleanup.purge_stale_sockets()
ExUnit.after_suite(fn _ -> NetRunner.TestCleanup.purge_stale_sockets() end)
