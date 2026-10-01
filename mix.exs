defmodule Candil.MixProject do
  use Mix.Project

  def project do
    [
      app: :candil,
      version: "3.0.0",
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
      # ── Sibling deps, straight from GitHub, always tracking main @ HEAD ──
      # No version bumps to track, no publish ordering between packages.
      #
      # The explicit `branch: "main"` is deliberate: without it a dep silently
      # follows whatever the remote HEAD is, and a branch rename or a
      # default-branch change breaks the build in a way that looks unrelated.
      #
      # `override: true` is required, not decorative. arrea, trebejo and alaja
      # all declare each other without a `branch:`, so Mix sees
      # `github: ".../apero", branch: "main"` and `github: ".../apero"` as two
      # different deps and aborts with "is overriding a child dependency".
      # Ours is the authoritative declaration — we pin the branch, they don't —
      # so we override rather than negotiate.
      {:apero, github: "Lorenzo-SF/apero", branch: "main", override: true},
      {:arrea, github: "Lorenzo-SF/arrea", branch: "main", override: true},

      # Trebejo: OS introspection. Candil calls Trebejo.OS.arch/0 directly in
      # Candil.Detector.safe_arch/0, so it must be a direct dep and not only
      # transitive (it also arrives via botica). Its supervision tree is empty
      # by design — see Trebejo.Application — so runtime: false is correct and
      # keeps it out of Candil's own boot sequence.
      {:trebejo,
       github: "Lorenzo-SF/Trebejo",
       branch: "main",
       optional: true,
       runtime: false,
       override: true},

      # Alaja: CLI definition, tables, colour. Used only by
      # lib/candil/cli/** and lib/candil/doctor.ex. Alaja marks its own
      # `batamanta` dep optional+runtime:false and never references it from
      # lib/, so no `mix batamanta` step is needed here.
      {:alaja, github: "Lorenzo-SF/alaja", branch: "main", override: true},

      # Botica: health checks and fixes, used only by `candil doctor` for the
      # generic memory/disk checks. Optional so that Candil's core never
      # depends on a diagnostics library being present.
      {:botica, github: "Lorenzo-SF/botica", branch: "main", optional: true, override: true},
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 1.0.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/Lorenzo-SF/candil",
      homepage_url: "https://github.com/Lorenzo-SF/candil",
      source_ref: "3.0.0",
      extras: ["README.md", "LICENSE.md"],
      groups_for_modules: [
        Core: [Candil, Candil.Llm, Candil.Error, Candil.Cost],
        Store: [
          Candil.Store,
          Candil.ConfigManager,
          Candil.Model,
          Candil.Provider,
          Candil.Source,
          Candil.Build
        ],
        Diagnostics: [Candil.Health, Candil.Embeddings],
        Conversation: [
          Candil.Conversation,
          Candil.Conversation.Context,
          Candil.Conversation.TokenEstimator
        ],
        Inference: [
          Candil.Inference,
          Candil.Inference.Chat,
          Candil.Inference.Embeddings,
          Candil.RequestBuilder,
          Candil.Stream,
          Candil.HTTP,
          Candil.HTTP.Client,
          Candil.HTTP.Retry
        ],
        Backends: [Candil.Backend, Candil.Backend.LlamaCpp, Candil.Backend.OpenAICompat],
        "Tools & Agents": [Candil.Tool, Candil.Tools, Candil.Structured, Candil.Agent],
        Engine: [
          Candil.Engine,
          Candil.Engine.Launcher,
          Candil.Engine.Server,
          Candil.Engine.Server.External,
          Candil.Engine.HealthPoller,
          Candil.EnginePool,
          Candil.Detector,
          Candil.Detector.GPU,
          Candil.Detector.Models,
          Candil.Detector.Release,
          Candil.Installer
        ],
        Runtime: [Candil.Telemetry, Candil.Cancellation, Candil.RateLimiter]
      ]
    ]
  end

  defp dialyzer_config do
    [
      plt_file: {:no_warn, "priv/plts/candil"},
      plt_core_path: "priv/plts/core",
      # The sibling libraries Candil actually calls into, not just :mix.
      #
      # Without this, dialyzer's PLT contains OTP and Candil but none of the
      # app dependencies, so every cross-app call comes back as
      # `unknown_function`. Candil calls Trebejo.OS.arch/0, Apero.Proc.which/1
      # and Arrea.LongRunning, so those three are in.
      #
      # Add a sibling here the first time you call into it, not before. Every
      # app here makes the PLT build slower, and the CI caches it per OTP
      # version, so a stale entry costs build time on every cache miss.
      plt_add_apps: [:mix, :trebejo, :apero, :arrea],
      flags: [:error_handling, :no_opaque, :no_underspecs]
    ]
  end
end
