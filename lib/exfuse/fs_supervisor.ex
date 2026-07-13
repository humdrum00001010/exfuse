defmodule Exfuse.FsSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(options), do: DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_fs(module, init_arg, options) do
    spec = %{
      id: Exfuse.Fs.Runtime,
      start: {Exfuse.Fs.Runtime, :start_link, [module, init_arg, options]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
