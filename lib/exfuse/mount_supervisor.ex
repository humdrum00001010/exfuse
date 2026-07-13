defmodule Exfuse.MountSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(options), do: DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_mount(fs, mount_point, options) do
    spec = %{
      id: Exfuse.Mount,
      start: {Exfuse.Mount, :start_link, [fs, mount_point, options]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def mounts, do: DynamicSupervisor.which_children(__MODULE__)
end
