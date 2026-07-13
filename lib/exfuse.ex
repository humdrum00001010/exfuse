defmodule Exfuse do
  @moduledoc """
  API calls to mount, and manage filesystems.

  Exfuse assumes it owns its mount points: a path passed to `mount/4` must not
  be mounted by anything else. Under that assumption the lifecycle is fully
  managed here — one server per mount point (a second `mount/4` of the same
  point returns `{:error, {:already_mounted, pid}}`), a mount left orphaned in
  the kernel table by a crashed host VM is healed before remounting, transient
  FSKit "Resource busy" failures are retried, the mount is verified against
  the OS mount table before `mount/4` returns (rolled back if it never
  arrives), and `umount/2` settles or force-cleans the mount leaf.
  """

  # Transient FSKit "Resource busy" (a just-torn-down mount still settling):
  # rerun mount(8) against the same live server/wire listener.
  @busy_retries 12
  @busy_retry_ms 300
  # Post-mount verification poll (~2s total, matching the old best-effort
  # settle wait — but failing the mount instead of shrugging).
  @verify_tries 8
  @verify_interval_ms 250
  # How long umount/2 waits for the kernel table to clear before force-cleaning.
  @umount_settle_ms 1_000

  @doc """
  Mount a filesystem. The three parameters are the mount point, the callback
  module which implements the filesystem, and a term, which can be anything, and
  is passed to the filesystem implementation initialisation.

  See `Exfuse.Fs` for information on how to implement a filesystem callback
  module.

      iex> Exfuse.mount("/tmp/my_elixir_fs", MyApp.Filesystem, my_fs_opts)
      {:ok, #PID<0.194.0>}

  Returns `{:error, {:already_mounted, pid}}` when this point already has a
  live server.

  The mount is verified before returning: by default `mount/4` polls the OS
  mount table and rolls the server back with `{:error, :mount_not_visible}`
  if the kernel mount never appears. Pass `verify: :serving` to additionally
  require a successful directory read (see `serving?/1` — only for
  filesystems whose root readdir succeeds), or `verify: false` to skip
  verification (test stubs).

  Some example filesystems are provided which you can experiment with, and also
  inspect for improved understanding of how a filesystem is implemented.
  """

  @spec mount(String.t(), module, term, keyword) :: {:ok, pid} | {:error, term}

  def mount(mount_point, fs_mod, fs_state, opts \\ []) do
    backend = Keyword.get(opts, :backend, backend())

    with {:ok, backend_opts} <- prepare_backend(mount_point, backend, opts),
         :ok <- heal_mount_point(mount_point),
         {:ok, pid} <- start_server(mount_point, fs_mod, fs_state, backend, opts, backend_opts) do
      attach_and_verify(mount_point, pid, backend, opts, backend_opts)
    end
  end

  @doc """
  Whether the mount point is present in the OS mount table (realpath-aware).
  """
  @spec mounted?(String.t()) :: boolean()
  def mounted?(mount_point) when is_binary(mount_point) do
    any_mounted?(mount_candidates(mount_point))
  end

  @doc """
  Whether the mount point is in the OS mount table AND answers a directory
  read. Probes with an external `ls` — never in-beam `File.*`: the filesystem
  handlers run in this VM, so an in-beam file operation on the mount deadlocks
  the global `:file_server`. A mount orphaned by a VM crash stays in the table
  but fails this probe fast.

  Only meaningful for filesystems whose root readdir succeeds.
  """
  @spec serving?(String.t()) :: boolean()
  def serving?(mount_point) when is_binary(mount_point) do
    mounted?(mount_point) and
      match?({_out, 0}, System.cmd("ls", [mount_point], stderr_to_stdout: true))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp start_server(mount_point, fs_mod, fs_state, backend, opts, backend_opts) do
    server_opts =
      opts
      |> Keyword.merge(backend_opts)
      |> Keyword.put(:backend, backend)

    case Exfuse.MountSup.start_child(mount_point, fs_mod, fs_state, server_opts) do
      {:error, {:already_started, pid}} -> {:error, {:already_mounted, pid}}
      other -> other
    end
  end

  defp attach_and_verify(mount_point, pid, backend, opts, backend_opts) do
    with :ok <- attach_backend(mount_point, backend, opts, backend_opts, @busy_retries),
         :ok <- verify_mount(mount_point, opts) do
      {:ok, pid}
    else
      {:error, reason} ->
        stop_mount_server(pid)
        force_clean_leaf(mount_point)
        {:error, reason}
    end
  end

  # A mount point still in the kernel table with NO live server in this VM is
  # an orphan from a crashed host: any access EIOs, and mkdir/mount(8) over the
  # dead node fail. Force-unmount and drop the leaf before mounting again.
  defp heal_mount_point(mount_point) do
    if Registry.lookup(Exfuse.Registry, mount_point) == [] and mounted?(mount_point) do
      force_clean_leaf(mount_point)
    end

    :ok
  end

  defp verify_mount(mount_point, opts) do
    case Keyword.get(opts, :verify, :mounted) do
      false -> :ok
      :mounted -> poll_verify(mount_point, &mounted?/1, :mount_not_visible)
      :serving -> poll_verify(mount_point, &serving?/1, :mount_not_serving)
    end
  end

  defp poll_verify(mount_point, probe, error), do: poll_verify(mount_point, probe, error, @verify_tries)

  defp poll_verify(_mount_point, _probe, error, 0), do: {:error, error}

  defp poll_verify(mount_point, probe, error, tries) do
    if probe.(mount_point) do
      :ok
    else
      Process.sleep(@verify_interval_ms)
      poll_verify(mount_point, probe, error, tries - 1)
    end
  end

  # Force-unmount and drop the mount LEAF only (rmdir refuses non-empty dirs,
  # so real data is never touched); parents are the caller's business.
  defp force_clean_leaf(mount_point) do
    Enum.each(mount_candidates(mount_point), fn path ->
      _ = System.cmd("umount", ["-f", path], stderr_to_stdout: true)
    end)

    _ = File.rmdir(mount_point)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
        port = Keyword.get_lazy(opts, :wire_port, &available_wire_port!/0)
        session = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

        {:ok,
         wire_port: port,
         fskit_resource: %{
           device: "exfuse://127.0.0.1:#{port}/?session=#{session}",
           image: nil,
           owned: false
         }}
    end
  end

  defp available_wire_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
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

  # The FUSE port mounts on its own once the server is up; `verify_mount/2`
  # owns waiting for the kernel table on both backends.
  defp attach_backend(_mount_point, :fuse, _opts, _backend_opts, _retries), do: :ok

  defp attach_backend(mount_point, :fskit, opts, backend_opts, retries) do
    resource = backend_opts |> Keyword.fetch!(:fskit_resource) |> Map.fetch!(:device)
    File.mkdir_p!(mount_point)

    command = mount_command(opts)
    args = ["-F", "-t", "exfuse", resource, mount_point]
    timeout = Keyword.get(opts, :mount_timeout, 15_000)

    case run_command(command, args, timeout) do
      {_out, 0} ->
        :ok

      {:timeout, out} ->
        {:error, {:fskit_mount_timeout, timeout, String.trim(out)}}

      {:error, reason} ->
        {:error, {:fskit_mount_command_failed, reason}}

      {out, status} ->
        # A just-torn-down mount can leave the point transiently busy; the
        # server and its wire listener are untouched, so just rerun mount(8).
        if retries > 0 and String.contains?(out, "Resource busy") do
          Process.sleep(@busy_retry_ms)
          attach_backend(mount_point, :fskit, opts, backend_opts, retries - 1)
        else
          {:error, {:fskit_mount_failed, status, String.trim(out)}}
        end
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
  Unmount a filesystem. Idempotent: absent mounts are success.

      iex> Exfuse.umount("/tmp/my_elixir_fs")
      :ok

  Stops every server registered at the point, waits briefly for the kernel
  table to clear, and falls back to a force-unmount + leaf `rmdir` — which
  also reclaims a mount orphaned by a VM crash, where no server exists but
  the dead node still sits in the table.
  """

  @spec umount(String.t()) :: :ok

  def umount(mount_point) do
    list()
    |> Enum.filter(fn {_pid, {this_mount_point, _fs_mod, _fs_state, _os_pid}} ->
      this_mount_point == mount_point
    end)
    |> Enum.each(fn {pid, _status} -> stop_server(pid) end)

    unless settle_unmounted(mount_point) do
      force_clean_leaf(mount_point)
    end

    :ok
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

  defp settle_unmounted(mount_point) do
    deadline = System.monotonic_time(:millisecond) + @umount_settle_ms
    do_settle_unmounted(mount_candidates(mount_point), deadline)
  end

  defp do_settle_unmounted(paths, deadline) do
    cond do
      not any_mounted?(paths) ->
        true

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(50)
        do_settle_unmounted(paths, deadline)

      true ->
        false
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

  defp any_mounted?(paths) do
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
