defmodule Candil.Embeddings do
  @moduledoc """
  Embedding generation abstraction over multiple providers.

  Provides a unified `embed/2` that dispatches to the correct provider
  (ollama, local llama.cpp, OpenAI-compatible API). Used as a lower-level
  embedding backend independent from `Candil.Llm` — this module accepts
  raw provider parameters (URL, model, api_key) rather than Candil structs.

  All HTTP requests are routed through `Candil.HTTP.post_json/4` which
  provides circuit breaker, retry, and rate limiting.
  """

  alias Candil.HTTP

  @typedoc "Embedding vector"
  @type embedding :: [float()]

  @doc """
  Generates an embedding vector for a single text string.

  ## Options

    - `:provider` — provider type (default: "local")
    - `:url` — base URL
    - `:model` — model name
    - `:api_key` — API key for authenticated providers
    - `:timeout` — request timeout in ms (default: 30_000)
  """
  @spec embed(String.t(), keyword()) ::
          {:ok, embedding()} | {:error, String.t() | Exception.t()}
  def embed(text, opts \\ []) when is_binary(text) do
    provider = Keyword.get(opts, :provider, "local")
    url = Keyword.get(opts, :url, "http://127.0.0.1:8080")
    model = Keyword.get(opts, :model, "bge-m3")
    api_key = Keyword.get(opts, :api_key)
    timeout = Keyword.get(opts, :timeout, 30_000)

    case provider do
      "ollama" -> embed_ollama(text, url, model, timeout)
      "local" -> embed_openai_compat(text, url, model, api_key, timeout)
      "openai" -> embed_openai_compat(text, url, model, api_key, timeout)
      _ -> {:error, "unknown provider: #{provider}"}
    end
  end

  @doc """
  Generates embeddings for multiple texts in batched requests.

  Texts are grouped into chunks of `:batch_size` (default 32) and each
  chunk is sent as one request to providers that support batch input
  (ollama, openai-compat).

  ## Options

    - `:provider` — provider type (default: "local")
    - `:batch_size` — max texts per request (default: 32)
    - `:url`, `:model`, `:api_key`, `:timeout` — forwarded to the provider
  """
  @spec embed_batch([String.t()], keyword()) ::
          {:ok, [embedding()]} | {:error, String.t() | Exception.t()}
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    provider = Keyword.get(opts, :provider, "local")
    batch_size = Keyword.get(opts, :batch_size, 32)

    case provider do
      "ollama" -> embed_batch_ollama(texts, opts)
      _ -> embed_batch_openai_compat(texts, opts, batch_size)
    end
  end

  # ── Ollama ──────────────────────────────────────────────────────────

  defp embed_ollama(text, url, model, timeout) do
    body = %{model: model, input: text}
    headers = [{"content-type", "application/json"}]

    case HTTP.post_json("#{url}/api/embed", body, headers, timeout_ms: timeout, retry: false) do
      {:ok, %{body: %{"embeddings" => [vec | _]}}} when is_list(vec) ->
        {:ok, vec}

      {:ok, _} ->
        {:error, "unexpected Ollama response format"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp embed_batch_ollama(texts, opts) do
    url = Keyword.get(opts, :url, "http://127.0.0.1:11434")
    model = Keyword.get(opts, :model, "llama3.2")
    timeout = Keyword.get(opts, :timeout, 60_000)

    body = %{model: model, input: texts}
    headers = [{"content-type", "application/json"}]

    case HTTP.post_json("#{url}/api/embed", body, headers, timeout_ms: timeout, retry: false) do
      {:ok, %{body: %{"embeddings" => vectors}}} when is_list(vectors) ->
        {:ok, vectors}

      {:ok, _} ->
        {:error, "unexpected Ollama batch response format"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # ── OpenAI-compatible (llama.cpp, vLLM, Groq, Together, etc.) ──────

  defp embed_openai_compat(text, url, model, api_key, timeout) do
    req_body = %{model: model, input: text, encoding_format: "float"}

    headers =
      if api_key && api_key != "" do
        [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}]
      else
        [{"content-type", "application/json"}]
      end

    case HTTP.post_json("#{url}/v1/embeddings", req_body, headers,
           timeout_ms: timeout,
           retry: false
         ) do
      {:ok, %{body: %{"data" => [%{"embedding" => vec} | _]}}} when is_list(vec) ->
        {:ok, vec}

      {:ok, _} ->
        {:error, "unexpected OpenAI-compat response format"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp embed_batch_openai_compat(texts, opts, batch_size) do
    url = Keyword.get(opts, :url, "http://127.0.0.1:8080")
    model = Keyword.get(opts, :model, "bge-m3")
    api_key = Keyword.get(opts, :api_key)
    timeout = Keyword.get(opts, :timeout, 60_000)

    headers =
      if api_key && api_key != "" do
        [{"authorization", "Bearer #{api_key}"}, {"content-type", "application/json"}]
      else
        [{"content-type", "application/json"}]
      end

    texts
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      req_body = %{model: model, input: chunk, encoding_format: "float"}

      case HTTP.post_json("#{url}/v1/embeddings", req_body, headers,
             timeout_ms: timeout,
             retry: false
           ) do
        {:ok, %{body: %{"data" => data}}} when is_list(data) ->
          vectors =
            Enum.map(data, fn
              %{"embedding" => vec} when is_list(vec) -> vec
              _ -> nil
            end)

          if Enum.any?(vectors, &is_nil/1) do
            {:halt, {:error, "unexpected OpenAI-compat batch response format"}}
          else
            {:cont, {:ok, acc ++ vectors}}
          end

        {:ok, _} ->
          {:halt, {:error, "unexpected OpenAI-compat batch response format"}}

        {:error, reason} ->
          {:halt, {:error, inspect(reason)}}
      end
    end)
    |> case do
      {:ok, vectors} -> {:ok, vectors}
      error -> error
    end
  end
end
