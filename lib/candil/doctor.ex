defmodule Candil.Doctor do
  @moduledoc """
  Answers "is this machine set up to run Candil?", and for every "no" it says
  what to type.

  Seven checks, in the order the design document lists them (§17): config,
  binary, sources, ports, auth, gpu, memory. Each one returns a level and a
  sentence.

  ## The sentence is the product

  A check that says "engine failed" has moved the problem, not solved it. So
  every message here names either the thing that is wrong or the command that
  fixes it:

      ✗ ~/.candil/llm/bin/llama-server is not built;
        run `candil engine install` (source)
      ✗ ~/.candil/models/coder.gguf is not there;
        run `candil models pull coder`

  That rule is the whole acceptance criterion for this phase.

  ## Botica for the generic half

  Memory and disk are not LLM problems and re-implementing them here would be
  a worse `free` on a different machine. Those two go to
  `BoticaMemory` and `Botica.Batteries.Disk`; the other five are
  ours, because they are about models, engines, ports and keys. Each one in its
  own domain, which is the correct division rather than a courtesy.

  ## One check, one crash

  A check that raises produces an `:error` for itself and the rest of the
  report still comes out. A doctor that dies because one probe failed is a
  doctor you cannot use on a machine that is broken — which is the only machine
  where you would reach for it.
  """

  alias Apero.OS, as: AperoOS
  alias Botica.Batteries.Memory, as: BoticaMemory
  alias Candil.{Build, Engine, Instances, Model, Store}
  alias Candil.Config, as: CandilConfig
  alias Candil.Detector.GPU

  @type level :: :ok | :warning | :error

  @type check :: %{
          name: atom(),
          level: level(),
          message: binary(),
          fix: binary() | nil
        }

  @type report :: %{checks: [check()], errors: non_neg_integer(), warnings: non_neg_integer()}

  @doc """
  Runs every check and returns the report.

  `opts[:fix]` additionally attempts the repairs that are safe to attempt, and
  records which ones it made. What it could not do is still listed, with the
  command, because a fix that silently gives up is worse than no fix.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    checks =
      [
        {:config, &config/0},
        {:binary, &binary/0},
        {:sources, &sources/0},
        {:ports, &ports/0},
        {:auth, &auth/0},
        {:gpu, &gpu/0},
        {:memory, &memory/0}
      ]
      |> Enum.map(&probed/1)
      |> then(fn list -> if opts[:fix], do: repair(list), else: list end)

    %{
      checks: checks,
      errors: Enum.count(checks, &(&1.level == :error)),
      warnings: Enum.count(checks, &(&1.level == :warning))
    }
  end

  @doc """
  Renders the report the way §17 shows it.
  """
  @spec render(report()) :: binary()
  def render(%{checks: checks, errors: errors, warnings: warnings}) do
    lines =
      Enum.map(checks, fn %{name: name, level: level, message: message} ->
        "#{mark(level)} #{name}#{pad(name)}  #{message}"
      end)

    Enum.join(lines, "\n") <>
      "\n\n#{errors} errores · #{warnings} advertencias."
  end

  defp mark(:ok), do: "✓"
  defp mark(:warning), do: "⚠"
  defp mark(:error), do: "✗"

  defp pad(name) do
    " " <> String.duplicate(" ", max(1, 10 - String.length(to_string(name))))
  end

  # ── the seven checks ─────────────────────────────────────────────────────

  @doc """
  Is there a configuration, and does it describe something?
  """
  @spec config() :: check()
  def config do
    case CandilConfig.File.load() do
      {:ok, %{} = config} ->
        models = map_size(Map.get(config, "model", %{}))
        engines = map_size(Map.get(config, "engine", %{}))
        providers = map_size(Map.get(config, "provider", %{}))

        if models + engines + providers == 0 do
          warning(
            :config,
            "no models, no engines and no providers. Edit " <>
              "#{CandilConfig.File.default_path()}"
          )
        else
          ok(
            :config,
            "válido · #{models} modelos · #{engines} engine(s) · #{providers} provider(s)"
          )
        end

      # `Config.File.load/1` is typed `{:ok, map()} | {:error, term()}` and in
      # practice only ever hands back the error, which dialyzer confirms. Two
      # clauses, not three: a `{:ok, _}` that matches a map already handled
      # above is a branch that cannot run, and a branch that cannot run reads
      # like a case that can.
      {:error, problems} when is_list(problems) ->
        error(
          :config,
          "el fichero no valida: " <> Enum.join(Enum.take(problems, 2), "; "),
          "arregla #{CandilConfig.File.default_path()}"
        )

      {:error, reason} ->
        error(:config, "no se pudo leer la config: #{inspect(reason)}")
    end
  end

  @doc """
  Is the engine's binary actually there?
  """
  @spec binary() :: check()
  def binary do
    case first_engine() do
      {:ok, engine} ->
        # `Engine.binary_path/1` answers a PATH, never nil — the engine either
        # has one or it falls back to a default. So the question here is not
        # "is there a path" but "is there a file at that path", and those are
        # different failures with different fixes.
        path = Engine.binary_path(engine)

        if File.exists?(path) do
          ok(:binary, "#{engine.alias} → #{path}")
        else
          describe_missing_binary(engine, path)
        end

      :error ->
        warning(:binary, "no hay ningun engine configurado")
    end
  end

  # "not there" and "not built yet" are different problems with different
  # remedies, and the difference is exactly the install plan.
  defp describe_missing_binary(engine, path) do
    case engine.install do
      %Build{} = install ->
        error(
          :binary,
          "#{path} is not built",
          "candil engine install  (estrategia #{install.strategy})"
        )

      _ ->
        error(
          :binary,
          "no esta #{path}",
          "ponlo a mano o declara [engine.#{engine.alias}.install]"
        )
    end
  end

  @doc """
  Which model files are on disk, and which are not.
  """
  @spec sources() :: check()
  def sources do
    models = Store.list_models() |> Enum.filter(&Model.managed?/1)

    case models do
      [] ->
        warning(:sources, "no hay modelos locales configurados")

      models ->
        {present, absent} = Enum.split_with(models, &Model.downloaded?/1)
        count = "#{length(present)}/#{length(models)} descargados"

        if absent == [] do
          ok(:sources, count)
        else
          warning(
            :sources,
            count <> " (faltan " <> Enum.map_join(absent, ", ", &to_string(&1.alias)) <> ")",
            "candil models pull"
          )
        end
    end
  end

  @doc """
  Are the ports in the engine's range actually free?
  """
  @spec ports() :: check()
  def ports do
    case first_engine() do
      {:ok, engine} ->
        base = engine.base_port
        busy = taken(base, base + 99)

        case busy do
          [] ->
            ok(:ports, ":#{base}-#{base + 99} libres")

          taken ->
            warning(
              :ports,
              "ocupados: " <> Enum.map_join(taken, " ", &":#{&1}"),
              "candil stop <model>"
            )
        end

      :error ->
        warning(:ports, "no hay ningun engine configurado")
    end
  end

  defp taken(base, max) do
    Enum.filter(base..max, fn port ->
      case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 60) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, _} ->
          false
      end
    end)
  end

  @doc """
  Is the engine's API key actually resolvable, and set in the environment?

  A key that resolves to `nil` because the variable is not set is the failure
  that costs an afternoon: the TOML is right, the env is not, and the server
  answers 401 with nothing pointing at the variable.
  """
  @spec auth() :: check()
  def auth do
    case first_engine() do
      {:ok, engine} ->
        describe_auth(engine)

      :error ->
        warning(:auth, "no hay ningun engine configurado")
    end
  end

  defp describe_auth(%Engine{api_key: nil}) do
    ok(:auth, "el engine no pide key")
  end

  defp describe_auth(%Engine{api_key: {:system, var}}) do
    case System.get_env(var) do
      nil ->
        error(
          :auth,
          "api_key_env=#{var} pero #{var} NO esta puesta",
          "export #{var}=... en el shell que arranca el engine"
        )

      value ->
        ok(:auth, "api_key_env=#{var} (puesta, #{String.length(value)} caracteres)")
    end
  end

  defp describe_auth(%Engine{api_key: key}) when is_binary(key) do
    ok(:auth, "api_key en el fichero (#{String.length(key)} caracteres)")
  end

  @doc """
  What GPU is there, and how much of it is left?
  """
  @spec gpu() :: check()
  def gpu do
    {backend, cuda_version} = GPU.detect_gpu(AperoOS.type())

    case backend do
      :cpu ->
        ok(:gpu, "sin GPU: los modelos iran por CPU, mas lento pero funciona")

      backend ->
        detail = if cuda_version, do: "CUDA #{cuda_version}", else: to_string(backend)
        ok(:gpu, detail)
    end
  end

  @doc """
  How much memory is left. Botica's job, not ours.
  """
  @spec memory() :: check()
  def memory do
    # Botica answers with a `{:status, message}` tuple, not a map. Guessing the
    # shape gives you an empty message and a green tick, which is the worst
    # possible failure for a check whose whole job is to tell you something.
    case safe(fn -> BoticaMemory.check_memory(80, 95) end) do
      {:ok, {:ok, message}} -> ok(:memory, message)
      {:ok, {:warning, message}} -> warning(:memory, message)
      {:ok, {:error, message}} -> error(:memory, message)
      {:error, reason} -> warning(:memory, "no se pudo leer la memoria: " <> reason)
    end
  end

  # ── repair ───────────────────────────────────────────────────────────────

  # A fix is attempted only when the check says one exists, and the result is
  # never swallowed: if it did not work, the check stays at :error with the
  # command still attached.
  # The repairs that are safe to attempt, done once, before the per-check
  # pass. It used to hang off the `:config` check's `fix` field, which meant
  # it only ran when the config was broken in exactly the right way — a repair
  # that depends on which check failed is a repair you cannot reason about.
  defp repair(checks) do
    dir = Instances.data_dir()
    _ = File.mkdir_p(Path.join(dir, "logs"))
    _ = File.mkdir_p(dir)
    Enum.map(checks, &announce(&1, dir))
  end

  defp announce(%{name: :config} = check, dir) do
    put_new(check, "creado #{dir}")
  end

  defp announce(check, _dir), do: check

  defp put_new(check, message) do
    %{check | message: check.message <> " · " <> message}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Every check runs inside this, and the moduledoc promised it. It did not:
  # only `memory/0` was wrapped, so an engine whose `binary` blew up inside
  # `Engine.binary_path/1` took the whole report with it — which is the one
  # machine where you most need the doctor. A promise in a docstring that the
  # code does not keep is worse than no promise.
  defp probed({name, fun}) do
    fun.()
  rescue
    error ->
      %{
        name: name,
        level: :error,
        message: "el check reviento: " <> Exception.message(error),
        fix: nil
      }
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{inspect(kind)}: #{inspect(reason)}"}
  end

  defp first_engine do
    case Store.list_engines() do
      [engine | _] -> {:ok, engine}
      [] -> :error
    end
  end

  defp ok(name, message), do: %{name: name, level: :ok, message: message, fix: nil}

  defp warning(name, message, fix \\ nil) do
    %{name: name, level: :warning, message: message, fix: fix}
  end

  defp error(name, message, fix \\ nil) do
    %{name: name, level: :error, message: message, fix: fix}
  end
end
