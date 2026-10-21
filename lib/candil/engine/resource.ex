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

  # Cuánto puede cambiar la memoria ajena antes de reajustar el ledger. Con
  # menos de esto, cada arranque provocaría un `release`+`acquire` por unos
  # megas de diferencia entre dos mediciones de `nvidia-smi`.
  @foreign_threshold_mb 64

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

  @doc """
  El nombre con el que un device está registrado en `Arrea.Resource`.

  Es público porque **el átomo no se puede inventar en runtime**: `:"cuda0"`
  creado en un test es un átomo nuevo, y los átomos no se recogen. Los
  nombres de este módulo están precalculados en compilación, así que este
  `device_name/1` es la única forma correcta de referirse a ellos.

  Un índice fuera de rango es un error explícito, no un átomo nuevo.
  """
  @spec device_name(non_neg_integer()) :: atom()
  def device_name(index) when is_integer(index) and index >= 0 and index < @max_devices do
    Enum.at(@device_names, index)
  end

  def device_name(index) do
    raise ArgumentError,
          "device index #{inspect(index)} fuera de rango: hay #{@max_devices} " <>
            "nombres precalculados (0..#{@max_devices - 1})"
  end

  @doc """
  Para el resource de un device, si lo hay.

  `Arrea.Resource` no tiene API para parar un resource, pero su proceso está
  en `Arrea.Resource.Registry` y un GenServer se para. Lo que se para es el
  **ledger entero**: las reservas que tuviera se van con él.

  Sirve para el cleanup de los tests, porque el registro es global: un
  resource que se queda puesto entre tests deja titulares que no son de
  nadie y hace que el siguiente test mida una memoria que ya no existe.
  """
  @spec stop_device(non_neg_integer()) :: :ok
  def stop_device(device_index) when is_integer(device_index) and device_index >= 0 do
    name = device_name(device_index)

    case Registry.lookup(Arrea.Resource.Registry, name) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Ajusta la memoria que usan procesos que **Candil no gestiona**.

  Es el hueco que hacía que el ledger dijera 15933 MiB libres cuando la
  memoria REALMENTE libre era menos: en la medición del 2026-10-21 eran
  11518 MiB, de los que 4216 ocupaba un modelo de otra sesión, y el ledger no
  lo sabía. La reserva se tomaba sobre una memoria que ya no estaba, y el OOM
  pasaba con la cuenta «correcta».

  ## Por que un titular y no cambiar la capacidad

  `Arrea.Resource` **no tiene API para cambiar la capacidad** de un resource
  registrado, ni para pararlo. Re-registrarlo perdería el ledger entero —el
  estado `holders` vive en el proceso—, y con él las reservas de los modelos
  que ya están arrancados.

  La vía que no pierde nada es **meter la memoria ajena en el ledger como un
  titular más**, al lado de `:system`. Con la capacidad del device y tres
  titulares:

      available = total − (system + foreign + modelos de Candil)

  y como `foreign = (total − free_real) − modelos_de_Candil`:

      available = free_real − system

  que es exactamente **la memoria que un motor nuevo puede usar**: la real
  menos su propio contexto CUDA.

  El criterio de aceptación es una **fórmula**, no una cifra:

      available == free_real − 370

  Medido el 2026-10-21: con 11718 MiB libres de verdad, la disponible pasó de
  15933 (el total del device, que no existía) a **11348** (= 11718 − 370). Las
  dos cifras de la línea anterior eran de otro instante —la memoria ajena de
  otra sesión cambia mientras se mide—, y por eso el criterio va en
  fórmula: el número vale en cada momento, la cifra no.

  Reajustar **no** pierde el ledger: `acquire/4` añade una entrada y
  `release/2` quita la primera de ese titular, así que un `release` + `acquire`
  del delta es un ajuste limpio. Es el mismo mecanismo que usa la corrección
  de la reserva de un modelo.

  El delta se ignora si es menor que el umbral, para no provocar un
  `release`+`acquire` en cada arranque por unos megas de diferencia.
  """
  @spec sync_foreign(non_neg_integer()) :: :ok | {:error, term()}
  def sync_foreign(device_index) when is_integer(device_index) and device_index >= 0 do
    with :ok <- ensure_registered(device_index),
         {:ok, total, free} <- device_memory(device_index),
         {:ok, used_by_models} <- used_by_models(device_index) do
      # Lo que ocupa la GPU y no es de Candil. Puede ser **más** que lo que
      # queda tras `:system`: con la GPU al 99 % (42 MiB libres de verdad), la
      # memoria ajena es de 16261 MiB y el ledger solo tiene 15933 de hueco
      # tras el overhead. Entonces el `acquire` del titular fallaría y la
      # disponible se quedaría en 15933 — **la cifra que no existe**, que es
      # justo lo que este módulo viene a quitar.
      #
      # La verdad en ese caso es «no cabe nada», así que el titular se recorta
      # a lo que queda y la disponible cae a 0. Un 0 es honesto; un 15933 no.
      foreign = max(total - free - used_by_models, 0)
      max_foreign = max(total - @overhead_mb - used_by_models, 0)
      wanted = min(foreign, max_foreign)

      current = foreign_reserved(device_index)

      if abs(wanted - current) > @foreign_threshold_mb do
        adjust_foreign(device_index, wanted)
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  # ── internos ─────────────────────────────────────────────────────────────

  defp adjust_foreign(device_index, wanted) do
    name = device_name(device_index)

    # Primero se suelta la reserva vieja, y solo después se pide la nueva: al
    # revés, con la memoria justa, pedir antes de soltar podría no caber.
    if foreign_reserved(device_index) > 0 do
      _ = Arrea.Resource.release(name, :foreign)
    end

    if wanted > 0 do
      case Arrea.Resource.acquire(name, :foreign, wanted, 0) do
        {:ok, _receipt} -> :ok
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  defp foreign_reserved(device_index) do
    name = device_name(device_index)

    case Arrea.Resource.status(name) do
      %{holders: holders} ->
        holders
        |> Enum.filter(&(elem(&1, 0) == :foreign))
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()

      _ ->
        0
    end
  end

  defp used_by_models(device_index) do
    name = device_name(device_index)

    case Arrea.Resource.status(name) do
      %{holders: holders} ->
        {:ok,
         holders
         |> Enum.reject(&(elem(&1, 0) in [:system, :foreign]))
         |> Enum.map(&elem(&1, 1))
         |> Enum.sum()}

      _ ->
        {:error, :not_registered}
    end
  end

  # `total` y `free` de `nvidia-smi`. `free` es la memoria que no usa NADIE:
  # ni los modelos de Candil ni los de otras sesiones. Por eso hay que
  # restarle las reservas de Candil para sacar lo ajeno.
  defp device_memory(device_index) do
    case Enum.find(Devices.detect(), &(&1.index == device_index)) do
      %{total_mb: total, free_mb: free} when is_integer(total) and is_integer(free) ->
        {:ok, total, free}

      _ ->
        {:error, :memory_unknown}
    end
  end

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

  defp device_capacity(device_index) do
    case Enum.find(Devices.detect(), &(&1.index == device_index)) do
      %{total_mb: total} when is_integer(total) and total > 0 -> total
      _ -> 0
    end
  end
end
