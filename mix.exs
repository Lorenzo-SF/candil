defmodule Candil.MixProject do
  use Mix.Project

  def project do
    [
      app: :candil,
      version: "2.0.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Candil",
      description: "LLM inference and model management for Elixir.",
      source_url: "https://github.com/Lorenzo-SF/candil",
      homepage_url: "https://github.com/Lorenzo-SF/candil",
      package: [
        name: :candil,
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/Lorenzo-SF/candil"},
        maintainers: ["Lorenzo Sánchez"]
      ],
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: dialyzer_config()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Candil.Application, []}
    ]
  end

  defp deps do
    [
      {:apero, github: "Lorenzo-SF/apero", branch: "main"},
      {:arrea, github: "Lorenzo-SF/arrea", branch: "main"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 1.0.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/Lorenzo-SF/candil",
      homepage_url: "https://github.com/Lorenzo-SF/candil",
      source_ref: "2.0.0",
      extras: ["README.md", "LICENSE.md"],
      groups_for_modules: [
        Core: [Candil, Candil.Llm, Candil.Error, Candil.Cost],
        Config: [Candil.Config, Candil.ConfigManager, Candil.Model, Candil.Provider],
        Diagnostics: [Candil.Health, Candil.Embeddings],
        Conversation: [Candil.Conversation],
        Inference: [Candil.Inference, Candil.RequestBuilder, Candil.Stream, Candil.HTTP],
        Engine: [Candil.Engine, Candil.Engine.Server, Candil.Detector, Candil.Installer]
      ]
    ]
  end

  defp dialyzer_config do
    [
      plt_file: {:no_warn, "priv/plts/candil"},
      plt_core_path: "priv/plts/core",
      plt_add_apps: [:mix],
      flags: [:error_handling, :no_opaque, :no_underspecs]
    ]
  end
end
