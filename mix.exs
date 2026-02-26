defmodule NetRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :net_runner,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"]
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
      {:elixir_make, "~> 0.9", runtime: false}
    ]
  end
end
