defmodule Exfuse.Fs.Supervisor do
  @moduledoc false

  use Supervisor

  alias Exfuse.{FileSupervisor, MountSupervisor}

  def start_link(module, init_arg, options) do
    Supervisor.start_link(__MODULE__, {module, init_arg, options})
  end

  def runtime(fs), do: child(fs, :runtime)
  def file_supervisor(fs), do: child(fs, :files)
  def mount_supervisor(fs), do: child(fs, :mounts)

  def root(fs), do: fs |> runtime() |> Exfuse.Fs.Runtime.root()
  def status(fs), do: fs |> runtime() |> Exfuse.Fs.Runtime.status()

  @impl true
  def init({module, init_arg, options}) do
    files = {:via, Registry, {Exfuse.Registry, {:files, self()}}}
    mounts = {:via, Registry, {Exfuse.Registry, {:mounts, self()}}}

    runtime_options =
      options
      |> Keyword.put(:file_supervisor, files)
      |> Keyword.put(:filesystem, self())

    children = [
      %{
        id: :files,
        start: {FileSupervisor, :start_link, [[name: files]]},
        type: :supervisor
      },
      %{
        id: :mounts,
        start: {MountSupervisor, :start_link, [[name: mounts]]},
        type: :supervisor
      },
      %{
        id: :runtime,
        start: {Exfuse.Fs.Runtime, :start_link, [module, init_arg, runtime_options]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp child(fs, id) do
    case List.keyfind(Supervisor.which_children(fs), id, 0) do
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> exit({:fs_child_not_running, id})
    end
  end
end
