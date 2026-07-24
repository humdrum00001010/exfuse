defmodule Exfuse.FsRealTest do
  use ExUnit.Case, async: false

  test "satisfies the filesystem operation contract" do
    Exfuse.Test.FsContract.run(fn label ->
      root = Path.join(System.tmp_dir!(), "exfuse-real-#{label}")
      File.mkdir_p!(root)
      {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Real, root: root)

      {:ok, fs,
       fn ->
         Exfuse.stop_fs(fs)
         File.rm_rf!(root)
       end}
    end)
  end

  test "represents a leaf symlink but rejects traversal through it" do
    root = tmp_root()
    outside = tmp_root()
    File.write!(Path.join(outside, "secret"), "secret")
    File.ln_s!(outside, Path.join(root, "linked"))

    {:ok, fs} =
      Exfuse.start_fs(Exfuse.Fs.Real,
        root: root,
        exclude: [".ecrits"]
      )

    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert {:ok, %Exfuse.Fs.Stat{type: :symlink}} =
             Exfuse.Fs.stat(fs, "/linked")

    assert {:ok, ^outside} = Exfuse.Fs.readlink(fs, "/linked")
    assert {:error, :eacces} = Exfuse.Fs.read(fs, "/linked/secret")

    File.mkdir_p!(Path.join(root, ".ecrits"))
    assert {:error, :enoent} = Exfuse.Fs.list(fs, "/.ecrits")

    assert {:ok, entries} = Exfuse.Fs.list(fs, "/")
    refute Enum.any?(entries, &(&1.name == ".ecrits"))
  end

  test "creates a missing real root" do
    root = Path.join(tmp_root(), "nested/workspace")
    refute File.exists?(root)

    assert {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Real, root: root)
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    assert File.dir?(root)
    assert {:ok, []} = Exfuse.Fs.list(fs)
  end

  test "application reads and atomic writes do not enter file_server_2" do
    root = tmp_root()
    File.write!(Path.join(root, "document.hwp"), "before")

    {:ok, fs} = Exfuse.start_fs(Exfuse.Fs.Real, root: root)
    on_exit(fn -> Exfuse.stop_fs(fs) end)

    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)

    try do
      task =
        Task.async(fn ->
          with {:ok, "before"} <- Exfuse.Fs.read(fs, "/document.hwp"),
               :ok <- Exfuse.Fs.write(fs, "/document.hwp", "after"),
               {:ok, "after"} <- Exfuse.Fs.read(fs, "/document.hwp") do
            :ok
          end
        end)

      assert :ok = Task.await(task, 1_000)
    after
      :ok = :sys.resume(file_server)
    end

    assert File.read!(Path.join(root, "document.hwp")) == "after"
  end

  test "native engine bridge does not enter file_server_2" do
    root = tmp_root()
    path = Path.join(root, "document.hwp")
    File.write!(path, "before")

    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)

    try do
      task =
        Task.async(fn ->
          with {:ok, "before"} <- Exfuse.Fs.Real.read_native(path),
               :ok <- Exfuse.Fs.Real.atomic_write_native(path, "after"),
               {:ok, "after"} <- Exfuse.Fs.Real.read_native(path) do
            :ok
          end
        end)

      assert :ok = Task.await(task, 1_000)
    after
      :ok = :sys.resume(file_server)
    end

    assert File.read!(path) == "after"
  end

  defp tmp_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "exfuse-real-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
