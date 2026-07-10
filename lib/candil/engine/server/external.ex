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

  @health_poll_ms 5_000

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

    Process.send_after(self(), :poll_health, @health_poll_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:health, _from, %{healthy: healthy} = state) do
    {:reply, if(healthy, do: :ok, else: :not_ready), state}
  end

  def handle_call(:base_url, _from, %{base_url: url} = state) do
    {:reply, url, state}
  end

  @impl GenServer
  def handle_info(:poll_health, state) do
    healthy = probe_health(state.base_url)
    Process.send_after(self(), :poll_health, @health_poll_ms)
    {:noreply, %{state | healthy: healthy}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{pid: nil}), do: :ok

  def terminate(_reason, %{pid: pid}) do
    Process.exit(pid, :shutdown)
    :ok
  end

  defp probe_health(base_url) do
    case Req.get("#{base_url}/health", receive_timeout: 1_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end
end
