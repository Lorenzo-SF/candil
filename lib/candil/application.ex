defmodule Candil.Application do
  @moduledoc """
  OTP application for `Candil`.

  Starts the ETS-based catalogue (`Candil.Store`), the shared conversation
  store (`Candil.Context`), and the dynamic supervisor that manages
  llama-server engines started via `Candil.start_engine/2`.

  `Candil.Store` comes before `Candil.Context` because the other children
  read its tables, and a supervision order that gets this backwards produces
  a table that is sometimes there.

  Note: `Arrea.Application` is NOT listed here because `Arrea` is a direct
  dependency of Candil (`mix.exs` → `{:arrea, "~> 2.1.0"}`) and its
  `mix.exs` declares `mod: {Arrea.Application, []}`. The OTP application
  controller starts `Arrea.Application` automatically as soon as the
  application graph boots — no manual `Arrea.Supervisor.start_link/1` call
  is required. The supervision tree it brings up (Registry, Monitor,
  Leader, `Arrea.WorkerSupervisor`) is available before `Candil.Application`
  starts its own children.
  """

  use Application

  require Logger

  alias Candil.Config, as: CandilConfig
  alias Candil.Config.Hydrate, as: Hydrate

  @impl true
  def start(_type, _args) do
    # The catalogue is read from candil.toml before anything else starts, so
    # that `Store` is populated by the time a command looks at it. Without this
    # the file is parsed by `Config.File` and then thrown away, and every
    # `candil models list` prints an empty table that looks like a broken
    # configuration.
    children = [
      {Registry, keys: :unique, name: Candil.Registry},
      # Store first: it owns the catalogue tables that the others read.
      Candil.Store,
      Candil.Context,
      Candil.Context.PrefixManager,
      Candil.Router.Cache,
      Candil.Router.Consumer,
      Candil.Cancellation,
      Candil.Tool,
      Candil.EnginePool,
      {DynamicSupervisor, name: Candil.EngineSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Candil.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # AFTER the tree, not before: the catalogue lives in ETS tables that
    # `Candil.Store` creates in its own `init/1`. Hydrating first answers
    # "the table identifier does not refer to an existing ETS table", which is
    # a confusing way to learn that the order was wrong.
    hydrate()

    {:ok, pid}
  end

  # A missing or broken file is not a reason to refuse to boot: a library that
  # will not start without a config file cannot be used as a library. The
  # failure is reported and Candil comes up with an empty catalogue.
  defp hydrate do
    case CandilConfig.File.load() do
      {:ok, config} ->
        result = Hydrate.hydrate(config)
        report(result, config)

      {:error, _reason} ->
        :ok
    end
  rescue
    # A configuration problem is a warning, never a reason to refuse to boot.
    # A library that will not start without a config file cannot be used as a
    # library, and the one moment a user most needs `candil doctor` is the
    # moment their config is wrong.
    error ->
      Logger.warning("Candil: no se pudo cargar la configuracion: #{Exception.message(error)}")
  end

  # `Hydrate.hydrate/1` does not return an `:errors` count — it returns the
  # three sections, each one a list of entries that are either an alias or an
  # error tuple. Counting the tuples is the whole job, and reading a key that
  # is not there is how this logged "0 entradas" over a list of three.
  defp error_entry?({:error, _, _}), do: true
  defp error_entry?(_), do: false

  defp report(result, _config) do
    bad =
      [result.engines, result.models, result.providers]
      |> Enum.flat_map(fn section -> Enum.filter(section, &error_entry?/1) end)

    case bad do
      [] ->
        :ok

      bad ->
        Logger.warning(
          "Candil: #{length(bad)} entrada(s) del fichero de configuracion no se pudieron " <>
            "registrar: " <>
            Enum.map_join(bad, ", ", fn {_section, name, reasons} ->
              "#{name} (#{List.first(reasons)})"
            end)
        )
    end
  end
end
