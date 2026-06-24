defmodule ExfuseTest do
  use Exfuse.Fs, attribs: true
  use ExUnit.Case

  @moduletag :fuse

  defmodule WriteFs do
    use Exfuse.Fs
    alias Exfuse.Socket

    def exfuse_init(_mount_point, agent), do: {:ok, agent}

    def handle_event(:readdir, %{path: "/"}, socket), do: {:reply, ["f"], socket}

    def handle_event(:getattr, %{path: "/"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(:getattr, %{path: "/f"}, socket),
      do: {:reply, {0o0644, @attr_file, 0}, socket}

    def handle_event(:open, %{path: "/f"}, socket), do: {:noreply, socket}

    def handle_event(op, %{path: "/f"}, socket) when op in [:flush, :release],
      do: {:noreply, socket}

    def handle_event(:read, _event, socket), do: {:reply, "", socket}

    def handle_event(
          :write,
          %{path: path, offset: offset, data: data},
          %Socket{state: agent} = socket
        ) do
      Agent.update(agent, &[{path, offset, data} | &1])
      {:reply, byte_size(data), socket}
    end

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  defmodule FineGrainedFs do
    use Exfuse.Fs
    alias Exfuse.Socket

    def start_link do
      Agent.start(fn ->
        %{
          events: [],
          nodes: %{
            "/" => {:dir, 0o0755},
            "/file" => {:file, 0o0644, "abcdef"},
            "/old" => {:file, 0o0644, "old"},
            "/empty" => {:dir, 0o0755}
          },
          owners: %{}
        }
      end)
    end

    def events(agent), do: Agent.get(agent, &Enum.reverse(&1.events))
    def node(agent, path), do: Agent.get(agent, & &1.nodes[path])
    def file(agent, path), do: elem(node(agent, path), 2)

    def exfuse_init(_mount_point, agent), do: {:ok, agent}

    def handle_event(:readdir, %{path: path}, %Socket{state: agent} = socket) do
      Agent.get(agent, fn %{nodes: nodes} ->
        case nodes[path] do
          {:dir, _mode} ->
            entries =
              nodes
              |> Map.keys()
              |> Enum.reject(&(&1 == path))
              |> Enum.filter(&(Path.dirname(&1) == path))
              |> Enum.map(&Path.basename/1)
              |> Enum.sort()

            {:reply, entries, socket}

          _ ->
            {:error, :enoent, socket}
        end
      end)
    end

    def handle_event(:getattr, %{path: path}, %Socket{state: agent} = socket) do
      case node(agent, path) do
        {:dir, mode} -> {:reply, {mode, @attr_dir, 0}, socket}
        {:file, mode, data} -> {:reply, {mode, @attr_file, byte_size(data)}, socket}
        _ -> {:error, :enoent, socket}
      end
    end

    def handle_event(:readlink, _event, socket), do: {:error, :enoent, socket}

    def handle_event(
          :read,
          %{path: path, offset: offset, size: size},
          %Socket{state: agent} = socket
        ) do
      case node(agent, path) do
        {:file, _mode, data} ->
          record(agent, {:read, path})
          {:reply, slice(data, offset, size), socket}

        _ ->
          {:error, :enoent, socket}
      end
    end

    def handle_event(:open, %{path: path, flags: flags}, %Socket{state: agent} = socket) do
      record(agent, {:open, path, flags})
      {:reply, 101, socket}
    end

    def handle_event(
          :write,
          %{path: path, offset: offset, data: data},
          %Socket{state: agent} = socket
        ) do
      Agent.get_and_update(agent, fn state ->
        case state.nodes[path] do
          {:file, mode, content} ->
            state =
              put_node(
                state,
                path,
                {:file, mode, write_at(content, offset, data)},
                {:write, path, offset, data}
              )

            {{:reply, byte_size(data), socket}, state}

          _ ->
            {{:error, :enoent, socket}, state}
        end
      end)
    end

    def handle_event(
          :create,
          %{path: path, mode: mode, flags: flags},
          %Socket{state: agent} = socket
        ) do
      Agent.update(agent, &put_node(&1, path, {:file, mode, ""}, {:create, path, mode, flags}))
      {:reply, 202, socket}
    end

    def handle_event(:truncate, %{path: path, size: size}, %Socket{state: agent} = socket) do
      update_file(agent, socket, path, {:truncate, path, size}, fn mode, content ->
        {:file, mode, resize(content, size)}
      end)
    end

    def handle_event(:unlink, %{path: path}, %Socket{state: agent} = socket) do
      update(agent, socket, fn state ->
        %{state | nodes: Map.delete(state.nodes, path), events: [{:unlink, path} | state.events]}
      end)
    end

    def handle_event(:rename, %{path: from, target: to}, %Socket{state: agent} = socket) do
      update(agent, socket, fn state ->
        {node, nodes} = Map.pop(state.nodes, from)
        %{state | nodes: Map.put(nodes, to, node), events: [{:rename, from, to} | state.events]}
      end)
    end

    def handle_event(:mkdir, %{path: path, mode: mode}, %Socket{state: agent} = socket) do
      update(agent, socket, &put_node(&1, path, {:dir, mode}, {:mkdir, path, mode}))
    end

    def handle_event(:rmdir, %{path: path}, %Socket{state: agent} = socket) do
      update(agent, socket, fn state ->
        %{state | nodes: Map.delete(state.nodes, path), events: [{:rmdir, path} | state.events]}
      end)
    end

    def handle_event(:chmod, %{path: path, mode: mode}, %Socket{state: agent} = socket) do
      update_file(agent, socket, path, {:chmod, path, mode}, fn _old_mode, content ->
        {:file, mode, content}
      end)
    end

    def handle_event(
          :chown,
          %{path: path, owner_uid: uid, owner_gid: gid},
          %Socket{state: agent} = socket
        ) do
      update(agent, socket, fn state ->
        %{
          state
          | owners: Map.put(state.owners, path, {uid, gid}),
            events: [{:chown, path, uid, gid} | state.events]
        }
      end)
    end

    def handle_event(
          :flush,
          %{path: path, flags: flags, handle: handle},
          %Socket{state: agent} = socket
        ) do
      update(agent, socket, &%{&1 | events: [{:flush, path, flags, handle} | &1.events]})
    end

    def handle_event(
          :release,
          %{path: path, flags: flags, handle: handle},
          %Socket{state: agent} = socket
        ) do
      update(agent, socket, &%{&1 | events: [{:release, path, flags, handle} | &1.events]})
    end

    def handle_event(
          :fsync,
          %{path: path, datasync: datasync, flags: flags, handle: handle},
          %Socket{state: agent} = socket
        ) do
      update(
        agent,
        socket,
        &%{&1 | events: [{:fsync, path, datasync, flags, handle} | &1.events]}
      )
    end

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}

    defp update(agent, socket, fun) do
      Agent.update(agent, fun)
      {:noreply, socket}
    end

    defp update_file(agent, socket, path, event, fun) do
      Agent.get_and_update(agent, fn state ->
        case state.nodes[path] do
          {:file, mode, content} ->
            {{:noreply, socket}, put_node(state, path, fun.(mode, content), event)}

          _ ->
            {{:error, :enoent, socket}, state}
        end
      end)
    end

    defp record(agent, event) do
      Agent.update(agent, &%{&1 | events: [event | &1.events]})
    end

    defp put_node(state, path, node, event) do
      %{state | nodes: Map.put(state.nodes, path, node), events: [event | state.events]}
    end

    defp write_at(content, offset, data) do
      content = pad_to(content, offset)
      before = binary_part(content, 0, offset)
      after_offset = min(offset + byte_size(data), byte_size(content))
      after_data = binary_part(content, after_offset, byte_size(content) - after_offset)
      before <> data <> after_data
    end

    defp resize(content, size) when byte_size(content) > size, do: binary_part(content, 0, size)
    defp resize(content, size), do: pad_to(content, size)

    defp slice(content, offset, size) do
      start = min(offset, byte_size(content))
      count = min(size, byte_size(content) - start)
      binary_part(content, start, count)
    end

    defp pad_to(content, size) when byte_size(content) < size do
      content <> :binary.copy(<<0>>, size - byte_size(content))
    end

    defp pad_to(content, _size), do: content
  end

  defmodule SocketFs do
    use Exfuse.Fs
    alias Exfuse.Socket

    def exfuse_init(_mount_point, agent), do: {:ok, agent}

    def handle_event(:readdir, %{path: "/"}, socket),
      do: {:reply, ["ctx"], socket}

    def handle_event(:getattr, %{path: "/"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(:getattr, %{path: "/ctx"}, socket),
      do: {:reply, {0o0644, @attr_file, 3}, socket}

    def handle_event(:open, %{path: "/ctx"}, socket), do: {:noreply, socket}

    def handle_event(op, %{path: "/ctx"}, socket) when op in [:flush, :release],
      do: {:noreply, socket}

    def handle_event(:read, %{path: "/ctx"} = event, %Socket{state: agent} = socket) do
      Agent.update(agent, &[{event.uid, event.gid, event.pid, event.umask} | &1])
      {:reply, "ctx", socket}
    end

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  defmodule FindSocketFs do
    use Exfuse.Fs
    alias Exfuse.Socket

    @tree %{
      "/" => {:dir, ["README.md", "docs"]},
      "/README.md" => {:file, "readme\n"},
      "/docs" => {:dir, ["a.txt", "deep"]},
      "/docs/a.txt" => {:file, "alpha\n"},
      "/docs/deep" => {:dir, ["b.txt"]},
      "/docs/deep/b.txt" => {:file, "beta\n"}
    }

    def exfuse_init(_mount_point, agent), do: {:ok, %{agent: agent, tree: @tree}}

    def events(agent), do: Agent.get(agent, &Enum.reverse/1)

    def handle_event(:readdir, %{path: path}, %Socket{state: state} = socket) do
      path = normalize_path(path)

      case state.tree[path] do
        {:dir, entries} -> {:reply, entries, touch(socket, :readdir, path)}
        _ -> {:error, :enoent, socket}
      end
    end

    def handle_event(:getattr, %{path: path}, %Socket{state: state} = socket) do
      path = normalize_path(path)

      case state.tree[path] do
        {:dir, _entries} ->
          {:reply, {0o0755, @attr_dir, 0}, touch(socket, :getattr, path)}

        {:file, body} ->
          {:reply, {0o0644, @attr_file, byte_size(body)}, touch(socket, :getattr, path)}

        nil ->
          {:error, :enoent, socket}
      end
    end

    def handle_event(:open, %{path: path}, %Socket{state: state} = socket) do
      path = normalize_path(path)

      case state.tree[path] do
        {:file, _body} -> {:noreply, touch(socket, :open, path)}
        _ -> {:error, :enoent, socket}
      end
    end

    def handle_event(
          :read,
          %{path: path, offset: offset, size: size},
          %Socket{state: state} = socket
        ) do
      path = normalize_path(path)

      case state.tree[path] do
        {:file, body} -> {:reply, slice(body, offset, size), touch(socket, :read, path)}
        _ -> {:error, :enoent, socket}
      end
    end

    def handle_event(op, %{path: path}, socket) when op in [:flush, :release],
      do: {:noreply, touch(socket, op, normalize_path(path))}

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}

    defp touch(%Socket{state: %{agent: agent}} = socket, op, path) do
      count = Socket.get_assign(socket, :count, 0) + 1
      socket = Socket.assign(socket, :count, count)
      Agent.update(agent, &[{op, path, socket.id, count} | &1])
      socket
    end

    defp normalize_path("/."), do: "/"
    defp normalize_path(path), do: path

    defp slice(content, offset, size) do
      start = min(offset, byte_size(content))
      count = min(size, byte_size(content) - start)
      binary_part(content, start, count)
    end
  end

  defmodule MacroFs do
    use Exfuse.Fs

    init do
      opts
    end

    readdir "/" do
      {:reply, ["docs"], socket}
    end

    readdir "/docs" do
      {:reply, Map.keys(state), socket}
    end

    getattr "/" do
      {:reply, dir(), socket}
    end

    getattr "/docs" do
      {:reply, dir(), socket}
    end

    getattr "/docs/:name" do
      case Map.fetch(state, name) do
        {:ok, body} -> {:reply, file(size: byte_size(body)), socket}
        :error -> {:error, :enoent, socket}
      end
    end

    read "/docs/:name" do
      case Map.fetch(state, name) do
        {:ok, body} -> {:reply, slice(body, event.offset, event.size), socket}
        :error -> {:error, :enoent, socket}
      end
    end

    defp slice(content, offset, size) do
      start = min(offset, byte_size(content))
      count = min(size, byte_size(content) - start)
      binary_part(content, start, count)
    end
  end

  defmodule PlugMountedEndpoint do
    def handle_event(:getattr, %{params: %{name: name}}, socket) do
      case Map.fetch(socket.state, name) do
        {:ok, body} -> {:reply, Exfuse.Fs.file(size: byte_size(body)), socket}
        :error -> {:error, :enoent, socket}
      end
    end

    def handle_event(:read, %{params: %{name: name}, offset: offset, size: size}, socket) do
      case Map.fetch(socket.state, name) do
        {:ok, body} -> {:reply, slice(body, offset, size), socket}
        :error -> {:error, :enoent, socket}
      end
    end

    def handle_event(:open, %{params: %{name: name}}, socket) do
      if Map.has_key?(socket.state, name), do: {:noreply, socket}, else: {:error, :enoent, socket}
    end

    def handle_event(op, %{params: %{name: _name}}, socket) when op in [:flush, :release],
      do: {:noreply, socket}

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}

    defp slice(content, offset, size) do
      start = min(offset, byte_size(content))
      count = min(size, byte_size(content) - start)
      binary_part(content, start, count)
    end
  end

  defmodule PlugMountedFs do
    use Exfuse.Fs

    init do
      opts
    end

    readdir "/" do
      {:reply, ["docs"], socket}
    end

    readdir "/docs" do
      {:reply, Map.keys(state), socket}
    end

    getattr "/" do
      {:reply, dir(), socket}
    end

    getattr "/docs" do
      {:reply, dir(), socket}
    end

    plug("/docs/:name", ExfuseTest.PlugMountedEndpoint)
  end

  defmodule InitNotifyFs do
    use Exfuse.Fs

    def exfuse_init(mp, opts) do
      send(opts[:owner], {:exfuse_init, mp, opts})
      {:ok, opts}
    end

    def handle_event(:readdir, %{path: "/"}, socket), do: {:reply, [], socket}

    def handle_event(:getattr, %{path: "/"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  defmodule ReaddirMountedFs do
    use Exfuse.Fs

    def exfuse_init(_mp, _opts), do: {:ok, :ready}
    def handle_event(:readdir, %{path: "/"}, socket), do: {:reply, ["aaa", "bbb"], socket}

    def handle_event(:getattr, %{path: "/"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(:getattr, %{path: path}, socket) when path in ["/aaa", "/bbb"],
      do: {:reply, {0o0644, @attr_file, 0}, socket}

    def handle_event(:getattr, _event, socket), do: {:error, :enoent, socket}
    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  defmodule AttrMountedFs do
    use Exfuse.Fs

    def exfuse_init(_mp, _opts), do: {:ok, :ready}

    def handle_event(:getattr, %{path: "/"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(:getattr, %{path: "/f"}, socket),
      do: {:reply, {0o0644, @attr_file, 10}, socket}

    def handle_event(:getattr, %{path: "/d"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(:getattr, %{path: "/s"}, socket),
      do: {:reply, {0o0555, @attr_symlink, 20}, socket}

    def handle_event(:getattr, %{path: "/e"}, socket), do: {:error, :enoent, socket}
    def handle_event(:getattr, _event, socket), do: {:error, :enoent, socket}
    def handle_event(:readlink, %{path: "/s"}, socket), do: {:reply, "/target", socket}
    def handle_event(:readlink, _event, socket), do: {:error, :enoent, socket}
    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  defmodule ReadMountedFs do
    use Exfuse.Fs

    @content "abcdefghijklmnopqrstuvwxyz0123456789"

    def exfuse_init(_mp, _opts), do: {:ok, :ready}
    def content, do: @content

    def handle_event(:getattr, %{path: "/"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(:getattr, %{path: "/f"}, socket),
      do: {:reply, {0o0644, @attr_file, byte_size(@content)}, socket}

    def handle_event(:getattr, _event, socket), do: {:error, :enoent, socket}
    def handle_event(:open, %{path: "/f"}, socket), do: {:noreply, socket}

    def handle_event(op, %{path: "/f"}, socket) when op in [:flush, :release],
      do: {:noreply, socket}

    def handle_event(:read, %{path: "/f", offset: offset, size: size}, socket),
      do: {:reply, slice(@content, offset, size), socket}

    def handle_event(:read, _event, socket), do: {:error, :enoent, socket}
    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}

    defp slice(content, offset, size) do
      start = min(offset, byte_size(content))
      count = min(size, byte_size(content) - start)
      binary_part(content, start, count)
    end
  end

  defmodule LinkMountedFs do
    use Exfuse.Fs
    alias Exfuse.Socket

    def exfuse_init(_mp, target), do: {:ok, target}

    def handle_event(:getattr, %{path: "/"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(:getattr, %{path: "/s"}, %Socket{state: target} = socket),
      do: {:reply, {0o0644, @attr_symlink, byte_size(target)}, socket}

    def handle_event(:getattr, _event, socket), do: {:error, :enoent, socket}

    def handle_event(:readlink, %{path: "/s"}, %Socket{state: target} = socket),
      do: {:reply, target, socket}

    def handle_event(:readlink, _event, socket), do: {:error, :enoent, socket}
    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  describe "mount" do
    setup do
      mp = tmp_mount("mount")
      System.cmd("mkdir", [mp], stderr_to_stdout: true)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rmdir", [mp], stderr_to_stdout: true)
      end)

      {:ok, mp: mp}
    end

    test "returns PID of FS", %{mp: mp} do
      {:ok, pid} = Exfuse.mount(mp, TestFs, this: 2, that: 3)
      assert is_pid(pid)
    end

    test "FS init is called", %{mp: mp} do
      opts = [owner: self(), answer: 42]

      {:ok, pid} = Exfuse.mount(mp, InitNotifyFs, opts)

      assert is_pid(pid)
      assert_receive {:exfuse_init, ^mp, ^opts}
    end
  end

  describe "umount" do
    setup do
      mp = tmp_mount("umount")
      System.cmd("mkdir", ["-p", mp])

      on_exit(fn ->
        System.cmd("rmdir", [mp])
      end)

      {:ok, mp: mp}
    end

    test "returns successful unmount for mounted FS", %{mp: mp} do
      {:ok, pid} = Exfuse.mount(mp, TestFs, this: 2, that: 3)
      assert {:ok, ^pid} = Exfuse.umount(mp)
    end

    test "returns error for not mounted FS", %{mp: mp} do
      assert {:error, :not_mounted} = Exfuse.umount(mp)
    end
  end

  describe "list" do
    setup do
      mp1 = tmp_mount("list-1")
      mp2 = tmp_mount("list-2")
      System.cmd("mkdir", ["-p", mp1, mp2])

      on_exit(fn ->
        Exfuse.umount(mp1)
        Exfuse.umount(mp2)
        System.cmd("rmdir", [mp1, mp2])
      end)

      {:ok, mp1: mp1, mp2: mp2}
    end

    test "returns a list of mounted filesystems", %{mp1: mp1, mp2: mp2} do
      {:ok, pid1} = Exfuse.mount(mp1, TestFs, this: 2, that: 3)
      assert Exfuse.list() |> Enum.map(fn {pid, _} -> pid end) |> Enum.member?(pid1)
      {:ok, pid2} = Exfuse.mount(mp2, TestFs, this: 2, that: 3)
      assert Exfuse.list() |> Enum.map(fn {pid, _} -> pid end) |> Enum.member?(pid1)
      assert Exfuse.list() |> Enum.map(fn {pid, _} -> pid end) |> Enum.member?(pid2)
    end
  end

  describe "readdir" do
    setup do
      mp = tmp_mount("readdir")
      System.cmd("mkdir", ["-p", mp])
      {:ok, _pid} = Exfuse.mount(mp, ReaddirMountedFs, :ok)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rm", ["-rf", mp])
      end)

      {:ok, mp: mp}
    end

    test "FS implementation represented to OS (files returned)", %{mp: mp} do
      assert {:ok, ls_files} = File.ls(mp)
      assert Enum.sort(ls_files) == ["aaa", "bbb"]
    end

    test "FS implementation represented to native ls", %{mp: mp} do
      assert {out, 0} = System.cmd("ls", ["-1", mp], stderr_to_stdout: true)

      assert out
             |> String.split("\n", trim: true)
             |> Enum.sort() == ["aaa", "bbb"]
    end
  end

  describe "getattr" do
    setup do
      mp = tmp_mount("getattr")
      System.cmd("mkdir", ["-p", mp])
      {:ok, _pid} = Exfuse.mount(mp, AttrMountedFs, :ok)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rm", ["-rf", mp])
      end)

      {:ok, mp: mp}
    end

    test "FS implementation represented to OS (file)", %{mp: mp} do
      {:ok, {mode, size, type}} = os_stat(mp <> "/f")
      assert mode === 0o0644
      assert type === :file
      assert size === 10
    end

    test "FS implementation represented to OS (directory)", %{mp: mp} do
      {:ok, {mode, _size, type}} = os_stat(mp <> "/d")
      assert mode === 0o0755
      assert type === :dir
    end

    test "FS implementation represented to OS (symlink)", %{mp: mp} do
      {:ok, {mode, size, type}} = os_stat(mp <> "/s")
      assert mode === 0o0555
      assert size === 20
      assert type === :symlink
    end

    test "FS implementation represented to OS (noent error)", %{mp: mp} do
      {:error, :enoent} = os_stat(mp <> "/e")
    end
  end

  describe "read" do
    setup do
      mp = tmp_mount("read")
      System.cmd("mkdir", ["-p", mp])
      {:ok, _pid} = Exfuse.mount(mp, ReadMountedFs, :ok)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rmdir", [mp])
      end)

      {:ok, mp: mp}
    end

    test "FS implementation represented to OS", %{mp: mp} do
      content = ReadMountedFs.content()
      assert {:ok, ^content} = File.read(mp <> "/f")
    end
  end

  describe "linkread" do
    setup do
      mp = tmp_mount("linkread")
      System.cmd("mkdir", ["-p", mp])
      target = mp <> "/f"
      {:ok, _pid} = Exfuse.mount(mp, LinkMountedFs, target)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rmdir", [mp])
      end)

      {:ok, mp: mp, target: target}
    end

    test "FS implementation represented to OS", %{mp: mp, target: target} do
      assert {:ok, ^target} = File.read_link(mp <> "/s")
    end
  end

  describe "write" do
    setup do
      mp = tmp_mount("write")
      System.cmd("mkdir", ["-p", mp])
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, _pid} = Exfuse.mount(mp, WriteFs, agent)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rmdir", [mp])
      end)

      {:ok, agent: agent, mp: mp}
    end

    test "FS implementation receives OS writes", %{agent: agent, mp: mp} do
      assert {:ok, file} = File.open(mp <> "/f", [:raw, :read, :write])
      assert :ok = :file.pwrite(file, 0, "abc")
      assert :ok = File.close(file)
      assert [{"/f", 0, "abc"}] = Agent.get(agent, &Enum.reverse/1)
    end
  end

  describe "socket mounted requests" do
    setup do
      mp = tmp_mount("socket")
      System.cmd("mkdir", ["-p", mp])
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, _pid} = Exfuse.mount(mp, SocketFs, agent)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rmdir", [mp])
      end)

      {:ok, agent: agent, mp: mp}
    end

    test "exposes caller context from macFUSE", %{agent: agent, mp: mp} do
      assert {:ok, "ctx"} = File.read(mp <> "/ctx")

      assert [{uid, gid, pid, umask}] = Agent.get(agent, &Enum.reverse/1)
      assert uid == current_id("-u")
      assert gid == current_id("-g")
      assert is_integer(pid) and pid > 0
      assert is_integer(umask) and umask >= 0
    end
  end

  describe "long-lived socket traversal" do
    setup do
      mp = tmp_mount("socket-find")
      System.cmd("mkdir", ["-p", mp])
      {:ok, agent} = Agent.start(fn -> [] end)
      {:ok, _pid} = Exfuse.mount(mp, FindSocketFs, agent)

      on_exit(fn ->
        Exfuse.umount(mp)
        if Process.alive?(agent), do: Agent.stop(agent)
        System.cmd("rmdir", [mp])
      end)

      {:ok, agent: agent, mp: mp}
    end

    test "keeps one socket alive while find walks the mounted tree", %{agent: agent, mp: mp} do
      assert {output, 0} = System.cmd(find_bin(), ["."], cd: mp, stderr_to_stdout: true)

      assert output |> String.split("\n", trim: true) |> Enum.sort() ==
               Enum.sort([
                 ".",
                 "./README.md",
                 "./docs",
                 "./docs/a.txt",
                 "./docs/deep",
                 "./docs/deep/b.txt"
               ])

      events = FindSocketFs.events(agent)

      assert [_socket_id] =
               events
               |> Enum.map(fn {_op, _path, socket_id, _count} -> socket_id end)
               |> Enum.uniq()

      assert events |> Enum.map(fn {_op, _path, _socket_id, count} -> count end) ==
               Enum.to_list(1..length(events))

      assert {:readdir, "/", :_, :_} |> event_seen?(events)
      assert {:readdir, "/docs", :_, :_} |> event_seen?(events)
      assert {:readdir, "/docs/deep", :_, :_} |> event_seen?(events)
      assert {:getattr, "/docs/deep/b.txt", :_, :_} |> event_seen?(events)
    end
  end

  defmodule SocketHandleFs do
    use Exfuse.Fs
    alias Exfuse.Socket

    def exfuse_init(_mount_point, agent), do: {:ok, agent}

    def handle_event(:readdir, %{path: "/"}, socket),
      do: {:reply, ["f"], socket}

    def handle_event(:getattr, %{path: "/"}, socket),
      do: {:reply, {0o0755, @attr_dir, 0}, socket}

    def handle_event(:getattr, %{path: "/f"}, socket),
      do: {:reply, {0o0644, @attr_file, 3}, socket}

    def handle_event(:open, %{path: "/f"}, socket),
      do: {:reply, 303, socket}

    def handle_event(:read, %{path: "/f"} = event, %Socket{state: agent} = socket) do
      Agent.update(agent, &[{:read, event.handle, event.offset, event.size} | &1])
      {:reply, "abc", socket}
    end

    def handle_event(:write, %{path: "/f"} = event, %Socket{state: agent} = socket) do
      Agent.update(agent, &[{:write, event.handle, event.offset, event.data} | &1])
      {:reply, byte_size(event.data), socket}
    end

    def handle_event(op, %{path: "/f"}, socket) when op in [:flush, :release],
      do: {:noreply, socket}

    def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
  end

  describe "socket file handles" do
    setup do
      mp = tmp_mount("socket-handle")
      System.cmd("mkdir", ["-p", mp])
      {:ok, agent} = Agent.start_link(fn -> [] end)
      {:ok, _pid} = Exfuse.mount(mp, SocketHandleFs, agent)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rmdir", [mp])
      end)

      {:ok, agent: agent, mp: mp}
    end

    test "passes open handle to read and write", %{agent: agent, mp: mp} do
      assert {:ok, file} = File.open(mp <> "/f", [:raw, :read, :write])
      assert {:ok, "abc"} = :file.pread(file, 0, 3)
      assert :ok = :file.pwrite(file, 1, "Z")
      assert :ok = File.close(file)

      assert {:read, 303, 0, 3} in Agent.get(agent, & &1)
      assert {:write, 303, 1, "Z"} in Agent.get(agent, & &1)
    end
  end

  describe "route macro mounted requests" do
    setup do
      mp = tmp_mount("macro")
      System.cmd("mkdir", ["-p", mp])
      {:ok, _pid} = Exfuse.mount(mp, MacroFs, %{"hello.txt" => "hello\n"})

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rmdir", [mp])
      end)

      {:ok, mp: mp}
    end

    test "serves files through generated socket endpoint", %{mp: mp} do
      assert {:ok, ["hello.txt"]} = File.ls(mp <> "/docs")
      assert {:ok, "hello\n"} = File.read(mp <> "/docs/hello.txt")
    end
  end

  describe "plug macro mounted requests" do
    setup do
      mp = tmp_mount("plug-macro")
      System.cmd("mkdir", ["-p", mp])
      {:ok, _pid} = Exfuse.mount(mp, PlugMountedFs, %{"hello.txt" => "hello\n"})

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rmdir", [mp])
      end)

      {:ok, mp: mp}
    end

    test "delegates real FUSE packets to the plugged module", %{mp: mp} do
      assert {:ok, ["hello.txt"]} = File.ls(mp <> "/docs")
      assert {:ok, "hello\n"} = File.read(mp <> "/docs/hello.txt")
    end
  end

  describe "fine-grained mounted file ops" do
    @describetag timeout: 10_000

    setup do
      mp = tmp_mount("fine-grained")
      System.cmd("mkdir", ["-p", mp])
      {:ok, agent} = FineGrainedFs.start_link()
      {:ok, _pid} = Exfuse.mount(mp, FineGrainedFs, agent)

      on_exit(fn ->
        Exfuse.umount(mp)
        System.cmd("rm", ["-rf", mp])
      end)

      {:ok, agent: agent, mp: mp}
    end

    test "dispatches open for existing files", %{agent: agent, mp: mp} do
      assert {:ok, file} = File.open(mp <> "/file", [:raw, :read])
      assert :ok = File.close(file)
      assert_event(agent, {:open, "/file", :_})
      assert_event(agent, {:release, "/file", :_, 101})
    end

    test "dispatches fsync with open handle", %{agent: agent, mp: mp} do
      assert {_, 0} = python_fsync(mp <> "/file")
      assert_event(agent, {:fsync, "/file", true, :_, 101})
    end

    test "dispatches write with offset", %{agent: agent, mp: mp} do
      assert {:ok, file} = File.open(mp <> "/file", [:raw, :read, :write])
      assert :ok = :file.pwrite(file, 2, "ZZ")
      assert :ok = File.close(file)
      assert FineGrainedFs.file(agent, "/file") == "abZZef"
      assert_event(agent, {:write, "/file", :_, :_})
    end

    test "dispatches create through File.write", %{agent: agent, mp: mp} do
      assert :ok = File.write(mp <> "/created", "new")
      assert FineGrainedFs.file(agent, "/created") == "new"
      assert_event(agent, {:create, "/created", :_, :_})
    end

    test "dispatches truncate for existing files", %{agent: agent, mp: mp} do
      assert {:ok, file} = File.open(mp <> "/file", [:raw, :read, :write])
      assert {:ok, 3} = :file.position(file, 3)
      assert :ok = :file.truncate(file)
      assert :ok = File.close(file)
      assert_eventually(fn -> FineGrainedFs.file(agent, "/file") == "abc" end)
      assert_event(agent, {:truncate, "/file", 3})
    end

    test "dispatches unlink", %{agent: agent, mp: mp} do
      assert :ok = File.rm(mp <> "/file")
      assert FineGrainedFs.node(agent, "/file") == nil
      assert_event(agent, {:unlink, "/file"})
    end

    test "dispatches rename", %{agent: agent, mp: mp} do
      assert :ok = File.rename(mp <> "/old", mp <> "/renamed")
      assert FineGrainedFs.node(agent, "/old") == nil
      assert FineGrainedFs.file(agent, "/renamed") == "old"
      assert_event(agent, {:rename, "/old", "/renamed"})
    end

    test "dispatches mkdir and rmdir", %{agent: agent, mp: mp} do
      assert :ok = File.mkdir(mp <> "/made")
      assert {:dir, _mode} = FineGrainedFs.node(agent, "/made")
      assert_event(agent, {:mkdir, "/made", :_})

      assert :ok = File.rmdir(mp <> "/made")
      assert FineGrainedFs.node(agent, "/made") == nil
      assert_event(agent, {:rmdir, "/made"})
    end

    test "dispatches chmod", %{agent: agent, mp: mp} do
      assert :ok = File.chmod(mp <> "/file", 0o0600)
      assert {:file, 0o0600, _data} = FineGrainedFs.node(agent, "/file")
      assert_event(agent, {:chmod, "/file", 0o0600})
    end

    test "dispatches chown", %{agent: agent, mp: mp} do
      uid = current_id("-u")
      gid = current_id("-g")

      assert :ok = :file.change_owner(to_charlist(mp <> "/file"), uid, gid)
      assert_event(agent, {:chown, "/file", uid, gid})
    end
  end

  # File.stat is not very good; hides sylinks, no proper access

  def os_stat(path) do
    case File.lstat(path) do
      {:ok, %{mode: mode, size: size, type: type}} ->
        {:ok, {Bitwise.band(mode, 0o7777), size, stat_type(type)}}

      {:error, :enoent} ->
        {:error, :enoent}
    end
  end

  defp stat_type(:regular), do: :file
  defp stat_type(:directory), do: :dir
  defp stat_type(type), do: type

  defp tmp_mount(prefix) do
    Path.join(
      "/tmp/exfuse-runs",
      "exfuse-#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp assert_event(agent, pattern) do
    assert Enum.any?(FineGrainedFs.events(agent), &event_match?(&1, pattern))
  end

  defp event_seen?(pattern, events) do
    Enum.any?(events, &event_match?(&1, pattern))
  end

  defp assert_eventually(fun) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert_eventually(fun, deadline)
  end

  defp assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        assert_eventually(fun, deadline)

      true ->
        flunk("condition did not become true")
    end
  end

  defp event_match?(event, pattern) do
    event
    |> Tuple.to_list()
    |> Enum.zip(Tuple.to_list(pattern))
    |> Enum.all?(fn
      {_actual, :_} -> true
      {same, same} -> true
      _ -> false
    end)
  end

  defp current_id(flag) do
    {id, 0} = System.cmd("id", [flag])
    id |> String.trim() |> String.to_integer()
  end

  defp find_bin do
    System.find_executable("find") || "/usr/bin/find"
  end

  defp python_fsync(path) do
    python = System.find_executable("python3")

    code = """
    import os, sys
    fd = os.open(sys.argv[1], os.O_RDWR)
    os.write(fd, bytes([97, 98, 99]))
    os.fsync(fd)
    os.close(fd)
    """

    System.cmd(python, ["-c", code, path], stderr_to_stdout: true)
  end
end
