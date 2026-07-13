# Backend-neutral filesystem execution

## What changed

Exfuse now separates a logical filesystem from its native attachments:

```text
Fs.Supervisor
├── FileSupervisor
│   ├── File (root callback state)
│   └── File (one per plug declaration, started lazily)
├── MountSupervisor
│   ├── Mount (FSKit attachment)
│   └── Mount (Linux FUSE attachment)
└── Fs.Runtime (namespace and routing state)
```

The `fs` PID returned by `Exfuse.start_fs/3` is this per-filesystem supervisor.
Its file and mount children are not shared with another filesystem. `File`
owns callback state and request scheduling. `Mount` owns only the native
transport and mount lifecycle. FSKit and Linux FUSE decode into the same normal
operation and call the same `File` process.

This is a clean v3 cutover. There is no v2 parser, old mount API, compatibility
adapter, `Exfuse.Server`, or parameter-keyed endpoint process.

## Public use

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
{:ok, local} = Exfuse.mount(fs, "/Volumes/docs")
{:ok, mirror} = Exfuse.mount(fs, "/Volumes/docs-mirror")

:ok = Exfuse.unmount(local)
:ok = Exfuse.unmount(mirror)
:ok = Exfuse.stop_fs(fs)
```

The filesystem is initialized once. A mount point is event context, not
filesystem state; every event includes `event.mount_point`.

## Attributes and readdir

`attr/1` is the only public attribute constructor:

```elixir
attr(type: :dir)
# => {0o0755, 1, 0}

attr(type: :file, size: 1_024, mtime: 1_720_000_000)
# => {0o0644, 2, 1_024, 1_720_000_000}

attr(type: :symlink, size: byte_size("README.md"))
# => {0o0755, 3, 9}
```

Normal `readdir` always returns `{name, attributes}` pairs:

```elixir
def handle_event(:readdir, %{path: path}, socket) do
  entries =
    list(path)
    |> Enum.map(fn
      %{name: name, kind: :directory} -> {name, attr(type: :dir)}
      %{name: name, body: body} -> {name, attr(type: :file, size: byte_size(body))}
    end)

  {:reply, entries, socket}
end
```

These are not public directory-page or entry structs. A pair is sufficient:
the name identifies the child and the ordinary attribute tuple carries the
metadata the kernel needs. Cursors, page generations, and a special
`readdir_plus` operation are not part of the filesystem callback API.

The performance change is concrete. Before v3, FSKit did:

```text
readdir(/topics) -> [name ...]
getattr(/topics/name-1)
getattr(/topics/name-2)
...
```

It now does:

```text
readdir(/topics) -> [{name, attr} ...]
```

For Vweb's indexed collections, the same cached index document produces both
the names and their attributes. A directory listing no longer creates one
Elixir/native/HTTP lookup chain per child.

## Plug process ownership

```elixir
defmodule RootFs do
  use Exfuse.Fs
  plug "/topics/:id", TopicFile
end

defmodule TopicFile do
  @behaviour Exfuse.Fs

  def exfuse_init(service), do: {:ok, service}

  def handle_event(:read, %{params: %{id: id}} = event, socket) do
    {:reply, Service.read(socket.state, id, event.offset, event.size), socket}
  end

  def handle_event(operation, _event, socket), do: {:error, unsupported(operation), socket}
end
```

`plug "/topics/:id", TopicFile` creates at most one `File`, lazily. Both
`/topics/1` and `/topics/2` run through that process; `event.params` carries the
different values. Another `plug` declaration gets another process.

Read-only operations (`readdir`, `getattr`, `readlink`, and `read`) run
concurrently from one socket snapshot. They may not mutate callback state.
Stateful operations are queued and applied in arrival order. Each `File` has a
bounded queue and returns `EBUSY` when saturated.

## Packet flow

FSKit uses a pool of 16 persistent TCP connections. The pool checks out any
idle connection rather than round-robining onto a busy lane. Each accepted
socket executes a serial receive/dispatch/send loop, while separate sockets run
concurrently:

```text
FSKit callback
  -> checkout idle ExfuseWireConnection
  -> encode v3 request
  -> TCP packet-4
  -> WireListener connection task
  -> Wire.decode_request
  -> root File.dispatch
  -> optional plug File.dispatch
  -> Wire.encode_reply
  -> same TCP connection
  -> validate v3 envelope
  -> decode operation payload
  -> FSKit completion
```

Linux FUSE uses the same envelope over the Rust port's packet-4 stdio. Request
IDs permit concurrent callbacks and out-of-order replies.

## v3 wire contract

All integers are unsigned big-endian unless noted.

Request envelope:

```text
magic:u32 = 0xC02155AC
version:u32 = 0x76330003
operation:u32
request_id:u64
uid:u32
gid:u32
pid:u32
umask:u32
payload:bytes
```

Response envelope:

```text
magic:u32
version:u32
operation:u32
request_id:u64
errno:u32
payload:bytes
```

Attribute payloads are either 16 or 24 bytes:

```text
mode:u32
type:u32       # 1 directory, 2 regular file, 3 symlink
size:u64
[mtime:u64]
```

`readdir` response payload:

```text
entry_count:u32
repeat entry_count times:
  name_length:u32
  name:utf8[name_length]
  attr_length:u32       # 16 or 24
  attr:bytes[attr_length]
```

Names must be valid UTF-8, at most 255 bytes, nonempty, not `.` or `..`, and
contain neither `/` nor NUL. Decoders reject trailing bytes, invalid attribute
types, oversized frames, malformed lengths, and every non-v3 envelope.

## FSKit boundary

The FSKit extension opens the volume when macOS calls the
`UnaryFileSystemExtension` lifecycle. Exfuse does not call an FSKit API to
construct a volume directly. `Exfuse.mount/3` starts the listener and invokes:

```text
mount -F -t exfuse exfuse://127.0.0.1:<port>/?session=<token> <mount-point>
```

macOS selects the installed extension, creates the FSKit resource, calls the
extension to probe/load it, and then calls `activate` and `mount` on the volume.
The URL tells the extension which Exfuse listener to connect to.

During directory enumeration, `ExfuseVolume` converts each returned attr into
`FSItem.Attributes` and passes it to `FSDirectoryEntryPacker`. It does not call
`getattr` for each name.

FSKit may fill its packer before the directory is complete and continue with a
cookie in another callback. The first callback obtains one Exfuse `readdir`
result and assigns an FSKit directory verifier; continuation callbacks reuse
that result. It is discarded when that enumeration reaches the end. A later
enumeration starts with the initial verifier and obtains a fresh result, so
this is enumeration state rather than a persistent directory cache.

## Linux boundary

The Rust port starts libfuse with the requested mount point. Its normal
`readdir` callback decodes the same rich records and passes a populated
`libc::stat` pointer to the standard FUSE filler. This is backend-specific
adaptation of a common operation, not a backend-specific operation in the
Elixir API.

## Removed surface

The cutover deletes:

- `Exfuse.mount(path, module, state, options)` and `Exfuse.umount(path)`;
- `Exfuse.Server`, `Exfuse.Endpoint`, and `Exfuse.MountSup`;
- `exfuse_init(mount_point, state)`;
- `dir/1`, `file/1`, and `symlink/1` helpers;
- names-only `readdir` replies;
- v2 and unversioned wire parsing;
- parameter-keyed plug processes;
- legacy FSKit resource cleanup and provisioning compatibility code.

There is one execution path per backend and one callback contract.
