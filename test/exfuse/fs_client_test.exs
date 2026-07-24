defmodule Exfuse.FsClientTest do
  use ExUnit.Case, async: true

  defmodule EchoFs do
    use Exfuse.Fs

    read "/*path" do
      {:reply, %{path: "/" <> Enum.join(path, "/"), offset: event.offset}, socket}
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
end
