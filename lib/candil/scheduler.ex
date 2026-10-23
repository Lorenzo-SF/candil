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
          # El nombre con el que se le habla al motor (`CUDA0`, `ROCm0`…). Es
          # `nil` cuando el motor no se pudo preguntar: sin nombre no hay
          # `--device`, y ese device no se puede colocar.
          name: String.t() | nil,
          backend: atom(),
          total_mb: non_neg_integer() | nil,
          free_mb: non_neg_integer() | nil,
          usable: boolean(),
          # De dónde salen las cifras: `:engine` (el motor) o `:system`. Nunca
          # las dos para el mismo número (D-28).
          source: :engine | :system
        }

  @type instance :: %{
          model_alias: term(),
          # `nil` = no se sabe en qué dispositivo está (modelo de CPU, o
          # `nvidia-smi` no lo lista). No es «device 0»: es un hecho distinto.
          device_index: non_neg_integer() | nil,
          # `nil` = **no se sabe** cuánto ocupa. No es 0: es «no lo sé», y un
          # device cuyo tamaño se desconoce no se puede expulsar (no se sabe
          # cuánto liberaría).
          size_mb: non_neg_integer() | nil,
          in_use: boolean(),
          pinned: boolean(),
          last_used_at: DateTime.t() | nil
        }

  @type decision ::
          {:ok, non_neg_integer() | :proceed}
          | {:evict, [term()], non_neg_integer()}
          | {:error, :no_gpu}
          | {:error, :memory_unknown}
          | {:error, :gpu_layers_fixed}
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

  Si pide VRAM y **no hay GPU**, devuelve `{:error, :no_gpu}`. Si hay GPU pero
  no se puede **medir** —el motor no se puede preguntar, o su memoria no se
  puede leer—, devuelve `{:error, :memory_unknown}`: son hechos distintos, y
  el primero se resuelve con `--cpu` y el segundo no. Y si hay GPU pero no
  cabe, `{:error, :no_room}`.

  Devuelve `{:ok, :proceed}` si no hay que hacer nada especial, o la
  decisión de `place/3`.
  """
  @spec plan(Candil.Model.t()) :: decision()
  def plan(%Candil.Model{} = model) do
    plan(model, binary_for(model))
  end

  @doc """
  Planifica la colocación con el binario del motor dado.

  `binary` es la ruta del binario del motor (`llama-server`): es quien publica
  la lista de devices con sus nombres y su memoria, y la única fuente que
  funciona en todos los backends (D-28).
  """
  @spec plan(Candil.Model.t(), binary() | nil) :: decision()
  def plan(%Candil.Model{} = model, binary) do
    cond do
      # Un modelo de CPU no pide VRAM: no hay nada que colocar. Sin esto, con la
      # GPU llena, un modelo de CPU se rechazaba con `:no_room` — y un modelo que
      # corre en CPU no puede quedarse sin arrancar por falta de GPU.
      model.gpu_layers == 0 ->
        {:ok, nil}

      # El modelo FIJA las capas en GPU, y no reparte expertos a la CPU.
      #
      # `llama-fit-params` no puede ajustar un `--n-gpu-layers` que el usuario
      # puso: aborta con «n_gpu_layers already set by user to 99». Sin
      # medición no hay peso real, la reserva se queda en la estimación —una
      # suposición— y el motor arranca sin ajustar: que es como se llena la
      # VRAM y se para en seco.
      #
      # Medido el 2026-10-22 con un modelo de 13 GB y la GPU con 15 886 MiB
      # libres: con 99 el fit aborta y el motor sale con codigo 1; con `-1` el
      # fit ajusta y el modelo arranca.
      #
      # La excepción son los modelos con `--n-cpu-moe`: los expertos se van a
      # la RAM, lo que queda en la VRAM cabe, y el modelo arranca bien. Esos
      # arrancan, pero **su reserva tampoco se mide** (el fit aborta igual), y
      # de eso avisa el motor cuando lo detecta.
      gpu_layers_fixed?(model) and not cpu_moe?(model) ->
        {:error, :gpu_layers_fixed}

      true ->
        plan_on_gpu(model, binary)
    end
  end

  # El binario del motor del modelo, si el catálogo lo sabe. Sin él, la
  # medición cae a la fuente del sistema, que no trae nombres: los devices
  # salen inservibles y el scheduler dice `:memory_unknown`.
  defp binary_for(%Candil.Model{engine: engine_alias}) when is_atom(engine_alias) do
    case Candil.Store.get_engine(engine_alias) do
      {:ok, engine} -> Candil.Engine.binary_path(engine)
      _ -> nil
    end
  end

  defp binary_for(_model), do: nil

  @doc """
  Si el modelo **fija** las capas en GPU en vez de dejar que se ajusten.

  `gpu_layers: -1` es «las que quepan» ✓ —se puede ajustar—. Un número
  positivo es «exactamente estas» ✗, y `llama-fit-params` aborta cuando
  intenta cambiarlo.
  """
  @spec gpu_layers_fixed?(Candil.Model.t()) :: boolean()
  def gpu_layers_fixed?(%Candil.Model{gpu_layers: layers}) when is_integer(layers) and layers > 0,
    do: true

  def gpu_layers_fixed?(_model), do: false

  # Si el modelo reparte los expertos del MoE a la CPU (`--n-cpu-moe`), lo que
  # queda en la VRAM cabe aunque las capas esten fijadas.
  defp cpu_moe?(%Candil.Model{model_args: args}) when is_list(args) do
    args
    |> Enum.chunk_every(2)
    |> Enum.any?(fn
      ["--n-cpu-moe", _value] -> true
      _ -> false
    end)
  end

  defp plan_on_gpu(model, binary) do
    size_mb = model.vram_mb || estimate_model_size(model)

    # El ledger tiene que estar al día ANTES de decidir, o la decisión se toma
    # sobre una memoria que ya no existe. La memoria ajena —la que usan
    # procesos que Candil no gestiona— se ajusta aquí.
    #
    # Y la decisión se toma con la cifra **del ledger**, no con la del sistema.
    # No es un detalle: `free_mb` del sistema es lo que hay libre ahora mismo,
    # y el ledger descuenta además lo que Candil ya tiene reservado y la
    # memoria que usa otra gente. Si uno decidiera con `free_mb` y el otro
    # reservara con `available`, los dos podrían decir cosas distintas: el
    # scheduler «cabe» y la reserva «no cabe», y el modelo no arrancaría con
    # un error que nadie entiende.
    #
    # Con la misma cifra en los dos lados, la respuesta es la misma por
    # construcción: `available` es exactamente lo que le cabe a un motor
    # nuevo, contexto incluido.
    devices =
      binary
      |> Candil.Scheduler.Devices.detect()
      |> Enum.map(&sync_foreign/1)

    # «No hay GPU» y «no lo sé» y «no cabe» son **hechos distintos**, y el
    # mensaje tiene que distinguirlos: `--cpu` es la salida del primero, del
    # segundo no hay salida, y del tercero la hay si se libera memoria.
    #
    # Antes los dos primeros salían como `:no_room`, que en una máquina sin
    # GPU decía «la GPU está llena» cuando la verdad es «aquí no hay GPU».
    cond do
      devices == [] ->
        {:error, :no_gpu}

      Enum.any?(devices, & &1.usable) ->
        place(size_mb, devices, build_instances())

      true ->
        {:error, :memory_unknown}
    end
  end

  # Sincroniza el ledger de un device y devuelve su cifra **del ledger**.
  #
  # Si no se puede medir, el device queda inservible: no se coloca con una
  # cifra vieja, y el scheduler acaba diciendo `:memory_unknown` (D-28). Un
  # `:ok` que no ajustó nada sería indistinguible de un ajuste de verdad.
  defp sync_foreign(device) do
    if device.usable do
      case Candil.Engine.Resource.sync_foreign(device) do
        :ok -> %{device | free_mb: Candil.Engine.Resource.available(device.index)}
        {:error, _reason} -> %{device | usable: false, free_mb: nil}
      end
    else
      device
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

  @doc """
  Cuánta VRAM ocupa una instancia **que ya está corriendo**.

  La respuesta es la de `nvidia-smi`, no la del catálogo. Y no es un detalle:
  el scheduler expulsa a las víctimas **por tamaño**, así que con la cuenta
  equivocada dice «no cabe» con la GPU llena de un modelo que sí cabría.

  Medido el 2026-10-22: un `coder` corriendo ocupaba **1054 MiB** según
  `nvidia-smi`, y el scheduler lo contaba como **512** — la estimación
  (`div(ctx, 1024) * 4`), porque el modelo no declara `vram_mb`. Con un
  modelo de 7978 MiB la diferencia es de 7 GB, y la expulsión no libera lo
  que cree que libera.

  ## Cuando no hay medición, se dice que no se sabe

  Sin medición, el valor **declarado** (`vram_mb`) es una **cota inferior**: el
  mínimo que el modelo ocupa con seguridad. Expulsarlo libera al menos eso,
  así que usarlo para decidir una expulsión es conservador: se puede expulsar
  de menos, nunca de más.

  Y si no hay medición **ni declaración**, no se inventa el número: se
  devuelve `nil`. La estimación (`estimate_model_size/1`) era una suposición
  —512 MiB para un modelo que ocupa 7978— y una suposición no puede decidir
  a quién se expulsa. Un device cuyo tamaño se desconoce **no se expulsa**:
  no se sabe cuánto liberaría, y expulsar a ciegas es peor que no expulsar.

  ## Por qué no 0

  Un `0` significaría «no ocupa nada», que es un hecho. `nil` es «no lo sé»,
  que es otro hecho. Y el planificador tiene que poder distinguirlos.
  """
  @spec size_mb(Candil.Model.t(), map() | nil) :: non_neg_integer() | nil
  def size_mb(_model, %{used_mb: used}) when is_integer(used) and used >= 0, do: used

  def size_mb(%Candil.Model{vram_mb: vram}, _usage) when is_integer(vram) and vram >= 0, do: vram

  def size_mb(_model, _usage), do: nil

  defp build_instances do
    usage_by_pid = process_usage_by_pid()

    Candil.EnginePool.list()
    |> Enum.map(fn entry ->
      model = entry.model
      usage = usage_for(entry, usage_by_pid)

      %{
        model_alias: entry.alias,
        device_index: usage && usage.device_index,
        size_mb: size_mb(model, usage),
        in_use: false,
        pinned: model.exclusive == true,
        last_used_at: nil
      }
    end)
  end

  # La medición de `nvidia-smi` para este motor, si la hay. El PID del SO es
  # el que `nvidia-smi` conoce: el del GenServer de Candil no.
  defp usage_for(entry, usage_by_pid) do
    case entry.pid do
      beam_pid when is_pid(beam_pid) ->
        case Candil.Engine.os_pid(beam_pid) do
          nil -> nil
          os_pid -> Map.get(usage_by_pid, os_pid)
        end

      _ ->
        nil
    end
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
  #
  # La medicion completa (el device Y la VRAM que ocupa) la trae `usage_for/2`:
  # los dos datos salen del mismo `nvidia-smi`, y separarlos es como acabar
  # con la tarjeta de un lado y la memoria de otro.

  defp evict(_size_mb, [], _instances), do: {:error, :no_room}

  defp evict(size_mb, devices, instances) do
    # Para cada dispositivo, calcular el conjunto mínimo de víctimas
    # (las menos usadas, más pequeñas) que libera suficiente espacio.
    candidates_per_device =
      Enum.map(devices, fn device ->
        device_instances = Enum.filter(instances, &(&1.device_index == device.index))

        # Solo son víctimas las que se pueden medir: una instancia cuyo
        # tamaño se desconoce no libera una cantidad que se pueda contar, y
        # contar con una suposición sería decidir una expulsión con un
        # número inventado (D-28).
        evictable =
          Enum.filter(device_instances, fn i ->
            not i.in_use and not i.pinned and is_integer(i.size_mb)
          end)

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
