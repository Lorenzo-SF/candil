defmodule Candil.Application do
  @moduledoc """
  OTP application for `Candil`.

  Starts the ETS-based configuration registry (`Candil.Config`) and
  the dynamic supervisor that manages llama-server engines started
  via `Candil.start_engine/2`.

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
      Candil.Config,
      {DynamicSupervisor, name: Candil.EngineSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Candil.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
