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

  @doc """
  Kills everything left in the leaf at `path` (relative to the cgroup v2
  root) and removes it, sub-cgroups first. Logs and returns
  `{:error, reason}` when the leaf cannot be removed within ~1 s.
  """
  @spec remove_orphaned_leaf(String.t()) :: :ok | {:error, File.posix()}
  def remove_orphaned_leaf(path) do
    leaf = @root <> path
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
