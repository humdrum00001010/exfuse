defmodule Exfuse.Supervisor do
  @moduledoc """
  Exfuse's process tree, started by the HOST rather than by an application
  callback.

  Exfuse used to own its own root (`mod: {Exfuse.App, []}` -> `Exfuse.Sup`),
  which made it a peer of the host's tree instead of a child. That is why mounts
  leaked: `Exfuse.Mount` traps exits and unmounts in `terminate/2`, but nothing
  in the host's tree could reach exfuse to shut it down, so an orderly host
  shutdown — or a dev-server restart — never triggered the one teardown that
  exists. 148 orphaned OS mounts accumulated that way, one of them over
  `$HOME/.ecrits`, which shadowed a real file read-only.

  Place this EARLY in the host's children. Startup order does not matter (nothing
  mounts at boot; the first mount happens when a workspace is opened), but
  children terminate in REVERSE order — so early here means this stops LAST,
  after whatever owns the mounts has already torn them down.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, options, name: name)
  end

  @impl true
  def init(_options) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Exfuse.Registry},
        Exfuse.FsSupervisor,
        {Task.Supervisor, name: Exfuse.RequestSupervisor}
      ],
      strategy: :one_for_one
    )
  end
end
