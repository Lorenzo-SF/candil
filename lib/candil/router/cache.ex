defmodule Candil.Router.Cache do
  @moduledoc """
  Prompt hash to decision, with a TTL.

  The key is a hash of the messages rather than the messages, because ETS keys
  have a size limit and a long conversation does not fit in one. The hash is
  over the last user turn only: routing a follow-up should follow the same
  route as the question it follows, not the whole transcript.

  Not bounded in size. A routing cache is not a cache of anything expensive,
  it is a small map of hashes, and a size limit on it would mostly evict
  entries that were about to be useful.
  """

  use GenServer

  alias Candil.Router.Decision

  @table :candil_router_cache

  @default_ttl_seconds 300

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The hash used as a cache key for a message list.

  Only the last user turn counts. Two turns of the same conversation in the
  same conversation route the same way.

  ## The consumer is part of the key

  It has to be. A pin or a candidate list is per consumer, so the same prompt
  can route to different models for different consumers — and a key of the
  prompt alone means whichever consumer routed first decides for all of them.
  That is the exact leak the `{consumer, session_id}` partitioning exists to
  prevent, reappearing in the cache.
  """
  @spec key([map()], atom()) :: {atom(), binary()}
  def key(messages, consumer \\ :default) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find_value("", fn
        %{role: "user", content: content} -> content
        _ -> nil
      end)

    hash =
      :crypto.hash(:sha256, last_user)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    {consumer, hash}
  end

  @doc """
  Reads a decision from the cache.
  """
  @spec get([map()], atom()) :: {:ok, Decision.t()} | :miss
  def get(messages, consumer \\ :default) do
    case :ets.lookup(@table, key(messages, consumer)) do
      [{_key, decision, expires_at}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:ok, decision}
        else
          :ets.delete(@table, key(messages, consumer))
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Stores a decision.

  Ignores a cache miss rather than failing: the caller has a decision either
  way, and a full cache is not a reason to fail a request.
  """
  @spec put([map()], Decision.t(), keyword()) :: :ok
  def put(messages, %Decision{} = decision, opts \\ []) do
    consumer = Keyword.get(opts, :consumer, :default)
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
    :ets.insert(@table, {key(messages, consumer), decision, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Empties the cache.
  """
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
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
