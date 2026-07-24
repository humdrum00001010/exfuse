defmodule Exfuse.Fs.Memory do
  @moduledoc "Process-owned in-memory implementation of the `Exfuse.Fs` contract."

  @behaviour Exfuse.Fs

  alias Exfuse.{Fs, Socket}

  @impl true
  def exfuse_init(opts) do
    files = Keyword.get(opts, :files, %{})
    symlinks = Keyword.get(opts, :symlinks, %{})

    nodes =
      Enum.reduce(files, %{"/" => directory()}, fn {path, bytes}, nodes ->
        path = canonical!(path)
        nodes |> ensure_parents(path) |> Map.put(path, file(bytes))
      end)

    nodes =
      Enum.reduce(symlinks, nodes, fn {path, target}, nodes ->
        path = canonical!(path)
        nodes |> ensure_parents(path) |> Map.put(path, symlink(target))
      end)

    {:ok, %{nodes: nodes}}
  end

  @impl true
  def handle_event(:readdir, %{path: path}, socket) do
    with {:ok, %{type: :directory}} <- fetch(socket, path) do
      entries =
        socket.state.nodes
        |> Enum.filter(fn {candidate, _node} -> Path.dirname(candidate) == path end)
        |> Enum.reject(fn {candidate, _node} -> candidate == path end)
        |> Enum.map(fn {candidate, node} ->
          {Path.basename(candidate), attrs(node)}
        end)
        |> Enum.sort_by(&elem(&1, 0))

      {:reply, entries, socket}
    else
      {:ok, _node} -> {:error, :enotdir, socket}
      :error -> {:error, :enoent, socket}
    end
  end

  def handle_event(:getattr, %{path: path}, socket) do
    case fetch(socket, path) do
      {:ok, node} -> {:reply, attrs(node), socket}
      :error -> {:error, :enoent, socket}
    end
  end

  def handle_event(:readlink, %{path: path}, socket) do
    case fetch(socket, path) do
      {:ok, %{type: :symlink, target: target}} -> {:reply, target, socket}
      {:ok, _node} -> {:error, :einval, socket}
      :error -> {:error, :enoent, socket}
    end
  end

  def handle_event(:read, %{path: path, offset: offset, size: size}, socket) do
    case fetch(socket, path) do
      {:ok, %{type: :file, bytes: bytes}} ->
        start = min(offset, byte_size(bytes))
        length = min(size, max(byte_size(bytes) - offset, 0))
        {:reply, binary_part(bytes, start, length), socket}

      {:ok, %{type: :directory}} ->
        {:error, :eisdir, socket}

      {:ok, %{type: :symlink}} ->
        {:error, :einval, socket}

      :error ->
        {:error, :enoent, socket}
    end
  end

  def handle_event(:mkdir, %{path: path, mode: mode}, socket) do
    cond do
      Map.has_key?(socket.state.nodes, path) ->
        {:error, :eexist, socket}

      not parent_directory?(socket.state.nodes, path) ->
        {:error, :enoent, socket}

      true ->
        node = %{type: :directory, mode: mode, mtime: now()}
        {:noreply, put_node(socket, path, node)}
    end
  end

  def handle_event(:create, %{path: path, mode: mode}, socket) do
    cond do
      not parent_directory?(socket.state.nodes, path) ->
        {:error, :enoent, socket}

      match?(%{type: :directory}, Map.get(socket.state.nodes, path)) ->
        {:error, :eisdir, socket}

      match?(%{type: :symlink}, Map.get(socket.state.nodes, path)) ->
        {:error, :eacces, socket}

      true ->
        handle = System.unique_integer([:positive, :monotonic])
        node = %{type: :file, mode: mode, mtime: now(), bytes: ""}
        {:reply, handle, put_node(socket, path, node)}
    end
  end

  def handle_event(:write, %{path: path, offset: offset, data: data}, socket) do
    case fetch(socket, path) do
      {:ok, %{type: :file, bytes: bytes} = node} ->
        node = %{node | bytes: splice(bytes, offset, data), mtime: now()}
        {:reply, byte_size(data), put_node(socket, path, node)}

      {:ok, _node} ->
        {:error, :eisdir, socket}

      :error ->
        {:error, :enoent, socket}
    end
  end

  def handle_event(operation, _event, socket) when operation in [:flush, :release],
    do: {:noreply, socket}

  def handle_event(:rename, %{path: source, target: target}, socket) do
    nodes = socket.state.nodes
    source_node = Map.get(nodes, source)
    target_node = Map.get(nodes, target)

    cond do
      is_nil(source_node) ->
        {:error, :enoent, socket}

      source == "/" ->
        {:error, :ebusy, socket}

      source == target ->
        {:noreply, socket}

      source_node.type == :directory and String.starts_with?(target, source <> "/") ->
        {:error, :einval, socket}

      not parent_directory?(nodes, target) ->
        {:error, :enoent, socket}

      incompatible_target?(source_node, target_node) ->
        {:error, target_type_error(source_node), socket}

      match?(%{type: :directory}, target_node) and directory_nonempty?(nodes, target) ->
        {:error, :enotempty, socket}

      true ->
        moved =
          Enum.filter(nodes, fn {path, _node} ->
            path == source or String.starts_with?(path, source <> "/")
          end)

        nodes = delete_subtree(nodes, target)
        nodes = Enum.reduce(moved, nodes, fn {path, _node}, acc -> Map.delete(acc, path) end)

        nodes =
          Enum.reduce(moved, nodes, fn {path, node}, acc ->
            Map.put(acc, String.replace_prefix(path, source, target), node)
          end)

        {:noreply, Socket.put_state(socket, %{socket.state | nodes: nodes})}
    end
  end

  def handle_event(:unlink, %{path: path}, socket),
    do: remove_node(socket, path, :non_directory)

  def handle_event(:rmdir, %{path: path}, socket),
    do: remove_node(socket, path, :directory)

  def handle_event(_operation, _event, socket), do: {:error, :enosys, socket}

  defp canonical!(path) do
    case Fs.Path.canonical(path) do
      {:ok, path} -> path
      {:error, reason} -> raise ArgumentError, "invalid memory path: #{inspect(reason)}"
    end
  end

  defp ensure_parents(nodes, "/"), do: nodes

  defp ensure_parents(nodes, path) do
    path
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 != "/"))
    |> Enum.reverse()
    |> then(&["/" | &1])
    |> Enum.reduce(nodes, fn parent, acc -> Map.put_new(acc, parent, directory()) end)
  end

  defp parent_directory?(nodes, path) do
    match?(%{type: :directory}, Map.get(nodes, Path.dirname(path)))
  end

  defp put_node(socket, path, node) do
    Socket.put_state(socket, %{socket.state | nodes: Map.put(socket.state.nodes, path, node)})
  end

  defp fetch(socket, path), do: Map.fetch(socket.state.nodes, path)

  defp directory, do: %{type: :directory, mode: 0o755, mtime: now()}
  defp file(bytes), do: %{type: :file, mode: 0o644, mtime: now(), bytes: bytes}
  defp symlink(target), do: %{type: :symlink, mode: 0o755, mtime: now(), target: target}
  defp now, do: System.system_time(:second)

  defp attrs(%{type: :directory, mode: mode, mtime: mtime}),
    do: Fs.attr(type: :dir, mode: mode, mtime: mtime)

  defp attrs(%{type: :file, mode: mode, mtime: mtime, bytes: bytes}),
    do: Fs.attr(type: :file, mode: mode, size: byte_size(bytes), mtime: mtime)

  defp attrs(%{type: :symlink, mode: mode, mtime: mtime, target: target}),
    do: Fs.attr(type: :symlink, mode: mode, size: byte_size(target), mtime: mtime)

  defp splice(bytes, offset, data) do
    size = byte_size(bytes)

    prefix =
      if offset <= size do
        binary_part(bytes, 0, offset)
      else
        bytes <> :binary.copy(<<0>>, offset - size)
      end

    suffix_offset = offset + byte_size(data)

    suffix =
      if suffix_offset < size do
        binary_part(bytes, suffix_offset, size - suffix_offset)
      else
        ""
      end

    prefix <> data <> suffix
  end

  defp remove_node(socket, path, :non_directory) do
    case Map.fetch(socket.state.nodes, path) do
      {:ok, %{type: :directory}} ->
        {:error, :eisdir, socket}

      {:ok, _node} ->
        nodes = Map.delete(socket.state.nodes, path)
        {:noreply, Socket.put_state(socket, %{socket.state | nodes: nodes})}

      :error ->
        {:error, :enoent, socket}
    end
  end

  defp remove_node(socket, "/", :directory), do: {:error, :ebusy, socket}

  defp remove_node(socket, path, :directory) do
    case Map.fetch(socket.state.nodes, path) do
      {:ok, %{type: :directory}} ->
        if directory_nonempty?(socket.state.nodes, path) do
          {:error, :enotempty, socket}
        else
          nodes = Map.delete(socket.state.nodes, path)
          {:noreply, Socket.put_state(socket, %{socket.state | nodes: nodes})}
        end

      {:ok, _node} ->
        {:error, :enotdir, socket}

      :error ->
        {:error, :enoent, socket}
    end
  end

  defp incompatible_target?(_source, nil), do: false

  defp incompatible_target?(%{type: :directory}, %{type: :directory}), do: false
  defp incompatible_target?(%{type: :directory}, _target), do: true

  defp incompatible_target?(_source, %{type: :directory}), do: true

  defp incompatible_target?(_source, _target), do: false

  defp target_type_error(%{type: :directory}), do: :enotdir
  defp target_type_error(_source), do: :eisdir

  defp directory_nonempty?(nodes, path),
    do: Enum.any?(Map.keys(nodes), &String.starts_with?(&1, path <> "/"))

  defp delete_subtree(nodes, path) do
    nodes
    |> Enum.reject(fn {candidate, _node} ->
      candidate == path or String.starts_with?(candidate, path <> "/")
    end)
    |> Map.new()
  end
end
