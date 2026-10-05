defmodule Candil.Engine.Log do
  @moduledoc """
  Puts the engine's own output where a person can read it.

  ## Why

  `Arrea.LongRunning` spawns the engine with `stderr_to_stdout` and hands the
  text to `[:arrea, :long_running, :data]`. It also emits
  `[:arrea, :long_running, :crashed]` with the reason the child died. **Nobody
  subscribed to either.** So when `llama-server` refused to start, the one
  line that said why — an unknown flag, a missing mmproj, a VRAM overflow —
  went nowhere, and the holder's log contained nothing but the holder's own
  summary of the symptom.

  That cost an evening. The path was announced by `run --detach`, the file
  existed, and it was empty of the only information that mattered. A log that
  is not where the problem is explained is worse than no log, because it looks
  like you already looked.

  ## What lands there

  Per model and port, under `Instances.log_dir/`. A 17 GB model prints a few
  thousand lines while it loads, and that is the point: if it fails, the reason
  is in the last twenty.

  ## Why the id carries the port

  Telemetry metadata gives the `id` and nothing else. Without the port in it,
  a listener cannot know which file to write to, and would have to guess from a
  registry lookup that is already gone by the time the crash arrives.
  """

  alias Candil.Instances

  require Logger

  @handler_id "candil-engine-log"

  @doc """
  Attaches the handlers. Idempotent, and safe to call from several processes.
  """
  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many(@handler_id, events(), &__MODULE__.handle_event/4, nil)
  catch
    # El logger de telemetria no esta arrancado todavia. Se reintenta en la
    # siguiente llamada; Candil funciona igual sin esto, solo que el log del
    # engine sale vacio.
    :error, _ -> :ok
  end

  # LOS CUATRO, y no solo los dos que se subsided al principio. Un engine que
  # sale con codigo de error es un `{:exit_status, code}`, y Arrea emite
  # `:stopped` para eso — NO `:crashed`, que es solo para el `{:EXIT, port,
  # reason}`. Suscribirse a `data` y `crashed` y creerse que se ve todo es
  # justamente el fallo que hacia que el log saliera vacio.
  defp events do
    [
      [:arrea, :long_running, :data],
      [:arrea, :long_running, :stopped],
      [:arrea, :long_running, :crashed]
    ]
  end

  @doc false
  def handle_event([:arrea, :long_running, :data], %{data: data, id: id}, _config, _pid) do
    write(slot(id), IO.iodata_to_binary(data))
  end

  def handle_event([:arrea, :long_running, :crashed], %{reason: reason, id: id}, _config, _pid) do
    write(slot(id), "\n[candil] el proceso ha muerto: #{inspect(reason)}\n")
  end

  def handle_event([:arrea, :long_running, :stopped], %{id: id} = metadata, _config, _pid) do
    # Un exit con codigo es la salida MAS NORMAL de un binario que se niega a
    # arrancar, y es la que no se estaba registrando. `exit_code: 1` sin mas
    # contexto parece poco, pero va pegado a lo que el engine haya impreso
    # antes, que es donde esta el motivo de verdad.
    code = Map.get(metadata, :exit_code)
    write(slot(id), "\n[candil] el engine ha salido con codigo #{inspect(code)}\n")
  end

  def handle_event(_event, _measurements, _config, _pid), do: :ok

  @doc false
  def slot({:candil_engine, model, port}), do: {to_string(model), port}
  def slot(_other), do: nil

  @doc false
  def write(nil, _text), do: :ok

  def write({model, port}, text) do
    dir = Instances.log_dir()
    # El directorio se crea aqui y no se da por hecho: `run --detach` ANUNCIA
    # esta ruta, y en una maquina donde todavia no se ha arrancado nada el
    # directorio no existe. `File.write/3` no crea directorios padre y falla, y
    # el fallo se come el error del engine, que es justo lo que pretendia
    # guardar. Prometer una ruta y no poder escribir en ella es peor que no
    # prometerla.
    File.mkdir_p!(dir)

    path = Path.join([dir, "#{model}-#{port}.log"])
    File.write(path, text, [:append])
  rescue
    # Un log que no se puede escribir no puede ser motivo para tumbar un modelo
    # que funciona. Aqui `_kind` no es `_` porque Elixir no admite el comodin
    # en la palabra clave de un rescue.
    _kind -> :ok
  end
end
