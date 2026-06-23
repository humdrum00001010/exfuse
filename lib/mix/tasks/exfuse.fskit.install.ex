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
  """

  @extension_id "org.exfuse.fskit.extension"
  @extension_relative_path "Contents/Extensions/ExfuseFSKitExtension.appex"

  @impl true
  def run(args) do
    if :os.type() == {:unix, :darwin} do
      {opts, _rest, _invalid} =
        OptionParser.parse(args,
          strict: [source: :string, destination: :string],
          aliases: [s: :source, d: :destination]
        )

      root = File.cwd!()
      source = Path.expand(Keyword.get(opts, :source, "_build/fskit/ExfuseFSKit.app"), root)
      destination = Keyword.get(opts, :destination, "/Applications/ExfuseFSKit.app")

      install(source, destination)
    else
      Mix.raise("FSKit install can only run on macOS")
    end
  end

  defp install(source, destination) do
    unless File.dir?(source) do
      Mix.raise("FSKit bundle not found at #{source}; run mix exfuse.fskit.bundle first")
    end

    source_extension = Path.join(source, @extension_relative_path)
    destination_extension = Path.join(destination, @extension_relative_path)

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
