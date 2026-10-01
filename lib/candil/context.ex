defmodule Candil.Context do
  @moduledoc """
  Conversation history shared between consumers, partitioned by consumer.

  Why this exists: `Candil.Conversation` keeps history in the process that
  calls it. Two consumers in the same VM each have their own, they cannot be
  shared, nothing can be summarised, and nothing survives a restart. That is
  the right default for a library and the wrong one for an agent that talks to
  several tools over several turns.

  ## The partition is the design

  Everything is keyed by `{consumer, session_id}`. `posadero` and `opencode`
  may both call a session `"s1"` and must not see each other's messages. A
  plain `session_id` key would collide, and the failure would be silent: the
  right number of messages from the wrong conversation.

  ## Eviction is both LRU and TTL

  A TTL alone collects sessions nobody returns to, but not a process that
  opens a new session on every request. An LRU alone bounds memory but keeps
  dead entries alive until pressure arrives. Both, because they fail
  differently.
  """

  use GenServer

  alias Candil.Context.Session

  @table :candil_context_sessions

  @default_max_sessions 1_000
  @default_ttl_seconds 86_400

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a session, or returns the existing one.

  Idempotent, because two processes racing to create the same session should
  not produce a lost update or a crash.
  """
  @spec create(atom(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def create(consumer, id) do
    case get(consumer, id) do
      {:ok, session} ->
        {:ok, session}

      {:error, :not_found} ->
        session = Session.new(consumer, id)

        if :ets.insert_new(@table, {{consumer, id}, session}) do
          {:ok, session}
        else
          get(consumer, id)
        end
    end
  end

  @doc """
  Reads a session.
  """
  @spec get(atom(), String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get(consumer, id) do
    case :ets.lookup(@table, {consumer, id}) do
      [{_key, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Appends a message, creating the session if it does not exist.
  """
  @spec append_message(atom(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def append_message(consumer, session_id, role, content) do
    with {:ok, session} <- create(consumer, session_id) do
      updated = Session.add_message(session, role, content)
      :ets.insert(@table, {{consumer, session_id}, updated})
      :ok
    end
  end

  @doc """
  Applies a function to a session and stores the result.
  """
  @spec update(atom(), String.t(), (Session.t() -> Session.t())) :: :ok | {:error, :not_found}
  def update(consumer, session_id, fun) when is_function(fun, 1) do
    case get(consumer, session_id) do
      {:ok, session} ->
        :ets.insert(@table, {{consumer, session_id}, fun.(session)})
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes one session. The consumer's other sessions are untouched.
  """
  @spec delete(atom(), String.t()) :: :ok
  def delete(consumer, session_id) do
    :ets.delete(@table, {consumer, session_id})
    :ok
  end

  @doc """
  Lists a consumer's sessions, most recently used first.
  """
  @spec list(atom()) :: [Session.t()]
  def list(consumer) do
    :ets.match_object(@table, {{consumer, :"$1"}, :"$2"})
    |> Enum.map(fn {_key, session} -> session end)
    |> Enum.sort_by(& &1.last_used_at, {:desc, DateTime})
  end

  @doc """
  Lists every consumer that has at least one session.
  """
  @spec consumers() :: [atom()]
  def consumers do
    :ets.match_object(@table, {{:"$1", :_}, :_})
    |> Enum.map(fn {key, _session} -> elem(key, 0) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  How many sessions a consumer has.
  """
  @spec count(atom()) :: non_neg_integer()
  def count(consumer), do: length(list(consumer))

  @doc """
  Collects expired sessions, and evicts the least recently used above
  `max_sessions`.

  Returns `{:ok, %{ttl: n, lru: m}}` with how many of each were removed.
  """
  @spec gc(keyword()) :: {:ok, %{ttl: non_neg_integer(), lru: non_neg_integer()}}
  def gc(opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    max = Keyword.get(opts, :max_sessions, @default_max_sessions)
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_seconds, :second)

    all = :ets.tab2list(@table)

    expired =
      Enum.filter(all, fn {_key, session} ->
        DateTime.compare(session.last_used_at, cutoff) == :lt
      end)

    Enum.each(expired, fn {key, _session} -> :ets.delete(@table, key) end)

    {lru, _} = evict_lru(all -- expired, max)

    {:ok, %{ttl: length(expired), lru: lru}}
  end

  defp evict_lru(sessions, max) when length(sessions) <= max, do: {0, sessions}

  defp evict_lru(sessions, max) do
    sorted = Enum.sort_by(sessions, fn {_key, session} -> session.last_used_at end)
    # max(excess, 0), NOT max(-excess, 0). Negating before calling max/2 gives
    # 0 for every over-limit case, because the negative side always wins, and
    # Enum.split(sorted, 0) removes nothing. The collection silently never
    # collected anything.
    excess = max(length(sorted) - max, 0)
    {to_remove, keep} = Enum.split(sorted, excess)
    Enum.each(to_remove, fn {key, _session} -> :ets.delete(@table, key) end)
    {length(to_remove), keep}
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

    schedule_gc()
    {:ok, %{}}
  end

  defp schedule_gc do
    Process.send_after(self(), :gc, max(div(@default_ttl_seconds * 1000, 10), 3_600_000))
  end

  @doc false
  @impl GenServer
  def handle_info(:gc, state) do
    # A collection failure must not take the GenServer down: the table is the
    # only state and a crash here loses every session.
    _ = gc()
    interval = div(@default_ttl_seconds * 1000, 10)
    Process.send_after(self(), :gc, max(interval, 3_600_000))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
