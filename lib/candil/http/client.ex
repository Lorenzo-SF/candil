defmodule Candil.HTTP.Client do
  @moduledoc false

  alias Apero.Http, as: AperoHTTP
  alias Candil.Error

  @type response :: %{status: pos_integer(), body: any(), headers: list()}

  @spec get(binary(), [{binary(), binary()}], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(url, headers \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)

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

  def do_post_json(url, body, headers, timeout) do
    case AperoHTTP.post(url, body, headers, receive_timeout: timeout) do
      {:ok, %AperoHTTP.Response{status: status, headers: headers, body: body}} ->
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, %AperoHTTP.Error{} = error} ->
        {:error, error}
    end
  end

  def do_post_streaming(url, body, headers, timeout, streaming_opts) do
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

  def default_stream_callback({:data, data}, acc) do
    {:cont, [data | acc]}
  end

  def default_stream_callback(:done, _acc) do
    {:halt, []}
  end

  def breaker_name(url) do
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

  @spec wrap_error(term()) :: {:ok, response()} | {:error, Error.t()}
  def wrap_error({:ok, %{status: status} = response}) when status in 200..299 do
    {:ok, response}
  end

  def wrap_error({:ok, %{status: 429, body: body}}) do
    {:error, Error.rate_limited(body["retry_after"])}
  end

  def wrap_error({:ok, %{status: status, body: body}}) do
    {:error, Error.http_error(status, body)}
  end

  def wrap_error({:error, %{reason: :timeout}}) do
    {:error, Error.timeout()}
  end

  def wrap_error({:error, reason}) do
    {:error, Error.wrap(reason)}
  end

  def wrap_reason(%{reason: :timeout}), do: Error.timeout()
  def wrap_reason(reason), do: Error.wrap(reason)
end
