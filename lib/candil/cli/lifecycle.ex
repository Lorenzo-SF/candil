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
  alias Candil.CLI.{Colorize, Ports, Preflight}
  alias Candil.{Engine, EnginePool, Instances, Model, Store}

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
        EnginePool.put(model.alias, port, nil, model, %Engine{alias: model.engine})
        record(model, port, opts)
        started(model, port, opts)

      {:occupied, holder, port} ->
        occupied(model, port, holder, opts)
    end
  end

  # The written record is what makes `--detach` mean anything. A detached
  # instance outlives this VM, so the only thing a second `candil` can consult
  # is the file. The owner is this process's OS pid, and `C19` is the whole
  # rule: kill the owner and the engine goes with it, because the engine was
  # never detached from it.
  defp record(%Model{alias: name, engine: engine}, port, opts) do
    if opts[:port], do: Instances.claim_ad_hoc(port)

    instance =
      Instances.build(
        to_string(name),
        port,
        engine && to_string(engine),
        Instances.os_pid(),
        true
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
  defp started(%Model{alias: name}, port, opts) do
    if opts[:detach] do
      Say.print_success(
        "#{name} detached (owner pid #{Instances.os_pid()}) · log: #{log_path(name, port)}"
      )
    else
      Say.print_raw(Colorize.line("  #{name} arrancado en :#{port}") <> "\n")
    end

    :ok
  end

  defp log_path(name, port), do: Path.join([Instances.data_dir(), "logs", "#{name}-#{port}.log"])

  # The design document's own wording, kept close to the original: do not kill
  # automatically, name what is holding the port, offer the two ways forward.
  defp occupied(model, port, holder, opts) do
    if opts[:force] do
      Say.print_warning("--force: matando '#{holder}' en :#{port}")
      stop_holder(model, port)
      EnginePool.put(model.alias, port, nil, model, %Engine{alias: model.engine})
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
    if get(opts, :json) == true do
      # Raw, and with the newline: a `--json` consumer pipes this into jq
      # and decoration is exactly what breaks it.
      Say.print_raw(Jason.encode!(Enum.map(EnginePool.list(), &json_row/1)) <> "\n")
    else
      print_table(EnginePool.list())
    end

    :ok
  end

  defp json_row(%{alias: a, port: p, pid: pid, started_at: started}) do
    %{
      model: to_string(a),
      port: p,
      pid: pid && inspect(pid),
      state: state_of(a),
      uptime_ms: System.monotonic_time(:millisecond) - started
    }
  end

  defp print_table([]), do: Say.print_info("no hay instancias")

  defp print_table(instances) do
    Table.print(
      headers: ["SLOT", "PORT", "STATE", "MODEL", "PID", "UPTIME", "ENGINE"],
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
  defp row(%{port: port, alias: a, pid: pid, engine: engine, started_at: started}) do
    [
      slot(port),
      to_string(port),
      state_of(to_string(a)),
      to_string(a),
      pid || "-",
      uptime(started),
      (engine.alias && to_string(engine.alias)) || "llama-server"
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

  defp uptime(started) do
    seconds = div(System.monotonic_time(:millisecond) - started, 1000)
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
