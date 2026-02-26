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
      # Hex
      description: description(),
      package: package(),
      # Docs
      name: "NetRunner",
      docs: docs(),
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
      {:elixir_make, "~> 0.9", runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Safe OS process execution for Elixir. Zero zombie processes, NIF-based backpressure, PTY support, cgroup isolation."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib c_src/*.c c_src/*.h priv/.gitkeep Makefile mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "NetRunner",
      extras: [
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
