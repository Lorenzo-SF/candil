defmodule Candil.EnginePool do
  @moduledoc """
  Lightweight LRU pool for `Candil.Engine` instances.

  The pool keeps a list of engines ordered from most‑recently used to
  least‑recently used. Each engine is identified by its ``alias``. The
  public API mimics a simple key‑value store with LRU semantics:

  * ``start_link/0`` – starts the pool as a GenServer named
    ``__MODULE__``.
  * ``put/1`` – insert or update an engine, marking it as most
    recently used.
  * ``get/0`` – return the least‑recently used engine and promote
    it to “most recently used”.
  * ``evict/0`` – remove the least‑recently used engine from the pool
    and return it.
  """

  use GenServer

  @typedoc "Engine struct expected by the pool"
  @type engine :: struct()

  ## Public API
  @doc "Starts the engine pool GenServer."
  @spec start_link() :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Marks an engine as most recently used (or inserts it)."
  @spec put(engine) :: :ok
  def put(engine) when is_map(engine) do
    GenServer.cast(__MODULE__, {:put, engine})
  end

  @doc "Returns the least recently used engine, promoting it to MRU."
  @spec get() :: engine | :empty
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc "Evicts the least recently used engine and returns it."
  @spec evict() :: engine | :empty
  def evict do
    GenServer.call(__MODULE__, :evict)
  end

  ## GenServer callbacks
  def init(_opts) do
    {:ok, []}
  end

  def handle_cast({:put, engine}, state) do
    # Remove any previous occurrence of this alias
    state = Enum.reject(state, fn e -> Map.get(e, :alias) == Map.get(engine, :alias) end)
    {:noreply, [engine | state]}
  end

  def handle_call(:get, _from, []), do: {:reply, :empty, []}
  def handle_call(:get, _from, state) do
    {least, rest} = List.pop_at(state, -1)
    new_state = [least | rest]
    {:reply, least, new_state}
  end

  def handle_call(:evict, _from, []), do: {:reply, :empty, []}
  def handle_call(:evict, _from, state) do
    {least, rest} = List.pop_at(state, -1)
    {:reply, least, rest}
  end
end
