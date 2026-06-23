defmodule Exfuse.MixProject do
  use Mix.Project

  def project do
    [
      app: :exfuse,
      version: "0.1.0",
      elixir: "~> 1.20.1",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      source_url: source_url(),
      homepage_url: source_url(),
      docs: docs(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      compilers: [:exfuse_rust] ++ Mix.compilers(),
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  def application do
    [
      mod: {Exfuse.App, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Elixir filesystem routing over native user-space filesystem backends"
  end

  defp source_url do
    "https://github.com/humdrum00001010/exfuse"
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_url: source_url()
    ]
  end

  defp package() do
    [
      name: "exfuse",
      files: [
        "config",
        "CHANGELOG.md",
        "LICENSE",
        "lib",
        "mix.exs",
        "native/fskit",
        "README.md",
        "rust/Cargo.lock",
        "rust/Cargo.toml",
        "rust/build.rs",
        "rust/src",
        "rust-toolchain.toml"
      ],
      maintainers: [
        "humdrum00001010"
      ],
      licenses: ["MIT"],
      build_tools: ["mix"],
      links: %{
        "Source" => source_url(),
        "GitHub" => source_url()
      }
    ]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end
end

defmodule Mix.Tasks.Compile.ExfuseRust do
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    cargo = System.find_executable("cargo") || Mix.raise("cargo not found")
    root = File.cwd!()
    manifest = Path.join(root, "rust/Cargo.toml")
    release? = Mix.env() == :prod
    profile = if release?, do: "release", else: "debug"
    args = ["build", "--manifest-path", manifest] ++ if(release?, do: ["--release"], else: [])

    case System.cmd(cargo, args, stderr_to_stdout: true) do
      {output, 0} ->
        if output != "", do: Mix.shell().info(output)
        copy_binary(root, profile)
        {:ok, []}

      {output, status} ->
        Mix.raise("cargo build failed with status #{status}\n#{output}")
    end
  end

  @impl true
  def clean do
    root = File.cwd!()
    File.rm(Path.join(root, "priv/exfuse_port"))

    if cargo = System.find_executable("cargo") do
      System.cmd(cargo, ["clean", "--manifest-path", Path.join(root, "rust/Cargo.toml")],
        stderr_to_stdout: true
      )
    end

    :ok
  end

  defp copy_binary(root, profile) do
    source = Path.join([root, "rust/target", profile, "exfuse_port"])
    target = Path.join(root, "priv/exfuse_port")

    File.mkdir_p!(Path.dirname(target))
    File.cp!(source, target)
    File.chmod!(target, 0o755)
  end
end
