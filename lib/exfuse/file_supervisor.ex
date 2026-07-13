defmodule Exfuse.FileSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(options), do: DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_file(options) do
    spec = %{
      id: {Exfuse.File, Keyword.fetch!(options, :key)},
      start: {Exfuse.File, :start_link, [options]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
