defmodule Candil.Engine.Server do
  @moduledoc """
  GenServer that supervises a single `llama-server` OS process.

  The OS process itself is owned by `Arrea.LongRunning`, which gives us
  for free:

    * Registration in `Arrea.Registry` under `id_for/2`: the MODEL alias and the
      port the engine actually bound to
      so other apps can `Arrea.LongRunning.state(id)` / `health(id)` /
      `stop(id)` without going through Candil.
    * Telemetry events on `[:arrea, :long_running, ...]` for started /
      stopped / crashed / data.
    * Automatic port cleanup on crash (Arrea links the port and the
      GenServer; if the binary dies, Arrea dies, and the link cascade
      kills this GenServer too).
    * Crash isolation — but from two supervisors, not one, and the previous
      version of this bullet said only `Arrea.WorkerSupervisor`, which was
      wrong about half of it. The OS process runs under
      `Arrea.WorkerSupervisor` because `Arrea.LongRunning.start/1` puts
      it there. *This* GenServer runs under `Candil.EngineSupervisor`, a
      `DynamicSupervisor` that Candil owns. Both are `:one_for_one`, so the
      property holds; attributing it to Arrea alone made a host reading this
      think it could find these processes in Arrea's tree, and it cannot.

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

  require Logger

  alias Candil.Engine

  alias Arrea.LongRunning

  alias Candil.Engine.{HealthPoller, Server.Args}

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

    case LongRunning.start_link(
           # El puerto va dentro del id a proposito: `Arrea.LongRunning`
           # emite la salida del engine por telemetria con solo el `id`, y sin
           # el puerto quien la escucha no sabe en que log escribirla.
           id: id_for(model, engine),
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
         ) do
      {:ok, lr_pid} ->
        state = %{
          engine: engine,
          model: model,
          base_url: base_url,
          lr_pid: lr_pid,
          healthy: false
        }

        Process.send_after(self(), :poll_health, HealthPoller.poll_interval())
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:health, _from, state), do: HealthPoller.handle_health_call(state)

  def handle_call(:base_url, _from, state),
    do: HealthPoller.handle_base_url_call(state, state.base_url)

  @impl GenServer
  def handle_info(:poll_health, state), do: HealthPoller.handle_poll_health(state)

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  # El id de Arrea, en UN sitio, y con cada campo de donde le toca: el ALIAS
  # del modelo y el PUERTO del engine.
  #
  # No son el mismo campo. El modelo se llama `analyst` y su engine se llama
  # `llama_cpp`; el engine escucha en el puerto que ha resuelto la CLI para el
  # slot. Con el alias del engine, el log del motor se llamaba
  # `llama_cpp-9990.log` —un fichero por engine, no por modelo, con un nombre
  # que no le corresponde a nadie— mientras el titular anunciaba
  # `analyst-9990.log` y escribia ahi. Dos nombres para el mismo log, y el que
  # se anuncia no es el que se escribe.
  #
  # Con `Model.port` en vez de `engine.port` el id decia 9999 mientras el
  # proceso escuchaba en 9990, `terminate/2` iba a parar un id que no existia, y
  # el proceso se quedaba vivo sin que `candil stop` lo alcanzara. Con `coder`
  # los tres coincidian y no se notaba.
  def id_for(%{alias: model_alias}, %{port: port}), do: {:candil_engine, model_alias, port}

  @impl GenServer
  def terminate(_reason, %{model: model, engine: engine}) do
    # Explicit cleanup so the OS process goes away when Candil asks it
    # to. If we got here because the link already died (port crashed),
    # this returns {:error, :not_found} harmlessly.
    # El id sale del MODELO y del ENGINE, cada uno de donde le toca: ver `id_for/2`.
    _ = LongRunning.stop(id_for(model, engine))
    :ok
  end

  defp build_args(%Engine{start_args: engine_args, host: host, port: port} = engine, model) do
    {model_args, cpu_report} = Args.for_cpu(model_args(model), engine.cpu)
    announce_cpu_overrides(model, cpu_report)

    if String.contains?(model.model_dir, "..") or String.contains?(model.filename, "..") do
      raise ArgumentError, "model path must not contain path traversal (..)"
    end

    model_path = Path.join(model.model_dir, model.filename)
    context = to_string(model.context_size || 4096)

    base =
      [
        "--model",
        model_path,
        "--ctx-size",
        context,
        "--host",
        host,
        "--port",
        to_string(port),
        "--alias",
        to_string(model.alias)
      ] ++ api_key_args(engine)

    base ++ model_args ++ engine_args
  end

  # ── `--cpu`: lo que de verdad significa ir a CPU ──────────────────────────
  #
  # Sin esto, `--cpu` era un flag que se parseaba, se validaba y no se leia en
  # ningun sitio. El modelo se lanzaba con SUS `model_args`, incluidos los de
  # GPU, y con `--n-gpu-layers 99` de la config lo que pasaba era:
  #
  #     failed to fit params to free device memory:
  #       n_gpu_layers already set by user to 99, abort
  #     allocating 12005.90 MiB on device 0: cudaMalloc failed: out of memory
  #
  # Es decir:Candil decia "lo voy a poner en CPU" mientras el modelo intentaba
  # subir 12 GB a una GPU que ya tenia 14 GB cogidos. Y llama-server decia,
  # en su propia linea de aviso, que si NO le fijaras el numero se habria
  # ajustado solo. El flag del usuario le quitaba justo la capacidad de
  # adaptarse.
  #
  # Asi que `--cpu` pone `--n-gpu-layers 0` —no "lo que quepa", sino CPU, que
  # es lo que significa el flag— y quita los flags que solo tienen sentido en
  # GPU. El resto de la configuracion del modelo se respeta: muestreo, cache y
  # eso valen igual en CPU.
  #
  # Y AVISA de lo que ha pisado, porque modificar la configuracion de alguien
  # en silencio es la forma de perder su confianza el dia que algo va mal.
  defp announce_cpu_overrides(model, {forced, unknown}) do
    if forced != [] do
      Logger.warning(
        "--cpu en #{model.alias}: #{Enum.join(forced, ", ")} puestos a CPU. " <>
          "El toml los pedia en GPU y hay otra cosa en la tarjeta."
      )
    end

    # Lo que huele a GPU y no conozco se DICE. Una regla que hace la mitad del
    # trabajo en silencio es peor que una que dice cual no hace.
    if unknown != [] do
      Logger.warning(
        "--cpu en #{model.alias}: no conozco #{Enum.join(unknown, ", ")} y huele a GPU. " <>
          "Pasan tal cual. Dime que significan y los anado a la regla."
      )
    end

    :ok
  end

  # `--api-key` is only added when the engine configures one, so a server
  # started without it behaves exactly as before. The flag has to be on the
  # command line and not only in the request headers: a server started with
  # it answers 401 to anything that does not send a matching bearer, and
  # Candil is not the only thing that may need to talk to it.
  defp api_key_args(%Engine{} = engine) do
    case Engine.api_key(engine) do
      nil -> []
      key -> ["--api-key", key]
    end
  end

  defp model_args(%{model_args: args}) when is_list(args), do: args
  defp model_args(_), do: []

  defp model_dir_safe(%{model_dir: nil}), do: "."
  defp model_dir_safe(%{model_dir: dir}) when is_binary(dir), do: dir
end
