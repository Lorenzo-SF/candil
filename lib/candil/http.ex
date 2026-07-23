defmodule Candil.HTTP do
  @moduledoc """
  Shared HTTP client with circuit breaker, retry, and rate limiting for Candil.

  Wraps `Arrea.CircuitBreaker` around all outbound HTTP calls. Uses
  `Apero.Retry` with exponential backoff for transient failures.
  Implements a sliding-window rate limiter per breaker name.

  Transport is provided by `Apero.Http` — a dedicated Finch pool managed
  by `Apero.Http.Finch`.
  """

  alias Candil.Error
  alias Candil.HTTP.Client
  alias Candil.HTTP.Retry

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
    breaker = Keyword.get(opts, :breaker_name, Client.breaker_name(url))
    rate_limit = Keyword.get(opts, :rate_limit)

    fn -> Client.do_post_json(url, body, headers, timeout) end
    |> Retry.run(breaker, rate_limit, opts)
    |> Client.wrap_error()
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
    breaker = Keyword.get(opts, :breaker_name, Client.breaker_name(url))
    rate_limit = Keyword.get(opts, :rate_limit)

    result =
      fn -> Client.do_post_streaming(url, body, headers, timeout, streaming_opts) end
      |> Retry.run(breaker, rate_limit, opts)

    case result do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, Client.wrap_reason(reason)}
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
    Client.get(url, headers, opts)
  end
end
