defmodule Candil.HTTP.Retry do
  @moduledoc false

  alias Apero.Retry, as: AperoRetry
  alias Arrea.CircuitBreaker
  alias Candil.Error
  alias Candil.RateLimiter

  @doc """
  Wraps a raw request function with circuit breaker and retry.
  """
  def run(raw_request_fn, breaker, rate_limit, opts) do
    request_fn = fn ->
      with :ok <- check_rate_limit(breaker, rate_limit) do
        CircuitBreaker.call(breaker, raw_request_fn)
        |> case do
          {:ok, result} -> result
          {:error, :circuit_open} -> {:error, Error.wrap(:circuit_open)}
          {:error, :execution_failed} -> {:error, Error.wrap(:execution_failed)}
          other -> other
        end
      end
    end

    if Keyword.get(opts, :retry, true) do
      request_fn
      |> AperoRetry.with(
        max_attempts: Keyword.get(opts, :max_retries, 3) + 1,
        base_delay: Keyword.get(opts, :base_delay, 1000),
        max_delay: Keyword.get(opts, :max_delay, 30_000),
        retry_on: fn
          {:ok, %{status: status}} when status in 429..599 -> true
          {:error, %{reason: :timeout}} -> true
          _ -> false
        end
      )
    else
      request_fn.()
    end
  end

  defp check_rate_limit(_breaker, nil), do: :ok

  defp check_rate_limit(breaker, max_per_second) do
    RateLimiter.check(breaker, max_per_second)
  end
end
