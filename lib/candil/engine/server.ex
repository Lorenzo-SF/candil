defmodule Candil.Engine.Server do
  @moduledoc """
  GenServer that supervises a single `llama-server` OS process.

  The OS process itself is owned by `Arrea.LongRunning`, which gives us
  for free:

    * Registration in `Arrea.Registry` under `{:candil_engine, model.alias}`
      so other apps can `Arrea.LongRunning.state(id)` / `health(id)` /
      `stop(id)` without going through Candil.
    * Telemetry events on `[:arrea, :long_running, ...]` for started /
      stopped / crashed / data.
    * Automatic port cleanup on crash (Arrea links the port and the
      GenServer; if the binary dies, Arrea dies, and the link cascade
      kills this GenServer too).
    * Crash isolation via `Arrea.WorkerSupervisor`'s `:one_for_one`
      strategy.

  What this GenServer keeps:

    * The Candil-side `Candil.Registry` registration under the model
      alias (so `Candil.Engine.stop/1`, `healthy?/1`, `base_url/1` keep
      working through the existing API).
    * A cached `healthy` boolean refreshed by a 5s `/health` poll
      (informational; Arrea also runs the probe for telemetry).
    * The `terminate/2` cleanup that calls `Arrea.LongRunning.stop/1`
      explicitly when Candil stops the engine normally.
  """

  use GenServer

  alias Candil.Engine

  alias Arrea.LongRunning

  alias Candil.Engine.HealthPoller

  @type state :: %{
          engine: Engine.t(),
          model: Candil.Model.t(),
          base_url: binary(),
          lr_pid: pid(),
          healthy: boolean()
        }

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{model: model} = init_arg) do
    registry = Engine.registry()
    GenServer.start_link(__MODULE__, init_arg, name: {:via, Registry, {registry, model.alias}})
  end

  @impl GenServer
  def init(%{engine: engine, model: model}) do
    args = build_args(engine, model)
    binary = Engine.binary_path(engine)
    base_url = "http://#{engine.host}:#{engine.port}"

    {:ok, lr_pid} =
      LongRunning.start_link(
        id: {:candil_engine, model.alias},
        binary: binary,
        args: args,
        cd: model_dir_safe(model),
        env: [],
        health: fn ->
          case HealthPoller.probe_health(base_url) do
            true -> :ok
            false -> {:error, :not_ready}
          end
        end
      )

    state = %{
      engine: engine,
      model: model,
      base_url: base_url,
      lr_pid: lr_pid,
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
  def terminate(_reason, %{model: model}) do
    # Explicit cleanup so the OS process goes away when Candil asks it
    # to. If we got here because the link already died (port crashed),
    # this returns {:error, :not_found} harmlessly.
    _ = LongRunning.stop({:candil_engine, model.alias})
    :ok
  end

  defp build_args(%Engine{start_args: engine_args, host: host, port: port}, model) do
    model_path = Path.join(model.model_dir, model.filename)
    context = to_string(model.context_size || 4096)

    base = [
      "--model",
      model_path,
      "--ctx-size",
      context,
      "--host",
      host,
      "--port",
      to_string(port)
    ]

    base ++ model_args(model) ++ engine_args
  end

  defp model_args(%{model_args: args}) when is_list(args), do: args
  defp model_args(_), do: []

  defp model_dir_safe(%{model_dir: nil}), do: "."
  defp model_dir_safe(%{model_dir: dir}) when is_binary(dir), do: dir
end
