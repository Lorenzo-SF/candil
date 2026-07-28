defmodule Candil.RateLimiter do
  @moduledoc """
  Global sliding-window rate limiter backed by ETS.

  Replaces the per-process `Process.get/1`/`Process.put/2` approach so
  that rate limits apply globally across all processes using the same
  circuit breaker.

  The ETS table is created lazily on first access. Each breaker name
  has its own sliding window of recent request timestamps.
  """

  alias Candil.Error

  @table_name :candil_rate_limiter

  @doc """
  Starts the rate limiter ETS table.

  Safe to call multiple times — second call is a no-op.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(_opts \\ []) do
    ensure_table()
    :ignore
  end

  @doc """
  Checks whether a request for `breaker` is within the rate limit.
  Returns `:ok` or `{:error, Candil.Error.t()}` with the retry-after
  delay in milliseconds.
  """
  @spec check(binary() | atom(), pos_integer() | nil) :: :ok | {:error, Error.t()}
  def check(_breaker, nil), do: :ok

  def check(breaker, max_per_second) when is_integer(max_per_second) and max_per_second > 0 do
    ensure_table()
    now = System.monotonic_time(:millisecond)
    window_ms = 1000

    timestamps =
      case :ets.lookup(@table_name, breaker) do
        [{_key, list}] when is_list(list) -> list
        [] -> []
      end

    recent = Enum.filter(timestamps, &(now - &1 < window_ms))

    if length(recent) < max_per_second do
      :ets.insert(@table_name, {breaker, [now | recent]})
      :ok
    else
      retry_after = window_ms - (now - List.last(recent))
      {:error, Error.rate_limited(max(retry_after, 0))}
    end
  end

  defp ensure_table do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:set, :protected, :named_table])

      _ ->
        :ok
    end
  end
end
