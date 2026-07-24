defmodule Exfuse.FsSharedTest do
  use ExUnit.Case, async: false

  test "ensure_fs returns one filesystem and watcher for a canonical key" do
    root = tmp_root()

    assert {:ok, first} =
             Exfuse.ensure_fs(
               Exfuse.Fs.Real,
               [root: root],
               key: {:real, root}
             )

    on_exit(fn -> Exfuse.stop_fs(first) end)

    assert {:ok, second} =
             Exfuse.ensure_fs(
               Exfuse.Fs.Real,
               [root: root],
               key: {:real, root}
             )

    assert first == second

    status = Exfuse.Fs.Supervisor.status(first)
    assert is_pid(status.watcher)
  end

  test "concurrent ensure_fs callers converge on one filesystem" do
    root = tmp_root()
    key = {:concurrent_real, root}

    filesystems =
      1..8
      |> Task.async_stream(
        fn _index ->
          Exfuse.ensure_fs(Exfuse.Fs.Real, [root: root], key: key)
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, fs}} -> fs end)
      |> Enum.uniq()

    assert [fs] = filesystems
    on_exit(fn -> Exfuse.stop_fs(fs) end)
  end

  defp tmp_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "exfuse-shared-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
