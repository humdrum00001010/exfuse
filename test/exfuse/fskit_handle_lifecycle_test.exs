defmodule Exfuse.FSKitHandleLifecycleTest do
  use ExUnit.Case, async: true

  if :os.type() == {:unix, :darwin} do
    test "FSKit item retains and propagates one backend handle until full close" do
      root = Path.expand("../..", __DIR__)

      executable =
        Path.join(System.tmp_dir!(), "exfuse-fskit-handle-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(executable) end)

      args = [
        "-parse-as-library",
        "-warnings-as-errors",
        "-sdk",
        sdk!(),
        "-framework",
        "FSKit",
        "-framework",
        "Foundation",
        "-framework",
        "OSLog",
        Path.join(root, "native/fskit/ExfuseItem.swift"),
        Path.join(root, "native/fskit/ExfuseWire.swift"),
        Path.join(root, "native/fskit/ExfuseVolume.swift"),
        Path.join(root, "test/native/fskit_handle_lifecycle_main.swift"),
        "-o",
        executable
      ]

      assert {compile_output, 0} = System.cmd(swiftc!(), args, stderr_to_stdout: true)
      assert compile_output == ""
      assert {run_output, 0} = System.cmd(executable, [], stderr_to_stdout: true)
      assert run_output == ""
    end
  else
    @tag :skip
    test "FSKit item retains and propagates one backend handle until full close" do
      :ok
    end
  end

  defp swiftc! do
    [
      System.get_env("EXFUSE_FSKIT_SWIFTC"),
      "/Library/Developer/CommandLineTools/usr/bin/swiftc",
      System.find_executable("swiftc")
    ]
    |> Enum.find(&(is_binary(&1) and File.exists?(&1)))
    |> then(&(&1 || raise("swiftc not found; set EXFUSE_FSKIT_SWIFTC")))
  end

  defp sdk! do
    [
      System.get_env("EXFUSE_FSKIT_SDK"),
      "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
      "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk",
      "/Library/Developer/CommandLineTools/SDKs/MacOSX26.1.sdk",
      "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    ]
    |> Enum.find(&fskit_sdk?/1)
    |> then(&(&1 || raise("macOS SDK with FSKit.framework not found; set EXFUSE_FSKIT_SDK")))
  end

  defp fskit_sdk?(path) when is_binary(path) do
    File.dir?(Path.join(path, "System/Library/Frameworks/FSKit.framework"))
  end

  defp fskit_sdk?(_path), do: false
end
