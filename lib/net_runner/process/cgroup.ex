defmodule NetRunner.Process.Cgroup do
  @moduledoc false

  # BEAM-side cgroup teardown, for the one case the shepherd cannot cover:
  # its own abnormal death (SIGKILL, OOM). It normally owns cgroup.kill and
  # the rmdir of its leaf; dead, it leaves the leaf behind, and every later
  # spawn on the same :cgroup_path fails with "already exists". The leaf is
  # ours to remove: a spawn only reaches MSG_CHILD_STARTED after the shepherd
  # created it (a pre-existing leaf fails the spawn).

  require Logger

  @root "/sys/fs/cgroup/"

  # Same schedule as the shepherd's cgroup_cleanup: 1, 2, 4 ... 512 ms, ~1 s.
  @max_delay_ms 512

  @typedoc "A leaf this spawn created: its path and the inode it had then."
  @type leaf :: {String.t(), non_neg_integer()}

  @doc """
  Records the identity of the leaf at `path`, right after a successful spawn
  (the shepherd created it before MSG_CHILD_STARTED). `nil` when there is no
  cgroup or it cannot be stat'ed, in which case no cleanup is ever attempted.
  """
  @spec identify(String.t() | nil) :: leaf() | nil
  def identify(nil), do: nil

  def identify(path) do
    case File.stat(@root <> path) do
      {:ok, %File.Stat{inode: inode}} -> {path, inode}
      {:error, _} -> nil
    end
  end

  @doc """
  Kills everything left in `leaf` and removes it, sub-cgroups first. Does
  nothing when the path now names a different cgroup than the one recorded
  by `identify/1`: a shepherd that died after removing its own leaf leaves
  the path free for another spawn, whose processes must not be killed. Logs
  and returns `{:error, reason}` when the leaf cannot be removed within ~1 s.
  """
  @spec remove_orphaned_leaf(leaf()) :: :ok | :not_ours | {:error, File.posix()}
  def remove_orphaned_leaf({path, inode}) do
    full = @root <> path

    case File.stat(full) do
      {:ok, %File.Stat{inode: ^inode}} -> kill_and_remove(path, full)
      {:ok, _other} -> :not_ours
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp kill_and_remove(path, leaf) do
    # Recursive: also reaches descendants that left the child's process
    # group (setsid daemonisers), which the BEAM's group kill cannot.
    _ = File.write(Path.join(leaf, "cgroup.kill"), "1")

    case rmdir_with_backoff(leaf, 1) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "[NetRunner] could not remove orphaned cgroup #{inspect(path)}: #{inspect(reason)}; " <>
            "later spawns on this :cgroup_path will fail until it is removed"
        )

        error
    end
  end

  defp rmdir_with_backoff(leaf, delay_ms) do
    case rmdir_tree(leaf) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      # The kernel reaps the cgroup.kill'ed processes asynchronously; cgroup
      # v2 refuses rmdir on a populated cgroup until then.
      {:error, reason} when reason in [:ebusy, :eexist, :enotempty] and delay_ms <= @max_delay_ms ->
        Process.sleep(delay_ms)
        rmdir_with_backoff(leaf, delay_ms * 2)

      {:error, _} = error ->
        error
    end
  end

  # cgroupfs has no unlinkable files and no symlinks: a cgroup is removed by
  # rmdir alone, once its sub-cgroups are gone.
  defp rmdir_tree(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.each(&rmdir_tree/1)

        File.rmdir(dir)

      {:error, _} = error ->
        error
    end
  end
end
