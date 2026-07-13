defmodule Exfuse.FsDslTest do
  use ExUnit.Case, async: false

  alias Exfuse.{File, Socket}

  defmodule RoutedFs do
    use Exfuse.Fs

    init do
      opts
    end

    readdir "/" do
      {:reply, [{"docs", attr(type: :dir)}, {"README", attr(type: :file, size: 6)}], socket}
    end

    getattr "/docs/:name" do
      {:reply, attr(type: :file, size: byte_size(name)), socket}
    end

    read "/tree/*path" do
      {:reply, Enum.join(path, "/"), socket}
    end
  end

  defmodule PlugFile do
    @behaviour Exfuse.Fs

    def exfuse_init(owner) do
      send(owner, {:plug_init, self()})
      {:ok, %{owner: owner, file: self()}}
    end

    def handle_event(:read, %{params: %{name: name}}, socket) do
      send(socket.state.owner, {:plug_read, socket.state.file, name})
      {:reply, name, socket}
    end

    def handle_event(_operation, _event, socket), do: {:error, :enoent, socket}
  end

  defmodule PlugFs do
    use Exfuse.Fs
    plug("/items/:name", Exfuse.FsDslTest.PlugFile)
  end

  test "attr/1 is the single public attribute constructor" do
    assert Exfuse.Fs.attr(type: :dir) == {0o0755, 1, 0}
    assert Exfuse.Fs.attr(type: :file, size: 1_024, mtime: 42) == {0o0644, 2, 1_024, 42}
    assert Exfuse.Fs.attr(type: :symlink, size: 8) == {0o0755, 3, 8}
  end

  test "routes normalize mandatory rich readdir entries" do
    {:ok, state} = RoutedFs.exfuse_init(:state)
    socket = Socket.new(%{}, state)

    assert {:reply, [{"docs", {0o0755, 1, 0}}, {"README", {0o0644, 2, 6}}], ^socket} =
             RoutedFs.handle_event(:readdir, %{path: "/"}, socket)

    assert {:reply, {0o0644, 2, 6}, ^socket} =
             RoutedFs.handle_event(:getattr, %{path: "/docs/report"}, socket)

    assert {:reply, "a/b", ^socket} =
             RoutedFs.handle_event(:read, %{path: "/tree/a/b"}, socket)
  end

  test "one File process serves every parameter value of a plug declaration" do
    {:ok, fs} = Exfuse.start_fs(PlugFs, self())
    {:ok, root} = Exfuse.Fs.Supervisor.root(fs)

    assert {:reply, "a", _socket} = File.dispatch(root, :read, %{path: "/items/a"})
    assert_receive {:plug_init, plug}
    assert_receive {:plug_read, ^plug, "a"}

    assert {:reply, "b", _socket} = File.dispatch(root, :read, %{path: "/items/b"})
    assert_receive {:plug_read, ^plug, "b"}
    refute_receive {:plug_init, _other}, 25

    assert %{files: files} = Exfuse.Fs.Supervisor.status(fs)
    assert length(files) == 2
    Exfuse.stop_fs(fs)
  end
end
