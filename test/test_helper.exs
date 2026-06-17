exclude =
  case System.get_env("EXFUSE_RUN_FUSE_TESTS") do
    value when value in ["1", "true", "TRUE", "yes"] -> []
    _ -> [fuse: true]
  end

ExUnit.start(exclude: exclude)
