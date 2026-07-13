defmodule Exfuse.FileSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(options) do
    case Keyword.fetch(options, :name) do
      {:ok, name} -> DynamicSupervisor.start_link(__MODULE__, options, name: name)
      :error -> DynamicSupervisor.start_link(__MODULE__, options)
    end
  end

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_file(supervisor, options) do
    spec = %{
      id: {Exfuse.File, Keyword.fetch!(options, :key)},
      start: {Exfuse.File, :start_link, [options]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(supervisor, spec)
  end
end
