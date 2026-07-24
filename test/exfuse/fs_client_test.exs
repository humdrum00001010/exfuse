defmodule Exfuse.FsClientTest do
  use ExUnit.Case, async: true

  defmodule EchoFs do
    use Exfuse.Fs

    read "/*path" do
      {:reply, %{path: "/" <> Enum.join(path, "/"), offset: event.offset}, socket}
    end
  end

  defmodule ContractFs do
    use Exfuse.Fs

    init do
      %{owner: opts}
    end

    readdir "/" do
      send(state.owner, {:operation, :readdir, event})

      {:reply,
       [
         {"docs", attr(type: :dir)},
         {"README.md", attr(type: :file, size: 5)}
       ], socket}
    end

    getattr "/*" do
      send(state.owner, {:operation, :getattr, event})
      {:reply, attr(type: :file, size: 5, mtime: 42), socket}
    end

    read "/*" do
      send(state.owner, {:operation, :read, event})
      {:reply, "hello", socket}
    end

    readlink "/*" do
      send(state.owner, {:operation, :readlink, event})
      {:reply, "/target", socket}
    end

    create "/*" do
      send(state.owner, {:operation, :create, event})
      {:reply, 7, socket}
    end

    write "/*" do
      send(state.owner, {:operation, :write, event})

      if event.data == "fail" do
        {:error, :eio, socket}
      else
        {:reply, byte_size(event.data), socket}
      end
    end

    flush "/*" do
      send(state.owner, {:operation, :flush, event})
      {:noreply, socket}
    end

    release "/*" do
      send(state.owner, {:operation, :release, event})
      {:noreply, socket}
    end

    rename "/*" do
      send(state.owner, {:operation, :rename, event})
      {:noreply, socket}
    end

    mkdir "/*" do
      send(state.owner, {:operation, :mkdir, event})
      {:noreply, socket}
    end

    unlink "/*" do
      send(state.owner, {:operation, :unlink, event})
      {:noreply, socket}
    end
  end

  test "request canonicalizes and dispatches through the root file" do
    {:ok, fs} = Exfuse.start_fs(EchoFs, %{})
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert {:ok, %{path: "/docs/a.md", offset: 3}} =
             Exfuse.Fs.request(fs, :read, %{path: "docs//a.md", offset: 3})

    assert {:error, :path_traversal} =
             Exfuse.Fs.request(fs, :read, %{path: "../secret", offset: 0})
  end

  test "request converts native errno values back to atoms" do
    {:ok, fs} = Exfuse.start_fs(EchoFs, %{})
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert {:error, :enoent} =
             Exfuse.Fs.request(fs, :getattr, %{path: "/missing"})
  end

  test "application wrappers use the routed operation vocabulary" do
    {:ok, fs} = Exfuse.start_fs(ContractFs, self())
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert {:ok, [%Exfuse.Fs.Entry{name: "docs", type: :directory} | _]} =
             Exfuse.Fs.list(fs, "/")

    assert {:ok, %Exfuse.Fs.Stat{type: :file, size: 5, mtime: 42}} =
             Exfuse.Fs.stat(fs, "/README.md")

    assert {:ok, "/target"} = Exfuse.Fs.readlink(fs, "/shortcut")
    assert {:ok, "hello"} = Exfuse.Fs.read(fs, "/README.md")
    assert :ok = Exfuse.Fs.mkdir(fs, "/new")
    assert :ok = Exfuse.Fs.remove(fs, "/README.md")
    assert :ok = Exfuse.Fs.rename(fs, "/old", "/new")
  end

  test "write is atomic by default" do
    {:ok, fs} = Exfuse.start_fs(ContractFs, self())
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert :ok = Exfuse.Fs.write(fs, "/README.md", "new")

    assert_receive {:operation, :create, %{path: temp}}
    assert String.starts_with?(temp, "/.README.md.tmp-")
    assert_receive {:operation, :write, %{path: ^temp, data: "new", offset: 0, handle: 7}}
    assert_receive {:operation, :flush, %{path: ^temp, handle: 7}}
    assert_receive {:operation, :release, %{path: ^temp, handle: 7}}
    assert_receive {:operation, :rename, %{path: ^temp, target: "/README.md"}}
  end

  test "write can use the destination directly" do
    {:ok, fs} = Exfuse.start_fs(ContractFs, self())
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert :ok = Exfuse.Fs.write(fs, "/README.md", "new", atomic: false)

    assert_receive {:operation, :create, %{path: "/README.md"}}
    assert_receive {:operation, :write, %{path: "/README.md", data: "new"}}
    assert_receive {:operation, :release, %{path: "/README.md"}}
    refute_receive {:operation, :rename, _event}
  end

  test "failed atomic writes close and remove their temporary file" do
    {:ok, fs} = Exfuse.start_fs(ContractFs, self())
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert {:error, :eio} = Exfuse.Fs.write(fs, "/README.md", "fail")

    assert_receive {:operation, :create, %{path: temp}}
    assert_receive {:operation, :write, %{path: ^temp}}
    assert_receive {:operation, :release, %{path: ^temp}}
    assert_receive {:operation, :getattr, %{path: ^temp}}
    assert_receive {:operation, :unlink, %{path: ^temp}}
  end
end
