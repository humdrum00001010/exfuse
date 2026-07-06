defmodule Mix.Tasks.Exfuse.Fskit.Install do
  use Mix.Task

  alias Exfuse.FSKit.Signing

  @shortdoc "Installs and registers the local macOS FSKit host app"

  @moduledoc """
  Installs the locally built FSKit host app into `/Applications`, registers the
  embedded FSKit extension, and elects it with PlugInKit.

  This task cannot complete the macOS approval step. After it runs, enable the
  extension in:

      System Settings > General > Login Items & Extensions > File System Extensions

  The default source path is `_build/fskit/ExfuseFSKit.app`.

  Pass `--build` to build/sign the bundle before installing:

      mix exfuse.fskit.install --build --sign "Apple Development: Name (TEAMID)"

  If `--sign` is omitted, the build step uses `EXFUSE_CODESIGN_IDENTITY` or
  auto-selects an Apple Development, Mac Developer, or Developer ID Application
  identity from the login keychain. Ad-hoc bundles are rejected by default
  because macOS will not launch an FSKit extension with the restricted FSKit
  entitlement under an ad-hoc signature.
  """

  @extension_id "org.exfuse.fskit.extension"
  @extension_relative_path "Contents/Extensions/ExfuseFSKitExtension.appex"

  @impl true
  def run(args) do
    if :os.type() == {:unix, :darwin} do
      {opts, _rest, _invalid} =
        OptionParser.parse(args,
          strict: [
            source: :string,
            destination: :string,
            build: :boolean,
            sign: :string,
            no_sign: :boolean,
            allow_adhoc: :boolean
          ],
          aliases: [s: :source, d: :destination]
        )

      root = File.cwd!()
      source = Path.expand(Keyword.get(opts, :source, "_build/fskit/ExfuseFSKit.app"), root)
      destination = Keyword.get(opts, :destination, "/Applications/ExfuseFSKit.app")

      if Keyword.get(opts, :build, false), do: build(source, opts)
      install(source, destination, opts)
    else
      Mix.raise("FSKit install can only run on macOS")
    end
  end

  defp build(source, opts) do
    args =
      ["--output", source]
      |> maybe_put_option("--sign", Keyword.get(opts, :sign))
      |> maybe_put_flag("--no-sign", Keyword.get(opts, :no_sign, false))
      |> maybe_put_flag("--allow-adhoc", Keyword.get(opts, :allow_adhoc, false))

    Mix.Task.reenable("exfuse.fskit.bundle")
    Mix.Task.run("exfuse.fskit.bundle", args)
  end

  defp install(source, destination, opts) do
    unless File.dir?(source) do
      Mix.raise("FSKit bundle not found at #{source}; run mix exfuse.fskit.bundle first")
    end

    source_extension = Path.join(source, @extension_relative_path)
    destination_extension = Path.join(destination, @extension_relative_path)

    verify_extension_signature!(source_extension, opts)

    maybe_run("pluginkit", ["-r", source_extension])
    maybe_run("pluginkit", ["-r", destination_extension])

    File.rm_rf!(destination)
    run!("ditto", [source, destination])
    maybe_run("xattr", ["-dr", "com.apple.quarantine", destination])
    run!(lsregister!(), ["-f", "-R", destination])
    run!("pluginkit", ["-a", destination_extension])
    run!("pluginkit", ["-e", "use", "-p", "com.apple.fskit.fsmodule", "-i", @extension_id])

    Mix.shell().info("Installed #{destination}")
    Mix.shell().info("Registered FSKit extension #{@extension_id}")
    Mix.shell().info("")

    Mix.shell().info(
      "Enable it in System Settings > General > Login Items & Extensions > File System Extensions."
    )

    Mix.shell().info(
      "Until that toggle is enabled, mount will fail with: Module #{@extension_id} is disabled!"
    )
  end

  defp verify_extension_signature!(source_extension, opts) do
    if Keyword.get(opts, :allow_adhoc, false) do
      :ok
    else
      do_verify_extension_signature!(source_extension)
      verify_extension_profile!(source_extension)
    end
  end

  defp verify_extension_profile!(source_extension) do
    profile = Path.join(source_extension, "Contents/embedded.provisionprofile")

    unless File.exists?(profile) do
      Mix.raise("""
      FSKit extension has no embedded.provisionprofile; AMFI will kill it at launch
      because the FSKit entitlement is restricted. Rebuild with --build (the bundle
      task embeds a matching profile) after minting one with mix exfuse.fskit.provision.
      """)
    end

    :ok
  end

  defp do_verify_extension_signature!(source_extension) do
    case Signing.signature(source_extension) do
      {:ok, :signed} ->
        :ok

      {:ok, :adhoc} ->
        Mix.raise("""
        FSKit extension is ad-hoc signed and macOS will reject its restricted entitlement.
        Rebuild with --build --sign "Apple Development: Name (TEAMID)" or set
        EXFUSE_CODESIGN_IDENTITY. Pass --allow-adhoc only for non-runnable local checks.
        """)

      {:error, {status, output}} ->
        Mix.raise("codesign verification failed with status #{status}\n#{output}")

      {:error, reason} ->
        Mix.raise("codesign verification failed: #{inspect(reason)}")
    end
  end

  defp maybe_put_option(args, _name, nil), do: args
  defp maybe_put_option(args, name, value), do: args ++ [name, value]

  defp maybe_put_flag(args, name, true), do: args ++ [name]
  defp maybe_put_flag(args, _name, false), do: args

  defp run!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} ->
        if output != "", do: Mix.shell().info(String.trim_trailing(output))

      {output, status} ->
        Mix.raise("#{command} failed with status #{status}\n#{output}")
    end
  end

  defp maybe_run(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> :ok
    end
  end

  defp lsregister! do
    path =
      "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    if File.exists?(path), do: path, else: Mix.raise("lsregister not found at #{path}")
  end
end
