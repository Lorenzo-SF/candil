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
  Generates embeddings for multiple texts in a single batch request.

  Falls back to individual requests if batching is not supported by the provider.
  """
  @spec embed_batch([String.t()], keyword()) ::
          {:ok, [embedding()]} | {:error, String.t() | Exception.t()}
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    provider = Keyword.get(opts, :provider, "local")

    case provider do
      "ollama" -> embed_batch_ollama(texts, opts)
      _ -> embed_batch_openai_compat(texts, opts)
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

  defp embed_batch_openai_compat(texts, opts) do
    results =
      Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, acc} ->
        case embed(text, opts) do
          {:ok, vec} -> {:cont, {:ok, [vec | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case results do
      {:ok, vecs} -> {:ok, Enum.reverse(vecs)}
      error -> error
    end
  end
end
