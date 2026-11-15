defmodule NetRunner.SecurityTest do
  use ExUnit.Case, async: true

  import Bitwise
  import NetRunner.TestHelpers

  alias NetRunner.Process, as: Proc

  describe "port FD hygiene (SEC-3)" do
    test "the child does not inherit the BEAM port FDs 3/4" do
      # With :nouse_stdio the shepherd talks to the BEAM over fds 3/4. Those
      # must be CLOEXEC so the child cannot read from or scribble into the
      # port protocol. A write to a closed fd fails and the shell exits
      # non-zero; without the fix fd 4 is the port's input pipe and the
      # write would succeed.
      {_out, status3} = NetRunner.run(["sh", "-c", "echo x >&3 2>/dev/null"])
      assert status3 != 0, "fd 3 leaked into the child"

      {_out, status4} = NetRunner.run(["sh", "-c", "echo x >&4 2>/dev/null"])
      assert status4 != 0, "fd 4 leaked into the child"
    end
  end

  describe ":env option (SEC-9)" do
    test "malformed env raises at Proc.start, before anything is spawned" do
      for bad <- [
            %{"A=B" => "x"},
            %{"" => "x"},
            %{"OK" => "a\0b"},
            %{"OK" => <<0xFF>>},
            {:merge, %{"OK" => "x"}}
          ] do
        assert_raise ArgumentError, ~r/:env/, fn ->
          Proc.start("echo", ["x"], env: bad)
        end
      end
    end
  end

  describe "set_window_size validation (SEC-10)" do
    test "rejects values outside the 2-byte protocol range" do
      {:ok, pid} = Proc.start("cat", [], pty: true)

      assert {:error, :invalid_window_size} = Proc.set_window_size(pid, -1, 80)
      assert {:error, :invalid_window_size} = Proc.set_window_size(pid, 24, 70_000)
      assert {:error, :invalid_window_size} = Proc.set_window_size(pid, :rows, 80)

      assert :ok = Proc.set_window_size(pid, 24, 80)

      Proc.kill(pid, :sigkill)
      Proc.await_exit(pid)
    end
  end

  describe ":stderr_tail_bytes cap (SEC-11)" do
    test "rejects a tail above 1 MiB" do
      assert_raise ArgumentError, ~r/1048576/, fn ->
        Proc.start("echo", ["x"], stderr_tail_bytes: 1_048_577)
      end

      # The maximum itself is accepted.
      {:ok, pid} = Proc.start("echo", ["x"], stderr_tail_bytes: 1_048_576)
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe ":kill_timeout validation" do
    test "rejects values the shepherd would refuse, in the caller" do
      # Out-of-range or non-integer values make the shepherd exit before
      # connecting, with the reason only on the VM's stderr.
      for bad <- [0, 60_001, 5000.0, "5000", nil] do
        assert_raise ArgumentError, ~r/:kill_timeout/, fn ->
          Proc.start("echo", ["x"], kill_timeout: bad)
        end
      end

      {:ok, pid} = Proc.start("echo", ["x"], kill_timeout: 60_000)
      assert {:ok, 0} = Proc.await_exit(pid)
    end
  end

  describe "shepherd argv terminator" do
    test "a command whose name starts with '-' is never parsed as a shepherd flag" do
      # Before the "--" terminator, cmd: "--kill-timeout" consumed the next
      # argv entry as a shepherd option and exec'd whatever followed. Now the
      # shepherd must try to exec the literal flag name and fail (127).
      for {flag, rest} <- [
            {"--kill-timeout", ["1"]},
            {"--cwd", ["/"]},
            {"--replace-env", ["0"]},
            {"--cgroup-path", ["net_runner/x"]},
            {"--pty", []},
            {"--token-fd", []},
            {"--", []}
          ] do
        assert {"", 127, stderr} =
                 NetRunner.run([flag | rest] ++ ["sh", "-c", "echo pwned"], stderr: :capture)

        assert stderr =~ flag
        refute stderr =~ "pwned"
      end
    end
  end

  describe "shepherd token read" do
    # The BEAM unlinks the port for the token write, so a spawner that dies
    # before writing does not necessarily close fd 3. The shepherd must not
    # wait for the token forever.
    test "a shepherd that never receives its token gives up" do
      # --token-timeout shortens the 10 s default wait (T-19).
      port = open_tokenless_shepherd(["--token-timeout", "200"])
      assert {output, 1} = await_shepherd_exit(port)
      assert output =~ "timed out waiting for token"
    end

    test "--token-timeout is range-checked like --kill-timeout" do
      port = open_tokenless_shepherd(["--token-timeout", "0"])
      assert {output, 1} = await_shepherd_exit(port)
      assert output =~ "--token-timeout must be 1-60000 ms"
    end

    test "a shepherd whose token channel closes early exits promptly" do
      # Five bytes of the 32-byte token, then EOF on fd 3.
      port = open_tokenless_shepherd([], "00000")
      assert {output, 1} = await_shepherd_exit(port)
      assert output =~ "BEAM closed before sending token"
    end
  end

  describe "handshake authentication (S-07, T-05)" do
    alias NetRunner.Process.Exec

    @token String.duplicate("ab", 16)

    setup do
      # Peer-uid checks compare against the uid recorded with the UDS base
      # dir, which the first spawn creates.
      {"", 0} = NetRunner.run(~w(true))
      :ok
    end

    defp far_deadline, do: System.monotonic_time(:millisecond) + 10_000

    test "the correct token is accepted" do
      {beam_side, peer} = uds_pair()
      :ok = :socket.send(peer, @token)
      assert :ok = Exec.authenticate_shepherd(beam_side, @token, far_deadline())
    end

    test "a wrong token is rejected" do
      {beam_side, peer} = uds_pair()
      :ok = :socket.send(peer, String.duplicate("x", 32))

      assert {:error, :shepherd_auth_failed} =
               Exec.authenticate_shepherd(beam_side, @token, far_deadline())
    end

    # A same-uid peer that connects and stays silent used to hold the accept
    # loop for the whole 10 s deadline, failing the real spawn queued behind
    # it. Each connection now gets at most 250 ms.
    test "a silent peer is dropped after ~250 ms, not the whole deadline" do
      {beam_side, _peer} = uds_pair()

      {us, result} =
        :timer.tc(fn -> Exec.authenticate_shepherd(beam_side, @token, far_deadline()) end)

      assert {:error, {:shepherd_auth_failed, :timeout}} = result
      assert us in 200_000..2_000_000, "silent peer held the accept loop #{div(us, 1000)} ms"
    end
  end

  describe "received fds are close-on-exec (S-04)" do
    @tag :linux_only
    test "stdin, stdout and the pidfd carry FD_CLOEXEC in the BEAM" do
      {:ok, pid} = Proc.start("cat", [])
      on_exit(fn -> Proc.stop(pid) end)
      os_pid = Proc.os_pid(pid)

      {:ok, stdin_link} = File.read_link("/proc/#{os_pid}/fd/0")
      {:ok, stdout_link} = File.read_link("/proc/#{os_pid}/fd/1")

      held = beam_fds_linking_to(stdin_link) ++ beam_fds_linking_to(stdout_link)
      assert length(held) == 2, "expected the BEAM's stdin and stdout ends, got #{inspect(held)}"

      pidfds =
        if :sys.get_state(pid).pidfd, do: beam_fds_linking_to("anon_inode:[pidfd]"), else: []

      for {fd, flags} <- held ++ pidfds do
        assert band(flags, 0o2000000) != 0,
               "fd #{fd} lacks O_CLOEXEC (flags #{inspect(flags, base: :octal)})"
      end
    end
  end

  describe "UDS base directory (SEC-5)" do
    test "lives in a 0700 directory owned by us" do
      # Force at least one spawn so the base dir exists.
      assert {"x\n", 0} = NetRunner.run(~w(echo x))

      {dir, uid} = :persistent_term.get({NetRunner.Process.Exec, :uds_base_dir})
      assert %File.Stat{type: :directory, mode: mode, uid: ^uid} = File.lstat!(dir)
      assert band(mode, 0o7777) == 0o700
    end
  end

  # Runs the shepherd up to its token read, behind a /bin/sh wrapper that sets
  # up fd 3, because :stderr_to_stdout (which brings the shepherd's error
  # line back as port data instead of leaking it into the suite output)
  # excludes the :nouse_stdio fd 3/4 channel. Without `token_feed`, fd 3 is
  # the port's input, as in production; with it, fd 3 is a pipe that
  # delivers `token_feed` and then closes.
  defp open_tokenless_shepherd(extra_flags, token_feed \\ nil) do
    shepherd = Path.join(to_string(:code.priv_dir(:net_runner)), "shepherd")
    socket_path = Path.join(System.tmp_dir!(), "nr_unused_#{System.unique_integer([:positive])}")

    {script, env} =
      if token_feed do
        {~S[printf %s "$NR_TOKEN_FEED" | { exec 3<&0 </dev/null; exec "$0" "$@"; }],
         [{~c"NR_TOKEN_FEED", String.to_charlist(token_feed)}]}
      else
        {~S|exec 3<&0; exec "$0" "$@"|, []}
      end

    Port.open(
      {:spawn_executable, "/bin/sh"},
      [
        :stderr_to_stdout,
        :exit_status,
        :binary,
        env: env,
        args:
          ["-c", script, shepherd, socket_path, "--token-fd" | extra_flags] ++
            ["--", "/bin/true"]
      ]
    )
  end

  # Everything the port printed, and its exit status.
  defp await_shepherd_exit(port, acc \\ []) do
    receive do
      {^port, {:data, data}} -> await_shepherd_exit(port, [acc | data])
      {^port, {:exit_status, status}} -> {IO.iodata_to_binary(acc), status}
    after
      3_000 -> flunk("shepherd did not exit; output so far: #{inspect(acc)}")
    end
  end

  # The pipe end or pidfd the BEAM holds for `link` ("pipe:[ino]",
  # "anon_inode:[pidfd]"), with its fdinfo flags.
  defp beam_fds_linking_to(link) do
    for fd <- File.ls!("/proc/self/fd"),
        File.read_link("/proc/self/fd/#{fd}") == {:ok, link},
        {:ok, info} <- [File.read("/proc/self/fdinfo/#{fd}")],
        [_, flags] <- [Regex.run(~r/^flags:\s+([0-7]+)$/m, info)],
        do: {fd, String.to_integer(flags, 8)}
  end
end
