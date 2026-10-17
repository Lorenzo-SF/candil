defmodule Candil.Agents.Breakers do
  @moduledoc """
  El estado del circuito de un agente, fuera del proceso del agente.

  Un agente que se cuelga cinco veces abre su circuito, y eso hasta aquí
  vivía dentro del proceso —que es justo lo que no ayuda cuando el agente
  **revienta** y el supervisor lo levanta con el contador a cero. Este
  almacén es la memoria que sobrevive al proceso: la misma idea que
  `Candil.Agents.Snapshots`, pero para el cerrojo en vez de para el estado
  del mundo.

  ## Clave por nombre

  Igual que los snapshots: la clave es el nombre del agente. Un agente sin
  nombre no persiste su circuito (no tiene identidad que sobreviva a un
  reinicio, así que no puede), y se queda con el circuito en memoria, como
  hasta ahora.

  ## Lo que NO hace

  No decide si un agente se reinicia. Eso es del supervisor. Este módulo solo
  guarda y devuelve el circuito; que el agente arranque con el circuito abierto
  y se niegue a trabajar es lo que para el bucle de crashes, no un reinicio
  que no ocurre.
  """

  use GenServer

  alias Candil.Agents.Breaker

  @table :candil_agents_breakers

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Guarda el circuito de un agente, reemplazando el que hubiera.

  `nil` para el nombre no guarda nada: un agente sin nombre no tiene circuito
  que sobreviva.
  """
  @spec save(term(), Breaker.t()) :: :ok
  def save(nil, _breaker), do: :ok

  def save(name, %Breaker{} = breaker) do
    :ets.insert(@table, {name, breaker})
    :ok
  end

  @doc """
  Lee el último circuito guardado para ese nombre.
  """
  @spec load(term()) :: {:ok, Breaker.t()} | {:error, :not_found}
  def load(name) do
    case :ets.lookup(@table, name) do
      [{_name, breaker}] -> {:ok, breaker}
      [] -> {:error, :not_found}
    end
  end

  @doc "Olvida el circuito guardado para ese nombre."
  @spec forget(term()) :: :ok
  def forget(name) do
    :ets.delete(@table, name)
    :ok
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
