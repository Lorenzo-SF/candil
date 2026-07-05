defmodule Candil.Application do
  @moduledoc """
  OTP application for `Candil`.

  Starts the ETS-based configuration registry (`Candil.Config`) and
  the dynamic supervisor that manages llama-server engines started
  via `Candil.start_engine/2`.
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
