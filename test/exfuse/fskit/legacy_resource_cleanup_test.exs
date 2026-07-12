defmodule Exfuse.FSKit.LegacyResourceCleanupTest do
  use ExUnit.Case, async: true

  alias Exfuse.FSKit.LegacyResourceCleanup

  test "detaches and deletes legacy images when no exfuse mount is active" do
    root = tmp_dir()
    image = Path.join(root, "exfuse-123.dmg")
    File.write!(image, "legacy")
    on_exit(fn -> File.rm_rf(root) end)

    test_pid = self()

    runner = fn
      "mount", [] ->
        {"/dev/disk1s1 on / (apfs, local)\n", 0}

      "hdiutil", ["info"] ->
        {"image-path      : #{image}\n/dev/disk42\t\n", 0}

      "hdiutil", ["detach", "/dev/disk42"] ->
        send(test_pid, {:detached, "/dev/disk42"})
        {"detached", 0}
    end

    assert {:ok, %{deleted: 1, detached: 1, kept: 0, skipped: nil}} =
             LegacyResourceCleanup.cleanup(
               os_type: {:unix, :darwin},
               temp_dir: root,
               runner: runner
             )

    assert_receive {:detached, "/dev/disk42"}
    refute File.exists?(image)
  end

  test "does not touch legacy images while another process has an exfuse mount" do
    root = tmp_dir()
    image = Path.join(root, "exfuse-456.dmg")
    File.write!(image, "active")
    on_exit(fn -> File.rm_rf(root) end)

    runner = fn
      "mount", [] -> {"exfuse://127.0.0.1:35368 on /tmp/mount (exfuse, local)\n", 0}
    end

    assert {:ok, %{deleted: 0, detached: 0, kept: 0, skipped: :active_mount}} =
             LegacyResourceCleanup.cleanup(
               os_type: {:unix, :darwin},
               temp_dir: root,
               runner: runner
             )

    assert File.exists?(image)
  end

  test "keeps an attached image when detach fails" do
    root = tmp_dir()
    image = Path.join(root, "exfuse-789.dmg")
    File.write!(image, "busy")
    on_exit(fn -> File.rm_rf(root) end)

    runner = fn
      "mount", [] -> {"", 0}
      "hdiutil", ["info"] -> {"image-path : #{image}\n/dev/disk99\n", 0}
      "hdiutil", ["detach", "/dev/disk99"] -> {"busy", 1}
    end

    assert {:ok, %{deleted: 0, detached: 0, kept: 1, skipped: nil}} =
             LegacyResourceCleanup.cleanup(
               os_type: {:unix, :darwin},
               temp_dir: root,
               runner: runner
             )

    assert File.exists?(image)
  end

  test "does not delete images when attached-resource discovery fails" do
    root = tmp_dir()
    image = Path.join(root, "exfuse-987.dmg")
    File.write!(image, "unknown ownership")
    on_exit(fn -> File.rm_rf(root) end)

    runner = fn
      "mount", [] -> {"", 0}
      "hdiutil", ["info"] -> {"unavailable", 1}
    end

    assert {:ok, %{deleted: 0, detached: 0, kept: 0, skipped: :hdiutil_unavailable}} =
             LegacyResourceCleanup.cleanup(
               os_type: {:unix, :darwin},
               temp_dir: root,
               runner: runner
             )

    assert File.exists?(image)
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "exfuse-legacy-cleanup-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end
end
