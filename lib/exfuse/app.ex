defmodule Exfuse.App do
  @moduledoc """
  Port-binary path resolution.

  This is NOT an application callback module any more. Exfuse's tree moved to
  `Exfuse.Supervisor` so the HOST starts and stops it — see that module for why
  owning its own root leaked mounts.
  """

  @doc """
  Finds the path of the port and returns `{:ok, path}` if successful.
  """

  def find_port! do
    candidates()
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> {:error, {:port_not_found, candidates()}}
      port_path -> {:ok, port_path}
    end
  end

  defp candidates do
    root = Path.expand("../..", __DIR__)

    [
      System.get_env("EXFUSE_PORT"),
      Path.join(root, "priv/exfuse_port"),
      Path.join(root, "rust/target/release/exfuse_port"),
      Path.join(root, "rust/target/debug/exfuse_port"),
      Application.app_dir(:exfuse, "priv/exfuse_port")
    ]
    |> Enum.reject(&is_nil/1)
  end
end
