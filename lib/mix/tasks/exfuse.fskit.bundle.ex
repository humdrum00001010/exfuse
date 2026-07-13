defmodule Mix.Tasks.Exfuse.Fskit.Bundle do
  use Mix.Task

  @shortdoc "Builds the macOS FSKit app with Xcode"

  @moduledoc """
  Builds the FSKit host app and embedded extension through Xcode.

  Xcode owns provisioning and signing. Pass the Apple development team with
  `--team TEAMID` or `DEVELOPMENT_TEAM`:

      mix exfuse.fskit.bundle --team TEAMID

  Use `--no-sign` only for compile and package checks.
  """

  @impl true
  def run(args) do
    unless :os.type() == {:unix, :darwin} do
      Mix.raise("FSKit bundles can only be built on macOS")
    end

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [output: :string, team: :string, no_sign: :boolean],
        aliases: [o: :output]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    build_root = File.cwd!()

    output =
      Path.expand(Keyword.get(opts, :output, "_build/fskit/ExfuseFSKit.app"), build_root)

    no_sign? = Keyword.get(opts, :no_sign, false)
    team = Keyword.get(opts, :team) || System.get_env("DEVELOPMENT_TEAM")

    if not no_sign? and team in [nil, ""] do
      Mix.raise("pass --team TEAMID or set DEVELOPMENT_TEAM")
    end

    build(source_root!(), build_root, output, team, no_sign?)
    Mix.shell().info("Built #{output}")
  end

  defp build(source_root, build_root, output, team, no_sign?) do
    symroot = Path.join(build_root, "_build/fskit/xcode")
    project = Path.join(source_root, "native/fskit/xcode/ExfuseFSKitExtension.xcodeproj")

    args = [
      "-quiet",
      "-project",
      project,
      "-target",
      "ExfuseFSKitHost",
      "-configuration",
      "Release",
      "clean",
      "build",
      "SYMROOT=#{symroot}"
    ]

    args =
      if no_sign? do
        args ++ ["CODE_SIGNING_ALLOWED=NO"]
      else
        args ++ ["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=#{team}"]
      end

    run_xcodebuild!(args)

    built = Path.join(symroot, "Release/ExfuseFSKit.app")
    unless File.dir?(built), do: Mix.raise("xcodebuild produced no app at #{built}")

    File.rm_rf!(output)
    run!("ditto", [built, output])
  end

  defp source_root! do
    if Mix.Project.config()[:app] == :exfuse do
      File.cwd!()
    else
      Mix.Project.deps_paths()
      |> Map.fetch!(:exfuse)
      |> Path.expand()
    end
  end

  defp run_xcodebuild!(args) do
    case System.cmd("xcodebuild", args, stderr_to_stdout: true) do
      {output, 0} ->
        if output != "", do: Mix.shell().info(String.trim_trailing(output))

      {output, status} ->
        Mix.raise("xcodebuild failed with status #{status}\n#{output}")
    end
  rescue
    error in ErlangError -> Mix.raise("could not run xcodebuild: #{Exception.message(error)}")
  end

  defp run!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> Mix.raise("#{command} failed with status #{status}\n#{output}")
    end
  end
end
