defmodule Candil.Agents.Crashes do
  @moduledoc """
  Cuántas veces ha reventado un agente, y cuándo.

  El breaker cubre el **cuelgue**; este módulo cubre el **crash**: un agente
  que revienta en bucle. El supervisor ya tiene una intensidad global (10 en
  5 s), pero es global —un agente que revienta diez veces en cinco segundos
  se lleva por delante a los agentes sanos—. Aquí el presupuesto es **por
  agente**, y sobrevive al reinicio, que es lo que hace que un bucle se pare
  en vez de agotar la intensidad del supervisor.

  ## Clave por nombre

  Igual que `Candil.Agents.Snapshots` y `Candil.Agents.Breakers`: la clave es
  el nombre del agente. Un agente sin nombre no tiene presupuesto que
  sobreviva (no tiene identidad) y se queda con el del supervisor, como antes.
  """

  use GenServer

  @table :candil_agents_crashes
  @window_ms 60_000

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registra un crash para ese nombre, con la marca de tiempo `now` (monotónico,
  en milisegundos). Los crashes fuera de la ventana se olvidan.
  """
  @spec record(term(), integer()) :: :ok
  def record(nil, _now), do: :ok

  def record(name, now) when is_integer(now) do
    crashes =
      case load(name) do
        {:ok, ts} -> ts
        {:error, :not_found} -> []
      end

    crashes = prune(crashes, now) ++ [now]
    :ets.insert(@table, {name, crashes})
    :ok
  end

  @doc """
  Cuántos crashes hay en la ventana para ese nombre.
  """
  @spec count(term(), integer()) :: non_neg_integer()
  def count(nil, _now), do: 0

  def count(name, now) when is_integer(now) do
    case load(name) do
      {:ok, ts} -> length(prune(ts, now))
      {:error, :not_found} -> 0
    end
  end

  @doc """
  Lee las marcas de tiempo de los crashes en la ventana.
  """
  @spec load(term()) :: {:ok, [integer()]} | {:error, :not_found}
  def load(name) do
    case :ets.lookup(@table, name) do
      [{_name, ts}] -> {:ok, ts}
      [] -> {:error, :not_found}
    end
  end

  @doc "Olvida los crashes registrados para ese nombre."
  @spec forget(term()) :: :ok
  def forget(name) do
    :ets.delete(@table, name)
    :ok
  end

  @doc false
  @spec prune([integer()], integer()) :: [integer()]
  def prune(timestamps, now) when is_list(timestamps) and is_integer(now) do
    Enum.filter(timestamps, fn ts -> now - ts < @window_ms end)
  end

  @doc false
  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
