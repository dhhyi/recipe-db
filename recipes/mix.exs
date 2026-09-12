defmodule Recipes.MixProject do
  use Mix.Project

  def project do
    [
      app: :recipes,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Recipes.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:exqlite, "~> 0.40"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.18"},
      {:uniq, "~> 0.6"}
    ]
  end
end
