defmodule Exfuse.FsSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(options), do: DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_fs(module, init_arg, options) do
    spec = %{
      id: Exfuse.Fs.Supervisor,
      start: {Exfuse.Fs.Supervisor, :start_link, [module, init_arg, options]},
      restart: :temporary,
      type: :supervisor
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def ensure_fs(key, module, init_arg, options) do
    name = {:via, Registry, {Exfuse.Registry, {:filesystem, key}}}
    options = Keyword.put(options, :name, name)

    case start_fs(module, init_arg, options) do
      {:ok, fs} ->
        {:ok, fs}

      {:error, {:already_started, fs}} ->
        {:ok, fs}

      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, fs}}}} ->
        {:ok, fs}

      other ->
        other
    end
  end

  def stop_fs(fs) do
    notify_stop(fs)

    case DynamicSupervisor.terminate_child(__MODULE__, fs) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  def filesystems, do: DynamicSupervisor.which_children(__MODULE__)

  defp notify_stop(fs) do
    fs
    |> Exfuse.Fs.Supervisor.runtime()
    |> Exfuse.Fs.Runtime.notify_stop()
  catch
    :exit, _reason -> :ok
  end
end
