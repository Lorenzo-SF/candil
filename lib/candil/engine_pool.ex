defmodule Candil.EnginePool do
  @moduledoc """
  Registry of the engine instances that are actually running.

  An instance is a `{model_alias, port}` pair. The same model can be alive on
  more than one port — a GPU slot and a CPU slot, which is what `--cpu` gives
  you — so the alias alone is not a key. What is a key is the pair, because
  that is what a request is routed to.

  ## Why this stopped being a pool

  It used to be an LRU of `N` engines with a `get/0` that returned the least
  recently used one and an `evict/0` that nobody called. That was pretending to
  solve a memory-pressure problem nobody has: four 20 GB models do not fit, and
  an LRU of four entries does not change that. It just made the catalogue look
  like it was managing capacity.

  So there is no capacity and no eviction here. This records what is alive, and
  a process that is not alive is not a decision this module gets to make.

  ## The port is the hard part

  `claim_port/2` does not ask the operating system for a free port; it asks
  whether something is *listening*. The difference matters: a `ropero` server
  that was killed badly, or a `llama-server` whose process is a zombie holding
  the socket, occupies a port that every "is it in use" test says is free.
  Connecting is the only check that tells the two apart.
  """

  use GenServer

  alias Candil.{Engine, Model}

  @connect_host ~c"127.0.0.1"

  # A refused connection on loopback is immediate. This is the ceiling for the
  # one case where something is listening but not answering, and a hundred
  # ports at a tenth of a second each is still faster than a failed start.
  @connect_timeout_ms 100

  @typedoc """
  One running engine: which model it serves, on which port, under which
  engine, and which process owns it.
  """
  @type instance :: %{
          alias: atom(),
          port: pos_integer(),
          pid: pid() | nil,
          model: Model.t(),
          engine: Engine.t(),
          started_at: integer(),
          healthy: boolean()
        }

  @typedoc "The key an instance is registered under."
  @type key :: {atom(), pos_integer()}

  ## Public API

  @doc "Starts the registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Registers a running instance under `{model_alias, port}`.

  A call rather than a cast, which is what it used to be. A cast returns `:ok`
  whether or not the entry was ever stored, so a caller that had just started a
  `llama-server` had no way to know whether the pool knew about it — and the
  answer determined which port the next request went to.

  `healthy` starts out `true`. Nothing flips it yet: the health poller that
  will is a later phase, and until then this reports the same thing it did
  before, which is "we have not heard otherwise".
  """
  @spec put(atom(), pos_integer(), pid() | nil, Model.t(), Engine.t()) :: :ok
  def put(model_alias, port, pid, %Model{} = model, %Engine{} = engine)
      when is_atom(model_alias) and is_integer(port) and port > 0 do
    GenServer.call(__MODULE__, {:put, model_alias, port, pid, model, engine})
  end

  @doc "Removes an instance. Unknown keys are not an error: the point of the call is the absence."
  @spec delete(atom(), pos_integer()) :: :ok
  def delete(model_alias, port) when is_atom(model_alias) and is_integer(port) and port > 0 do
    GenServer.call(__MODULE__, {:delete, model_alias, port})
  end

  @doc "Looks up one instance."
  @spec get(atom(), pos_integer()) :: {:ok, instance()} | :error
  def get(model_alias, port) when is_atom(model_alias) and is_integer(port) and port > 0 do
    GenServer.call(__MODULE__, {:get, model_alias, port})
  end

  @doc """
  Every instance of one model, across all of its ports.

  This is the multi-slot case: the same GGUF on a GPU port and on a CPU port
  are two instances of one model, and this is how you find them.
  """
  @spec by_model(atom()) :: [instance()]
  def by_model(model_alias) when is_atom(model_alias) do
    GenServer.call(__MODULE__, {:by_model, model_alias})
  end

  @doc "Every registered instance."
  @spec list() :: [instance()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "How many instances are registered."
  @spec count() :: non_neg_integer()
  def count, do: GenServer.call(__MODULE__, :count)

  @doc "The ports that are in use, ascending."
  @spec ports() :: [pos_integer()]
  def ports, do: GenServer.call(__MODULE__, :ports)

  @doc """
  Returns a port in `base..max` that is free in both senses.

  Free as far as this registry knows — a port already handed to an instance is
  skipped — and free as far as the operating system is concerned, which is
  decided by actually connecting. A closed port refuses; a port with something
  listening accepts. That is the whole test.

  Returns `{:error, :no_free_port}` when the range is exhausted.

  This does **not** reserve what it returns. The caller is expected to
  `put/5` straight away, and until it does, the next `claim_port/2` can hand
  the same port out again. Reserving needs a model alias, and the key is
  `{alias, port}`.
  """
  @spec claim_port(pos_integer(), pos_integer()) :: {:ok, pos_integer()} | {:error, :no_free_port}
  def claim_port(base, max)
      when is_integer(base) and is_integer(max) and base > 0 and max >= base do
    GenServer.call(__MODULE__, {:claim_port, base, max})
  end

  @doc false
  @deprecated "Use get/2, by_model/1 or list/0. An LRU of engines with no capacity to enforce."
  @spec get() :: :empty | map()
  def get do
    IO.warn(
      "Candil.EnginePool.get/0 is deprecated and returns :empty. " <>
        "Use get/2, by_model/1 or list/0 — this is a registry of running instances, not a pool.",
      []
    )

    :empty
  end

  ## GenServer callbacks

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:put, model_alias, port, pid, model, engine}, _from, state) do
    instance = %{
      alias: model_alias,
      port: port,
      pid: pid,
      model: model,
      engine: engine,
      started_at: System.monotonic_time(:millisecond),
      healthy: true
    }

    {:reply, :ok, Map.put(state, {model_alias, port}, instance)}
  end

  def handle_call({:delete, model_alias, port}, _from, state) do
    {:reply, :ok, Map.delete(state, {model_alias, port})}
  end

  def handle_call({:get, model_alias, port}, _from, state) do
    case Map.fetch(state, {model_alias, port}) do
      {:ok, instance} -> {:reply, {:ok, instance}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:by_model, model_alias}, _from, state) do
    matches =
      state
      |> Enum.filter(fn {{alias, _port}, _instance} -> alias == model_alias end)
      |> Enum.sort_by(fn {_key, instance} -> instance.port end)
      |> Enum.map(fn {_key, instance} -> instance end)

    {:reply, matches, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, sorted(state), state}
  end

  def handle_call(:count, _from, state) do
    {:reply, map_size(state), state}
  end

  def handle_call(:ports, _from, state) do
    ports = state |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    {:reply, ports, state}
  end

  def handle_call({:claim_port, base, max}, _from, state) do
    taken = MapSet.new(state, fn {key, _instance} -> elem(key, 1) end)

    case Enum.find(base..max, &(not MapSet.member?(taken, &1) and free?(&1))) do
      nil -> {:reply, {:error, :no_free_port}, state}
      port -> {:reply, {:ok, port}, state}
    end
  end

  defp sorted(state) do
    state
    |> Enum.sort_by(fn {{_alias, port}, instance} -> {port, instance.alias} end)
    |> Enum.map(fn {_key, instance} -> instance end)
  end

  defp free?(port) do
    case :gen_tcp.connect(@connect_host, port, [:binary, active: false], @connect_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, _reason} ->
        true
    end
  end
end
