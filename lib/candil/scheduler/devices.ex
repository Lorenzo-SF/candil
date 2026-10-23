defmodule Candil.Scheduler.Devices do
  @moduledoc """
  Construye la lista de dispositivos que el scheduler consume.

  ## De dónde sale

  La fuente es el **motor** —`llama-server --list-devices`—, que publica el
  nombre (`CUDA0`, `ROCm0`…), la capacidad que él ve y el libre, todo de la
  misma medición. Es la fuente que funciona en **todos** los backends: en
  ROCm, en SYCL y en Vulkan no hay `nvidia-smi`, y Candil medía con él, así
  que no veía el acelerador (P-12).

  El sistema —`nvidia-smi`, o `sysctl`/`vm_stat` en macOS— solo entra cuando
  el motor no se puede preguntar, y sus devices salen **sin nombre**: sin el
  nombre del motor no hay `--device` que se le pueda pasar, así que no se
  pueden colocar. Se marcan `usable: false` y el scheduler dice
  `:memory_unknown`: hay GPU, y no lo sé.

  ## El nombre es una dirección, no una medida

  El nombre viene siempre del motor. Las **cifras** vienen de una sola fuente
  por device: la del motor, y —en la memoria unificada de macOS, donde el
  motor no publica los megas del sistema— la del sistema. Nunca se mezclan
  dentro de un mismo device.
  """

  alias Candil.Detector.Devices
  alias Candil.Detector.EngineDevices

  @doc """
  Detecta los dispositivos y los devuelve en la forma que `Candil.Scheduler`
  consume.

  `binary` es la ruta del binario del motor. Si es `nil` —o si el motor no se
  puede preguntar— se cae a la fuente del sistema, que no trae nombres.
  """
  @spec detect(binary() | nil) :: [Candil.Scheduler.device()]
  def detect(binary \\ nil) do
    case engine_devices(binary) do
      [] -> system_devices()
      devices -> devices
    end
  end

  defp engine_devices(nil), do: []

  defp engine_devices(binary) do
    case EngineDevices.detect(binary) do
      {:ok, %{devices: devices}} ->
        system = raw_system_devices()
        Enum.map(devices, &to_device(&1, system))

      {:error, _reason} ->
        []
    end
  end

  # La fuente del sistema: `nvidia-smi`, o la memoria unificada de macOS. Sin
  # el nombre del motor no hay dirección, así que no se pueden colocar.
  defp system_devices do
    Enum.map(
      raw_system_devices(),
      &%{to_device(&1, []) | name: nil, usable: false, source: :system}
    )
  end

  defp raw_system_devices do
    case Devices.detect() do
      {:ok, %{devices: devices}} -> devices
      {:error, _reason} -> []
    end
  end

  # Un device del motor: su nombre y sus cifras, de la misma medición.
  #
  # La excepción es la **memoria unificada** de macOS: el motor publica el
  # device de Metal, pero los megas que de verdad puede usar un modelo nuevo
  # son los del **sistema**, y son los que sabe medir `vm_stat`. Ahí se coge
  # el nombre del motor y las cifras del sistema —nunca de dos sitios para
  # el mismo número— y la fuente queda dicha: `:system`.
  defp to_device(device, system) do
    {total_mb, free_mb, source} = figures(device, system)

    %{
      index: device.index,
      name: device.name,
      backend: device.backend,
      total_mb: total_mb,
      free_mb: free_mb,
      usable: usable?(device, total_mb, free_mb),
      source: source
    }
  end

  # Las cifras de un device, y de dónde salen.
  #
  # La memoria unificada de macOS es la excepción: el motor publica el device
  # de Metal, pero los megas que de verdad puede usar un modelo nuevo son los
  # del **sistema**, y son los que sabe medir `vm_stat`. Ahí se coge el nombre
  # del motor y las cifras del sistema —nunca de dos sitios para el mismo
  # número— y la fuente queda dicha: `:system`.
  defp figures(%{backend: :metal} = device, system) do
    case Enum.find(system, &(&1.index == device.index)) do
      %{total_mb: total, free_mb: free}
      when is_integer(total) and total > 0 and is_integer(free) ->
        {total, free, :system}

      _ ->
        {device.total_mb, device.free_mb, :engine}
    end
  end

  defp figures(device, _system), do: {device.total_mb, device.free_mb, :engine}

  # Un device se puede colocar si tiene **dirección** (el nombre del motor) y
  # **cifras**: sin nombre no hay `--device`, y sin cifras no hay nada que
  # comparar. Las dos cosas o ninguna.
  defp usable?(%{name: name}, total, free) do
    is_binary(name) and is_integer(total) and total > 0 and is_integer(free)
  end
end
