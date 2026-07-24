defmodule Exfuse.FsMemoryTest do
  use ExUnit.Case, async: false

  test "satisfies the filesystem operation contract" do
    Exfuse.Test.FsContract.run(fn _root ->
      {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Memory, files: %{})
      {:ok, fs, fn -> Exfuse.stop_fs(fs) end}
    end)
  end

  test "represents symlinks without following them" do
    {:ok, fs} =
      Exfuse.start_fs(
        Exfuse.Fs.Memory,
        files: %{"/target" => "body"},
        symlinks: %{"/shortcut" => "/target"}
      )

    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert {:ok, %Exfuse.Fs.Stat{type: :symlink}} =
             Exfuse.Fs.stat(fs, "/shortcut")

    assert {:ok, "/target"} = Exfuse.Fs.readlink(fs, "/shortcut")
    assert {:error, :einval} = Exfuse.Fs.read(fs, "/shortcut")
    assert :ok = Exfuse.Fs.remove(fs, "/shortcut")
    assert {:error, :enoent} = Exfuse.Fs.stat(fs, "/shortcut")
  end
end
