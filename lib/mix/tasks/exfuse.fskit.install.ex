defmodule Mix.Tasks.Exfuse.Fskit.Install do
  use Mix.Task

  @shortdoc "Installs and registers the local macOS FSKit host app"

  @moduledoc """
  Installs the locally built FSKit host app into `/Applications`, registers the
  embedded FSKit extension, and elects it with PlugInKit.

  This task cannot complete the macOS approval step. After it runs, enable the
  extension in:

      System Settings > General > Login Items & Extensions > File System Extensions

  The default source path is `_build/fskit/ExfuseFSKit.app`.

  Pass `--build` to build and sign the bundle through Xcode before installing:

      mix exfuse.fskit.install --build --team TEAMID

  The team can also be set with `DEVELOPMENT_TEAM`. Xcode selects the signing
  identity and provisioning profile from the configured developer account.
  """

  @extension_id "org.exfuse.fskit.extension"
  @extension_relative_path "Contents/Extensions/ExfuseFSKitExtension.appex"

  @impl true
  def run(args) do
    if :os.type() == {:unix, :darwin} do
      {opts, _rest, invalid} =
        OptionParser.parse(args,
          strict: [
            source: :string,
            destination: :string,
            build: :boolean,
            team: :string
          ],
          aliases: [s: :source, d: :destination]
        )

      if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

      root = File.cwd!()
      source = Path.expand(Keyword.get(opts, :source, "_build/fskit/ExfuseFSKit.app"), root)
      destination = Keyword.get(opts, :destination, "/Applications/ExfuseFSKit.app")

      if Keyword.get(opts, :build, false), do: build(source, opts)
      install(source, destination)
    else
      Mix.raise("FSKit install can only run on macOS")
    end
  end

  defp build(source, opts) do
    args =
      ["--output", source]
      |> maybe_put_option("--team", Keyword.get(opts, :team))

    Mix.Task.reenable("exfuse.fskit.bundle")
    Mix.Task.run("exfuse.fskit.bundle", args)
  end

  defp install(source, destination) do
    unless File.dir?(source) do
      Mix.raise("FSKit bundle not found at #{source}; run mix exfuse.fskit.bundle first")
    end

    source_extension = Path.join(source, @extension_relative_path)
    destination_extension = Path.join(destination, @extension_relative_path)

    verify_signature!(source)
    verify_extension_profile!(source_extension)

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

  defp verify_extension_profile!(source_extension) do
    profile = Path.join(source_extension, "Contents/embedded.provisionprofile")

    unless File.exists?(profile) do
      Mix.raise("""
      FSKit extension has no embedded.provisionprofile; AMFI will kill it at launch
      because the FSKit entitlement is restricted. Rebuild with --build --team TEAMID.
      """)
    end

    :ok
  end

  defp verify_signature!(source) do
    case System.cmd("codesign", ["--verify", "--deep", "--strict", source],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Mix.raise("codesign verification failed with status #{status}\n#{output}")
    end
  end

  defp maybe_put_option(args, _name, nil), do: args
  defp maybe_put_option(args, name, value), do: args ++ [name, value]

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
