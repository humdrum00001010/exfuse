defmodule Exfuse.MountSupervisor do
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

  def start_mount(supervisor, fs, mount_point, options) do
    spec = %{
      id: Exfuse.Mount,
      start: {Exfuse.Mount, :start_link, [fs, mount_point, options]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(supervisor, spec)
  end

  def mounts(supervisor), do: DynamicSupervisor.which_children(supervisor)
end
