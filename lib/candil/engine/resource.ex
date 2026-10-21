defmodule Candil.Engine.Resource do
  # Nombres de device precalculados en compilación. `Arrea.Resource` se
  # registra por átomo y el índice viene de `nvidia-smi`, o sea de fuera:
  # `:"cuda#{index}"` en runtime crearía átomos desde un dato que no controla
  # este módulo. 32 devices es de sobra; un índice mayor es un error explícito.
  @max_devices 32

  @device_names Enum.map(0..(@max_devices - 1), fn index ->
                  String.to_atom("cuda" <> Integer.to_string(index))
                end)

  @moduledoc """
  Gestiona el ciclo de vida de `Arrea.Resource` por device.

  `Arrea.Resource` es la pieza que decide si un modelo cabe en una GPU: capacidad
  entera en megas, cuota decimal, identidad estricta del titular. Este módulo
  es el consumidor que D-27 pedía: registra el resource al arrancar, reserva
  antes de cargar, libera si el motor muere.

  ## Capacidad

  La capacidad es la del **motor** (15933 MiB en una RTX 5080), no la de
  `nvidia-smi` (16303). La diferencia (≈370 MiB) es el contexto CUDA. Se
  registra el total de `nvidia-smi` y se reserva el overhead como titular
  `:system`, así que la disponible es la del motor.

  ## Cuota

  Un modelo local no compite por un presupuesto blando: la cuota de cada
  `acquire/3` es **`0`**, que en `Arrea.Resource` significa «este modelo no
  consume cuota» y es una afirmación legítima. `:infinity` **no** vale en ese
  eje —solo como `:quota` del resource— y devuelve `:unknown_cost`, que aborta
  el arranque. Por eso la cuota no es un parámetro de este módulo.

  ## Titular

  El titular es `{alias, port}` (un tuple), no solo el alias. Con eso dos
  instancias del mismo modelo reservan por separado y `release` es exacto.
  La identidad estricta de `Arrea.Resource` (`===`) funciona con tuples.

  ## Nombres de device

  Los nombres están precalculados en compilación para `0..#{@max_devices - 1}`;
  un índice mayor es un error explícito, no un átomo nuevo.
  """

  alias Candil.Scheduler.Devices

  @overhead_mb 370

  @doc """
  Registra el resource de un device si no existe. Idempotente.

  La capacidad se toma de `Devices.detect/0` (`total_mb`). El overhead se
  reserva como titular `:system` para que la disponible sea la del motor.
  Si la detección no da una capacidad positiva, **no se registra** el
  resource: una capacidad 0 se comería todos los arranques para siempre y
  «no lo sé» no es «ahora no cabe nada».
  """
  @spec ensure_registered(non_neg_integer()) :: :ok | {:error, :capacity_unknown}
  def ensure_registered(device_index) when is_integer(device_index) and device_index >= 0 do
    name = device_name(device_index)

    case Registry.lookup(Arrea.Resource.Registry, name) do
      [{_pid, _}] ->
        :ok

      [] ->
        case device_capacity(device_index) do
          capacity when is_integer(capacity) and capacity > 0 -> register(name, capacity)
          _ -> {:error, :capacity_unknown}
        end
    end
  end

  @doc """
  Reserva capacidad en un device. Devuelve `{:ok, receipt}` o un error.

  `cost` son megas enteros `> 0`. La cuota de política es siempre `0`: un
  modelo local no consume un presupuesto blando, y `Arrea.Resource` exige un
  número en ese eje.
  """
  @spec acquire(non_neg_integer(), term(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def acquire(device_index, holder, cost)
      when is_integer(device_index) and device_index >= 0 and is_integer(cost) and cost > 0 do
    with :ok <- ensure_registered(device_index) do
      Arrea.Resource.acquire(device_name(device_index), holder, cost, 0)
    end
  end

  @doc """
  Libera la reserva de un titular en un device.
  """
  @spec release(non_neg_integer(), term()) :: {:ok, map()} | {:error, term()}
  def release(device_index, holder) when is_integer(device_index) and device_index >= 0 do
    name = device_name(device_index)
    Arrea.Resource.release(name, holder)
  end

  @doc """
  VRAM disponible en un device (0 si no está registrado).
  """
  @spec available(non_neg_integer()) :: non_neg_integer()
  def available(device_index) when is_integer(device_index) and device_index >= 0 do
    name = device_name(device_index)
    Arrea.Resource.available(name)
  end

  # ── internos ─────────────────────────────────────────────────────────────

  defp register(name, capacity) do
    case Arrea.Resource.start_link(name, capacity) do
      {:ok, _pid} ->
        # El overhead del contexto CUDA, como titular `:system`. Cuota 0:
        # `:infinity` no es un número y `acquire/4` lo rechaza.
        if capacity > @overhead_mb do
          {:ok, _receipt} = Arrea.Resource.acquire(name, :system, @overhead_mb, 0)
        end

        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, _reason} ->
        {:error, :capacity_unknown}
    end
  end

  defp device_name(index) when is_integer(index) and index >= 0 and index < @max_devices do
    Enum.at(@device_names, index)
  end

  defp device_name(index) do
    raise ArgumentError,
          "device index #{inspect(index)} fuera de rango: hay #{@max_devices} " <>
            "nombres precalculados (0..#{@max_devices - 1})"
  end

  defp device_capacity(device_index) do
    case Enum.find(Devices.detect(), &(&1.index == device_index)) do
      %{total_mb: total} when is_integer(total) and total > 0 -> total
      _ -> 0
    end
  end
end
