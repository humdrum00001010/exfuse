defmodule Mix.Tasks.Exfuse.Fskit.Check do
  use Mix.Task

  @shortdoc "Typechecks the macOS FSKit extension sources"

  @moduledoc """
  Typechecks the Swift FSKit extension sources against a local macOS SDK.

  This task does not build or register an app extension bundle. It is a fast API
  compatibility check for the native FSKit source layer.
  """

  @impl true
  def run(_args) do
    if :os.type() == {:unix, :darwin} do
      swiftc = swiftc!()
      sdk = sdk!()
      sources = Path.wildcard("native/fskit/*.swift")

      args =
        [
          "-parse-as-library",
          "-sdk",
          sdk,
          "-framework",
          "FSKit",
          "-framework",
          "ExtensionFoundation",
          "-framework",
          "Foundation",
          "-framework",
          "OSLog",
          "-typecheck"
        ] ++ sources

      case System.cmd(swiftc, args, stderr_to_stdout: true) do
        {output, 0} ->
          if output != "", do: Mix.shell().info(output)
          :ok

        {output, status} ->
          Mix.raise("FSKit typecheck failed with status #{status}\n#{output}")
      end
    else
      Mix.shell().info("Skipping FSKit check on non-macOS host")
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
    |> case do
      nil -> Mix.raise("swiftc not found; set EXFUSE_FSKIT_SWIFTC")
      path -> path
    end
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
    |> case do
      nil -> Mix.raise("macOS SDK with FSKit.framework not found; set EXFUSE_FSKIT_SDK")
      path -> path
    end
  end

  defp fskit_sdk?(path) when is_binary(path) do
    File.dir?(Path.join(path, "System/Library/Frameworks/FSKit.framework"))
  end

  defp fskit_sdk?(_path), do: false
end
