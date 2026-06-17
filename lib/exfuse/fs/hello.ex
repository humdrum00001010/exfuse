defmodule Exfuse.Fs.Hello do
  @moduledoc """
  A simple hello-world filesystem.
  """

  use Exfuse.Fs

  @hello "Hello world!\n"

  init do
    :ready
  end

  readdir "/" do
    {:reply, ["hello", "world"], socket}
  end

  getattr "/" do
    {:reply, dir(), socket}
  end

  getattr "/hello" do
    {:reply, file(size: byte_size(@hello)), socket}
  end

  getattr "/world" do
    {:reply, symlink(length: byte_size("hello")), socket}
  end

  readlink "/world" do
    {:reply, "hello", socket}
  end

  read "/hello" do
    {:reply, slice(@hello, event.offset, event.size), socket}
  end

  defp slice(content, offset, size) do
    start = min(offset, byte_size(content))
    count = min(size, byte_size(content) - start)
    binary_part(content, start, count)
  end
end
