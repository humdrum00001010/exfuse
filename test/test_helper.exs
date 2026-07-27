exclude =
  case System.get_env("EXFUSE_RUN_FUSE_TESTS") do
    value when value in ["1", "true", "TRUE", "yes"] -> []
    _ -> [fuse: true]
  end

# Exfuse no longer starts itself: the HOST owns the tree (see Exfuse.Supervisor
# for why owning its own application root leaked mounts). The suite is a host
# like any other, so it starts the tree the same way ecrits does.
{:ok, _} = Exfuse.Supervisor.start_link([])

ExUnit.start(exclude: exclude)
