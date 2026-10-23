defmodule Candil.Detector.EngineDevices do
  @moduledoc """
  La lista de dispositivos que publica **el motor**: `llama-server --list-devices`.

  ## Por qué el motor y no el sistema

  `nvidia-smi` solo sabe de NVIDIA. En una máquina con ROCm, SYCL o Vulkan,
  `Candil.Detector.Devices` devuelve `devices: []` y Candil **no ve el
  acelerador**: mide el hardware con una herramienta que solo habla de un
  backend.

  El motor sí los ve todos, porque los usa todos. Medido el 2026-10-22:

      $ llama-server --list-devices
      Available devices:
        CUDA0: NVIDIA GeForce RTX 5080 Laptop GPU (15933 MiB, 857 MiB free)

  De ahí salen tres cosas que ninguna otra fuente da junta:

  - **El nombre** con el que se le habla al motor: `CUDA0`. Y `--device` no
    acepta índices —`--device 0` responde `invalid device: 0`—, así que el
    nombre no es un detalle: es **la dirección** del device.
  - **La capacidad** que el motor ve: 15933 MiB, que son 16303 (el total que
    ve `nvidia-smi`) menos el contexto de CUDA. El motor ya se ha descontado su
    propio contexto, así que su capacidad **es** la que le cabe a un motor
    nuevo.
  - **El libre** en el mismo instante y en la misma fuente que la capacidad.

  ## Una sola fuente

  La capacidad y el libre tienen que venir **de la misma fuente**. La fórmula
  `available = capacity − foreign − candil_used` miente si la capacidad es de
  un sitio y el libre de otro: son dos coordenadas y la resta no significa nada.

  Por eso este módulo es la fuente del ledger, y `nvidia-smi` se queda con lo
  que sí sabe hacer bien: el uso **por proceso**, que es lo que necesita el
  scheduler para decidir a quién expulsa.

  ## Lo que este módulo NO hace

  No decide nada: no elige device, no reserva, no expulsa. Eso es el scheduler.
  Aquí solo se **mide**, y se mide lo que el motor dice de sí mismo.

  ## El tiempo que cuesta

  0,44 s medidos el 2026-10-22 (el motor inicializa el backend para responder).
  Es lo que cuesta una colocación, que ya dura segundos: no hace falta cachear
  nada, y **cachear sería peor**: una cifra cacheada es una cifra de otro
  instante.
  """

  @typedoc """
  Un device del motor. `total_mb` y `free_mb` vienen de la misma fuente —la
  del motor— y `name` es el nombre con el que se le habla.
  """
  @type device :: %{
          index: non_neg_integer(),
          name: String.t(),
          backend: atom(),
          total_mb: non_neg_integer(),
          free_mb: non_neg_integer(),
          usable: boolean()
        }

  @type result :: %{backend: atom(), devices: [device()]}

  # `CUDA0: NVIDIA GeForce RTX 5080 Laptop GPU (15933 MiB, 857 MiB free)`
  #
  # El nombre no puede llevar `:` ni espacios (es lo que se pasa a `--device`),
  # y el total y el libre son enteros en MiB. La descripción del device es
  # libre: puede llevar comas, paréntesis y lo que quiera, así que se acota
  # por el final —`(N MiB, M MiB free)`— y no por el principio.
  @device_regex ~r/^\s*(?<name>[A-Za-z][A-Za-z0-9_]*)\s*:\s*(?<desc>.*?)\s*\((?<total>\d+)\s*MiB,\s*(?<free>\d+)\s*MiB free\)\s*$/

  @doc """
  Le pregunta al motor qué devices tiene.

  `binary` es la ruta del binario del motor (`llama-server`). Si no existe, o
  no se puede ejecutar, o falla, se devuelve un error —**no una lista vacía**:
  una lista vacía sería «el motor no tiene devices», que es un hecho
  distinto de «no se pudo preguntar».
  """
  @spec detect(binary()) :: {:ok, result()} | {:error, term()}
  def detect(binary) when is_binary(binary) do
    case System.cmd(binary, ["--list-devices"], stderr_to_stdout: true) do
      {out, 0} -> parse(out)
      {_out, status} -> {:error, {:engine_failed, status}}
    end
  rescue
    # `System.cmd/3` **lanza** `:enoent` si el binario no existe o no se puede
    # ejecutar. Un crash de producción no es la forma de decir «no lo sé».
    _kind -> {:error, :no_binary}
  end

  @doc """
  Parsea la salida de `--list-devices`.

  Función pura, sin proceso ni máquina: se prueba con el texto de verdad.

  ## Qué se salta y qué se rechaza

  - La cabecera (`Available devices:`) y las líneas en blanco se saltan.
  - Una línea que **no** se entiende se salta, y si al final no queda ningún
    device pero **había** líneas, se devuelve `{:error, :unparseable}`: se sabe
    que había algo y no se sabe qué es. Un parser que se come lo raro deja al
    scheduler sin devices y dice «no hay GPU», que no es lo que pasó.
  - Un device con el libre **mayor** que el total es una línea que no se sabe
    leer: se rechaza, igual que hace `Candil.Detector.Devices` con `nvidia-smi`.
  """
  @spec parse(binary()) :: {:ok, result()} | {:error, term()}
  def parse(output) when is_binary(output) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or header?(&1)))

    devices =
      lines
      |> Enum.map(&parse_line/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> with_indices()

    cond do
      lines == [] -> {:ok, %{backend: nil, devices: []}}
      devices == [] -> {:error, :unparseable}
      true -> {:ok, %{backend: backend_of(devices), devices: devices}}
    end
  end

  @doc """
  El device de un índice, por su nombre.

  El índice es **la posición en la lista del motor**: `CUDA0` es el 0, `CUDA1`
  el 1. Es la misma coordenada que usa `--main-gpu`, y es distinta del nombre.
  """
  @spec device(binary(), non_neg_integer()) :: {:ok, device()} | {:error, term()}
  def device(binary, index) when is_binary(binary) and is_integer(index) and index >= 0 do
    case detect(binary) do
      {:ok, %{devices: devices}} ->
        case Enum.find(devices, &(&1.index == index)) do
          nil -> {:error, :no_device}
          device -> {:ok, device}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  El nombre con el que se le habla al motor a un device.

  Es el `--device` que se le pasa a `llama-server`: `CUDA0`, `ROCm0`,
  `Vulkan0`… **Nunca** `CUDA\#{index}`: eso es falso en ROCm, en SYCL y en
  Vulkan, y el motor lo rechaza con `invalid device`.
  """
  @spec name_for(binary(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def name_for(binary, index) do
    case device(binary, index) do
      {:ok, %{name: name}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  ## ── interno ────────────────────────────────────────────────────────────────

  defp header?("Available devices" <> _), do: true
  defp header?(_), do: false

  defp parse_line(line) do
    case Regex.named_captures(@device_regex, line) do
      nil ->
        {:error, :bad_line}

      captures ->
        total = String.to_integer(captures["total"])
        free = String.to_integer(captures["free"])

        if free > total do
          {:error, :bad_line}
        else
          name = captures["name"]

          {:ok,
           %{
             index: 0,
             name: name,
             backend: backend_of_name(name),
             total_mb: total,
             free_mb: free,
             usable: true
           }}
        end
    end
  end

  # El índice es **la posición en la lista**: es lo que el motor llama `id`, y
  # lo que `--main-gpu` espera.
  defp with_indices(devices), do: Enum.with_index(devices) |> Enum.map(&set_index/1)

  defp set_index({device, index}), do: Map.put(device, :index, index)

  # El backend se deduce del **prefijo del nombre que publica el motor**:
  # `CUDA0` es CUDA, `ROCm0` es ROCm. No es una suposición sobre el hardware:
  # es el nombre que el propio motor le da a su device, y llama a su backend
  # como lo llama. Un prefijo que Candil no conoce cae en `:unknown`, que es
  # la respuesta honesta: se sabe el nombre y se sabe la memoria, y no se
  # sabe de qué backend habla.
  defp backend_of_name(name) do
    cond do
      String.starts_with?(name, "CUDA") -> :cuda
      String.starts_with?(name, "ROCm") -> :rocm
      String.starts_with?(name, "Vulkan") -> :vulkan
      String.starts_with?(name, "SYCL") -> :sycl
      String.starts_with?(name, "Metal") -> :metal
      String.starts_with?(name, "CPU") -> :cpu
      true -> :unknown
    end
  end

  defp backend_of(devices) do
    case devices |> Enum.map(& &1.backend) |> Enum.uniq() do
      [backend] -> backend
      _ -> :unknown
    end
  end
end
