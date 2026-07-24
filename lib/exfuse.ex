defmodule Exfuse do
  alias Exfuse.Command

  @moduledoc "Filesystem runtime and native mount API."

  @busy_retries 12
  @busy_retry_ms 300
  @mount_timeout 15_000
  @unmount_settle_ms 1_000

  def start_fs(module, init_arg, options \\ []) when is_atom(module) and is_list(options) do
    Exfuse.FsSupervisor.start_fs(module, init_arg, options)
  end

  def ensure_fs(module, init_arg, options) when is_atom(module) and is_list(options) do
    key = Keyword.fetch!(options, :key)
    Exfuse.FsSupervisor.ensure_fs(key, module, init_arg, Keyword.delete(options, :key))
  end

  def stop_fs(fs) when is_pid(fs), do: Exfuse.FsSupervisor.stop_fs(fs)

  def mount(fs, mount_point, options \\ []) when is_pid(fs) and is_binary(mount_point) do
    mount_point = Path.expand(mount_point)
    backend = Keyword.get(options, :backend, default_backend())

    with {:ok, backend_options} <- prepare_backend(backend, options),
         :ok <- heal_mount_point(mount_point),
         :ok <- File.mkdir_p(mount_point),
         mount_options = Keyword.merge(options, backend_options) |> Keyword.put(:backend, backend),
         {:ok, mount} <- start_mount(fs, mount_point, mount_options) do
      attach_and_verify(mount, backend, mount_point, mount_options)
    end
  end

  @doc """
  Unmount a managed mount, or force-detach a mount point by path.

  The path form cleans an OS-level FUSE/FSKit mount even when its owning VM has
  exited and `list/0` is empty. The PID form remains idempotent.
  """
  @spec unmount(pid() | String.t()) :: :ok
  def unmount(mount) when is_pid(mount) do
    %{mount_point: mount_point} = Exfuse.Mount.status(mount)
    unmount(mount_point)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :normal -> :ok
  end

  def unmount(mount_point) when is_binary(mount_point) do
    mount_point = Path.expand(mount_point)
    detach_native(mount_point)
    mount_point |> mounts_at() |> Enum.each(fn {mount, _status} -> stop_mount(mount) end)

    :ok
  end

  @doc "Whether the path is present in the operating system mount table."
  def mounted?(mount_point) when is_binary(mount_point) do
    mount_point |> mount_candidates() |> any_mounted?()
  end

  @doc "Whether the mounted path answers an external directory read."
  def serving?(mount_point) when is_binary(mount_point) do
    mounted?(mount_point) and
      match?({_output, 0}, Command.run("ls", [mount_point], 2_000))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def list do
    Exfuse.FsSupervisor.filesystems()
    |> Enum.flat_map(fn
      {:undefined, fs, :supervisor, [Exfuse.Fs.Supervisor]} ->
        fs
        |> Exfuse.Fs.Supervisor.mount_supervisor()
        |> Exfuse.MountSupervisor.mounts()

      _ ->
        []
    end)
    |> Enum.flat_map(&mount_status/1)
  end

  defp start_mount(fs, mount_point, options) do
    supervisor = Exfuse.Fs.Supervisor.mount_supervisor(fs)

    case Exfuse.MountSupervisor.start_mount(supervisor, fs, mount_point, options) do
      {:error, {:already_started, pid}} -> {:error, {:already_mounted, pid}}
      other -> other
    end
  end

  defp attach_and_verify(mount, backend, mount_point, options) do
    with :ok <- attach_native(backend, mount_point, options, @busy_retries),
         :ok <- verify_mount(mount_point, options) do
      {:ok, mount}
    else
      {:error, reason} ->
        stop_mount(mount)
        force_clean_leaf(mount_point)
        {:error, reason}
    end
  end

  defp heal_mount_point(mount_point) do
    if Registry.lookup(Exfuse.Registry, {:mount, mount_point}) == [] and mounted?(mount_point) do
      unmount(mount_point)
    end

    :ok
  end

  defp mounts_at(mount_point) do
    list()
    |> Enum.filter(fn {_mount, status} -> status.mount_point == mount_point end)
  end

  defp verify_mount(mount_point, options) do
    timeout = Keyword.get(options, :mount_timeout, @mount_timeout)

    case Keyword.get(options, :verify, :mounted) do
      false -> :ok
      :mounted -> wait_until(mount_point, &mounted?/1, timeout, :mount_not_visible)
      :serving -> wait_until(mount_point, &serving?/1, timeout, :mount_not_serving)
      invalid -> {:error, {:invalid_verify, invalid}}
    end
  end

  defp wait_until(mount_point, probe, timeout, error) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(mount_point, probe, deadline, error)
  end

  defp wait_loop(mount_point, probe, deadline, error) do
    cond do
      probe.(mount_point) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, error}

      true ->
        Process.sleep(50)
        wait_loop(mount_point, probe, deadline, error)
    end
  end

  defp default_backend do
    case :os.type() do
      {:unix, :darwin} -> :fskit
      _ -> :fuse
    end
  end

  defp prepare_backend(:fuse, _options) do
    case :os.type() do
      {:unix, :darwin} -> {:error, :fuse_backend_unsupported_on_macos}
      _ -> {:ok, []}
    end
  end

  defp prepare_backend(:fskit, options) do
    port = Keyword.get_lazy(options, :wire_port, &available_wire_port!/0)
    session = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    resource = Keyword.get(options, :resource, "exfuse://127.0.0.1:#{port}/?session=#{session}")
    {:ok, wire_port: port, resource: resource}
  end

  defp attach_native(:fuse, _mount_point, _options, _retries), do: :ok

  defp attach_native(:fskit, mount_point, options, retries) do
    command = Keyword.get(options, :mount_command, "mount")
    resource = Keyword.fetch!(options, :resource)
    timeout = Keyword.get(options, :mount_timeout, @mount_timeout)
    args = ["-F", "-t", "exfuse", resource, mount_point]

    case Command.run(command, args, timeout) do
      {_output, 0} ->
        :ok

      {:timeout, output} ->
        {:error, {:fskit_mount_timeout, timeout, String.trim(output)}}

      {:error, reason} ->
        {:error, {:fskit_mount_command_failed, reason}}

      {output, status} ->
        if retries > 0 and String.contains?(output, "Resource busy") do
          Process.sleep(@busy_retry_ms)
          attach_native(:fskit, mount_point, options, retries - 1)
        else
          {:error, {:fskit_mount_failed, status, String.trim(output)}}
        end
    end
  end

  defp detach_native(mount_point) do
    candidates = mount_candidates(mount_point)
    Enum.each(candidates, &run_unmount(&1, false))

    unless settle_unmounted(candidates) do
      force_clean_leaf(mount_point)
    end

    :ok
  end

  defp settle_unmounted(candidates) do
    deadline = System.monotonic_time(:millisecond) + @unmount_settle_ms
    settle_loop(candidates, deadline)
  end

  defp settle_loop(candidates, deadline) do
    cond do
      not any_mounted?(candidates) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        settle_loop(candidates, deadline)
    end
  end

  defp force_clean_leaf(mount_point) do
    mount_point
    |> mount_candidates()
    |> Enum.each(&run_unmount(&1, true))

    _ = File.rmdir(mount_point)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp run_unmount(path, force?) do
    args = if force?, do: ["-f", path], else: [path]
    _ = Command.run("umount", args, 5_000)

    if force? and :os.type() == {:unix, :darwin} and mounted?(path) do
      _ = Command.run("diskutil", ["unmount", "force", path], 5_000)
    end

    :ok
  end

  defp any_mounted?(candidates) do
    case Command.run("mount", [], 2_000) do
      {mounts, 0} -> Enum.any?(candidates, &String.contains?(mounts, " on #{&1} "))
      _ -> false
    end
  end

  defp mount_candidates(mount_point) do
    [Path.expand(mount_point), realpath(mount_point)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp realpath(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, resolved} -> List.to_string(resolved)
      {:error, _} -> nil
    end
  end

  defp stop_mount(mount) do
    if Process.alive?(mount), do: Exfuse.Mount.stop(mount)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp available_wire_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp mount_status({:undefined, pid, :worker, [Exfuse.Mount]}) do
    try do
      [{pid, Exfuse.Mount.status(pid)}]
    catch
      :exit, _ -> []
    end
  end

  defp mount_status(_child), do: []
end
