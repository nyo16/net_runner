defmodule NetRunner.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/nyo16/net_runner"

  def project do
    [
      app: :net_runner,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      description: description(),
      package: package(),
      docs: docs(),
      name: "NetRunner",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {NetRunner.Application, []}
    ]
  end

  defp deps do
    [
      # Production dependencies
      {:elixir_make, "~> 0.9", runtime: false},

      # Development dependencies
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Safe OS process execution for Elixir with NIF-based backpressure, zero zombie processes, PTY support, and cgroup isolation."
  end

  defp package do
    [
      name: "net_runner",
      files:
        ~w(lib c_src/*.c c_src/*.h docs priv/.gitkeep Makefile mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      maintainers: ["Niko"]
    ]
  end

  defp docs do
    [
      main: "NetRunner",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "docs/architecture.md",
        "docs/protocol.md",
        "docs/decisions.md",
        "docs/backpressure.md",
        "docs/comparison.md",
        "docs/modules.md"
      ],
      groups_for_modules: [
        "Public API": [NetRunner, NetRunner.Process, NetRunner.Stream, NetRunner.Daemon],
        Internals: [
          NetRunner.Process.Exec,
          NetRunner.Process.Nif,
          NetRunner.Process.Pipe,
          NetRunner.Process.State,
          NetRunner.Process.Operations,
          NetRunner.Process.Stats,
          NetRunner.Signal,
          NetRunner.Watcher
        ]
      ]
    ]
  end
end
