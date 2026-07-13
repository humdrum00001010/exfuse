defmodule Exfuse do
  @moduledoc "Filesystem runtime and native mount API."

  def start_fs(module, init_arg, options \\ []) when is_atom(module) and is_list(options) do
    Exfuse.FsSupervisor.start_fs(module, init_arg, options)
  end

  def stop_fs(fs) when is_pid(fs), do: Exfuse.Fs.Runtime.stop(fs)

  def mount(fs, mount_point, options \\ []) when is_pid(fs) and is_binary(mount_point) do
    backend = Keyword.get(options, :backend, default_backend())
    File.mkdir_p!(mount_point)

    with {:ok, backend_options} <- prepare_backend(backend, options),
         mount_options = Keyword.merge(options, backend_options) |> Keyword.put(:backend, backend) do
      case Exfuse.MountSupervisor.start_mount(fs, mount_point, mount_options) do
        {:ok, mount} ->
          case attach_native(backend, mount_point, mount_options) do
            :ok ->
              {:ok, mount}

            {:error, reason} ->
              Exfuse.Mount.stop(mount)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def unmount(mount) when is_pid(mount) do
    %{mount_point: mount_point} = Exfuse.Mount.status(mount)
    detach_native(mount_point)
    Exfuse.Mount.stop(mount)
    :ok
  catch
    :exit, {:noproc, _} -> :ok
  end

  def list do
    Exfuse.MountSupervisor.mounts()
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, [Exfuse.Mount]} ->
        try do
          [{pid, Exfuse.Mount.status(pid)}]
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end)
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

  defp attach_native(:fuse, mount_point, options),
    do: wait_until_mounted(mount_point, Keyword.get(options, :mount_timeout, 15_000))

  defp attach_native(:fskit, mount_point, options) do
    command = Keyword.get(options, :mount_command, "mount")
    resource = Keyword.fetch!(options, :resource)
    timeout = Keyword.get(options, :mount_timeout, 15_000)

    case System.cmd(command, ["-F", "-t", "exfuse", resource, mount_point],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> wait_until_mounted(mount_point, timeout)
      {output, status} -> {:error, {:fskit_mount_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:fskit_mount_command_failed, Exception.message(error)}}
  end

  defp wait_until_mounted(mount_point, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(mount_point, deadline)
  end

  defp wait_loop(mount_point, deadline) do
    cond do
      mounted?(mount_point) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :mount_timeout}

      true ->
        Process.sleep(20)
        wait_loop(mount_point, deadline)
    end
  end

  defp detach_native(mount_point) do
    _ = System.cmd("umount", [mount_point], stderr_to_stdout: true)

    if mounted?(mount_point) do
      case System.find_executable("diskutil") do
        nil ->
          :ok

        diskutil ->
          System.cmd(diskutil, ["unmount", "force", mount_point], stderr_to_stdout: true)
      end
    end

    :ok
  end

  defp mounted?(mount_point) do
    candidates = [mount_point, realpath(mount_point)] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case System.cmd("mount", [], stderr_to_stdout: true) do
      {mounts, 0} -> Enum.any?(candidates, &String.contains?(mounts, " on #{&1} "))
      _ -> false
    end
  end

  defp realpath(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, resolved} -> List.to_string(resolved)
      {:error, _} -> nil
    end
  end

  defp available_wire_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
