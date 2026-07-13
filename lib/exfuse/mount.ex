defmodule Exfuse.Mount do
  @moduledoc false

  use GenServer

  alias Exfuse.{File, Fs, Wire}

  @magic 0xC021_55AC
  @status 100

  defstruct fs: nil,
            root: nil,
            mount_point: nil,
            backend: nil,
            listener: nil,
            port: nil,
            port_os_pid: nil,
            resource: nil

  def start_link(fs, mount_point, options) do
    GenServer.start_link(__MODULE__, {fs, mount_point, options},
      name: {:via, Registry, {Exfuse.MountRegistry, mount_point}}
    )
  end

  def stop(mount), do: GenServer.stop(mount, :normal)
  def status(mount), do: GenServer.call(mount, :status)

  def dispatch(root, mount_point, packet) do
    case Wire.decode_request(packet) do
      {:ok, request, event} ->
        event = Map.put(event, :mount_point, mount_point)
        request |> File.dispatch_request(root, event) |> Wire.encode_reply_for(request)

      {:error, request, reason} ->
        Wire.error_reply(request, reason)

      {:error, :eproto} ->
        :close
    end
  end

  @impl true
  def init({fs, mount_point, options}) do
    backend = Keyword.fetch!(options, :backend)

    with {:ok, root} <- Fs.Runtime.root(fs),
         {:ok, transport} <- start_transport(backend, root, mount_point, options),
         :ok <- Fs.Runtime.register_mount(fs, self()) do
      {:ok,
       struct!(
         __MODULE__,
         [fs: fs, root: root, mount_point: mount_point, backend: backend] ++ transport
       )}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       fs: state.fs,
       mount_point: state.mount_point,
       backend: state.backend,
       port_os_pid: state.port_os_pid,
       resource: state.resource
     }, state}
  end

  @impl true
  def handle_info({port, {:data, <<@magic::32, @status::32, os_pid::32>>}}, %{port: port} = state) do
    {:noreply, %{state | port_os_pid: os_pid}}
  end

  def handle_info({port, {:data, packet}}, %{port: port} = state) do
    owner = self()
    root = state.root
    mount_point = state.mount_point

    Task.Supervisor.start_child(Exfuse.RequestSupervisor, fn ->
      case dispatch(root, mount_point, packet) do
        reply when is_binary(reply) -> send(owner, {:port_reply, port, reply})
        :close -> send(owner, {:invalid_port_packet, port})
      end
    end)

    {:noreply, state}
  end

  def handle_info({:port_reply, port, reply}, %{port: port} = state) do
    _ = Port.command(port, reply)
    {:noreply, state}
  catch
    :error, :badarg -> {:stop, :port_closed, state}
  end

  def handle_info({:invalid_port_packet, port}, %{port: port} = state),
    do: {:stop, :protocol_error, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:port_exit, status}, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.listener) and Process.alive?(state.listener),
      do: GenServer.stop(state.listener)

    close_port(state.port)
    Fs.Runtime.unregister_mount(state.fs, self())
    :ok
  end

  defp start_transport(:fskit, root, mount_point, options) do
    port = Keyword.fetch!(options, :wire_port)

    case Exfuse.WireListener.start_link(
           dispatcher: {__MODULE__, :dispatch, [root, mount_point]},
           port: port
         ) do
      {:ok, listener} ->
        {:ok, listener: listener, resource: Keyword.fetch!(options, :resource)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_transport(:fuse, _root, mount_point, _options) do
    with {:ok, port_path} <- Exfuse.App.find_port!() do
      port =
        Port.open(
          {:spawn_executable, port_path},
          [{:args, ["--mount-point", mount_point]}, {:packet, 4}, :exit_status, :binary]
        )

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      {:ok, port: port, port_os_pid: os_pid}
    end
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end
end
