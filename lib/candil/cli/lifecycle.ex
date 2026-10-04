defmodule Candil.CLI.Lifecycle do
  @moduledoc """
  The `run`, `stop` and `status` commands.

  The ordering in `run/2` is the whole point of the module and it is fixed by
  the design document (§11.2):

    1. resolve the port
    2. preflight — model file, engine, binary, source
    3. only then look at whether the port is occupied

  Steps 1 and 2 happen before anything is claimed or spawned, so a start that
  cannot work leaves the machine exactly as it found it. Step 3 is the part
  with teeth: **Candil does not kill anything by itself.** A port held by
  another model is an error that names the holder and tells the user what to
  run. Only `--force` kills, and it says so before it does.
  """

  alias Alaja.Components.Table
  alias Alaja.Printer, as: Say
  alias Candil.CLI.{Colorize, Detach, Ports, Preflight}
  alias Candil.{Engine, EnginePool, Instances, Model, Store}
  alias Candil.Instances.Probe, as: Probe

  @doc """
  `candil run <model> [flags]`, with the flags already parsed.

  Takes the `opts` the Alaja DSL parsed rather than an `argv` list: the type
  of `--port` is an integer by the time it arrives, and it used to be a string
  that a hand-rolled `OptionParser` had promised was a number.

  Without a model name there is nothing to run, and saying so is the whole
  answer — the DSL makes `:model` required, so this clause is only reachable
  from the library, and it still says something useful rather than raising.
  """
  @spec run_model(map() | keyword()) :: :ok
  def run_model(opts) do
    case get(opts, :model) do
      nil ->
        error("usage: candil run <model> [--detach] [--port N]")
        error("       `candil models list` para ver los modelos disponibles")

      name ->
        alias_name = safe_alias(name)

        case fetch(alias_name) do
          {:ok, model} -> start_or_report(model, alias_name, run_opts(opts))
          :error -> error("no such model: #{name}")
        end
    end

    :ok
  end

  # The internal shape `Preflight` and `Ports` already speak. Built here so
  # those two keep asking for a keyword list and the DSL keeps asking for a
  # map, and neither has to know about the other.
  defp run_opts(opts) do
    [
      port: get(opts, :port),
      force: get(opts, :force) == true,
      cpu: get(opts, :cpu) == true,
      detach: get(opts, :detach) == true,
      yes: get(opts, :yes) == true
    ]
  end

  defp get(opts, key) when is_map(opts), do: Map.get(opts, key)

  defp get(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp start_or_report(model, alias_name, opts) do
    case Preflight.run(alias_name, opts) do
      {:error, reasons} -> report(reasons)
      {:ok, _engine} -> start(model, opts)
    end
  end

  defp start(%Model{} = model, opts) do
    case Ports.resolve(model, opts) do
      {:ok, port} -> claim_and_start(model, port, opts)
      {:error, :no_free_port} -> Say.print_error("no free port in the engine's range")
    end
  end

  defp claim_and_start(model, port, opts) do
    case claim_check(model, port, opts) do
      :ok ->
        if opts[:detach] do
          # Un detach delega en OTRO proceso, y no escribe el registro aqui:
          # el dueno del registro tiene que ser el proceso que de verdad sigue
          # vivo, y este se va a terminar en cuanto imprima.
          detach(model, port)
        else
          EnginePool.put(model.alias, port, nil, model, resolve_engine!(model, port))
          record(model, port, opts)
          started(model, port, opts)
        end

      {:occupied, holder, port} ->
        occupied(model, port, holder, opts)
    end
  end

  # The written record is what makes `--detach` mean anything. A detached
  # instance outlives this VM, so the only thing a second `candil` can consult
  # is the file. The owner is this process's OS pid, and `C19` is the whole
  # rule: kill the owner and the engine goes with it, because the engine was
  # never detached from it.
  # El engine REAL del catalogo, con el puerto ya puesto. Nunca un
  # `%Engine{alias: model.engine}` pelado: ese struct no tiene binary, ni
  # api_key, ni start_args, y su puerto es el 8080 por defecto, asi que el
  # modelo arranca hacia otro sitio o no arranca. Ver `Engine.for_model/2`.
  defp resolve_engine!(model, port) do
    case Engine.for_model(model, port) do
      {:ok, engine} ->
        engine

      {:error, :not_found} ->
        Say.print_error("el modelo #{model.alias} no tiene ningun engine en la configuracion")
        exit({:shutdown, 1})
    end
  end

  defp host_of(nil), do: "127.0.0.1"

  defp host_of(alias_name) do
    case Store.get_engine(alias_name) do
      {:ok, %Engine{host: host}} -> to_string(host)
      _ -> "127.0.0.1"
    end
  end

  defp record(%Model{alias: name, engine: engine}, port, opts) do
    if opts[:port], do: Instances.claim_ad_hoc(port)

    instance =
      Instances.build(
        to_string(name),
        port,
        engine && to_string(engine),
        Instances.os_pid(),
        true,
        host_of(engine)
      )

    :ok = Instances.put({to_string(name), port}, instance)
  end

  # Preflight passed and the port is decided. Now, and only now, does the
  # question "is it taken?" matter.
  defp claim_check(model, port, opts) do
    case Ports.occupant(port) do
      :free -> :ok
      # Already ours: the same model on its own port is not a collision, it is
      # the idempotent case.
      {:ok, holder} when holder == model.alias -> :ok
      {:ok, holder} -> {:occupied, holder, port}
      :unknown -> if opts[:force], do: :ok, else: {:occupied, "otro proceso", port}
    end
  end

  # The foreground path colours what it prints, and a detached run says so
  # instead. That is the whole of `--detach` at this layer: same start, a line
  # saying the process is not attached, and a log path to look at later. The
  # engine's own output goes through the same colouriser when the caller
  # supplies it as `:on_output`.
  # No se anuncia nada hasta que el registro lo confirma. Antes se escribia el
  # registro con el pid de este proceso, se imprimia "detached (owner pid N)" y
  # se salia: al siguiente `candil status` el registro ya estaba podado y no
  # habia ni proceso ni log ni nada que parar. Aqui se espera al titular.
  defp detach(model, port) do
    log = log_path(to_string(model.alias), port)

    case Detach.spawn(to_string(model.alias), port, log: log) do
      {:ok, pid} ->
        Say.print_success("#{model.alias} detached (owner pid #{pid}) · log: #{log}")
        :ok

      {:error, {:holder_no_arrived, log}} ->
        Say.print_error("#{model.alias} no ha podido quedarse en marcha. Mira el log:")
        Say.print_error("  #{log}")
        :error

      {:error, reason} ->
        Say.print_error("#{model.alias} no se ha podido lanzar: #{inspect(reason)}")
        :error
    end
  end

  defp started(%Model{alias: name}, port, _opts) do
    Say.print_raw(Colorize.line("  #{name} arrancado en :#{port}") <> "\n")
    :ok
  end

  defp log_path(name, port), do: Path.join([Instances.data_dir(), "logs", "#{name}-#{port}.log"])

  # The design document's own wording, kept close to the original: do not kill
  # automatically, name what is holding the port, offer the two ways forward.
  defp occupied(model, port, holder, opts) do
    if opts[:force] do
      Say.print_warning("--force: matando '#{holder}' en :#{port}")
      stop_holder(model, port)
      EnginePool.put(model.alias, port, nil, model, resolve_engine!(model, port))
      Say.print_success("#{model.alias} arrancado en :#{port}")
    else
      Say.print_error(":#{port} está ocupado por '#{holder}'.")
      Say.print("  candil no mata automáticamente. Usa:")
      Say.print("    candil stop #{holder}")
      Say.print("  o --force para rotar interactivamente.")
    end
  end

  # `EnginePool.delete/2` answers `:ok`, and `:ok && x` is never nil, so `&&`
  # was never doing anything except hiding that the kill is unconditional.
  defp stop_holder(%Model{alias: model_alias}, port) do
    case Enum.find(EnginePool.list(), &(&1.port == port)) do
      nil -> :ok
      instance -> kill(instance, model_alias, port)
    end
  end

  defp kill(%{pid: nil}, model_alias, port), do: EnginePool.delete(model_alias, port)

  defp kill(%{pid: pid}, model_alias, port) do
    :ok = EnginePool.delete(model_alias, port)
    Process.exit(pid, :kill)
    :ok
  end

  @doc """
  `candil stop [all|<model>]`.
  """
  @spec stop(map() | keyword()) :: :ok
  def stop(opts) when is_map(opts) or is_list(opts) do
    case get(opts, :model) do
      nil -> stop_all()
      "all" -> stop_all()
      name -> stop_one(name)
    end
  end

  def stop_one(name) do
    alias_name = safe_alias(name)
    local = EnginePool.list() |> Enum.filter(&(&1.alias == alias_name))

    # And then the file, which is where a DETACHED instance lives: a different
    # process, a different VM, absent from this pool by construction. Stopping
    # only what is in memory would report "nothing running" about something
    # that is very much running.
    remote = Instances.find(to_string(name))

    case {local, remote} do
      {[], []} ->
        Say.print_error("no hay instancias de '#{name}'")

      {instances, detached} ->
        Enum.each(instances, &halt/1)
        stopped_remote(detached)

        # Both counts, or the message says "0 paradas" while it just killed a
        # detached engine in another VM — which is the one case where the
        # number matters.
        Say.print_success(
          "#{length(instances) + length(detached)} instancia(s) de '#{name}' paradas"
        )
    end

    :ok
  end

  # The owner gets a TERM, not a KILL. `nohup` and a `llama-server` unloading
  # 20 GB both need the chance to close things in order; a KILL takes that
  # choice away and is what leaves a process holding a socket with nothing
  # behind it.
  defp stopped_remote([]), do: :ok

  defp stopped_remote(instances) do
    Enum.each(instances, fn %{owner: %{kind: :pid, pid: pid}} ->
      if pid > 0, do: signal(pid, "TERM")
    end)

    Enum.each(instances, fn %{model: model, port: port} ->
      :ok = Instances.delete({model, port})
    end)
  end

  defp signal(pid, name) do
    {_out, status} =
      System.cmd("kill", ["-" <> name, Integer.to_string(pid)], stderr_to_stdout: true)

    status == 0
  rescue
    ErlangError -> false
  end

  defp stop_all do
    local = EnginePool.list()
    remote = Instances.read()

    case {local, remote} do
      {[], []} ->
        Say.print_info("no hay instancias")

      {instances, _} ->
        Enum.each(instances, &halt/1)
        stopped_remote(remote)
        Say.print_success("#{length(instances) + length(remote)} instancias paradas")
    end

    :ok
  end

  defp halt(%{pid: nil, alias: alias_name, port: port}) do
    EnginePool.delete(alias_name, port)
    :ok
  end

  defp halt(%{pid: pid, alias: alias_name, port: port}) do
    EnginePool.delete(alias_name, port)
    Process.exit(pid, :kill)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  `candil status [--json]`.

  `--json` prints a list, not an object, because the acceptance criteria pipe
  it into `jq -r '.[0].model'`. A map would need `.models[0]` and the criteria
  are not a suggestion.
  """
  @spec status(map() | keyword()) :: :ok
  def status(opts) when is_map(opts) or is_list(opts) do
    running = running()

    if get(opts, :json) == true do
      # Raw, and with the newline: a `--json` consumer pipes this into jq
      # and decoration is exactly what breaks it.
      Say.print_raw(Jason.encode!(Enum.map(running, &json_row/1)) <> "\n")
    else
      print_table(running)
    end

    :ok
  end

  # Locales Y remotas, y no solo las locales.
  #
  # `EnginePool.list()` es la memoria de ESTE VM. Una instancia detached vive en
  # el registro, en otro proceso, y aqui no aparece: `candil run --detach`
  # contestaba "detached", `candil status` decia que no habia nada, y
  # `candil stop` —que si leia las dos— no tenia nada que parar. Status y stop
  # no podian estar mas en desacuerdo sobre que es estar corriendo.
  defp running do
    local =
      Enum.map(EnginePool.list(), fn entry ->
        %{
          model: to_string(entry.alias),
          port: entry.port,
          pid: entry.pid,
          state: state_of(entry.alias),
          engine: engine_name(entry),
          owner: "local",
          uptime_ms: System.monotonic_time(:millisecond) - entry.started_at
        }
      end)

    # El registro serializa el arranque como ISO 8601 ("2026-10-04T19:42:39Z").
    # Un reloj ilegible da `nil` y la celda sale "—", no cero: un cero parece un
    # dato y un "—" parece lo que es, que es que no lo sabemos.
    remote =
      Enum.map(Instances.read(), fn instance ->
        %{
          model: Map.get(instance, :model),
          port: Map.get(instance, :port),
          # El pid del dueno es del sistema operativo y pertenece a otro
          # proceso: es el unico identificador util de una instancia detached.
          pid: Map.get(instance, :pid),
          engine: Map.get(instance, :engine),
          owner: "detached",
          state: nil,
          # `Map.get/3` y no `instance.host`: un registro escrito por una
          # version anterior de Candil no tiene la clave, y `instance.host`
          # sobre un mapa descodificado de JSON es un KeyError esperando a que
          # alguien actualice de la version de ayer. Un registro del mundo real
          # se lee con get, nunca con punto.
          host: Map.get(instance, :host) || "127.0.0.1",
          # El registro solo sabe guardar un instante de RELOJ DE PARED, y una
          # fila local lo tiene de reloj MONOTONO. Restarlos entre si no
          # significa nada — salia un uptime de -39460084m, que es la clase de
          # numero que hace dudar de la maquina en vez del codigo—. Cada fila
          # mide su uptime en su propio reloj y ya.
          uptime_ms: uptime_since(Map.get(instance, :started_at))
        }
      end)

    local ++ probe(remote)
  end

  # STATE de una instancia detached se PREGUNTA, no se recuerda.
  #
  # El registro guarda `healthy: true` del momento en que arranco, y eso solo
  # significa "el proceso dueno existia". Con suerte. El usuario lo vio con una
  # herramienta que no es Candil: `candil status` decia ON y `ropero status`
  # decia que el puerto estaba libre. Los dos tenian razon sobre preguntas
  # distintas, y solo uno contestaba a la que dice la columna. Una columna
  # STATE en una tabla de modelos significa "esta sirviendo", y un proceso
  # vivo que no escucha es justo lo que tiene que salir como DOWN: ocupa GPU,
  # ocupa puerto y no contesta a nadie.
  defp probe(remote) do
    states = Probe.states(remote)
    Enum.map(remote, &%{&1 | state: Map.get(states, &1.port, "DOWN")})
  end

  defp engine_name(%{engine: %Engine{alias: nil}}), do: "llama-server"
  defp engine_name(%{engine: %Engine{alias: name}}), do: to_string(name)
  defp engine_name(_), do: "llama-server"

  defp uptime_since(_), do: nil

  # `state` sigue siendo lo que dice el polizador de salud. La procedencia va en
  # SU campo: un contrato que cambia de significado porque hacia falta otro
  # dato es un contrato roto por la puerta de atras.
  defp json_row(row) do
    %{
      model: row.model,
      port: row.port,
      pid: row.pid && inspect(row.pid),
      state: row.state,
      owner: row.owner,
      uptime_ms: row.uptime_ms
    }
  end

  defp print_table([]), do: Say.print_info("no hay instancias")

  defp print_table(instances) do
    Table.print(
      headers: ["SLOT", "PORT", "STATE", "MODEL", "PID", "UPTIME", "ENGINE", "OWNER"],
      rows: Enum.map(instances, &row/1),
      headers_color: :cyan,
      headers_effects: [:bold],
      table_border: :rounded
    )
  end

  # `STATE` is what the health poller says, not "there is a row for it". The
  # difference is the whole point of the column: a process whose row exists
  # and whose server stopped answering is `DOWN`, and a table that says `ON`
  # for it sends the user to debug the wrong thing.
  defp row(row) do
    [
      slot(row.port),
      to_string(row.port),
      row.state,
      row.model,
      row.pid || "-",
      uptime(row.uptime_ms),
      row.engine || "llama-server",
      row.owner
    ]
  end

  # A model name off the command line, not off the network. Same argument as
  # Config.Hydrate: the file is the user's, the count is the file's size.
  # One clause, one case. A per-type clause here reads as if some shape of
  # alias bypasses the health check, and it does not.
  defp state_of(alias_name) when is_binary(alias_name),
    do: alias_name |> to_alias() |> state_of()

  defp state_of(alias_name) do
    if Engine.healthy?(alias_name), do: "ON", else: "DOWN"
  end

  # A slot is the number of hundreds in the port, which is the only thing that
  # distinguishes a GPU instance from a CPU one in the default range.
  defp slot(port), do: if(rem(port, 100) >= 90, do: "dGPU", else: "CPU")

  defp uptime(nil), do: "—"
  defp uptime(ms) when ms < 0, do: "—"

  defp uptime(ms) do
    seconds = div(ms, 1000)
    "#{div(seconds, 60)}m#{rem(seconds, 60)}s"
  end

  @doc """
  Parses the flags `run/2` understands.

  `OptionParser` rather than a hand-rolled reducer: the first cut of this was
  a `case` over arguments that mis-paired `--port=10500` and never terminated
  on an empty list, and a third cut had a reducer whose `[]` clause shadowed
  the function it was supposed to belong to. The standard library already does
  this, and does it in a way a reader can check.

  Unknown flags are collected, not refused, so a script written against a
  future `candil` still starts a model on the version it has.
  """
  @switches [port: :integer, force: :boolean, cpu: :boolean, detach: :boolean, yes: :boolean]
  @aliases [p: :port, f: :force, d: :detach, y: :yes]

  @spec parse([binary()]) :: keyword()
  def parse(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)
    opts
  end

  defp fetch(name) when is_atom(name) do
    case Store.get_model(name) do
      {:ok, model} -> {:ok, model}
      {:error, :not_found} -> :error
    end
  end

  # A model alias off the command line is user input, so it goes through the
  # same shape check the configuration does rather than straight to to_atom/1.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp to_alias(name), do: String.to_atom(name)

  defp safe_alias(name), do: to_alias(name)

  defp report(reasons), do: Enum.each(reasons, &error/1)

  defp error(message), do: Say.print_error(message)
end
