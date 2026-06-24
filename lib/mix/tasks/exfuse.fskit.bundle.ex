defmodule Mix.Tasks.Exfuse.Fskit.Bundle do
  use Mix.Task

  alias Exfuse.FSKit.Signing

  @shortdoc "Builds the local macOS FSKit host app bundle"

  @moduledoc """
  Builds a local FSKit host app bundle with the embedded exfuse FSKit extension.

  The default output path is `_build/fskit/ExfuseFSKit.app`.

  By default, this task refuses ad-hoc signing because macOS kills FSKit
  extensions that carry the restricted `com.apple.developer.fskit.fsmodule`
  entitlement without a trusted code signature. Pass `--sign "Apple Development:
  Name (TEAMID)"`, set `EXFUSE_CODESIGN_IDENTITY`, or install an Apple code
  signing identity that the task can auto-select. `--allow-adhoc` is only for
  compile/package checks; that bundle will not mount through FSKit.
  """

  @impl true
  def run(args) do
    if :os.type() == {:unix, :darwin} do
      {opts, _rest, _invalid} =
        OptionParser.parse(args,
          strict: [
            output: :string,
            sign: :string,
            no_sign: :boolean,
            allow_adhoc: :boolean
          ],
          aliases: [o: :output]
        )

      root = File.cwd!()
      output = Path.expand(Keyword.get(opts, :output, "_build/fskit/ExfuseFSKit.app"), root)
      sign? = not Keyword.get(opts, :no_sign, false)
      identity = if sign?, do: identity!(opts), else: nil

      build_bundle(root, output)

      if sign? do
        sign_bundle(root, output, identity)
      end

      Mix.shell().info("Built #{output}")
    else
      Mix.raise("FSKit bundles can only be built on macOS")
    end
  end

  defp build_bundle(root, output) do
    swiftc = swiftc!()
    sdk = sdk!()
    app_macos = Path.join(output, "Contents/MacOS")
    extension_root = Path.join(output, "Contents/Extensions/ExfuseFSKitExtension.appex")
    extension_macos = Path.join(extension_root, "Contents/MacOS")

    File.rm_rf!(output)
    File.mkdir_p!(app_macos)
    File.mkdir_p!(extension_macos)

    File.cp!(
      Path.join(root, "native/fskit/host/Info.plist"),
      Path.join(output, "Contents/Info.plist")
    )

    File.cp!(
      Path.join(root, "native/fskit/Info.plist"),
      Path.join(extension_root, "Contents/Info.plist")
    )

    compile!(
      swiftc,
      sdk,
      Path.wildcard(Path.join(root, "native/fskit/host/*.swift")),
      Path.join(app_macos, "ExfuseFSKitHost"),
      ["Foundation"]
    )

    compile!(
      swiftc,
      sdk,
      Path.wildcard(Path.join(root, "native/fskit/*.swift")),
      Path.join(extension_macos, "ExfuseFSKitExtension"),
      ["FSKit", "ExtensionFoundation", "Foundation", "OSLog"]
    )
  end

  defp compile!(swiftc, sdk, sources, output, frameworks) do
    framework_args = Enum.flat_map(frameworks, &["-framework", &1])
    args = ["-parse-as-library", "-sdk", sdk] ++ framework_args ++ sources ++ ["-o", output]

    case System.cmd(swiftc, args, stderr_to_stdout: true) do
      {text, 0} ->
        if text != "", do: Mix.shell().info(text)

      {text, status} ->
        Mix.raise("swiftc failed with status #{status}\n#{text}")
    end
  end

  defp sign_bundle(root, output, identity) do
    extension = Path.join(output, "Contents/Extensions/ExfuseFSKitExtension.appex")

    codesign!(
      extension,
      identity,
      Path.join(root, "native/fskit/Entitlements.plist")
    )

    codesign!(
      output,
      identity,
      Path.join(root, "native/fskit/host/Entitlements.plist")
    )
  end

  defp codesign!(path, identity, entitlements) do
    args = ["--force", "--sign", identity, "--entitlements", entitlements, path]

    case System.cmd("codesign", args, stderr_to_stdout: true) do
      {text, 0} ->
        if text != "", do: Mix.shell().info(text)

      {text, status} ->
        Mix.raise("codesign failed with status #{status}\n#{text}")
    end
  end

  defp identity!(opts) do
    case Signing.resolve_identity(Keyword.get(opts, :sign),
           allow_adhoc: Keyword.get(opts, :allow_adhoc, false)
         ) do
      {:ok, identity} ->
        identity

      {:error, reason} ->
        Mix.raise(identity_error(reason))
    end
  end

  defp identity_error(:adhoc_not_allowed) do
    """
    FSKit bundles cannot be ad-hoc signed by default.
    Use --sign "Apple Development: Name (TEAMID)" or set EXFUSE_CODESIGN_IDENTITY.
    Pass --allow-adhoc only for non-runnable compile/package checks.
    """
  end

  defp identity_error(:no_codesign_identity) do
    """
    No valid code-signing identities were found.
    Install an Apple Development or Developer ID Application certificate in Keychain,
    or pass --allow-adhoc for a non-runnable build.
    """
  end

  defp identity_error(:no_preferred_codesign_identity) do
    """
    Valid code-signing identities exist, but none look like Apple Development,
    Mac Developer, or Developer ID Application. Pass the exact identity with --sign
    if you intend to use a different trusted signer.
    """
  end

  defp identity_error({:security_find_identity_failed, status, output}) do
    "security find-identity failed with status #{status}\n#{output}"
  end

  defp identity_error(reason), do: "could not resolve FSKit signing identity: #{inspect(reason)}"

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
