defmodule Exfuse.FsPathTest do
  use ExUnit.Case, async: true

  alias Exfuse.Fs.Path

  test "canonicalizes root-relative slash paths" do
    assert Path.canonical("/") == {:ok, "/"}
    assert Path.canonical("docs/a.md") == {:ok, "/docs/a.md"}
    assert Path.canonical("/docs//a.md") == {:ok, "/docs/a.md"}
    assert Path.canonical("/docs/./a.md") == {:ok, "/docs/a.md"}
  end

  test "rejects traversal and invalid bytes" do
    assert Path.canonical("../secret") == {:error, :path_traversal}
    assert Path.canonical("/docs/../../secret") == {:error, :path_traversal}
    assert Path.canonical("bad\0name") == {:error, :invalid_path}
    assert Path.canonical(42) == {:error, :invalid_path}
  end
end
