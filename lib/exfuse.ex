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

  @spec mount(String.t(), module, term, keyword) :: {:ok, pid} | {:error, term}

  def mount(mount_point, fs_mod, fs_state, opts \\ []) do
    backend = Keyword.get(opts, :backend, backend())

    case prepare_backend(mount_point, backend, opts) do
      {:ok, backend_opts} ->
        start_mount(mount_point, fs_mod, fs_state, backend, opts, backend_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_mount(mount_point, fs_mod, fs_state, backend, opts, backend_opts) do
    server_opts =
      opts
      |> Keyword.merge(backend_opts)
      |> Keyword.put(:backend, backend)

    case Exfuse.MountSup.start_child(
           mount_point,
           fs_mod,
           fs_state,
           server_opts
         ) do
      {:ok, pid} ->
        case mount_backend(mount_point, backend, opts, backend_opts) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            stop_mount_server(pid)
            {:error, reason}
        end

      other ->
        other
    end
  end

  # The FUSE/libfuse backend serves non-mac systems only; macOS mounts through
  # FSKit and the port binary is not even built there.
  defp prepare_backend(_mount_point, :fuse, _opts) do
    case :os.type() do
      {:unix, :darwin} -> {:error, :fuse_backend_unsupported_on_macos}
      _ -> {:ok, []}
    end
  end

  # The default FSKit resource is a generic URL (`exfuse://127.0.0.1:<port>`)
  # pointing at the wire listener: it carries the backend port, needs no stub
  # disk image, and classifies the mount as URL-backed rather than local
  # block storage (local volumes are assumed cache-coherent by the kernel).
  # Pass `:resource` explicitly to mount from a block device instead.
  defp prepare_backend(_mount_point, :fskit, opts) do
    cond do
      resource = Keyword.get(opts, :resource) ->
        {:ok, fskit_resource: %{device: resource, image: nil, owned: false}}

      true ->
        port = Keyword.get(opts, :wire_port, 35_368)
        {:ok, fskit_resource: %{device: "exfuse://127.0.0.1:#{port}", image: nil, owned: false}}
    end
  end

  defp stop_mount_server(pid) do
    ref = Process.monitor(pid)
    _ = Exfuse.Server.stop(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :normal -> :ok
  end

  defp mount_backend(mount_point, :fuse, _opts, _backend_opts) do
    wait_until_mounted(mount_point)
    :ok
  end

  defp mount_backend(mount_point, :fskit, opts, backend_opts) do
    resource = backend_opts |> Keyword.fetch!(:fskit_resource) |> Map.fetch!(:device)
    File.mkdir_p!(mount_point)

    command = mount_command(opts)
    args = ["-F", "-t", "exfuse", resource, mount_point]
    timeout = Keyword.get(opts, :mount_timeout, 15_000)

    case run_command(command, args, timeout) do
      {_out, 0} ->
        wait_until_mounted(mount_point)
        :ok

      {:timeout, out} ->
        {:error, {:fskit_mount_timeout, timeout, String.trim(out)}}

      {:error, reason} ->
        {:error, {:fskit_mount_command_failed, reason}}

      {out, status} ->
        {:error, {:fskit_mount_failed, status, String.trim(out)}}
    end
  end

  defp mount_command(opts) do
    command = Keyword.get(opts, :mount_command, "mount")

    cond do
      Path.type(command) == :absolute -> command
      executable = System.find_executable(command) -> executable
      true -> command
    end
  end

  defp run_command(command, args, timeout) do
    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    collect_command(port, [], System.monotonic_time(:millisecond) + timeout)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp collect_command(port, chunks, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_command(port, [data | chunks], deadline)

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining ->
        kill_command_port(port)
        {:timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp kill_command_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        kill_command_pid(pid)

      _ ->
        :ok
    end

    Port.close(port)
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp kill_command_pid(pid) do
    pid = "#{pid}"
    System.cmd("kill", [pid], stderr_to_stdout: true)
    Process.sleep(100)

    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> System.cmd("kill", ["-9", pid], stderr_to_stdout: true)
      _ -> :ok
    end
  end

  defp backend do
    case :os.type() do
      {:unix, :darwin} -> :fskit
      _ -> :fuse
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

      matches ->
        pids = Enum.map(matches, fn {pid, _status} -> pid end)
        Enum.each(pids, &stop_server/1)
        {:ok, List.first(pids)}
    end
  end

  defp stop_server(pid) do
    :ok = Exfuse.Server.stop(pid)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :normal -> :ok
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
