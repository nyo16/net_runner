defmodule NetRunner.MixProject do
  use Mix.Project

  @version "1.7.0"
  @source_url "https://github.com/nyo16/net_runner"

  def project do
    [
      app: :net_runner,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      description: description(),
      package: package(),
      docs: docs(),
      name: "NetRunner",
      source_url: @source_url,
      # The NIF stubs only raise until the library loads, and TestHelpers is
      # test scaffolding; neither says anything about library coverage.
      test_coverage: [
        summary: [threshold: 80],
        ignore_modules: [NetRunner.Nif, NetRunner.TestHelpers]
      ],
      # test/support is compiled in :test (where dialyzer runs in CI) and
      # calls ExUnit.Assertions.flunk/1; ExUnit is not in the default PLT.
      # PLTs live in plts/ so CI can cache them on their own key; not under
      # priv/, which Mix would link into the app path.
      dialyzer: [plt_add_apps: [:ex_unit], plt_core_path: "plts", plt_local_path: "plts"]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {NetRunner.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Production dependencies
      {:elixir_make, "~> 0.9", runtime: false},

      # Development dependencies
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp description do
    "Safe OS process execution for Elixir with NIF-based backpressure, zero zombie processes, PTY support, and cgroup isolation."
  end

  defp package do
    [
      name: "net_runner",
      # docs/ is listed file by file: it also holds working notes that are
      # not part of the published documentation.
      files: ~w(
        lib c_src/*.c c_src/*.h Makefile mix.exs README.md CHANGELOG.md LICENSE
        docs/architecture.md docs/protocol.md docs/decisions.md
        docs/backpressure.md docs/comparison.md docs/modules.md
      ),
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
      # These are all @moduledoc false, so every reference to them from an
      # extra resolves to a hidden entry and warns. The docs cite them by name
      # deliberately — they are the framing contract, the writer convention and
      # the read-size source of truth respectively — so suppress the autolink
      # rather than the prose or the modules' internal status.
      skip_code_autolink_to: [
        "NetRunner.Process.Protocol.parse_uds_message/1",
        "NetRunner.InputWriter",
        "NetRunner.Process.Pipe.read/2"
      ],
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
        "Public API": [
          NetRunner,
          NetRunner.Command,
          NetRunner.Process,
          NetRunner.Stream,
          NetRunner.Daemon,
          NetRunner.Error,
          # Public type (returned by Process.stats/1); its mutators are @doc false.
          NetRunner.Process.Stats
        ],
        Internals: [
          NetRunner.Process.Exec,
          NetRunner.Process.Options,
          NetRunner.Process.Protocol,
          NetRunner.Process.Cgroup,
          NetRunner.Process.Pipe,
          NetRunner.Process.State,
          NetRunner.Process.Operations,
          NetRunner.Signal,
          NetRunner.Watcher
        ]
      ]
    ]
  end
end
