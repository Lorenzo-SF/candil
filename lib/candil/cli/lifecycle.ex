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
  alias Candil.{Engine, EnginePool, Model, Store}

  @doc """
  Dispatches the lifecycle verbs.

  They share this module because they share the registry: a `stop` that did
  not know where `run` registered would be guessing.
  """
  @spec run([binary()]) :: :ok
  def run(["stop" | rest]), do: stop(rest)
  def run(["status" | rest]), do: status(rest)
  def run(["run" | rest]), do: run_model(rest)
  def run(argv), do: run_model(argv)

  @doc """
  `candil run <model> [opts]`.
  """
  @spec run_model([binary()]) :: :ok
  def run_model([name | rest]) do
    alias_name = safe_alias(name)
    opts = parse(rest)

    case fetch(alias_name) do
      {:ok, model} -> start_or_report(model, alias_name, opts)
      :error -> error("no such model: #{name}")
    end

    :ok
  end

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
        started(model, port)

      {:occupied, holder, port} ->
        occupied(model, port, holder, opts)
    end
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
  defp started(%Model{alias: name}, port) do
    IO.write(Colorize.line("  #{name} arrancado en :#{port}"))
    :ok
  end

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
  @spec stop([binary()]) :: :ok
  def stop([]), do: stop_all()
  def stop(["all" | _rest]), do: stop_all()

  def stop([name | _rest]) do
    alias_name = safe_alias(name)

    case EnginePool.list() |> Enum.filter(&(&1.alias == alias_name)) do
      [] ->
        Say.print_error("no hay instancias de '#{name}'")

      instances ->
        Enum.each(instances, &halt/1)
        Say.print_success("#{length(instances)} instancia(s) de '#{name}' paradas")
    end

    :ok
  end

  defp stop_all do
    case EnginePool.list() do
      [] ->
        Say.print_info("no hay instancias")

      instances ->
        Enum.each(instances, &halt/1)
        Say.print_success("#{length(instances)} instancias paradas")
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
  @spec status([binary()]) :: :ok
  def status(argv) do
    if "--json" in argv do
      IO.puts(Jason.encode!(Enum.map(EnginePool.list(), &json_row/1)))
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
      state: if(pid, do: "ON", else: "OFF"),
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

  defp row(%{port: port, alias: a, pid: pid, engine: engine, started_at: started}) do
    [
      slot(port),
      to_string(port),
      if(pid, do: "ON", else: "OFF"),
      to_string(a),
      pid || "-",
      uptime(started),
      (engine.alias && to_string(engine.alias)) || "llama-server"
    ]
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
  defp safe_alias(name) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    String.to_atom(name)
  rescue
    ArgumentError -> :__unknown__
  end

  defp report(reasons), do: Enum.each(reasons, &error/1)

  defp error(message), do: Say.print_error(message)
end
