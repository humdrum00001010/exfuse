defmodule Exfuse.MountSup do
  @moduledoc """
  Mount supervisor.
  """

  use DynamicSupervisor

  @doc """
  Starts the supervisor and links to it.
  """

  @spec start_link() :: {:ok, pid} | {:error, term}

  def start_link() do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_link([]), do: start_link()

  def init([]) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a child (a supervised filesystem). The arguments are the mount
  point, the implementation module and the options / config. See `Exfuse.mount/3`
  for more details.
  """

  @spec start_child(String.t(), module, term) :: {:ok, pid} | {:error, term}

  def start_child(mount_point, fs_mod, fs_state) do
    child_spec = %{
      id: Exfuse.Server,
      start: {Exfuse.Server, :start_link, [mount_point, fs_mod, fs_state]},
      restart: :transient
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Return the supervisors running children. See `Supervisor.which_children/1` for
  more details.
  """

  @spec which_children() :: [{:undefined, Supervisor.child(), :worker, [Exfuse.Server]}]

  def which_children() do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
