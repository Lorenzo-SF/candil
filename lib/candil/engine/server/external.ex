defmodule Candil.Engine.Server.External do
  @moduledoc """
  GenServer for engines whose OS process is owned by something else.

  This is the Candil-side counterpart of `Candil.Engine.Launcher`:
  it holds the `base_url` and optional `pid` returned by the launcher,
  exposes the same `:health` / `:base_url` call API as
  `Candil.Engine.Server`, polls `<base_url>/health` every 5 seconds
  for `Candil.Engine.healthy?/1`, and — on shutdown — sends `:shutdown`
  to the external pid if one was provided.

  The process is registered in `Candil.Registry` under the model alias,
  so `Candil.Engine.stop/1`, `Candil.Engine.healthy?/1` and
  `Candil.Engine.base_url/1` work uniformly for both local and
  externally-managed engines.
  """

  use GenServer

  alias Candil.Engine
  alias Candil.Engine.HealthPoller

  @type state :: %{
          engine: Engine.t(),
          model: Candil.Model.t(),
          base_url: binary(),
          pid: pid() | nil,
          healthy: boolean()
        }

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{model: model} = init_arg) do
    registry = Engine.registry()
    GenServer.start_link(__MODULE__, init_arg, name: {:via, Registry, {registry, model.alias}})
  end

  @impl GenServer
  def init(%{base_url: base_url, engine: engine, model: model} = args) do
    state = %{
      engine: engine,
      model: model,
      base_url: base_url,
      pid: Map.get(args, :pid),
      healthy: false
    }

    Process.send_after(self(), :poll_health, HealthPoller.poll_interval())
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:health, _from, state), do: HealthPoller.handle_health_call(state)

  def handle_call(:base_url, _from, state),
    do: HealthPoller.handle_base_url_call(state, state.base_url)

  @impl GenServer
  def handle_info(:poll_health, state), do: HealthPoller.handle_poll_health(state)

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{pid: nil}), do: :ok

  def terminate(_reason, %{pid: pid}) do
    Process.exit(pid, :shutdown)
    :ok
  end
end
