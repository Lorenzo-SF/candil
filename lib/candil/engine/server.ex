defmodule Candil.Engine.Server do
  @moduledoc """
  GenServer that manages a single `llama-server` OS process.

  Each running model occupies one `Server` process. The server is registered
  in `Candil.Registry` under the model alias so callers can look it up
  by name.

  The OS process is started with `Port.open/2` and monitored. If the process
  dies unexpectedly the GenServer terminates, which causes the Registry entry
  to be removed automatically.
  """

  use GenServer

  alias Candil.Engine

  @startup_timeout_ms 30_000
  @health_poll_ms 500

  @type state :: %{
          engine: Engine.t(),
          model: Candil.Model.t(),
          port: port(),
          base_url: binary(),
          healthy: boolean(),
          startup_timer: reference() | nil
        }

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{model: model} = init_arg) do
    registry = registry()
    GenServer.start_link(__MODULE__, init_arg, name: {:via, Registry, {registry, model.alias}})
  end

  @impl GenServer
  def init(%{engine: engine, model: model}) do
    args = build_args(engine, model)
    binary = Engine.binary_path(engine)
    base_url = "http://#{engine.host}:#{engine.port}"

    port =
      Port.open(
        {:spawn_executable, binary},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    timer = Process.send_after(self(), :startup_timeout, @startup_timeout_ms)

    state = %{
      engine: engine,
      model: model,
      port: port,
      base_url: base_url,
      healthy: false,
      startup_timer: timer
    }

    send(self(), :poll_health)
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
  def handle_info(:poll_health, %{base_url: url, healthy: false, startup_timer: timer} = state) do
    case do_health_check(url) do
      :ok ->
        _ = Process.cancel_timer(timer)
        {:noreply, %{state | healthy: true, startup_timer: nil}}

      :not_ready ->
        Process.send_after(self(), :poll_health, @health_poll_ms)
        {:noreply, state}
    end
  end

  def handle_info(:poll_health, state) do
    {:noreply, state}
  end

  def handle_info(:startup_timeout, %{healthy: false, port: os_port, model: model} = state) do
    if Port.info(os_port) != nil do
      Port.close(os_port)
    end

    {:stop, {:startup_timeout, model.alias}, state}
  end

  def handle_info(:startup_timeout, state) do
    {:noreply, state}
  end

  def handle_info({os_port, {:data, _output}}, %{port: os_port} = state) do
    {:noreply, state}
  end

  def handle_info({os_port, {:exit_status, code}}, %{port: os_port, model: model} = state) do
    {:stop, {:engine_exited, code, model.alias}, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: os_port}) do
    if Port.info(os_port) != nil do
      Port.close(os_port)
    end

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

  defp do_health_check(base_url) do
    case Req.get("#{base_url}/health", receive_timeout: @startup_timeout_ms) do
      {:ok, %{status: 200}} -> :ok
      _ -> :not_ready
    end
  end

  @doc """
  Returns the Registry module to use for engine registration.

  Can be configured via application config:

      config :candil, :registry, MyApp.CustomRegistry

  Defaults to `Candil.Registry`.
  """
  @spec registry() :: module()
  def registry do
    Application.get_env(:candil, :registry, Candil.Registry)
  end
end
