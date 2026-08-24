# Is NetRunner's ~4.4 ms spawn NetRunner's overhead, or this machine's exec cost?
#
#     MIX_ENV=prod mix run bench/exec_baseline.exs
#
# NetRunner performs TWO execs per spawn (shepherd, then the child). System.cmd
# performs ONE. The comparison isolates NetRunner's own coordination cost from
# the platform's fork+exec price.

n = 200

t = fn label, fun ->
  {us, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
  per = us / n
  IO.puts("#{String.pad_trailing(label, 48)} #{Float.round(per, 1)} us/op")
  per
end

IO.puts("\n=== exec cost baseline (n=#{n}, prod) ===\n")

NetRunner.run(["/usr/bin/true"])
System.cmd("/usr/bin/true", [])

one_exec =
  t.("System.cmd(true) — 1 exec, BEAM port", fn ->
    System.cmd("/usr/bin/true", [])
  end)

port_exec =
  t.("Port.open(true) + await exit_status — 1 exec", fn ->
    p = Port.open({:spawn_executable, "/usr/bin/true"}, [:nouse_stdio, :exit_status, :binary])

    receive do
      {^p, {:exit_status, _}} -> :ok
    after
      5_000 -> :timeout
    end
  end)

nr = t.("NetRunner.run(true) — 2 execs + UDS handshake", fn -> NetRunner.run(["/usr/bin/true"]) end)

IO.puts("""

  1 exec (System.cmd)        #{Float.round(one_exec, 0)} us
  1 exec (raw Port)          #{Float.round(port_exec, 0)} us
  2 execs (NetRunner)        #{Float.round(nr, 0)} us
  NetRunner overhead above 2x raw exec: #{Float.round(nr - 2 * port_exec, 0)} us
""")
