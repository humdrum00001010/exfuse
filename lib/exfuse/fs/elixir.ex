defmodule Exfuse.Fs.Elixir do
  @moduledoc """
  A UserFs filesystem implementation module which makes
  available common data from the Elixir run time.

  The implementation breaks the file path into leaves and the traverse/4
  function works through them to find the end of the path.

  The traverse/4 function verifies each element of the path as it is
  called. This is necessary because it is no use continuing past the
  pids/&lt;0.63.0> point if PID &lt;0.63.0> does not exist! The first two
  parameters to traverse/4 are passed on and through so they are
  available when the traversal finishes, the third parameter is the
  context in which to evaluate the next path element (for example
  traversing the "pids" directory results in the context being
  'all_pids', and the element after that is {pid, Pid}, enabling, for
  example, a read-directory event, if it is invoked at that
  point, to enumerate all objects that are inside a PID.

  See 'Exfuse.Fs.Example' for a simpler example of a filesystem, or the
  simple hello-world `Exfuse.Fs.Hello`.
  """

  use Exfuse.Fs

  defstruct mount_point: nil

  def exfuse_init(mount_point, _opts) do
    {:ok, %__MODULE__{mount_point: mount_point}}
  end

  def handle_event(:readdir, %{path: path}, socket) do
    dispatch(socket, :elixirfs_readdir, path)
  end

  def handle_event(:getattr, %{path: path}, socket) do
    dispatch(socket, :elixirfs_getattr, path)
  end

  def handle_event(:readlink, %{path: path}, socket) do
    dispatch(socket, :elixirfs_readlink, path)
  end

  def handle_event(:read, %{path: path, offset: offset, size: size}, socket) do
    with {:reply, content, socket} <- dispatch(socket, :elixirfs_read, path) do
      {:reply, slice(content, offset, size), socket}
    end
  end

  def handle_event(_op, _event, socket), do: {:error, :enosys, socket}

  defp dispatch(%Exfuse.Socket{state: state} = socket, request, "/" <> path) do
    path_leaves = String.split(path, "/", parts: :infinity)

    case traverse(state, request, :root, path_leaves) do
      {:ok, reply, new_state} -> {:reply, reply, Exfuse.Socket.put_state(socket, new_state)}
      {:error, reason, new_state} -> {:error, reason, Exfuse.Socket.put_state(socket, new_state)}
    end
  end

  defp slice(content, offset, size) do
    start = min(offset, byte_size(content))
    count = min(size, byte_size(content) - start)
    binary_part(content, start, count)
  end

  defp traverse(state, request, :root, [""]) do
    apply(__MODULE__, request, [state, :root])
  end

  defp traverse(state, request, :root, ["pids" | more]) do
    traverse(state, request, :all_pids, more)
  end

  defp traverse(state, request, :all_pids, []) do
    apply(__MODULE__, request, [state, :all_pids])
  end

  defp traverse(state, request, :all_pids, ["#PID" <> pid | more]) do
    traverse(state, request, {:pid, :erlang.list_to_pid(String.to_charlist(pid))}, more)
  end

  defp traverse(state, request, {:pid, pid}, []) do
    apply(__MODULE__, request, [state, {:pid, pid}])
  end

  defp traverse(state, request, :root, ["names" | more]) do
    traverse(state, request, :names, more)
  end

  defp traverse(state, request, :names, []) do
    apply(__MODULE__, request, [state, :names])
  end

  defp traverse(state, request, :names, ["local" | more]) do
    traverse(state, request, :local_names, more)
  end

  defp traverse(state, request, :local_names, []) do
    apply(__MODULE__, request, [state, :local_names])
  end

  defp traverse(state, request, :local_names, [name | more]) do
    traverse(state, request, {:local_name, String.to_atom(name)}, more)
  end

  defp traverse(state, request, {:local_name, name}, []) do
    apply(__MODULE__, request, [state, {:local_name, name}])
  end

  defp traverse(state, request, :names, ["global" | more]) do
    traverse(state, request, :global_names, more)
  end

  defp traverse(state, request, :global_names, []) do
    apply(__MODULE__, request, [state, :global_names])
  end

  defp traverse(state, request, :global_names, [name | more]) do
    traverse(state, request, {:global_name, String.to_atom(name)}, more)
  end

  defp traverse(state, request, {:global_name, name}, []) do
    apply(__MODULE__, request, [state, {:global_name, name}])
  end

  defp traverse(state, request, {:pid, pid}, ["process_info" | more]) do
    traverse(state, request, {:proc_info, pid}, more)
  end

  defp traverse(state, request, {:proc_info, pid}, []) do
    apply(__MODULE__, request, [state, {:proc_info, pid}])
  end

  defp traverse(state, request, {:proc_info, pid}, [item_spec]) do
    apply(__MODULE__, request, [state, {:proc_info, pid, String.to_atom(item_spec)}])
  end

  defp traverse(state, request, {:pid, pid}, ["linked" | more]) do
    traverse(state, request, {:link_from, pid}, more)
  end

  defp traverse(state, request, {:link_from, pid}, []) do
    apply(__MODULE__, request, [state, {:link_from, pid}])
  end

  defp traverse(state, request, {:link_from, _pid}, ["#PID" <> linked_pid]) do
    apply(__MODULE__, request, [
      state,
      {:link_to, :erlang.list_to_pid(String.to_charlist(linked_pid))}
    ])
  end

  defp traverse(state, request, :root, ["nodes" | more]) do
    traverse(state, request, :nodes, more)
  end

  defp traverse(state, request, :nodes, []) do
    apply(__MODULE__, request, [state, :nodes])
  end

  defp traverse(state, request, :nodes, [node]) do
    apply(__MODULE__, request, [state, {:node, String.to_atom(node)}])
  end

  defp traverse(state, request, :root, ["apps" | more]) do
    traverse(state, request, :apps, more)
  end

  defp traverse(state, request, :apps, []) do
    apply(__MODULE__, request, [state, :apps])
  end

  defp traverse(state, request, :apps, [name | more]) do
    traverse(state, request, {:app, String.to_atom(name)}, more)
  end

  defp traverse(state, request, {:app, app}, []) do
    apply(__MODULE__, request, [state, {:app, app}])
  end

  defp traverse(state, request, {:app, app}, [app_sub_dir | more]) do
    traverse(state, request, {:app, app, app_sub_dir}, more)
  end

  defp traverse(state, request, {:app, app, app_sub_dir}, []) do
    apply(__MODULE__, request, [state, {:app, app, app_sub_dir}])
  end

  defp traverse(state, request, {:app, app, "env"}, [opt]) do
    apply(__MODULE__, request, [state, {:app_env, app, String.to_atom(opt)}])
  end

  defp traverse(state, request, :root, ["code" | more]) do
    traverse(state, request, :code, more)
  end

  defp traverse(state, request, :code, []) do
    apply(__MODULE__, request, [state, :code])
  end

  defp traverse(state, request, :code, ["modules" | more]) do
    traverse(state, request, {:code, :modules}, more)
  end

  defp traverse(state, request, {:code, :modules}, []) do
    apply(__MODULE__, request, [state, {:code, :modules}])
  end

  defp traverse(state, request, {:code, :modules}, [module | more]) do
    traverse(state, request, {:code, :module, String.to_atom(module)}, more)
  end

  defp traverse(state, request, {code, :module, module}, []) do
    apply(__MODULE__, request, [state, {code, :module, module}])
  end

  defp traverse(state, request, {code, :module, module}, ["file"]) do
    apply(__MODULE__, request, [state, {code, :module, module, :file}])
  end

  defp traverse(state, _, _, _) do
    {:error, @error_noent, state}
  end

  @doc false
  def elixirfs_readdir(state, :root) do
    {:ok, ["pids", "names", "nodes", "apps", "code"], state}
  end

  def elixirfs_readdir(state, :all_pids) do
    readdir =
      for p when is_pid(p) <- Process.list(),
          do: "#PID" <> :erlang.list_to_binary(:erlang.pid_to_list(p))

    {:ok, readdir, state}
  end

  def elixirfs_readdir(state, :names) do
    {:ok, ["local", "global"], state}
  end

  def elixirfs_readdir(state, :local_names) do
    local_names = for n <- Process.registered(), do: "#{n}"
    {:ok, local_names, state}
  end

  def elixirfs_readdir(state, :global_names) do
    global_names = for n <- :global.registered_names(), do: "#{n}"
    {:ok, global_names, state}
  end

  def elixirfs_readdir(state, {:pid, _pid}) do
    {:ok, ["process_info", "linked"], state}
  end

  def elixirfs_readdir(state, {:proc_info, pid}) do
    case Process.info(pid) do
      nil ->
        {:error, @error_noent, state}

      info ->
        proc_info = for {k, _} <- info, do: "#{k}"
        {:ok, proc_info, state}
    end
  end

  def elixirfs_readdir(state, {:link_from, pid}) do
    {:links, linked} = Process.info(pid, :links)

    readdir =
      for p when is_pid(p) <- linked, do: "#PID" <> :erlang.list_to_binary(:erlang.pid_to_list(p))

    {:ok, readdir, state}
  end

  def elixirfs_readdir(state, :nodes) do
    readdir = for n <- [node() | Node.list()], do: "#{n}"
    {:ok, readdir, state}
  end

  def elixirfs_readdir(state, {:node, _node}) do
    {:ok, [], state}
  end

  def elixirfs_readdir(state, :apps) do
    {:ok, for({n, _} <- running_apps(), do: "#{n}"), state}
  end

  def elixirfs_readdir(state, {:app, app}) do
    case running_app_pid(app) do
      {:ok, :undefined} ->
        {:ok, ["descr", "vsn", "env"], state}

      {:ok, _pid} ->
        {:ok, ["app_proc", "top_sup", "descr", "vsn", "env"], state}

      :error ->
        {:error, @error_noent, state}
    end
  end

  def elixirfs_readdir(state, {:app, app, "env"}) do
    {:ok, for({opt, _val} <- Application.get_all_env(app), do: "#{opt}"), state}
  end

  def elixirfs_readdir(state, :code) do
    {:ok, ["modules"], state}
  end

  def elixirfs_readdir(state, {:code, :modules}) do
    {:ok, for({m, _file} <- :code.all_loaded(), do: "#{m}"), state}
  end

  def elixirfs_readdir(state, {:code, :module, _module}) do
    {:ok, ["file"], state}
  end

  @doc false
  def elixirfs_getattr(state, :root) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, :all_pids) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, :names) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, :local_names) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, :global_names) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:local_name, name}) do
    case Process.whereis(name) do
      nil -> {:error, @error_noent, state}
      _pid -> {:ok, {0o0755, @attr_symlink, 0}, state}
    end
  end

  def elixirfs_getattr(state, {:global_name, name}) do
    case global_name_pid(name) do
      {:ok, _pid} -> {:ok, {0o0755, @attr_symlink, 0}, state}
      :error -> {:error, @error_noent, state}
    end
  end

  def elixirfs_getattr(state, {:pid, _pid}) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:proc_info, _pid}) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:proc_info, pid, item_spec}) do
    case safe_process_info(pid, item_spec) do
      {:ok, {_item_spec, item_data}} ->
        {:ok, {0o0644, @attr_file, byte_size(proc_info_content(item_data))}, state}

      :error ->
        {:error, @error_noent, state}
    end
  end

  def elixirfs_getattr(state, :nodes) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:node, _Node}) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, :apps) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:app, app}) do
    case running_app_pid(app) do
      {:ok, _pid} -> {:ok, {0o0755, @attr_dir, 0}, state}
      :error -> {:error, @error_noent, state}
    end
  end

  def elixirfs_getattr(state, {:app, app, app_sub_dir}) do
    attrs =
      case {app_sub_dir, running_app_pid(app), loaded_app(app)} do
        {"app_proc", {:ok, pid}, _loaded} when pid !== :undefined ->
          {:ok, {0o0755, @attr_symlink, 0}}

        {"top_sup", {:ok, pid}, _loaded} when pid !== :undefined ->
          {:ok, {0o0755, @attr_symlink, 0}}

        {"descr", _running, {:ok, _descr, _vsn}} ->
          {:ok, {0o0644, @attr_file, file_size(state, {:app, app, app_sub_dir})}}

        {"vsn", _running, {:ok, _descr, _vsn}} ->
          {:ok, {0o0644, @attr_file, file_size(state, {:app, app, app_sub_dir})}}

        {"env", {:ok, _pid}, _loaded} ->
          {:ok, {0o0755, @attr_dir, 0}}

        _ ->
          :error
      end

    case attrs do
      {:ok, attrs} -> {:ok, attrs, state}
      :error -> {:error, @error_noent, state}
    end
  end

  def elixirfs_getattr(state, {:app_env, app, opt}) do
    case app_env(app, opt) do
      {:ok, _val} -> {:ok, {0o0644, @attr_file, file_size(state, {:app_env, app, opt})}, state}
      :error -> {:error, @error_noent, state}
    end
  end

  def elixirfs_getattr(state, {:link_from, _pid}) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:link_to, _linked_pid}) do
    {:ok, {0o0755, @attr_symlink, 0}, state}
  end

  def elixirfs_getattr(state, :code) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:code, :modules}) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:code, :module, _Module}) do
    {:ok, {0o0755, @attr_dir, 0}, state}
  end

  def elixirfs_getattr(state, {:code, :module, module, :file}) do
    {:ok, {0o0644, @attr_file, file_size(state, {:code, :module, module, :file})}, state}
  end

  @doc false
  def elixirfs_readlink(state, {:local_name, name}) do
    case Process.whereis(name) do
      nil ->
        {:error, @error_noent, state}

      pid ->
        dest =
          state.mount_point <> "/pids/#PID" <> :erlang.list_to_binary(:erlang.pid_to_list(pid))

        {:ok, dest, state}
    end
  end

  def elixirfs_readlink(state, {:global_name, name}) do
    case global_name_pid(name) do
      {:ok, pid} ->
        dest =
          state.mount_point <> "/pids/#PID" <> :erlang.list_to_binary(:erlang.pid_to_list(pid))

        {:ok, dest, state}

      :error ->
        {:error, @error_noent, state}
    end
  end

  def elixirfs_readlink(state, {:app, app, "app_proc"}) do
    case running_app_pid(app) do
      {:ok, pid} when pid !== :undefined ->
        dest =
          state.mount_point <> "/pids/#PID" <> :erlang.list_to_binary(:erlang.pid_to_list(pid))

        {:ok, dest, state}

      _ ->
        {:error, @error_noent, state}
    end
  end

  def elixirfs_readlink(state, {:app, app, "top_sup"}) do
    case running_app_pid(app) do
      {:ok, pid} when pid !== :undefined ->
        {sup_pid, _mod} = :application_master.get_child(pid)

        dest =
          state.mount_point <>
            "/pids/#PID" <> :erlang.list_to_binary(:erlang.pid_to_list(sup_pid))

        {:ok, dest, state}

      _ ->
        {:error, @error_noent, state}
    end
  end

  def elixirfs_readlink(state, {:link_to, linked_pid}) do
    dest =
      state.mount_point <> "/pids/#PID" <> :erlang.list_to_binary(:erlang.pid_to_list(linked_pid))

    {:ok, dest, state}
  end

  @doc false
  def elixirfs_read(state, {:proc_info, pid, item_spec}) do
    case safe_process_info(pid, item_spec) do
      {:ok, {^item_spec, item_data}} ->
        {:ok, proc_info_content(item_data), state}

      :error ->
        {:error, @error_noent, state}
    end
  end

  def elixirfs_read(state, {:app, app, "descr"}) do
    case loaded_app(app) do
      {:ok, descr, _vsn} -> {:ok, "#{descr}\n", state}
      :error -> {:error, @error_noent, state}
    end
  end

  def elixirfs_read(state, {:app, app, "vsn"}) do
    case loaded_app(app) do
      {:ok, _descr, vsn} -> {:ok, "#{vsn}\n", state}
      :error -> {:error, @error_noent, state}
    end
  end

  def elixirfs_read(state, {:app_env, app, opt}) do
    case app_env(app, opt) do
      {:ok, val} -> {:ok, inspect(val, pretty: true) <> "\n", state}
      :error -> {:error, @error_noent, state}
    end
  end

  def elixirfs_read(state, {:code, :module, module, :file}) do
    {:ok, "#{:code.which(module)}\n", state}
  end

  defp file_size(state, context) do
    {:ok, content, _state} = elixirfs_read(state, context)
    byte_size(content)
  end

  defp proc_info_content(item_data) do
    inspect(item_data, pretty: true) <> "\n"
  end

  defp safe_process_info(pid, item_spec) do
    case Process.info(pid, item_spec) do
      nil -> :error
      item -> {:ok, item}
    end
  rescue
    ArgumentError -> :error
  end

  defp loaded_apps() do
    :application_controller.info()[:loaded]
  end

  defp running_apps() do
    :application_controller.info()[:running]
  end

  defp running_app_pid(app) do
    case for {name, pid} when name == app <- running_apps(), do: pid do
      [pid] -> {:ok, pid}
      [] -> :error
    end
  end

  defp loaded_app(app) do
    case for {name, descr, vsn} when name == app <- loaded_apps(), do: {descr, vsn} do
      [{descr, vsn}] -> {:ok, descr, vsn}
      [] -> :error
    end
  end

  defp app_env(app, opt) do
    env = Application.get_all_env(app)

    if Keyword.has_key?(env, opt) do
      {:ok, Keyword.fetch!(env, opt)}
    else
      :error
    end
  end

  defp global_name_pid(name) do
    case :global.whereis_name(name) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end
end
