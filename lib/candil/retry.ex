defmodule Candil.Retry do
  @moduledoc """
  Retry with exponential backoff for remote operations.

  Provides utilities for retrying operations that may fail transiently,
  such as network requests to LLM providers.

  ## Configuration

  Default values can be overridden via application config:

      config :candil, Candil.Retry,
        max_retries: 3,
        base_delay: 1000,
        max_delay: 30_000,
        jitter: 0.1

  """

  @default_max_retries 3
  @default_base_delay 1000
  @default_max_delay 30_000
  @default_jitter 0.1

  @type retryable_error :: {:error, :timeout | :rate_limited | :http_error}

  @doc """
  Executes a function with exponential backoff retry.

  ## Options

    * `:max_retries` — maximum number of retry attempts (default: 3)
    * `:base_delay` — base delay in milliseconds (default: 1000)
    * `:max_delay` — maximum delay in milliseconds (default: 30_000)
    * `:jitter` — random jitter factor 0.0-1.0 (default: 0.1)
    * `:retry_on` — list of error reasons to retry on (default: `[:timeout, :rate_limited]`)

  ## Examples

      Candil.Retry.with_retry(fn ->
        Req.post(url, json: body)
      end)

      Candil.Retry.with_retry(fn ->
        some_operation()
      end, max_retries: 5, base_delay: 500)

  """
  @spec with_retry((-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_retries = Keyword.get(opts, :max_retries, default_max_retries())
    base_delay = Keyword.get(opts, :base_delay, default_base_delay())
    max_delay = Keyword.get(opts, :max_delay, default_max_delay())
    jitter_factor = Keyword.get(opts, :jitter, default_jitter())
    retry_on = Keyword.get(opts, :retry_on, default_retry_on())

    do_retry(fun, max_retries, base_delay, max_delay, jitter_factor, retry_on, 0)
  end

  defp do_retry(fun, max_retries, base_delay, max_delay, jitter, retry_on, attempt) do
    case fun.() do
      {:ok, _} = result ->
        result

      {:error, reason} = error ->
        if attempt < max_retries and retryable?(reason, retry_on) do
          delay = calculate_delay(attempt, base_delay, max_delay, jitter)

          :timer.sleep(delay)

          do_retry(
            fun,
            max_retries,
            base_delay,
            max_delay,
            jitter,
            retry_on,
            attempt + 1
          )
        else
          error
        end
    end
  end

  defp retryable?(reason, retry_on) when is_list(retry_on) do
    reason in retry_on
  end

  defp retryable?(_reason, _retry_on), do: false

  defp calculate_delay(attempt, base_delay, max_delay, jitter) do
    exponential = :math.pow(2, attempt) * base_delay
    capped = min(exponential, max_delay)

    jitter_amount = capped * jitter * (:rand.uniform() * 2 - 1)
    floor(capped + jitter_amount)
  end

  # Default getters from application config
  defp default_max_retries,
    do:
      Application.get_env(:candil, __MODULE__, [])
      |> Keyword.get(:max_retries, @default_max_retries)

  defp default_base_delay,
    do:
      Application.get_env(:candil, __MODULE__, [])
      |> Keyword.get(:base_delay, @default_base_delay)

  defp default_max_delay,
    do:
      Application.get_env(:candil, __MODULE__, []) |> Keyword.get(:max_delay, @default_max_delay)

  defp default_jitter,
    do: Application.get_env(:candil, __MODULE__, []) |> Keyword.get(:jitter, @default_jitter)

  defp default_retry_on, do: [:timeout, :rate_limited]

  @doc """
  Returns the delay for a given attempt number (useful for testing).
  """
  @spec delay_for_attempt(non_neg_integer(), keyword()) :: non_neg_integer()
  def delay_for_attempt(attempt, opts \\ []) do
    base_delay = Keyword.get(opts, :base_delay, @default_base_delay)
    max_delay = Keyword.get(opts, :max_delay, @default_max_delay)
    jitter = Keyword.get(opts, :jitter, @default_jitter)

    calculate_delay(attempt, base_delay, max_delay, jitter)
  end
end
