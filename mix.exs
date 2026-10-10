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
      # ── Sibling deps: las siete desde su `main`, por git ──
      #
      # **Esto estaba en Hex y se cambio el 2026-10-10 por decision del
      # dueno.** Se conserva el razonamiento anterior porque es bueno, y
      # porque el cambio no lo invalida: lo acota.
      #
      # Decia Hex, y con razon: *"una dependencia que nunca falla nunca esta
      # comprobada"*, y `branch: "main"` es una dependencia que no puede fallar
      # porque no tiene version con la que dejar de resolver. El 2026-10-07
      # Arrea publico 3.1.0 sin tag y sin subir su `mix.exs`, y ese commit
      # llego a Candil ENTERO. Con version eso es imposible: **o esta
      # publicado, o no esta**.
      #
      # ## Por que se cambio
      #
      # 1. **Medido: el coste de Hex era real y estaba bloqueando trabajo.**
      #    Lo publicado era 3.1.0, y el repo estaba tambien en 3.1.0. Mergeado
      #    `Arrea.Resource` (fase 2) en `main`, para Candil **no habia
      #    cambiado nada**, y Hex no admite republicar una version ya
      #    publicada: hacia falta subir de version y publicar a mano. La fase 2
      #    no desbloqueara la 3 hasta hacer eso, a mano, cada vez.
      # 2. **El ecosistema se mueve cada dia**, y el propio comentario
      #    reconocio el precio: *"Candil no recoge automaticamente un fix de
      #    una hermana. Entra cuando se publica una version nueva."*
      # 3. **El riesgo de Hex ya se materializo** y el de git todavia no, con
      #    una diferencia: el incidente del 07 fue un commit entero, que se ve;
      #    un fix sin publicar es un desfase que **no se ve** porque todo esta
      #    verde.
      #
      # ## Lo que se cede, escrito para que no se pierda de vista
      #
      # - **Candil puede romperse aunque Arrea este verde.** Si Arrea rompe su
      #   `main`, el CI de Candil lo ve en ese commit, no en el siguiente.
      # - **Un fix de una hermana no se recoge solo.** Hay que
      #   `mix deps.update <hermana>` a proposito.
      # - **Todo `override: true` es de forceps.** Sin el, el solvedor ve
      #   "arrea de aqui" y "arrea de ahi" y se niega: *"botica depends on
      #   arrea ~> 3.1 which doesn't match any versions"*. Con las siete
      #   apuntando al mismo sitio, el `override` deja de ser "usa la mia" y
      #   pasa a ser **lo que hace que Mix no se queje de tener dos fuentes
      #   para la misma biblioteca**.
      #
      # ## Lo que NO se cede
      #
      # `mix.lock` fija el **SHA exacto** de cada hermana. La build sigue
      # siendo reproducible y una build vieja no se rompe sola: el que decide
      # cuando se mueve Candil es el `mix.lock`, no la rama.
      #
      {:apero, github: "Lorenzo-SF/apero", branch: "main", override: true, optional: true},
      {:arrea, github: "Lorenzo-SF/arrea", branch: "main", override: true},
      {:trebejo, github: "Lorenzo-SF/trebejo", branch: "main", override: true},
      {:batamanta,
       github: "Lorenzo-SF/Batamanta",
       branch: "main",
       override: true,
       optional: true,
       runtime: false},
      {:alaja, github: "Lorenzo-SF/alaja", branch: "main", override: true},
      {:botica, github: "Lorenzo-SF/botica", branch: "main", override: true, optional: true},
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

      # Benchmarks. `mix bench` corre todos; `mix bench router` solo uno.
      #
      # NO esta en el CI, y es deliberado. Un benchmark es una medicion que se
      # lee UNA vez y se pega en el documento del modulo. Correrlo en cada push
      # cuesta minutos y no avisa de nada, porque un numero que sube un 15% por
      # el ruido de una maquina compartida no es un hallazgo.
      bench: ["run scripts/bench.exs"],
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
