defmodule Exfuse.FsTest do
  use ExUnit.Case

  @moduletag :examplefs
  @moduletag :fuse

  # not part of the app as such, these tests are not to test correct working of
  # these examples, just to check they don't crash or have any obvious problems

  describe "Exfuse.Fs" do
    test "Hello does not crash" do
      mp = tmp_mount("hello")
      fs_mod = Exfuse.Fs.Hello
      mount(mp, fs_mod)
      recursive_scans(mp)
      noent_checks(mp)
      umount(mp)
    end

    test "Example does not crash" do
      mp = tmp_mount("example")
      fs_mod = Exfuse.Fs.Example
      mount(mp, fs_mod)
      recursive_scans(mp)
      noent_checks(mp)
      umount(mp)
    end

    test "Elixir does not crash" do
      mp = tmp_mount("elixir")
      fs_mod = Exfuse.Fs.Elixir
      mount(mp, fs_mod)
      recursive_scans(mp)
      noent_checks(mp)
      umount(mp)
    end
  end

  defp mount(mp, fs_mod) do
    System.cmd("mkdir", ["-p", mp])
    {:ok, _pid} = Exfuse.mount(mp, fs_mod, nil)
    Process.sleep(200)
  end

  defp recursive_scans(mp) do
    {_out, 0} = System.cmd("find", [mp, "-exec", "ls", "-lad", "{}", ";"], stderr_to_stdout: true)
    {out, 0} = System.cmd("find", [mp, "-type", "f"], stderr_to_stdout: true)
    files = String.split(out, "\n")

    Enum.map(
      files,
      fn file ->
        File.read(file)
        :ok
      end
    )
  end

  defp noent_checks(mp) do
    {:error, :enoent} = File.stat(mp <> "/not_found")
    {:error, :enoent} = File.read_link(mp <> "/not_found")
    {:error, :enoent} = File.ls(mp <> "/not_found")
    {:error, :enoent} = File.read(mp <> "/not_found")
  end

  defp umount(mp) do
    Exfuse.umount(mp)
    System.cmd("rmdir", [mp])
  end

  defp tmp_mount(prefix) do
    Path.join(
      "/tmp/exfuse-runs",
      "exfuse-#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end
end
