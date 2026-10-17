defmodule Candil.Agents.Snapshots do
  @moduledoc """
  The last stable state of every agent that has one.

  A process that crashes takes its state with it, and the supervisor that
  raises it again gives it its start-up arguments back — not its state. A
  snapshot is that state written down somewhere that outlives the process, so
  the agent that comes back can be the agent that was, and not a stranger with
  the same name (F5.4, `docs/04-modulos/05-agentes` §5.1, type 2).

  ## Keyed by name

  The key is the agent's name — the same name its supervisor starts it under.
  That is what makes the restart work: the process that comes back asks for
  its own name and finds what it left. Two agents with the same name share
  the same last state: the name is the identity, so do not do that.

  ## Nothing evicts, yet

  An agent that will never come back leaves its snapshot behind. `forget/1`
  is the door for whoever knows that, and who forgets and when is a policy
  this phase deliberately does not take.
  """

  use GenServer

  @table :candil_agents_snapshots

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Writes an agent's state down under its name, replacing whatever was there.

  The snapshot is opaque here: this store does not look inside.
  """
  @spec save(term(), map()) :: :ok
  def save(name, snapshot) when is_map(snapshot) do
    :ets.insert(@table, {name, snapshot})
    :ok
  end

  @doc """
  Reads the last state stored under that name.
  """
  @spec load(term()) :: {:ok, map()} | {:error, :not_found}
  def load(name) do
    case :ets.lookup(@table, name) do
      [{_name, snapshot}] -> {:ok, snapshot}
      [] -> {:error, :not_found}
    end
  end

  @doc "Forgets the state stored under that name."
  @spec forget(term()) :: :ok
  def forget(name) do
    :ets.delete(@table, name)
    :ok
  end

  @doc false
  @impl GenServer
  def init(_opts) do
    # La tabla es de ESTE proceso, no del agente: el agente muere y la tabla
    # sigue — que es toda la razón de que este módulo exista. Va `:public`
    # para que guardar no pase por el GenServer: el camino es cada vuelta de
    # un agente, y una vuelta no debe depender del mailbox de una tienda.
    # Mismas banderas que `Candil.Context` (F5.2).
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
