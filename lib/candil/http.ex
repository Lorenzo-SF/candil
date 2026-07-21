defmodule Candil.HTTP do
  @moduledoc """
  Shared HTTP client with circuit breaker, retry, and rate limiting for Candil.

  Wraps `Arrea.CircuitBreaker` around all outbound HTTP calls. Uses
  `Apero.Retry` with exponential backoff for transient failures.
  Implements a sliding-window rate limiter per breaker name.

  Transport is provided by `Apero.Http` — a dedicated Finch pool managed
  by `Apero.Http.Finch`.
  """

  alias Apero.Http, as: AperoHTTP
  alias Apero.Retry
  alias Arrea.CircuitBreaker
  alias Candil.{Error, RateLimiter}

  @default_timeout_ms 60_000
  @default_stream_timeout_ms 120_000

  @type response :: %{status: pos_integer(), body: any(), headers: list()}

  @doc """
  Performs a POST request with JSON body, protected by circuit breaker and retry.

  ## Options

    * `:timeout_ms` — request timeout in milliseconds (default: 60_000)
    * `:retry` — enable retry with backoff (default: true)
    * `:max_retries` — maximum retry attempts (default: 3)
    * `:breaker_name` — circuit breaker name (default: from URL host)
    * `:rate_limit` — max requests per second (default: no limit)

  ## Returns

    * `{:ok, Candil.HTTP.response()}` — response map with status, body, headers
    * `{:error, Candil.Error.t()}` — error with unified error types
  """
  @spec post_json(binary(), map(), [{binary(), binary()}], keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def post_json(url, body, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    breaker = Keyword.get(opts, :breaker_name, breaker_name(url))
    rate_limit = Keyword.get(opts, :rate_limit)

    request_fn = fn ->
      with :ok <- check_rate_limit(breaker, rate_limit) do
        CircuitBreaker.call(breaker, fn ->
          do_post_json(url, body, headers, timeout)
        end)
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
      |> Retry.with(
        max_attempts: Keyword.get(opts, :max_retries, 3) + 1,
        base_delay: Keyword.get(opts, :base_delay, 1000),
        max_delay: Keyword.get(opts, :max_delay, 30_000),
        retry_on: fn
          {:ok, %{status: status}} when status in 429..599 -> true
          {:error, %{reason: :timeout}} -> true
          _ -> false
        end
      )
      |> wrap_error()
    else
      request_fn.()
      |> wrap_error()
    end
  end

  @doc """
  Performs a POST request with streaming response.

  The callback is called for each SSE data chunk. This function is used
  by `Candil.Stream` to handle streaming responses.

  ## Options

    * `:timeout_ms` — request timeout in milliseconds (default: 120_000)
    * `:into` — optional accumulator for streaming

  """
  @spec post_streaming(binary(), map(), [{binary(), binary()}], keyword(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def post_streaming(url, body, headers, opts \\ [], streaming_opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_stream_timeout_ms)
    breaker = Keyword.get(opts, :breaker_name, breaker_name(url))
    rate_limit = Keyword.get(opts, :rate_limit)

    request_fn = fn ->
      with :ok <- check_rate_limit(breaker, rate_limit) do
        CircuitBreaker.call(breaker, fn ->
          do_post_streaming(url, body, headers, timeout, streaming_opts)
        end)
        |> case do
          {:ok, _} = result -> result
          {:error, :circuit_open} -> {:error, Error.wrap(:circuit_open)}
          {:error, :execution_failed} -> {:error, Error.wrap(:execution_failed)}
          other -> other
        end
      end
    end

    result =
      if Keyword.get(opts, :retry, true) do
        request_fn
        |> Retry.with(
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

    case result do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, wrap_reason(reason)}
    end
  end

  @doc """
  Performs a GET request.

  ## Options

    * `:timeout_ms` — request timeout in milliseconds (default: 60_000)

  """
  @spec get(binary(), [{binary(), binary()}], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(url, headers \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case AperoHTTP.get(url, headers, receive_timeout: timeout) do
      {:ok, %AperoHTTP.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, %{status: status, body: body}}

      {:ok, %AperoHTTP.Response{status: 429, body: body}} ->
        {:error, Error.rate_limited(body["retry_after"])}

      {:ok, %AperoHTTP.Response{status: status, body: body}} ->
        {:error, Error.http_error(status, body)}

      {:error, %AperoHTTP.Error{reason: :timeout}} ->
        {:error, Error.timeout(%{url: url})}

      {:error, %AperoHTTP.Error{reason: reason}} ->
        {:error, Error.wrap(reason)}
    end
  end

  # Internal implementation

  defp do_post_json(url, body, headers, timeout) do
    case AperoHTTP.post(url, body, headers, receive_timeout: timeout) do
      {:ok, %AperoHTTP.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, %AperoHTTP.Error{} = error} ->
        {:error, error}
    end
  end

  defp do_post_streaming(url, body, headers, timeout, streaming_opts) do
    # Build a Finch-compatible streaming callback that:
    # 1. Skips status/headers entries (handled by the transport)
    # 2. Forwards {:data, data} and :done to the user's callback
    user_callback = Keyword.get(streaming_opts, :into, &default_stream_callback/2)

    stream_fun = fn entry, acc ->
      case entry do
        {:data, _data} -> user_callback.(entry, acc)
        {:done, _} -> {:halt, acc}
        _ -> {:cont, acc}
      end
    end

    case AperoHTTP.stream(:post, url, body, headers, [], stream_fun, receive_timeout: timeout) do
      {:ok, acc} ->
        {:ok, acc}

      {:error, %AperoHTTP.Error{reason: :timeout}} ->
        {:error, Error.timeout()}

      {:error, %AperoHTTP.Error{reason: reason}} ->
        {:error, Error.wrap(reason)}
    end
  end

  defp default_stream_callback({:data, data}, acc) do
    {:cont, [data | acc]}
  end

  defp default_stream_callback(:done, _acc) do
    {:halt, []}
  end

  defp breaker_name(url) do
    host = URI.parse(url).host
    existing_atom(host) || :default_breaker
  rescue
    _ -> :default_breaker
  end

  defp existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp check_rate_limit(_breaker, nil), do: :ok

  defp check_rate_limit(breaker, max_per_second) do
    RateLimiter.check(breaker, max_per_second)
  end

  @spec wrap_error(term()) :: {:ok, response()} | {:error, Error.t()}
  defp wrap_error({:ok, %{status: status} = response}) when status in 200..299 do
    {:ok, response}
  end

  defp wrap_error({:ok, %{status: 429, body: body}}) do
    {:error, Error.rate_limited(body["retry_after"])}
  end

  defp wrap_error({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, body)}
  end

  defp wrap_error({:error, %{reason: :timeout}}) do
    {:error, Error.timeout()}
  end

  defp wrap_error({:error, reason}) do
    {:error, Error.wrap(reason)}
  end

  defp wrap_reason(%{reason: :timeout}), do: Error.timeout()
  defp wrap_reason(reason), do: Error.wrap(reason)
end
