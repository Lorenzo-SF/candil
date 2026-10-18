defmodule Candil.Scheduler.Devices do
  @moduledoc """
  Construye la lista de dispositivos que el scheduler consume, a partir de
  `Candil.Detector.Devices` (medición real de nvidia-smi).

  El scheduler no sabe de `nvidia-smi` ni de puertos; solo ve una lista de
  dispositivos con `index`, `name`, `free_mb`, `total_mb` y `usable`. Este
  módulo es quien traduce el hardware al lenguaje del scheduler.
  """

  alias Candil.Detector.Devices

  @doc """
  Detecta los dispositivos y los devuelve en la forma que `Candil.Scheduler`
  consume. Si la detección falla (no hay nvidia-smi, etc.), devuelve una
  lista vacía —el scheduler responderá `:no_room`, que es lo honesto cuando
  no se sabe.
  """
  @spec detect() :: [Candil.Scheduler.device()]
  def detect do
    case Devices.detect() do
      {:ok, %{devices: devices}} ->
        Enum.map(devices, fn d ->
          %{
            index: d.index,
            name: d.name,
            total_mb: d.total_mb,
            free_mb: d.free_mb,
            usable: d.usable
          }
        end)

      {:error, _} ->
        []
    end
  end
end
