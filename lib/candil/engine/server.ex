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

  alias Candil.Engine.HealthPoller

  alias Candil.Model

  @doc false
  @spec args_for(Candil.Engine.t(), Candil.Model.t(), non_neg_integer() | nil, [String.t()] | nil) ::
          [binary()]
  def args_for(engine, model, device, fitted_args),
    do: build_args(engine, model, device, device_name_for(engine, device), fitted_args)

  # El nombre del device, el que publica el motor. Se pregunta aquí porque
  # quien construye los argumentos es quien sabe qué motor va a arrancar.
  defp device_name_for(%Engine{} = engine, device) when is_integer(device) and device >= 0 do
    case Candil.Detector.EngineDevices.name_for(Engine.binary_path(engine), device) do
      {:ok, name} -> name
      {:error, _reason} -> nil
    end
  end

  defp device_name_for(_engine, _device), do: nil

  @type state :: %{
          engine: Engine.t(),
          model: Candil.Model.t(),
          base_url: binary(),
          lr_pid: pid(),
          healthy: boolean(),
          device: non_neg_integer() | nil,
          holder: term() | nil,
          parent: pid() | nil
        }

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{model: model} = init_arg) do
    registry = Engine.registry()
    init_arg = Map.put_new(init_arg, :parent, self())
    GenServer.start_link(__MODULE__, init_arg, name: {:via, Registry, {registry, model.alias}})
  end

  @impl GenServer
  def init(%{engine: engine, model: model} = init_arg) do
    # La reserva de VRAM se libera en `terminate/2`. Sin `trap_exit`, la salida
    # de `LongRunning` —el motor murió, p. ej. OOM— mata este GenServer sin
    # pasar por `terminate/2` y la reserva se queda puesta para siempre.
    Process.flag(:trap_exit, true)

    parent = Map.get(init_arg, :parent)
    device = Map.get(init_arg, :device)
    device_name = Map.get(init_arg, :device_name)
    holder = Map.get(init_arg, :holder)
    fitted_args = Map.get(init_arg, :fitted_args)
    cd = model_dir_safe(model)
    args = build_args(engine, model, device, device_name, fitted_args)
    binary = Engine.binary_path(engine)
    base_url = "http://#{engine.host}:#{engine.port}"

    case LongRunning.start_link(
           id: id_for(model, engine),
           binary: binary,
           args: args,
           cd: cd,
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
          healthy: false,
          device: device,
          holder: holder,
          parent: parent
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

  # El PID del **proceso del sistema operativo** que esta haciendo el motor.
  #
  # El pid del BEAM que devuelve `Engine.start/2` no sirve para esto: quien
  # necesita el del SO es `nvidia-smi`, que responde por PID del SO. Y el
  # registro de `LongRunning` es por VM, asi que desde `candil status` —que es
  # otro proceso— no hay forma de preguntar. Se pregunta **aqui**, que esta en la
  # misma VM que el puerto.
  def handle_call(:os_pid, _from, %{model: model, engine: engine} = state) do
    {:reply, os_pid(id_for(model, engine)), state}
  end

  defp os_pid(id) do
    # El `os_pid` lo pone `Arrea.LongRunning` en su snapshot. Preguntar por el
    # puerto aqui seria repetir en Candil lo que ese modulo ya sabe —y el
    # snapshot lo dice para que nadie tenga que hacerlo-.
    case LongRunning.state(id) do
      {:ok, snapshot} -> Map.get(snapshot, :os_pid)
      {:error, :not_found} -> nil
    end
  end

  @impl GenServer
  def handle_info(:poll_health, state), do: HealthPoller.handle_poll_health(state)

  # `LongRunning` murió: el motor ya no está, y con él la reserva. Parar por
  # la misma razón arrastra `terminate/2`, que es quien la libera.
  def handle_info({:EXIT, pid, reason}, %{lr_pid: pid} = state) do
    {:stop, reason, state}
  end

  # El proceso que arrancó el engine. Un final normal del padre no lo para
  # —igual que un link sin `trap_exit`, donde `:normal` no mata—; uno anormal
  # sí, y pasa por `terminate/2`.
  def handle_info({:EXIT, pid, reason}, %{parent: pid} = state) when reason != :normal do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Como ropero: un 27B en CPU va limitado por hilos, y sin esto tienes un
  # modelo que tecnicamente esta en CPU y tarda cuatro veces mas.
  defp threads_args(%Engine{cpu: true}), do: ["--threads", Integer.to_string(cpu_count())]
  defp threads_args(%Engine{}), do: []

  defp cpu_count do
    case System.cmd("nproc", []) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {n, _} when n > 0 -> n
          _ -> 8
        end

      _ ->
        System.schedulers_online()
    end
  rescue
    _kind -> System.schedulers_online()
  end

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
  def terminate(_reason, %{model: model, engine: engine, device: device, holder: holder}) do
    _ = LongRunning.stop(id_for(model, engine))

    # D-27 sub-paso 3: liberar la reserva del resource si es GPU.
    #
    # Se libera **el titular que llegó con el server**, no uno recalculado
    # aquí: el titular lleva una generación (`make_ref/0`) y `{alias, port}`
    # no es único en el tiempo. Si el puerto se reutiliza y este `terminate/2`
    # llega tarde, un titular recalculado podría soltar la reserva **del
    # modelo nuevo**, que la estaba usando.
    if is_integer(device) and device >= 0 and not (engine.cpu or model.gpu_layers == 0) and
         holder != nil do
      Candil.Engine.Resource.release(device, holder)
    end

    :ok
  end

  defp build_args(
         %Engine{start_args: engine_args, host: host, port: port} = engine,
         model,
         device,
         device_name,
         fitted_args
       ) do
    # `--n-gpu-layers` sale SIEMPRE del campo `gpu_layers` del modelo, nunca
    # de `model_args`: `Hydrate` ya ha sacado el flag de ahi, asi que hay una
    # sola fuente de verdad y `--cpu` no tiene nada que reescribir.
    model_args = model_args(model) ++ ["--n-gpu-layers", to_string(layers(model, engine))]
    announce_cpu_overrides(model, engine)

    model_path = model_path(model)
    context = to_string(model.context_size)

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

    # D-27: Candil elige el device y se lo dice al motor. Con `gpu_layers: 0`
    # o `--cpu` no hay GPU, asi que `--device none` (sin `--main-gpu` ni
    # `--split-mode`). Si hay device, se fuerza un solo device con split
    # desactivado: `--fit` se queda en `on` y el `-1` (si lo hay) se recorta
    # dentro de ese device.
    device_args = device_args_for(engine, model, device, device_name)

    fitted = if is_list(fitted_args) and fitted_args != [], do: fitted_args, else: []

    base ++ device_args ++ model_args ++ threads_args(engine) ++ engine_args ++ fitted
  end

  # La ruta del modelo, la que sabe resolver `Candil.Model.file_path/1`: el
  # `model_dir`/`filename` de siempre, o el `source` cuando el modelo se
  # descargó de otro sitio (y entonces el `model_dir` puede no existir).
  #
  # Antes esto era `Path.join(model.model_dir, model.filename)`: con un modelo
  # declarado solo por `source` —sin `model_dir`— eso no era una ruta, era un
  # error, y el modelo no arrancaba.
  defp model_path(model) do
    case Model.file_path(model) do
      nil ->
        raise ArgumentError,
              "el modelo #{inspect(model.alias)} no tiene fichero: ni model_dir/filename " <>
                "ni source"

      path ->
        path
    end
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
  # Con `--cpu` el campo del modelo vale 0 y ya esta. Y se dice CUAL ERA, para
  # que no parezca que el modelo no tenia GPU: un 99 puesto a 0 sin explicar de
  # donde salio el 99 deja al usuario pensando que se lo hainventado Candil.
  defp layers(model, engine) do
    if engine.cpu do
      Logger.warning(
        "--cpu en #{model.alias}: #{model.gpu_layers} capas a la GPU → 0 (CPU entera)"
      )

      0
    else
      model.gpu_layers
    end
  end

  defp announce_cpu_overrides(_model, _engine), do: :ok

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

  # `--device` con el **nombre que publica el motor** (`CUDA0`, `ROCm0`,
  # `Vulkan0`…), nunca `CUDA#{index}`: eso es la convención de CUDA y es
  # falsa en ROCm, en SYCL y en Vulkan, donde el motor la rechaza con
  # `invalid device` (D-28).
  #
  # Y `--main-gpu` es un **índice**, que es otra coordenada: el que el motor
  # da a sus devices.
  defp device_args_for(%Engine{} = engine, %Model{} = model, device, device_name) do
    cond do
      engine.cpu or model.gpu_layers == 0 ->
        ["--device", "none"]

      is_binary(device_name) and is_integer(device) and device >= 0 ->
        ["--device", device_name, "--split-mode", "none", "--main-gpu", to_string(device)]

      is_integer(device) and device >= 0 ->
        raise ArgumentError,
              "no se sabe el nombre del device #{device}: el motor no se pudo preguntar, " <>
                "y '--device' no acepta índices"

      true ->
        []
    end
  end

  defp model_args(%{model_args: args}) when is_list(args), do: args
  defp model_args(_), do: []

  defp model_dir_safe(%{model_dir: nil}), do: "."
  defp model_dir_safe(%{model_dir: dir}) when is_binary(dir), do: dir
end
