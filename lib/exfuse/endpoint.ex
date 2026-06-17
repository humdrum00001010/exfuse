defmodule Exfuse.Endpoint do
  @moduledoc false

  use GenServer
  alias Exfuse.Socket

  @assign_key :exfuse_endpoints

  defstruct module: nil,
            socket: nil

  def dispatch(key, module, op, event, %Socket{} = socket) do
    case endpoint(socket, key, module) do
      {:ok, pid, socket} ->
        pid
        |> GenServer.call({:handle_event, op, event}, :infinity)
        |> sync_result(socket)

      {:error, reason} ->
        {:error, reason, socket}
    end
  end

  def start_link(module, %Socket{} = socket) do
    GenServer.start_link(__MODULE__, {module, socket})
  end

  @impl true
  def init({module, %Socket{} = socket}) do
    with {:ok, socket} <- init_socket(module, socket) do
      {:ok, %__MODULE__{module: module, socket: socket}}
    end
  end

  @impl true
  def handle_call(
        {:handle_event, op, event},
        _from,
        %__MODULE__{module: module, socket: socket} = state
      ) do
    result = module.handle_event(op, event, socket)
    {:reply, result, %{state | socket: result_socket(result, socket)}}
  end

  defp endpoint(%Socket{} = socket, key, module) do
    case Map.get(endpoints(socket), key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid, socket}, else: start_endpoint(socket, key, module)

      _missing ->
        start_endpoint(socket, key, module)
    end
  end

  defp start_endpoint(socket, key, module) do
    case start_link(module, socket) do
      {:ok, pid} -> {:ok, pid, remember(socket, key, pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp init_socket(module, socket) do
    if function_exported?(module, :init, 1) do
      case module.init(socket) do
        {:ok, %Socket{} = socket} -> {:ok, socket}
        {:error, reason} -> {:stop, reason}
        other -> {:stop, {:bad_init_return, other}}
      end
    else
      {:ok, socket}
    end
  end

  defp result_socket({:noreply, %Socket{} = socket}, _old_socket), do: socket
  defp result_socket({:reply, _reply, %Socket{} = socket}, _old_socket), do: socket
  defp result_socket({:error, _reason, %Socket{} = socket}, _old_socket), do: socket

  defp sync_result({:noreply, %Socket{}}, socket), do: {:noreply, socket}

  defp sync_result({:reply, reply, %Socket{}}, socket), do: {:reply, reply, socket}

  defp sync_result({:error, reason, %Socket{}}, socket), do: {:error, reason, socket}

  defp remember(socket, key, pid) do
    Socket.assign(socket, @assign_key, Map.put(endpoints(socket), key, pid))
  end

  defp endpoints(socket), do: Socket.get_assign(socket, @assign_key, %{})
end
