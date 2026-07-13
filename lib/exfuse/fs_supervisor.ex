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

  def stop_fs(fs) do
    case DynamicSupervisor.terminate_child(__MODULE__, fs) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  def filesystems, do: DynamicSupervisor.which_children(__MODULE__)
end
