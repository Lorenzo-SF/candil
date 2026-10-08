defmodule Candil.MixProject do
  use Mix.Project

  def project do
    [
      app: :candil,
      version: "4.0.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Candil",
      description: "LLM inference and model management for Elixir.",
      source_url: "https://github.com/Lorenzo-SF/candil",
      homepage_url: "https://github.com/Lorenzo-SF/candil",
      batamanta: batamanta(),
      package: [
        name: :candil,
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/Lorenzo-SF/candil"},
        maintainers: ["Lorenzo Sánchez"]
      ],
      docs: docs(),
      # Phase 3, 3.1. The plan says only lane H edits this file, and the
      # escript entry is exactly the kind of thing that belongs there — but
      # the phase's own acceptance criterion is `mix escript.build && ./candil
      # version`, and it cannot be executed without this line. Left as one
      # deliberate, flagged exception rather than a phase that cannot be
      # verified.
      escript: [main_module: Candil.CLI.Escript],
      test_coverage: [tool: ExCoveralls],
      aliases: aliases(),
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
      # ── Sibling deps: las siete desde Hex, con version ──
      #
      # El motivo es el de siempre, aplicado a las dependencias: **una
      # dependencia que nunca falla nunca esta comprobada**, y `branch: "main"`
      # es una dependencia que no puede fallar porque no tiene version con la
      # que dejar de resolver.
      #
      # Y no es teorico. El 2026-10-07 Arrea publico 3.1.0 sin tag y sin subir
      # su `mix.exs`, y ese commit llego a Candil ENTERO, porque la dep
      # estaba en `main` y el lock guarda el SHA de lo que hubiera ayer. Con
      # version eso es imposible: **o esta publicado, o no esta**.
      #
      # NO queda ni un `override: true`. Ese flag solo hacia falta mientras una
      # hermana se quedase en git declarando a las demas por git, y Hex lo
      # lo enian como otras dependencias. Siempre significaba "usa la mia"; con las
      # siete de Hex, Mix resuelve solo y no hay nada que imponer.
      #
      # Y al pasarlo aparecio el conflicto que `main` llevaba meses tapando:
      # `botica 2.1.0` pedia `trebejo ~> 1.0` y no resolvia con el Trebejo 2 que
      # necesita Candil. Con ramas cada repo tenia su realidad y nadie se
      # enteraba. Con versiones aparecio en 0,34 segundos, con un mensaje que decia
      # quien miente. Arreglado en botica 2.2.0.
      #
      # El coste sigue siendo real: Candil no recoge automaticamente un fix de
      # una hermana. Entra cuando se publica una version nueva. Para un
      # ecosistema donde todo cambia cada dia, es el precio de poder decir
      # "esto funciona" en vez de "esto funciona hoy".
      #
      {:apero, "~> 4.1", optional: true},
      {:arrea, "~> 3.1"},
      {:trebejo, "~> 2.1"},
      {:batamanta, "~> 3.1", optional: true, runtime: false},
      {:alaja, "~> 3.2"},
      {:botica, "~> 2.2", optional: true},
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"},
      {:mox, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 1.0.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      gen: ["deps.get", "compile", "batamanta", "install"],
      install: fn _ ->
        dest_dir = Path.expand("~/.local/bin")
        File.mkdir_p!(dest_dir)
        config = Mix.Project.config()
        app_name = Atom.to_string(config[:app])

        source_path = Path.expand("candil")
        dest_path = Path.join(dest_dir, app_name)

        if File.exists?(source_path) do
          install_binary(source_path, dest_path)
        else
          Mix.shell().error("[ERROR] No se encontro el binario: #{source_path}")
          Mix.shell().info("   Ejecutaste 'mix batamanta' primero?")
        end
      end
    ]
  end

  defp install_binary(source_path, dest_path) do
    unlink_if_symlink(dest_path)

    case File.cp(source_path, dest_path) do
      :ok ->
        File.chmod!(dest_path, 0o755)
        size = File.stat!(dest_path).size

        if size == 0 do
          Mix.raise("[ERROR] El binario instalado en #{dest_path} quedo vacio (0 bytes)")
        end

        Mix.shell().info("  Batamanta instalado en #{dest_path} (#{size} bytes)")

      {:error, reason} ->
        Mix.shell().error("[ERROR] No se pudo copiar alaja: #{inspect(reason)}")
    end
  end

  # Sustituye un symlink del destino por un fichero real. `File.cp/2`
  # escribe *a través* de un symlink, así que sin esto el destino
  # heredado puede seguir apuntando al build (o a cualquier otro sitio)
  # en vez de contener la copia recién instalada.
  defp unlink_if_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> File.rm(path)
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Mix.raise("[ERROR] No se pudo inspeccionar #{path}: #{inspect(reason)}")
    end
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
        Context: [Candil.Context, Candil.Context.Session],
        MCP: [Candil.MCP, Candil.MCP.Protocol],
        RAG: [Candil.RAG, Candil.RAG.Chunk],
        Gateway: [
          Candil.Gateway,
          Candil.Gateway.Auth,
          Candil.Gateway.Endpoint
        ],
        Router: [
          Candil.Router,
          Candil.Router.Decision,
          Candil.Router.Cache,
          Candil.Router.Consumer,
          Candil.Router.DecisionEngine,
          Candil.Router.Scorer
        ],
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

  defp batamanta do
    [
      format: :escript,
      execution_mode: :cli,
      compression: 19,
      binary_name: "Arrea",
      # BEAM-keeps-alive. The wrapper dispatches to a warm Erlang VM over a
      # Unix-domain socket instead of booting one per invocation. The socket
      # is namespaced by (app, version, target), so this daemon is Arrea's
      # own — it is not shared with the other packaged CLIs.
      #   ARREA_BEAM_ALIVE=<ms>  override the TTL for one shell (max 86_400_000)
      #   ARREA_BEAM_ALIVE=0     force the legacy cold-start path
      daemon: [
        enabled: true,
        var: "ARREA_BEAM_ALIVE",
        default_ms: 300_000,
        request_timeout_ms: 60_000
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
