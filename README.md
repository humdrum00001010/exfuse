# exfuse

Elixir filesystem routing over FUSE.

The native bridge is the Rust port `exfuse_port` under `rust`. Mix builds it
and copies it to `priv/exfuse_port`. It is not a NIF.

Set `EXFUSE_PORT=/path/to/exfuse_port` to override the port executable.

## Build

Tool versions live in `.mise.toml`: Elixir 1.20.1 on OTP 29.

```sh
mise install
mise exec -- mix deps.get
mise exec -- mix compile
```

Portable tests run by default:

```sh
mise exec -- mix test
```

Real mount tests require a working FUSE installation and are opt-in:

```sh
EXFUSE_RUN_FUSE_TESTS=1 mise exec -- mix test --only fuse
```

## Hex

Package metadata lives in `mix.exs`. The Hex package includes the Elixir source
and the Rust bridge source; generated binaries and build outputs are excluded.

Verify the package:

```sh
mise exec -- mix hex.build --unpack
mise exec -- mix hex.publish --dry-run
```

Publish with:

```sh
mise exec -- mix hex.publish
```

## License

MIT.

## Filesystem API

`Exfuse.mount/3` mounts one filesystem process at a mount point. Everything
below that mount point is served by the filesystem module through FUSE
operations like `readdir`, `getattr`, `open`, and `read`.

```elixir
defmodule DocsFs do
  use Exfuse.Fs

  init do
    opts
  end

  readdir "/*" do
    case Map.fetch(state, event.path) do
      {:ok, {:dir, entries}} -> {:reply, entries, socket}
      _ -> {:error, :enoent, socket}
    end
  end

  getattr "/*" do
    case Map.fetch(state, event.path) do
      {:ok, {:dir, _entries}} -> {:reply, dir(), socket}
      {:ok, {:file, data}} -> {:reply, file(size: byte_size(data)), socket}
      :error -> {:error, :enoent, socket}
    end
  end

  open "/*" do
    case Map.fetch(state, event.path) do
      {:ok, {:file, _data}} -> {:noreply, socket}
      {:ok, {:dir, _entries}} -> {:error, :eisdir, socket}
      _ -> {:error, :enoent, socket}
    end
  end

  read "/*" do
    case Map.fetch(state, event.path) do
      {:ok, {:file, data}} ->
        {:reply, slice(data, event.offset, event.size), socket}

      {:ok, {:dir, _entries}} ->
        {:error, :eisdir, socket}

      :error ->
        {:error, :enoent, socket}
    end
  end

  defp slice(data, offset, size) do
    start = min(offset, byte_size(data))
    count = min(size, byte_size(data) - start)
    binary_part(data, start, count)
  end
end
```

Mount a tree:

```elixir
{:ok, _pid} =
  Exfuse.mount("/tmp/docsfs", DocsFs, %{
    "/" => {:dir, ["README.md", "docs"]},
    "/README.md" => {:file, "readme\n"},
    "/docs" => {:dir, ["intro.txt", "api"]},
    "/docs/intro.txt" => {:file, "intro\n"},
    "/docs/api" => {:dir, ["mount.txt"]},
    "/docs/api/mount.txt" => {:file, "mount\n"}
  })
```

The mounted tree is searchable like a normal filesystem:

```sh
cd /tmp/docsfs
find .
# .
# ./README.md
# ./docs
# ./docs/intro.txt
# ./docs/api
# ./docs/api/mount.txt
```

Unmount with the OS tool or with:

```elixir
Exfuse.umount("/tmp/docsfs")
```

## Route Patterns

Route patterns:

```elixir
read "/docs/:file" do
  {:reply, state[file], socket}
end

read "/docs/*path" do
  {:reply, Enum.join(path, "/"), socket}
end

plug "/docs/:file", DocsFile
```

`:name` binds one path segment as a binary. `*name` binds the remaining path
tail as a list of segments. Bare `*` matches the remaining path tail without
binding it.

Inside a route block:

- `socket` is the long-lived mount session.
- `state` is `socket.state`.
- `event` is the current FUSE operation payload.
- route params are local variables, not socket fields.

`plug/2` delegates every matching operation packet to an endpoint process.
Processes are keyed by route params, so repeated packets for `/docs/a` reuse
one process while `/docs/b` gets another.

```elixir
defmodule DocsFile do
  def init(socket) do
    {:ok, socket}
  end

  def handle_event(:getattr, %{params: %{file: file}}, socket) do
    {:reply, Exfuse.Fs.file(size: byte_size(file)), socket}
  end

  def handle_event(:read, %{params: %{file: file}} = event, socket) do
    {:reply, read_file(file, event.offset, event.size), socket}
  end

  def handle_event(_op, _event, socket) do
    {:error, :enoent, socket}
  end
end
```

Plug params live in `event.params`; the socket is still only the long-lived
session held by that endpoint process.

Return Channel-style tuples:

```elixir
{:reply, reply, socket}
{:noreply, socket}
{:error, reason, socket}
```

Known error atoms include `:enoent`, `:eperm`, `:eio`, `:eacces`, `:eexist`,
`:enotdir`, `:eisdir`, `:einval`, `:enospc`, `:erofs`, and `:enosys`.

## Manual API

For full control, implement `handle_event/3` directly.

```elixir
defmodule ManualDocsFs do
  use Exfuse.Fs

  def exfuse_init(mount_point, docs) do
    {:ok, %{mount_point: mount_point, docs: docs}}
  end

  def handle_event(:readdir, %{path: "/"}, socket) do
    {:reply, Map.keys(socket.state.docs), socket}
  end

  def handle_event(:getattr, %{path: "/"}, socket) do
    {:reply, dir(), socket}
  end

  def handle_event(:getattr, %{path: "/" <> file}, socket) do
    case Map.fetch(socket.state.docs, file) do
      {:ok, data} -> {:reply, file(size: byte_size(data)), socket}
      :error -> {:error, :enoent, socket}
    end
  end

  def handle_event(:open, %{path: "/" <> file}, socket) do
    if Map.has_key?(socket.state.docs, file) do
      {handle, socket} = Exfuse.Socket.new_handle(socket, file)
      {:reply, handle, socket}
    else
      {:error, :enoent, socket}
    end
  end

  def handle_event(:read, %{handle: handle, offset: offset, size: size}, socket) do
    with {:ok, file} <- Exfuse.Socket.fetch_handle(socket, handle),
         {:ok, data} <- Map.fetch(socket.state.docs, file) do
      {:reply, slice(data, offset, size), socket}
    else
      :error -> {:error, :enoent, socket}
    end
  end

  def handle_event(:release, %{handle: handle}, socket) do
    {:noreply, Exfuse.Socket.delete_handle(socket, handle)}
  end

  def handle_event(_op, _event, socket) do
    {:error, :enoent, socket}
  end

  defp slice(data, offset, size) do
    start = min(offset, byte_size(data))
    count = min(size, byte_size(data) - start)
    binary_part(data, start, count)
  end
end
```

`%Exfuse.Socket{}` is the long-lived mount session:

```elixir
%Exfuse.Socket{
  id: term,
  mount_point: "/tmp/docsfs",
  state: term,
  assigns: %{}
}
```

Useful handle helpers:

```elixir
{handle, socket} = Exfuse.Socket.new_handle(socket, value)
{:ok, value} = Exfuse.Socket.fetch_handle(socket, handle)
socket = Exfuse.Socket.delete_handle(socket, handle)
```

The event carrier is a map. Every event includes:

```elixir
%{
  path: "/file",
  uid: uid,
  gid: gid,
  pid: pid,
  umask: umask
}
```

Extra fields by operation:

| op | fields |
| --- | --- |
| `:read` | `flags`, `handle`, `offset`, `size` |
| `:write` | `handle`, `offset`, `data` |
| `:open` | `flags` |
| `:create` | `mode`, `flags` |
| `:truncate` | `size` |
| `:rename` | `target` |
| `:mkdir`, `:chmod` | `mode` |
| `:chown` | `owner_uid`, `owner_gid` |
| `:flush`, `:release` | `flags`, `handle` |
| `:fsync` | `datasync`, `flags`, `handle` |

`handle_event/3` receives the operation as the first argument, so route and
manual code usually match on `op` there rather than inside the event map.
