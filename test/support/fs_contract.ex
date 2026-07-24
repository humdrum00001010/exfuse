defmodule Exfuse.Test.FsContract do
  import ExUnit.Assertions

  def run(start_fs) when is_function(start_fs, 1) do
    root = "contract-#{System.unique_integer([:positive])}"
    {:ok, fs, cleanup} = start_fs.(root)

    try do
      assert {:ok, []} = Exfuse.Fs.list(fs, "/")
      assert :ok = Exfuse.Fs.mkdir(fs, "/docs")
      assert :ok = Exfuse.Fs.write(fs, "/docs/a.md", "hello")
      assert {:ok, "hello"} = Exfuse.Fs.read(fs, "/docs/a.md")
      assert :ok = Exfuse.Fs.write(fs, "/docs/a.md", "updated")
      assert {:ok, "updated"} = Exfuse.Fs.read(fs, "/docs/a.md")

      assert {:ok, [%Exfuse.Fs.Entry{name: "a.md", type: :file, size: 7}]} =
               Exfuse.Fs.list(fs, "/docs")

      assert :ok = Exfuse.Fs.rename(fs, "/docs/a.md", "/docs/b.md")
      assert {:error, :enoent} = Exfuse.Fs.read(fs, "/docs/a.md")
      assert {:ok, "updated"} = Exfuse.Fs.read(fs, "/docs/b.md")
      assert :ok = Exfuse.Fs.remove(fs, "/docs/b.md")
      assert :ok = Exfuse.Fs.remove(fs, "/docs")
      assert {:ok, []} = Exfuse.Fs.list(fs, "/")
    after
      cleanup.()
    end
  end
end
