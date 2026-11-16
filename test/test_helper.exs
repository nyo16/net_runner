# :linux_only needs Linux (cgroups, /proc, pidfd); :non_linux pins the
# off-Linux contract (isolation options are rejected there).
exclude =
  case :os.type() do
    {:unix, :linux} -> [:non_linux]
    _ -> [:linux_only]
  end

ExUnit.start(exclude: exclude)

# Spawn sockets live in one private net_runner_<random>/ directory per VM
# (Exec.uds_base_dir); each socket file is removed by its spawn. Remove this
# VM's directory after the suite so test runs do not accumulate empty
# directories in the temp dir.
ExUnit.after_suite(fn _ ->
  case :persistent_term.get({NetRunner.Process.Exec, :uds_base_dir}, nil) do
    {dir, _uid} -> File.rm_rf(dir)
    nil -> :ok
  end
end)
