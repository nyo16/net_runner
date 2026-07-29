# Attributes the ~4.5 ms sequential spawn latency to phases.
#
#     MIX_ENV=prod mix run bench/spawn_breakdown.exs

alias NetRunner.Process, as: Proc

n = 200

t = fn label, fun ->
  {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
  IO.puts("#{String.pad_trailing(label, 44)} #{Float.round(us / n, 1)} us/op")
  us / n
end

IO.puts("\n=== spawn phase breakdown (n=#{n}, prod) ===\n")

# Warm.
NetRunner.run(["/usr/bin/true"])

# Baseline: what a bare fork+exec of the shepherd binary costs, with no UDS
# handshake, no child, no accept. Port.open returns before exec completes, so
# this is the BEAM-side cost only — see N3 in the plan scratchpad: it
# under-reports by design and the remainder is the accept() wait.
#
# Args are deliberately valid-shaped (a UDS path that does not exist, plus a
# command) so the shepherd fails at connect() rather than printing its usage
# banner 200 times to the BEAM's stderr. Both paths exit before doing any work.
shepherd = Path.join(to_string(:code.priv_dir(:net_runner)), "shepherd")
nowhere = Path.join(System.tmp_dir!(), "net_runner_bench_no_such.sock")

t.("Port.open(shepherd) + close, no handshake", fn ->
  p =
    Port.open({:spawn_executable, shepherd}, [
      :nouse_stdio,
      :exit_status,
      :binary,
      args: [nowhere, "/usr/bin/true"]
    ])

  try do
    Port.close(p)
  catch
    _, _ -> :ok
  end
end)

# The per-spawn dirty-IO stat flagged in the analysis.
dir = System.tmp_dir!()
t.("File.dir?/1 (per-spawn verification)", fn -> File.dir?(dir) end)

# :code.priv_dir + to_string + Path.join, per spawn.
t.("shepherd_executable/0 path resolution", fn ->
  Path.join(to_string(:code.priv_dir(:net_runner)), "shepherd")
end)

# UDS listener create + close + unlink, no shepherd involved.
t.("UDS open+bind+listen+close+unlink", fn ->
  path = Path.join(dir, "nrbench_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}.sock")
  {:ok, s} = :socket.open(:local, :stream, :default)
  :ok = :socket.bind(s, %{family: :local, path: path})
  :ok = :socket.listen(s)
  :socket.close(s)
  File.rm(path)
end)

# Full GenServer start: validation + listener + Port.open + accept + SCM_RIGHTS
# + 3x nif_create_fd + Watcher registration.
start_us =
  t.("Proc.start/3 (full spawn, no I/O)", fn ->
    {:ok, pid} = Proc.start(["/usr/bin/true"] |> hd(), [], [])
    Proc.await_exit(pid, 5_000)
    GenServer.stop(pid, :normal, 5_000)
  end)

# Watcher registration cost in isolation: a DynamicSupervisor.start_child round
# trip into the single WatcherSupervisor process.
t.("Watcher.watch/2 (DynamicSupervisor round trip)", fn ->
  {:ok, w} = NetRunner.Watcher.watch(self(), 1)
  GenServer.stop(w, :normal, 5_000)
end)

# End-to-end for reference.
run_us = t.("NetRunner.run(true) end to end", fn -> NetRunner.run(["/usr/bin/true"]) end)

IO.puts("\n  Proc.start is #{Float.round(start_us / run_us * 100, 1)}% of end-to-end run/2.\n")
