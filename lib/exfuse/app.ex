defmodule Exfuse.App do
  use Application

  @moduledoc """
  Exfuse application callback module.
  """

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Exfuse.MountRegistry},
      Exfuse.FsSupervisor,
      Exfuse.FileSupervisor,
      Exfuse.MountSupervisor,
      {Task.Supervisor, name: Exfuse.RequestSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Exfuse.Sup]
    Supervisor.start_link(children, opts)
  end

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
