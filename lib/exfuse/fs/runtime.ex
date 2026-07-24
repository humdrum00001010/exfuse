defmodule Exfuse.Fs.Runtime do
  @moduledoc false

  use GenServer

  alias Exfuse.{File, FileSupervisor, Socket}

  defstruct module: nil,
            init_arg: nil,
            options: [],
            filesystem: nil,
            file_supervisor: nil,
            files: nil,
            root: nil,
            watcher: nil,
            mounts: MapSet.new(),
            subscribers: %{}

  def start_link(module, init_arg, options) do
    GenServer.start_link(__MODULE__, {module, init_arg, options})
  end

  def root(fs), do: GenServer.call(fs, :root)
  def status(fs), do: GenServer.call(fs, :status)
  def stop(fs), do: GenServer.stop(fs, :normal)
  def register_mount(fs, mount), do: GenServer.call(fs, {:register_mount, mount})
  def unregister_mount(fs, mount), do: GenServer.cast(fs, {:unregister_mount, mount})
  def subscribe(runtime, subscriber), do: GenServer.call(runtime, {:subscribe, subscriber})
  def notify_stop(runtime), do: GenServer.call(runtime, :notify_stop)

  def publish_mutation(runtime, path, actions),
    do: GenServer.cast(runtime, {:publish_mutation, path, Enum.uniq(actions)})

  def dispatch_plug(
        %Socket{runtime: runtime} = root_socket,
        declaration,
        module,
        operation,
        event
      ) do
    with {:ok, file} <- lookup_or_start(runtime, declaration, module),
         result <- File.dispatch(file, operation, event) do
      sync_result(result, root_socket)
    else
      {:error, reason} -> {:error, reason, root_socket}
    end
  end

  @impl true
  def init({module, init_arg, options}) do
    files = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    file_supervisor = Keyword.fetch!(options, :file_supervisor)
    runtime = %{owner: self(), files: files, file_supervisor: file_supervisor}

    case start_file(:root, module, init_arg, runtime, options) do
      {:ok, root} ->
        Process.monitor(root)
        :ets.insert(files, {:root, root})

        {:ok,
         %__MODULE__{
           module: module,
           init_arg: init_arg,
           options: options,
           filesystem: Keyword.fetch!(options, :filesystem),
           file_supervisor: file_supervisor,
           files: files,
           root: root
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:root, _from, state), do: {:reply, {:ok, state.root}, state}

  def handle_call(:status, _from, state) do
    files = :ets.tab2list(state.files)

    status = %{
      module: state.module,
      filesystem: state.filesystem,
      root: state.root,
      files: files,
      mounts: state.mounts,
      watcher: state.watcher,
      subscribers: Map.values(state.subscribers)
    }

    {:reply, status, state}
  end

  def handle_call({:register_mount, mount}, _from, state) do
    Process.monitor(mount)
    {:reply, :ok, %{state | mounts: MapSet.put(state.mounts, mount)}}
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    case Enum.find(state.subscribers, fn {_ref, pid} -> pid == subscriber end) do
      nil ->
        reference = Process.monitor(subscriber)

        {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, reference, subscriber)}}

      _existing ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:notify_stop, _from, state) do
    notify_subscribers_stopped(state)
    Enum.each(Map.keys(state.subscribers), &Process.demonitor(&1, [:flush]))
    {:reply, :ok, %{state | subscribers: %{}}}
  end

  def handle_call({:ensure_file, declaration, module}, _from, state) do
    case live_file(state.files, declaration) do
      {:ok, file} ->
        {:reply, {:ok, file}, state}

      :error ->
        runtime = %{
          owner: self(),
          files: state.files,
          file_supervisor: state.file_supervisor
        }

        case start_file(declaration, module, state.init_arg, runtime, state.options) do
          {:ok, file} ->
            Process.monitor(file)
            :ets.insert(state.files, {declaration, file})
            {:reply, {:ok, file}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast({:unregister_mount, mount}, state) do
    {:noreply, %{state | mounts: MapSet.delete(state.mounts, mount)}}
  end

  def handle_cast({:publish_mutation, _path, _actions}, %{watcher: watcher} = state)
      when is_pid(watcher) do
    {:noreply, state}
  end

  def handle_cast({:publish_mutation, path, actions}, state) do
    broadcast(state, path, actions)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    subscribers = Map.delete(state.subscribers, reference)
    mounts = MapSet.delete(state.mounts, pid)

    :ets.match_delete(state.files, {:_, pid})

    if pid == state.root do
      {:stop, :root_file_stopped, %{state | mounts: mounts, subscribers: subscribers}}
    else
      {:noreply, %{state | mounts: mounts, subscribers: subscribers}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    notify_subscribers_stopped(state)

    Enum.each(state.mounts, &Exfuse.unmount/1)

    state.files
    |> :ets.tab2list()
    |> Enum.each(fn {_key, pid} -> safe_stop(pid) end)

    :ok
  end

  defp lookup_or_start(%{owner: owner, files: files}, declaration, module) do
    case live_file(files, declaration) do
      {:ok, file} -> {:ok, file}
      :error -> GenServer.call(owner, {:ensure_file, declaration, module}, :infinity)
    end
  end

  defp live_file(table, key) do
    case :ets.lookup(table, key) do
      [{^key, pid}] when is_pid(pid) -> if(Process.alive?(pid), do: {:ok, pid}, else: :error)
      _ -> :error
    end
  end

  defp start_file(key, module, init_arg, runtime, options) do
    FileSupervisor.start_file(
      runtime.file_supervisor,
      key: {self(), key},
      module: module,
      init_arg: init_arg,
      runtime: runtime,
      max_concurrency: Keyword.get(options, :max_concurrency, System.schedulers_online()),
      queue_limit: Keyword.get(options, :queue_limit, System.schedulers_online() * 16)
    )
  end

  defp sync_result({:noreply, %Socket{}}, root_socket), do: {:noreply, root_socket}
  defp sync_result({:reply, value, %Socket{}}, root_socket), do: {:reply, value, root_socket}
  defp sync_result({:error, reason, %Socket{}}, root_socket), do: {:error, reason, root_socket}

  defp broadcast(state, path, actions) do
    Enum.each(state.subscribers, fn {_ref, subscriber} ->
      send(subscriber, {:file_event, state.filesystem, {path, Enum.uniq(actions)}})
    end)
  end

  defp notify_subscribers_stopped(state) do
    Enum.each(state.subscribers, fn {_ref, subscriber} ->
      send(subscriber, {:file_event, state.filesystem, :stop})
    end)
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end
end
