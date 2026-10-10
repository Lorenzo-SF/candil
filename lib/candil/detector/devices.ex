defmodule Candil.Detector.Devices do
  @moduledoc """
  **Cuántas GPUs hay y cuánta VRAM tiene cada una.** Eso es todo.

  ## Por qué existe

  La 8b (Scheduler) tiene que responder *"¿qué motor se queda? ¿qué se
  descarga?"*, y la pregunta no tiene respuesta sin esto. Hoy `Candil` no lo
  sabe:

  - `Detector.GPU` devuelve un **átomo de backend** —`:cuda`, `:metal`,
    `:rocm`— y la versión del driver. No cuenta dispositivos.
  - No hay ningún campo `device` en el modelo ni en la configuración.
  - La columna `SLOT` de `candil status` no viene del hardware:

        defp slot(port), do: if(rem(port, 100) >= 90, do: "dGPU", else: "CPU")

    Es el **número de puerto**. Cualquier puerto acabado en `9x` es `dGPU` por
    definición, esté o no detrás de una GPU.

  Es el mismo patrón que la fase 0.4 —«el refusal de VRAM no existe»—: una
  política escrita que se apoya en un dato que nadie produce.

  ## Lo que este módulo NO hace

  No decide nada. No elige en qué GPU va un modelo, no expulsa a nadie y no
  conoce consumidores. Eso es la 8b. Aquí solo se **mide**, y se mide de
  manera que lo que no se sabe **se vea**.

  ## La salida

      iex> Candil.Detector.Devices.parse("", :cuda)
      {:error, :no_smi}

      iex> {:ok, ""} |> then(&Candil.Detector.Devices.parse_nvidia("0, NVIDIA GeForce RTX 5080, 16376, 16100")) |> elem(0)
      :ok

  ## El `N/A` de NVIDIA, y por qué es el caso importante

  NVIDIA imprime `N/A` cuando un atributo no está soportado por ese
  dispositivo. Y aquí está la trampa: **si `N/A` se convierte en `0`, el
  planificador cree que hay 0 MiB libres y dice «no cabe» con un número
  inventado; si se convierte en el total, cree que la GPU está libre y lanza
  un modelo que no entra.** Un `0` y un `total` son los dos finales del mismo
  fallo: decir con seguridad algo que no se sabe.

  Por eso un dispositivo con la memoria ilegible sale con `usable: false` y sus
  cifras a `nil`. Es un hecho, y se dice. Un planificador tiene que poder
  distinguir *«no hay sitio»* de *«no lo sé»*, y para eso la diferencia tiene
  que existir en el tipo.

  ## `free` no se calcula

  `nvidia-smi` separa reservado de usado, y `memory.free` es lo que se puede
  pedir de verdad. Calcularlo aquí como `total - used` sería inventar un número
  que el driver ya sabe y que además no coincide.
  """

  alias Apero.OS
  alias Candil.Detector.GPU

  @type backend :: :cuda | :metal | :rocm | :sycl | :vulkan | :cpu
  @type index :: non_neg_integer()
  @type device :: %{
          index: index(),
          name: String.t(),
          backend: backend(),
          total_mb: non_neg_integer() | nil,
          free_mb: non_neg_integer() | nil,
          usable: boolean()
        }
  @type result :: %{backend: backend(), devices: [device()]}

  @query ["--query-gpu=index,name,memory.total,memory.free", "--format=csv,noheader,nounits"]

  @doc """
  Detecta los dispositivos de la máquina.

  Devuelve `{:error, ...}` cuando **no se puede saber**, y `{:ok, %{devices: []}}`
  cuando **se sabe que no hay ninguno**. No es lo mismo y no se mezcla:

      # hay NVIDIA pero nvidia-smi no esta
      {:error, :no_smi}

      # hay NVIDIA y nvidia-smi no lista ninguna (no deberia pasar, pero)
      {:ok, %{backend: :cuda, devices: []}}
  """
  @spec detect() :: {:ok, result()} | {:error, term()}
  def detect do
    {backend, _version} = GPU.detect_gpu(OS.type())

    case backend do
      :cuda -> detect_cuda()
      :metal -> {:ok, %{backend: :metal, devices: [unified_memory()]}}
      other -> {:ok, %{backend: other, devices: []}}
    end
  end

  @doc """
  Corre `nvidia-smi` y parsea su salida.

  Separado de `parse_nvidia/1` a propósito: el parser es una función pura y se
  prueba en un runner sin GPU, que es el único sitio donde se puede probar.
  """
  @spec detect_cuda() :: {:ok, result()} | {:error, term()}
  def detect_cuda do
    case System.find_executable("nvidia-smi") do
      nil ->
        {:error, :no_smi}

      _path ->
        case System.cmd("nvidia-smi", @query, stderr_to_stdout: true) do
          {out, 0} -> parse_nvidia(out)
          {_out, _rc} -> {:error, :smi_failed}
        end
    end
  end

  @doc """
  Parsea la salida de `nvidia-smi` en una lista de dispositivos.

  ## Contrato con el comando

      nvidia-smi --query-gpu=index,name,memory.total,memory.free \
                 --format=csv,noheader,nounits

      0, NVIDIA GeForce RTX 5080, 16376, 16100

  Tolera, porque el comando puede cambiar o alguien puede llamarlo con otros
  flags:

  - la **cabecera** si falta el `noheader` (y la descarta: no es un dispositivo)
  - las **unidades pegadas** si falta el `nounits` (`16376 MiB`)
  - **`N/A`** en cualquier campo de memoria
  - **líneas de basura** intercaladas, que se saltan sin tirar el resultado

  Y **rechaza** lo que no puede ser un dispositivo: una línea con menos
  campos, o con `free` mayor que `total`. Un `{:error, ...}` es preferible a un
  dispositivo con cifras inventadas.
  """
  @spec parse_nvidia(binary()) :: {:ok, [device()]} | {:error, term()}
  def parse_nvidia(output) when is_binary(output) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    lines = Enum.reject(lines, &header?/1)

    devices =
      lines
      |> Enum.map(&parse_line/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(&elem(&1, 1))

    cond do
      # No hay nada que leer: se sabe que no hay dispositivos.
      lines == [] -> {:ok, []}
      # Habia lineas y ninguna se pudo leer: no se puede decir que no hay.
      devices == [] -> {:error, :unparseable}
      true -> {:ok, devices}
    end
  end

  @doc """
  Envuelve la salida de `nvidia-smi` con el backend, que es un dato que el
  parser solo no tiene.

  La salida vacía de un `nvidia-smi` **que existe** es `{:ok, %{devices: []}}`:
  sabemos que no hay ninguno. El "no se puede preguntar" —`{:error, :no_smi}`—
  lo devuelve `detect_cuda/0`, que es quien sabe si el binario está. Distintos
  hechos, y los dice quien puede saberlos.
  """
  @spec parse(binary(), backend()) :: {:ok, result()} | {:error, term()}
  def parse(output, backend) when is_binary(output) do
    case parse_nvidia(output) do
      {:ok, devices} -> {:ok, %{backend: backend, devices: devices}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## ── interno ────────────────────────────────────────────────────────────────

  defp header?("index" <> _), do: true
  defp header?("index," <> _), do: true
  defp header?(_), do: false

  defp parse_line(line) do
    # `parts: 4` para que el nombre con comas no parta el resto de la linea.
    case String.split(line, ",", parts: 4) do
      [index, name, total, free] ->
        with {i, ""} <- Integer.parse(String.trim(index)),
             {t, _} <- parse_mb(total),
             {f, _} <- parse_mb(free),
             :ok <- sane?(t, f) do
          usable = not is_nil(t) and not is_nil(f)

          {:ok,
           %{
             index: i,
             name: String.trim(name),
             backend: :cuda,
             total_mb: t,
             free_mb: f,
             usable: usable
           }}
        else
          _ -> {:error, :bad_line}
        end

      _ ->
        {:error, :bad_line}
    end
  end

  # `N/A` -> nil. No es 0, y no es el total. Es que no lo sabemos.
  defp parse_mb(str) do
    case str |> String.trim() |> Integer.parse() do
      {n, rest} when n >= 0 -> {n, rest}
      _ -> {nil, nil}
    end
  end

  # Si los dos son numeros, el libre no puede ser mayor que el total: eso no es
  # un dispositivo, es una linea que no se sabe leer.
  defp sane?(nil, _), do: :ok
  defp sane?(_, nil), do: :ok
  defp sane?(total, free) when free <= total, do: :ok
  defp sane?(_, _), do: :error

  # En macOS no hay tarjetas: hay memoria unificada. Es UN dispositivo, y por
  # eso `detect/0` lo pone en una lista de uno y no en un caso especial.
  defp unified_memory do
    case total_system_memory_mb() do
      nil ->
        %{
          index: 0,
          name: "Apple unified memory",
          backend: :metal,
          total_mb: nil,
          free_mb: nil,
          usable: false
        }

      mb ->
        %{
          index: 0,
          name: "Apple unified memory",
          backend: :metal,
          total_mb: mb,
          free_mb: mb,
          usable: true
        }
    end
  end

  defp total_system_memory_mb do
    case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> Integer.parse() do
          {bytes, _} when bytes > 0 -> {:ok, div(bytes, 1024 * 1024)}
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
