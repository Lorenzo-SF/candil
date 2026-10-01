defmodule Candil.Context.PrefixManager do
  @moduledoc """
  Caches a long system prompt per model, so it can be reused byte for byte.

  ## Why byte for byte

  The prompt is still sent every time. The cache does not avoid the transfer.
  What it enables is the provider-side prefix cache: a server that keeps a KV
  cache across requests can reuse the prefix only if the bytes are identical.
  One changed character early in the prompt invalidates everything after it.

  So the value is not bytes, it is stability. `stats/0` exists because the
  claim is only worth something if you can check it holds in your setup: if
  the hit rate is zero, the prefix is not stable enough for a cache and the
  number tells you so.

  The key is `{model, sha256(prompt)}`, so two models never share an entry
  even with the same prompt, and changing the prompt is a miss rather than a
  stale hit.
  """

  use GenServer

  # Module attributes, not atoms built at runtime. The counter keys are fixed
  # at compile time for the same reason the atom-table warning exists.
  @hits_key {:__hits__, nil}
  @misses_key {:__misses__, nil}

  @table :candil_prefix_cache
  @default_ttl_ms 600_000

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Caches a prompt for a model.
  """
  @spec put(atom(), String.t(), pos_integer()) :: :ok
  def put(model_alias, prompt, ttl_ms \\ @default_ttl_ms) do
    key = {model_alias, digest(prompt)}
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {key, prompt, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Reads a cached prompt, or `:miss`.
  """
  @spec get(atom(), String.t()) :: {:ok, String.t()} | :miss
  def get(model_alias, prompt) do
    key = {model_alias, digest(prompt)}

    case :ets.lookup(@table, key) do
      [{^key, stored, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, stored}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Empties the cache and the counters.
  """
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ets.delete(@table, @hits_key)
    :ets.delete(@table, @misses_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Hits and misses, for deciding whether the prefix cache is worth having.
  """
  @spec stats() :: %{hits: non_neg_integer(), misses: non_neg_integer()}
  def stats do
    %{hits: counter(@hits_key), misses: counter(@misses_key)}
  end

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp digest(prompt), do: :crypto.hash(:sha256, prompt)

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

    :ets.insert(@table, {@hits_key, 0})
    :ets.insert(@table, {@misses_key, 0})
    {:ok, %{}}
  end
end
