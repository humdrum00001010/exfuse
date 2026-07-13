# exfuse

Elixir filesystem routing over native user-space filesystem backends.

Exfuse runs one logical filesystem independently of its native mount points.
macOS uses FSKit; Linux and other supported Unix systems use the Rust
FUSE/libfuse port. Both adapters speak the same strict v3 protocol and invoke
the same Elixir callbacks.

## Filesystem API

```elixir
defmodule DocsFs do
  use Exfuse.Fs

  init do
    opts
  end

  readdir "/" do
    {:reply,
     [
       {"README.md", attr(type: :file, size: byte_size(state.readme))},
       {"docs", attr(type: :dir)}
     ], socket}
  end

  getattr "/" do
    {:reply, attr(type: :dir), socket}
  end

  getattr "/README.md" do
    {:reply, attr(type: :file, size: byte_size(state.readme)), socket}
  end

  read "/README.md" do
    start = min(event.offset, byte_size(state.readme))
    size = min(event.size, byte_size(state.readme) - start)
    {:reply, binary_part(state.readme, start, size), socket}
  end
end

{:ok, fs} = Exfuse.start_fs(DocsFs, %{readme: "hello\n"})
{:ok, mount} = Exfuse.mount(fs, "/tmp/docsfs")

:ok = Exfuse.unmount(mount)
:ok = Exfuse.stop_fs(fs)
```

One `fs` can be attached to multiple mount points. `readdir` always returns
`{name, attributes}` pairs; this lets FSKit and FUSE fill ordinary directory
entries without issuing one `getattr` callback per child.

`attr/1` is the single attribute constructor:

```elixir
attr(type: :dir)
attr(type: :file, size: 1_024, mtime: 1_720_000_000)
attr(type: :symlink, size: 9)
```

Route patterns bind path values:

```elixir
read "/docs/:file" do
  {:reply, state[file], socket}
end

read "/docs/*path" do
  {:reply, Enum.join(path, "/"), socket}
end

plug "/topics/:id", TopicFile
```

Each `plug` declaration owns one persistent `Exfuse.File` process. Parameter
values are carried in `event.params`; they do not create processes.

For full control, implement `exfuse_init/1` and `handle_event/3` directly:

```elixir
defmodule ManualFs do
  @behaviour Exfuse.Fs
  import Exfuse.Fs, only: [attr: 1]

  def exfuse_init(service), do: {:ok, service}

  def handle_event(:readdir, %{path: "/"}, socket) do
    entries = Enum.map(Service.list(socket.state), fn %{name: name, size: size} ->
      {name, attr(type: :file, size: size)}
    end)

    {:reply, entries, socket}
  end

  def handle_event(operation, _event, socket),
    do: {:error, if(operation == :write, do: :erofs, else: :enoent), socket}
end
```

Callbacks return Channel-style tuples:

```elixir
{:reply, value, socket}
{:noreply, socket}
{:error, reason, socket}
```

Read operations run concurrently from an immutable state snapshot. Stateful
operations run in arrival order. The event map always includes `path`,
`mount_point`, `uid`, `gid`, `pid`, and `umask`, plus operation-specific fields.

The detailed execution and wire design is in
[`docs/backend-neutral-filesystem-ir.md`](docs/backend-neutral-filesystem-ir.md).

## Backends

The Rust port lives under `rust`. It is a Port executable, not a NIF. Set
`EXFUSE_PORT=/path/to/exfuse_port` to override its location.

The FSKit implementation lives under `native/fskit`. It uses a pool of 16
persistent localhost connections to preserve concurrent FSKit callbacks.

Check SDK compatibility:

```sh
mix exfuse.fskit.check
```

Build the host app and extension. Xcode owns provisioning and signing:

```sh
mix exfuse.fskit.bundle --team TEAMID
```

The team may instead come from `DEVELOPMENT_TEAM`. For compile/package checks:

```sh
mix exfuse.fskit.bundle --no-sign
```

Build, sign, install, register, and elect the extension:

```sh
mix exfuse.fskit.install --build --team TEAMID
```

macOS also requires enabling `exfuse` under:

```text
System Settings > General > Login Items & Extensions > File System Extensions
```

## Build and test

Tool versions live in `.mise.toml`: Elixir 1.20.1 on OTP 29.

```sh
mise install
mise exec -- mix deps.get
mise exec -- mix compile
mise exec -- mix test
```

On macOS, Mix does not build the Linux FUSE port. Check it independently with:

```sh
cargo check --manifest-path rust/Cargo.toml
```

## License

MIT.
