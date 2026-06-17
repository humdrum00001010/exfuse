defmodule Exfuse do
  @moduledoc """
  API calls to mount, and manage filesystems.
  """

  @doc """
  Mount a filesystem. The three parameters are the mount point, the callback
  module which implements the filesystem, and a term, which can be anything, and
  is passed to the filesystem implementation initialisation.

  See `Exfuse.Fs` for information on how to implement a filesystem callback
  module.

      iex> Exfuse.mount("/tmp/my_elixir_fs", MyApp.Filesystem, my_fs_opts)
      {:ok, #PID<0.194.0>}

  Some example filesystems are provided which you can experiment with, and also
  inspect for improved understanding of how a filesystem is implemented.
  """

  @spec mount(String.t(), module, term) :: {:ok, pid}

  def mount(mount_point, fs_mod, fs_state) do
    case Exfuse.MountSup.start_child(mount_point, fs_mod, fs_state) do
      {:ok, pid} ->
        wait_until_mounted(mount_point)
        {:ok, pid}

      other ->
        other
    end
  end

  @doc """
  Unmount a filesystem.

      iex> Exfuse.umount("/tmp/my_elixir_fs")
      {:ok, #PID<0.194.0>}
  """

  @spec umount(String.t()) :: {:ok, pid} | {:error, :not_mounted}

  def umount(mount_point) do
    case Enum.filter(
           list(),
           fn {_pid, {this_mount_point, _fs_mod, _fs_state, _os_pid}} ->
             this_mount_point == mount_point
           end
         ) do
      [] ->
        {:error, :not_mounted}

      [{pid, _status}] ->
        try do
          :ok = Exfuse.Server.stop(pid)
        catch
          :exit, {:noproc, _} -> :ok
          :exit, :normal -> :ok
        end

        {:ok, pid}
    end
  end

  @doc """
  Enumerate the mounted filesystems. Returns a list of tuples, each
  tuple having two elements, the first being the PID of the Elixir process
  managing the FS, and the second being the status of the FS reported by it.
  The status is a tuple with four elements, the mount point of the FS, the
  callback module implementing the FS, the state of the FS (specific to the
  implementation module) and the OS PID of the port process which links the
  implementation module to the kernel of the OS.

      iex> Exfuse.list()
      [{#PID<0.194.0>, {"/tmp/foo", Exfuse.Fs.Hello, :ready, 29177}}]
  """

  @spec list() :: [{pid, {String.t(), atom, term, integer}}]

  def list() do
    Enum.filter(
      Enum.map(
        Exfuse.MountSup.which_children(),
        fn {:undefined, pid, :worker, [Exfuse.Server]} ->
          status =
            try do
              Exfuse.Server.status(pid, 1_000)
            catch
              :exit, {:noproc, _} -> :stopped
              :exit, {:normal, _} -> :stopped
              :exit, _reason -> :stopped
            end

          {pid, status}
        end
      ),
      fn {_pid, status} -> status !== :stopped end
    )
  end

  defp wait_until_mounted(mount_point) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_until_mounted(mount_candidates(mount_point), deadline)
  end

  defp do_wait_until_mounted(paths, deadline) do
    cond do
      mounted?(paths) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        do_wait_until_mounted(paths, deadline)

      true ->
        :ok
    end
  end

  defp mount_candidates(mount_point) do
    [mount_point, realpath(mount_point)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp realpath(path) do
    case System.find_executable("realpath") do
      nil ->
        nil

      realpath ->
        case System.cmd(realpath, [path], stderr_to_stdout: true) do
          {path, 0} -> String.trim(path)
          _ -> nil
        end
    end
  end

  defp mounted?(paths) do
    case System.find_executable("mount") do
      nil ->
        true

      mount ->
        case System.cmd(mount, [], stderr_to_stdout: true) do
          {mounts, 0} -> Enum.any?(paths, &String.contains?(mounts, " on #{&1} "))
          _ -> true
        end
    end
  end
end
