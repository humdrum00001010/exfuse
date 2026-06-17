defmodule Exfuse.Fs.Example do
  @moduledoc """
  A small example filesystem with files, directories, and symbolic links.
  """

  use Exfuse.Fs

  @dirs %{
    "/" => ["dir1", "dir2", "file1", "file2", "link1", "link2"],
    "/dir1" => ["file1"],
    "/dir2" => ["file3", "link2"]
  }

  @files %{
    "/file1" => "This is file one in the root directory.",
    "/file2" => "This is file two in the root directory.",
    "/dir1/file1" => "This is file one in directory one.",
    "/dir2/file3" => "This is file three in directory two."
  }

  @links %{
    "/link1" => "file1",
    "/link2" => "dir1/file1",
    "/dir2/link2" => "../file2"
  }

  init do
    :ready
  end

  readdir "/*" do
    reply(Map.fetch(@dirs, event.path), socket)
  end

  getattr "/*" do
    cond do
      Map.has_key?(@dirs, event.path) ->
        {:reply, dir(), socket}

      content = @files[event.path] ->
        {:reply, file(size: byte_size(content)), socket}

      target = @links[event.path] ->
        {:reply, symlink(length: byte_size(target)), socket}

      true ->
        {:error, :enoent, socket}
    end
  end

  readlink "/*" do
    reply(Map.fetch(@links, event.path), socket)
  end

  read "/*" do
    with {:ok, content} <- Map.fetch(@files, event.path) do
      {:reply, slice(content, event.offset, event.size), socket}
    else
      :error -> {:error, :enoent, socket}
    end
  end

  defp reply({:ok, value}, socket), do: {:reply, value, socket}
  defp reply(:error, socket), do: {:error, :enoent, socket}

  defp slice(content, offset, size) do
    start = min(offset, byte_size(content))
    count = min(size, byte_size(content) - start)
    binary_part(content, start, count)
  end
end
