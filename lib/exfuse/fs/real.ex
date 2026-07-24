defmodule Exfuse.Fs.Real do
  @moduledoc "Host directory-backed implementation of the `Exfuse.Fs` contract."

  @behaviour Exfuse.Fs

  alias Exfuse.{Fs, Socket}

  @impl true
  def exfuse_init(opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()

    if File.dir?(root) do
      {:ok, %{root: root, exclude: MapSet.new(Keyword.get(opts, :exclude, []))}}
    else
      {:error, :enoent}
    end
  end

  @impl true
  def watcher(%{root: root}), do: {:ok, dirs: [root], latency: 0}

  @impl true
  def event_path(%{root: root, exclude: exclude}, host_path) do
    host_path = Path.expand(host_path)
    relative = Path.relative_to(host_path, root)
    segments = Path.split(relative)

    cond do
      relative == host_path -> :ignore
      relative == "." -> :ignore
      String.starts_with?(relative, "../") -> :ignore
      Enum.any?(segments, &MapSet.member?(exclude, &1)) -> :ignore
      true -> Fs.Path.canonical(relative)
    end
  end

  @impl true
  def handle_event(:readdir, %{path: path}, socket) do
    with {:ok, host} <- host_path(socket.state, path),
         {:ok, names} <- File.ls(host) do
      entries =
        names
        |> Enum.reject(&MapSet.member?(socket.state.exclude, &1))
        |> Enum.flat_map(fn name ->
          case File.lstat(Path.join(host, name), time: :posix) do
            {:ok, stat} -> [{name, attrs(stat)}]
            {:error, _reason} -> []
          end
        end)
        |> Enum.sort_by(&elem(&1, 0))

      {:reply, entries, socket}
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:getattr, %{path: path}, socket) do
    with {:ok, host} <- host_path(socket.state, path, leaf: :nofollow),
         {:ok, stat} <- File.lstat(host, time: :posix) do
      {:reply, attrs(stat), socket}
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:readlink, %{path: path}, socket) do
    with {:ok, host} <- host_path(socket.state, path, leaf: :nofollow),
         {:ok, target} <- File.read_link(host) do
      {:reply, target, socket}
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:read, %{path: path, offset: offset, size: size}, socket) do
    with {:ok, host} <- host_path(socket.state, path) do
      case File.open(host, [:read, :binary], fn io -> :file.pread(io, offset, size) end) do
        {:ok, {:ok, bytes}} -> {:reply, bytes, socket}
        {:ok, :eof} -> {:reply, "", socket}
        {:ok, {:error, reason}} -> {:error, reason, socket}
        {:error, reason} -> {:error, reason, socket}
      end
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:create, %{path: path, mode: mode}, socket) do
    with {:ok, host} <- host_path(socket.state, path),
         :ok <- File.write(host, "", [:binary]) do
      case File.chmod(host, mode) do
        :ok ->
          {handle, socket} = Socket.new_handle(socket, host)
          {:reply, handle, socket}

        {:error, reason} ->
          {:error, reason, socket}
      end
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:write, %{handle: handle, offset: offset, data: data}, socket) do
    with {:ok, host} <- Socket.fetch_handle(socket, handle),
         :ok <- with_raw_file(host, [:read, :write], &:file.pwrite(&1, offset, data)) do
      {:reply, byte_size(data), socket}
    else
      :error -> {:error, :ebadf, socket}
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:flush, %{handle: handle}, socket) do
    with {:ok, host} <- Socket.fetch_handle(socket, handle),
         :ok <- with_raw_file(host, [:read, :write], &:file.sync/1) do
      {:noreply, socket}
    else
      :error -> {:error, :ebadf, socket}
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:release, %{handle: handle}, socket) do
    with {:ok, _host} <- Socket.fetch_handle(socket, handle) do
      {:noreply, Socket.delete_handle(socket, handle)}
    else
      :error -> {:error, :ebadf, socket}
    end
  end

  def handle_event(:rename, %{path: source, target: target}, socket) do
    with {:ok, source} <- host_path(socket.state, source, leaf: :nofollow),
         {:ok, target} <- host_path(socket.state, target, leaf: :nofollow),
         :ok <- File.rename(source, target) do
      {:noreply, socket}
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:mkdir, %{path: path, mode: mode}, socket) do
    with {:ok, host} <- host_path(socket.state, path),
         :ok <- File.mkdir(host) do
      case File.chmod(host, mode) do
        :ok ->
          {:noreply, socket}

        {:error, reason} ->
          File.rmdir(host)
          {:error, reason, socket}
      end
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  def handle_event(:unlink, %{path: path}, socket),
    do: host_mutation(socket, path, &File.rm/1, leaf: :nofollow)

  def handle_event(:rmdir, %{path: path}, socket),
    do: host_mutation(socket, path, &File.rmdir/1, leaf: :nofollow)

  def handle_event(_operation, _event, socket), do: {:error, :enosys, socket}

  defp host_path(state, path, opts \\ []) do
    with {:ok, path} <- Fs.Path.canonical(path) do
      relative = String.trim_leading(path, "/")
      segments = if relative == "", do: [], else: String.split(relative, "/")
      parent_segments = Enum.drop(segments, -1)
      leaf_policy = Keyword.get(opts, :leaf, :reject_symlink)

      cond do
        Enum.any?(segments, &MapSet.member?(state.exclude, &1)) ->
          {:error, :enoent}

        true ->
          candidate = Path.join([state.root | segments])

          with true <-
                 candidate == state.root or String.starts_with?(candidate, state.root <> "/"),
               :ok <- reject_symlink_ancestors(state.root, parent_segments),
               :ok <- validate_leaf(candidate, leaf_policy) do
            {:ok, candidate}
          else
            false -> {:error, :eacces}
            {:error, _reason} = error -> error
          end
      end
    end
  end

  defp reject_symlink_ancestors(root, segments) do
    segments
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn candidate, :ok ->
      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :eacces}}
        {:ok, %{type: :directory}} -> {:cont, :ok}
        {:ok, _stat} -> {:halt, {:error, :enotdir}}
        {:error, :enoent} -> {:halt, {:error, :enoent}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_leaf(_candidate, :nofollow), do: :ok

  defp validate_leaf(candidate, :reject_symlink) do
    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} -> {:error, :eacces}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp host_mutation(socket, path, operation, opts) do
    with {:ok, host} <- host_path(socket.state, path, opts),
         :ok <- operation.(host) do
      {:noreply, socket}
    else
      {:error, reason} -> {:error, reason, socket}
    end
  end

  defp with_raw_file(path, modes, operation) do
    with {:ok, io} <-
           :file.open(String.to_charlist(path), [:raw, :binary | modes]) do
      operation_result = operation.(io)
      close_result = :file.close(io)

      case {operation_result, close_result} do
        {:ok, :ok} -> :ok
        {{:error, _reason} = error, _close_result} -> error
        {:ok, {:error, reason}} -> {:error, reason}
      end
    end
  end

  defp attrs(%File.Stat{type: type, mode: mode, size: size, mtime: mtime}) do
    Fs.attr(
      type: entry_type(type),
      mode: Bitwise.band(mode, 0o7777),
      size: size,
      mtime: mtime
    )
  end

  defp entry_type(:directory), do: :dir
  defp entry_type(:regular), do: :file
  defp entry_type(:symlink), do: :symlink
  defp entry_type(_other), do: :file
end
