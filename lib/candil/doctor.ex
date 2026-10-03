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
  a worse `free` on a different machine. Those two go to Botica —
  `Botica.Batteries.Memory` and `Botica.Batteries.Disk` — and the other six
  are ours, because they are about models, engines, ports and keys. Each one in
  its own domain, which is the correct division rather than a courtesy.

  Disk was the one that had to be asked for: the audit claimed Botica was
  integrated and only `Batteries.Memory` was. It was, until the check that
  asked it for its other battery.

  ## One check, one crash

  A check that raises produces an `:error` for itself and the rest of the
  report still comes out. A doctor that dies because one probe failed is a
  doctor you cannot use on a machine that is broken — which is the only machine
  where you would reach for it.
  """

  alias Apero.OS, as: AperoOS
  alias Botica.Batteries.Disk, as: BoticaDisk
  alias Candil.Doctor.{Checks, FixTable}
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

  The running is `Botica`'s now: `Candil.Doctor.Checks` hands it eight
  `Botica.Types.check_def/0` and `Botica.Runner.Executor` runs them in
  parallel, each under its own timeout, isolating a check that raises. What
  comes back is put through `from_botica/3` so that the shape of this report is
  exactly what it always was.

  That last part is the point. `Botica` is better at running checks; it does
  not have opinions about what a LLM runtime's report looks like, and the CLI,
  the `--json` contract and twenty-something tests all depend on this one.
  Adapting at the boundary means the internal change costs nothing outside it.

  `opts[:fix]` additionally attempts the repairs that are safe to attempt, and
  records which ones it made. What it could not do is still listed, with the
  command, because a fix that silently gives up is worse than no fix.
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    table = FixTable.new()
    checks = collect(table, opts[:fix] == true)

    %{
      checks: checks,
      errors: Enum.count(checks, &(&1.level == :error)),
      warnings: Enum.count(checks, &(&1.level == :warning))
    }
  end

  # A `case` does not share bindings between its branches, so the whole
  # `Botica.Doctor.run/1` call lives in here rather than inline in `run/1`.
  defp collect(table, fix?) do
    config = %{
      app_name: "candil",
      checks: Checks.all(table)
    }

    case Botica.Doctor.run(config) do
      {:ok, results} ->
        checks = from_botica(results, table)
        if fix?, do: repair(checks, config, results, table), else: checks

      {:error, reason} ->
        # Botica refuses to run a config it considers invalid, and every one of
        # these definitions is built here, so this is unreachable in practice.
        # It is still handled: a doctor that printed nothing because a
        # dependency changed its mind would look exactly like a doctor that
        # found nothing, and those two must never be confused.
        [
          %{
            name: :runner,
            level: :error,
            message: "el runner no arranco: " <> to_string(reason),
            fix: nil
          }
        ]
    end
  end

  @doc """
  Runs one check by name and returns it as a check map.

  Public because `Candil.Doctor.Checks` wraps it; it is the same code that
  always ran, just addressed directly instead of through a list.
  """
  @spec run_one(atom()) :: check()
  def run_one(:config), do: config()
  def run_one(:binary), do: binary()
  def run_one(:sources), do: sources()
  def run_one(:ports), do: ports()
  def run_one(:auth), do: auth()
  def run_one(:gpu), do: gpu()
  def run_one(:memory), do: memory()
  def run_one(:disk), do: disk()

  # Botica's `result` is `%{id:, name:, status:, message:, fix_command:}`.
  # Candil's is `%{name:, level:, message:, fix:}`.
  #
  # The order comes from `Checks.ids/0` and not from the order the results
  # arrived in. Botica's executor uses `ordered: true` today, and a report whose
  # order depends on a sibling library's internals is one that silently changes
  # the day that flag does.
  defp from_botica(results, table) do
    by_id = Map.new(results, &{&1.id, &1})

    Checks.ids()
    |> Enum.map(fn id ->
      case Map.get(by_id, id) do
        nil ->
          %{
            name: id,
            level: :error,
            message: "el check no llego a ejecutarse",
            fix: nil
          }

        result ->
          %{
            name: result.id,
            level: result.status,
            message: result.message,
            fix: FixTable.get(table, id)
          }
      end
    end)
  end

  # `--fix` is two things, and Botica's model only covers the first.
  #
  # 1. **Per-check repairs**, through `Botica.Repair.Fixer`: any check that came
  #    back `:error` and carries a `fix` function is repaired here, and the
  #    applied / failed / skipped split is Botica's to keep.
  # 2. **The directories**, through `prepare/0`: a missing `candil.toml` is a
  #    *warning*, so the Fixer would never look at it, and `candil doctor
  #    --fix` would be a no-op on the fresh machine it exists for.
  #
  # The config check also registers `prepare/0` as its own `fix` (see
  # `Checks.config_fix/0`), so if a config problem ever *is* an error it gets
  # repaired through Botica's path. It is not called from here when that has
  # already happened, because creating a directory twice is harmless but
  # reporting it twice is a lie.
  defp repair(checks, config, results, table) do
    # `Fixer.fix/2` is typed `{:ok, fix_report()}` with no error clause, and
    # dialyzer is right: there is nothing to fall back from. A clause that
    # cannot match is a branch that reads like it can, and the next person
    # trusts it.
    {:ok, applied} = Botica.Repair.Fixer.fix(config, results)

    message =
      if :config in applied.applied do
        FixTable.get(table, :config)
      else
        case prepare() do
          {:ok, created} -> created
          {:error, _reason} -> nil
        end
      end

    if message, do: Enum.map(checks, &announce(&1, message)), else: checks
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

  # Is there room on the disk, for the model files Candil is about to write.
  # The path is the data directory rather than `/`, because `/` on a container
  # can be a small overlay while the volume the models land on has hundreds of
  # gigabytes free. Checking `/` would report a full machine that is not full.
  @spec disk() :: check()
  defp disk do
    path = Instances.data_dir()

    case safe(fn -> BoticaDisk.check_disk(path, 80, 95) end) do
      {:ok, {:ok, message}} -> ok(:disk, message)
      {:ok, {:warning, message}} -> warning(:disk, message)
      {:ok, {:error, message}} -> error(:disk, message)
      {:error, reason} -> warning(:disk, "no se pudo leer el disco: " <> reason)
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
  @doc """
  Creates the directories Candil needs, and says where.

  Not a `Botica.Repair.Fixer` repair, and deliberately so: a missing
  `candil.toml` is a *warning*, and the Fixer only repairs checks that came back
  `:error`. Routing this through the Fixer would make `candil doctor --fix` a
  no-op on exactly the fresh machine it exists for.

  It is public because `Candil.Doctor.Checks.config_fix/0` is the same function,
  and a check that *does* come back `:error` should be repaired through Botica's
  own path rather than a second one.
  """
  @spec prepare() :: {:ok, binary()} | {:error, binary()}
  def prepare do
    data = Instances.data_dir()
    logs = Instances.log_dir()

    with :ok <- Apero.File.ensure_dir(data), :ok <- Apero.File.ensure_dir(logs) do
      {:ok, "creado #{created(data, logs)}"}
    else
      {:error, reason} ->
        {:error, "no se pudo crear #{data}: #{inspect(reason)}"}
    end
  end

  # Say what was actually created. `log_dir` can point anywhere, and a `--fix`
  # that reports `<data_dir>/logs` while writing somewhere else is a small lie
  # in the one place the user is told what to trust.
  defp created(data, logs) when data == logs, do: data
  defp created(data, logs), do: "#{data} y #{logs}"

  # `message` already arrives as a sentence — `prepare/0` returns "creado /x y
  # /x/logs" — so nothing is prepended here. An earlier version did, and the
  # report said "creado creado /x", which is the kind of small nonsense that
  # makes someone doubt the rest of the line.
  defp announce(%{name: :config} = check, message) do
    put_new(check, message)
  end

  defp announce(check, _created), do: check

  defp put_new(check, message) do
    %{check | message: check.message <> " · " <> message}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Every check runs inside this, and the moduledoc promised it. It did not:
  # only `memory/0` was wrapped, so an engine whose `binary` blew up inside
  # `Engine.binary_path/1` took the whole report with it — which is the one
  # machine where you most need the doctor. A promise in a docstring that the
  # code does not keep is worse than no promise.
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
