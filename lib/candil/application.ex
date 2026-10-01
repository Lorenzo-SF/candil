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

  @impl true
  def start(_type, _args) do
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
    Supervisor.start_link(children, opts)
  end
end
