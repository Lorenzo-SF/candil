defmodule Candil.Scheduler do
  @moduledoc """
  Colocación y expulsión de modelos en dispositivos (8b, scheduler).

  Dado un conjunto de dispositivos libres y los modelos que ya están
  corriendo, decide **dónde** va un modelo nuevo y **qué** (si algo) hay que
  expulsar. Es una función pura: devuelve la decisión, no la ejecuta. Quien
  ejecuta es `Candil.Engine` / `Candil.EnginePool`.

  ## Las tres reglas (07-local-aparcado §3)

  1. **Si cabe, no se toca nada.** Nunca expulsar por tener sitio libre.
  2. **Si no cabe, la víctima más barata** — la que menos se usa y, a
     igualdad de antigüedad, la más pequeña que haga falta para dejar hueco.
     Un embedder de 1,8 GB se repone en segundos; un coder de 12 GB, no.
  3. **Nunca expulsar lo que está en uso ni lo que tiene un pin.**

  ## Por qué dos capas

  La **colocación** (dado un conjunto de dispositivos libres, ¿dónde va este
  modelo?) es un problema de empaquetado: con dos GPUs de 16 GB, 12 + 12 cabe
  entero y no se expulsa nada. La **expulsión** solo ocurre cuando no cabe en
  ninguna. La política depende de la topología, así que no puede ser una
  constante.

  ## Forma de la decisión

  - `{:ok, device_index}` — cabe tal cual, sin tocar nada.
  - `{:evict, [model_alias, ...], device_index}` — no cabe; expulsa esos
    modelos (en ese orden) y coloca el nuevo en `device_index`.
  - `{:error, :no_room}` — no cabe y no hay víctima expulsable que haga hueco.
  """

  @type device :: %{
          index: non_neg_integer(),
          name: String.t(),
          total_mb: non_neg_integer() | nil,
          free_mb: non_neg_integer() | nil,
          usable: boolean()
        }

  @type instance :: %{
          model_alias: term(),
          # `nil` = no se sabe en qué dispositivo está (modelo de CPU, o
          # `nvidia-smi` no lo lista). No es «device 0»: es un hecho distinto.
          device_index: non_neg_integer() | nil,
          size_mb: non_neg_integer(),
          in_use: boolean(),
          pinned: boolean(),
          last_used_at: DateTime.t() | nil
        }

  @type decision ::
          {:ok, non_neg_integer() | :proceed}
          | {:evict, [term()], non_neg_integer()}
          | {:error, :no_gpu}
          | {:error, :no_room}

  @doc """
  Decide dónde colocar un modelo de `size_mb` megas.

  `devices` es la lista de dispositivos (de `Candil.Detector.Devices`).
  `instances` es la lista de modelos ya corriendo, cada uno con su
  dispositivo, tamaño, si está en uso y si tiene pin.

  ## Ejemplos

      iex> devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 10_000, usable: true}]
      iex> Candil.Scheduler.place(4_000, devices, [])
      {:ok, 0}

      iex> devices = [%{index: 0, name: "GPU0", total_mb: 16_000, free_mb: 0, usable: true}]
      iex> instances = [%{model_alias: :embedder, device_index: 0, size_mb: 1_800, in_use: false, pinned: false, last_used_at: nil}]
      iex> Candil.Scheduler.place(1_800, devices, instances)
      {:evict, [:embedder], 0}

      iex> Candil.Scheduler.place(0, [], [])
      {:ok, :proceed}
  """
  @spec place(non_neg_integer(), [device()], [instance()]) :: decision()
  def place(0, _devices, _instances), do: {:ok, :proceed}

  def place(size_mb, devices, instances) when is_integer(size_mb) and size_mb >= 0 do
    usable_devices = Enum.filter(devices, & &1.usable)

    fitting = Enum.filter(usable_devices, fn d -> (d.free_mb || 0) >= size_mb end)

    if fitting != [] do
      device = Enum.max_by(fitting, fn d -> d.free_mb || 0 end)
      {:ok, device.index}
    else
      evict(size_mb, usable_devices, instances)
    end
  end

  @doc """
  Planifica la colocación de un modelo: detecta los dispositivos, lee las
  instancias que corren, y devuelve la decisión del scheduler.

  Es el puente entre la función pura (`place/3`) y el mundo: quien llama
  ejecuta la decisión (para los `{:evict, ...}` y `{:ok, _}`).

  Si el modelo no pide VRAM (`size_mb == 0`, típicamente un modelo de CPU
  puro), devuelve `{:ok, :proceed}` sin mirar dispositivos: no hay nada que
  colocar ni que expulsar.

  Si pide VRAM y **no hay GPU** (sin devices usables, o sin `nvidia-smi`),
  devuelve `{:error, :no_gpu}`. Y si hay GPU pero no cabe,
  `{:error, :no_room}`. Son hechos distintos: el primero se resuelve con
  `--cpu`, el segundo no.

  Devuelve `{:ok, :proceed}` si no hay que hacer nada especial, o la
  decisión de `place/3`.
  """
  @spec plan(Candil.Model.t()) :: decision()
  def plan(%Candil.Model{} = model) do
    # Un modelo de CPU no pide VRAM: no hay nada que colocar. Sin esto, con la
    # GPU llena, un modelo de CPU se rechazaba con `:no_room` — y un modelo que
    # corre en CPU no puede quedarse sin arrancar por falta de GPU.
    if model.gpu_layers == 0 do
      {:ok, nil}
    else
      plan_on_gpu(model)
    end
  end

  defp plan_on_gpu(model) do
    size_mb = model.vram_mb || estimate_model_size(model)

    # El ledger tiene que estar al día ANTES de decidir, o la decisión se toma
    # sobre una memoria que ya no existe. La memoria ajena —la que usan
    # procesos que Candil no gestiona— se ajusta aquí.
    #
    # Y la decisión se toma con la cifra **del ledger**, no con la de
    # `nvidia-smi`. No es un detalle: `free_mb` de `nvidia-smi` es lo que hay
    # libre ahora mismo, y el ledger descuenta además el overhead del
    # contexto CUDA (370 MiB) que el motor **nuevo** va a crear. Si uno
    # decidiera con `free_mb` y el otro reservara con `available`, los dos
    # podrían decir cosas distintas: el scheduler «cabe» y la reserva «no
    # cabe», y el modelo no arrancaría con un error que nadie entiende.
    #
    # Con la misma cifra en los dos lados, la respuesta es la misma por
    # construcción: `available` es exactamente lo que le cabe a un motor
    # nuevo, contexto CUDA incluido.
    devices =
      Enum.map(Candil.Scheduler.Devices.detect(), fn device ->
        if device.usable do
          :ok = Candil.Engine.Resource.sync_foreign(device.index)
          %{device | free_mb: Candil.Engine.Resource.available(device.index)}
        else
          device
        end
      end)

    # «No hay GPU» y «no cabe» son **hechos distintos**, y el mensaje tiene
    # que distinguirlos: `--cpu` es la salida del primero, y del segundo no
    # hay salida que no sea liberar memoria.
    #
    # Antes los dos salían como `:no_room`, que en una máquina sin GPU decía
    # «la GPU está llena» cuando la verdad es «aquí no hay GPU».
    if Enum.any?(devices, & &1.usable) do
      place(size_mb, devices, build_instances())
    else
      {:error, :no_gpu}
    end
  end

  @doc false
  @spec instances() :: [instance()]
  def instances, do: build_instances()

  @doc """
  El dispositivo en el que `nvidia-smi` dice que está `os_pid`.

  `usage_by_pid` es el mapa que devuelve `Candil.Detector.Devices.processes/0`
  indexado por PID. Un PID que no está en el mapa —un modelo en CPU, o una
  máquina sin `nvidia-smi`— devuelve `nil`: no se sabe, y no se inventa un 0.
  """
  @spec device_index(pos_integer() | nil, %{optional(pos_integer()) => map()}) ::
          non_neg_integer() | nil
  def device_index(os_pid, usage_by_pid) when is_integer(os_pid) do
    case Map.get(usage_by_pid, os_pid) do
      %{device_index: index} when is_integer(index) -> index
      _ -> nil
    end
  end

  def device_index(_os_pid, _usage_by_pid), do: nil

  @doc """
  La estimación de VRAM de un modelo: un cuarto de MiB por cada 1024 tokens de
  contexto.

  No es una estimación de VRAM: es un **suelo** (y un **mutex**) para cuando
  el modelo no declara `vram_mb`. La verdad la da `llama-fit-params` al
  arrancar, y por eso el número que se usa de verdad se recalcula en cada
  arranque. Ver P-10.

  Vive aquí y no en dos sitios: el scheduler la usa para decidir y
  `Candil.Engine` la usa como mutex, y dos copias de la misma fórmula son dos
  cifras que acabarán discrepando.
  """
  @spec estimate_model_size(Candil.Model.t()) :: non_neg_integer()
  def estimate_model_size(%Candil.Model{context_size: ctx}) when is_integer(ctx) and ctx > 0 do
    div(ctx, 1024) * 4
  end

  def estimate_model_size(_), do: 0

  defp build_instances do
    usage_by_pid = process_usage_by_pid()

    Candil.EnginePool.list()
    |> Enum.map(fn entry ->
      model = entry.model
      size_mb = (model && model.vram_mb) || estimate_model_size(model) || 0

      %{
        model_alias: entry.alias,
        device_index: device_index_for(entry, usage_by_pid),
        size_mb: size_mb,
        in_use: false,
        pinned: (model && model.exclusive == true) || false,
        last_used_at: nil
      }
    end)
  end

  # La VRAM y la tarjeta de cada proceso, por PID del sistema operativo.
  # `EnginePool` guarda el PID del GenServer; `Engine.os_pid/1` lo traduce al
  # PID del SO, que es el que `nvidia-smi` conoce.
  defp process_usage_by_pid do
    case Candil.Detector.Devices.processes() do
      {:ok, procesos} -> Map.new(procesos, &{&1.pid, &1})
      {:error, _reason} -> %{}
    end
  end

  # En qué GPU está un motor: lo dice `nvidia-smi` por PID, no el puerto. Un
  # puerto no es hardware; la heurística vieja (`rem(port, 100) >= 90`) acertaba
  # en una máquina de una sola GPU por casualidad y mandaba todo al device 0 en
  # una de dos.
  #
  # `nil` cuando no se puede saber: un modelo en CPU no aparece en
  # `nvidia-smi`, y sin `nvidia-smi` no hay medición. `nil` no expulsa, que es
  # lo correcto cuando no se sabe qué ocupa la GPU.
  defp device_index_for(entry, usage_by_pid) do
    case entry.pid do
      beam_pid when is_pid(beam_pid) ->
        device_index(Candil.Engine.os_pid(beam_pid), usage_by_pid)

      _ ->
        nil
    end
  end

  defp evict(_size_mb, [], _instances), do: {:error, :no_room}

  defp evict(size_mb, devices, instances) do
    # Para cada dispositivo, calcular el conjunto mínimo de víctimas
    # (las menos usadas, más pequeñas) que libera suficiente espacio.
    candidates_per_device =
      Enum.map(devices, fn device ->
        device_instances = Enum.filter(instances, &(&1.device_index == device.index))
        evictable = Enum.filter(device_instances, fn i -> not i.in_use and not i.pinned end)

        needed = size_mb - (device.free_mb || 0)

        if needed <= 0 do
          {:ok, [], device.index}
        else
          # Ordenar por menos usado (nil = nunca usado = primero), luego por tamaño.
          sorted = Enum.sort_by(evictable, fn i -> {usage_key(i.last_used_at), i.size_mb} end)
          {victims, freed} = accumulate(sorted, needed, [], 0)

          if freed >= needed do
            {:ok, victims, device.index}
          else
            {:insufficient, victims, device.index}
          end
        end
      end)

    # Elegir el dispositivo con menos víctimas (y, a igualdad, menos megas).
    best =
      candidates_per_device
      |> Enum.filter(fn
        {:ok, _, _} -> true
        _ -> false
      end)
      |> Enum.min_by(
        fn {:ok, victims, _} ->
          {length(victims), Enum.sum(Enum.map(victims, & &1.size_mb))}
        end,
        fn -> nil end
      )

    case best do
      nil -> {:error, :no_room}
      {:ok, [], device_index} -> {:ok, device_index}
      {:ok, victims, device_index} -> {:evict, Enum.map(victims, & &1.model_alias), device_index}
    end
  end

  defp accumulate([], _needed, acc, freed), do: {Enum.reverse(acc), freed}

  defp accumulate(_rest, needed, acc, freed) when freed >= needed do
    {Enum.reverse(acc), freed}
  end

  defp accumulate([candidate | rest], needed, acc, freed) do
    accumulate(rest, needed, [candidate | acc], freed + candidate.size_mb)
  end

  # nil = nunca usado → se evicta primero (menos valioso).
  defp usage_key(nil), do: {0, 0}
  defp usage_key(%DateTime{} = dt), do: {1, DateTime.to_unix(dt, :millisecond)}
end
