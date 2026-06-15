defmodule Candil.HTTP do
  @moduledoc """
  Shared HTTP client with retry and backoff for Candil.

  This module consolidates HTTP logic previously duplicated between
  `Candil.Inference` and `Candil.Stream`, providing:

  - Automatic retry with exponential backoff for transient errors
  - Configurable timeouts
  - Rate limiting detection (429 responses)
  - Proper error transformation to `Candil.Error`
  """

  alias Candil.{Error, Retry}

  @default_timeout_ms 60_000
  @default_stream_timeout_ms 120_000

  @doc """
  Performs a POST request with JSON body and optional retry.

  ## Options

    * `:timeout_ms` — request timeout in milliseconds (default: 60_000)
    * `:retry` — enable retry with backoff (default: true)
    * `:max_retries` — maximum retry attempts (default: 3)

  ## Returns

    * `{:ok, map()}` — successful response body
    * `{:error, Candil.Error.t()}` — error with unified error types
  """
  @spec post_json(binary(), map(), [{binary(), binary()}], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def post_json(url, body, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    retry? = Keyword.get(opts, :retry, true)

    request_fn = fn ->
      do_post_json(url, body, headers, timeout)
    end

    if retry? do
      request_fn
      |> Retry.with_retry(
        max_retries: Keyword.get(opts, :max_retries, 3),
        base_delay: Keyword.get(opts, :base_delay, 1000),
        retry_on: [:timeout, :rate_limited]
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

    case do_post_streaming(url, body, headers, timeout, streaming_opts) do
      {:ok, _} = result ->
        result

      {:error, reason} ->
        {:error, wrap_reason(reason)}
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

    case Req.get(url, headers: headers, receive_timeout: timeout) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %{status: status, body: body}}

      {:ok, %{status: 429, body: body}} ->
        {:error, Error.rate_limited(body["retry_after"])}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.http_error(status, body)}

      {:error, %{reason: :timeout}} ->
        {:error, Error.timeout(%{url: url})}

      {:error, reason} ->
        {:error, Error.wrap(reason)}
    end
  end

  # Internal implementation

  defp do_post_json(url, body, headers, timeout) do
    Req.post(url,
      json: body,
      headers: headers,
      receive_timeout: timeout
    )
  end

  defp do_post_streaming(url, body, headers, timeout, streaming_opts) do
    Req.post(url,
      json: body,
      headers: headers,
      receive_timeout: timeout,
      into: Keyword.get(streaming_opts, :into, &stream_callback/2)
    )
  end

  defp stream_callback({:data, data}, acc) do
    {:cont, [data | acc]}
  end

  defp stream_callback(:done, acc) do
    {:halt, Enum.reverse(acc)}
  end

  defp wrap_error({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, %{status: status, body: body}}
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
