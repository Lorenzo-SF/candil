defmodule Candil.Embeddings do
  @moduledoc """
  Embedding generation abstraction over multiple providers.

  Provides a unified `embed/2` that dispatches to the correct provider
  (ollama, local llama.cpp, OpenAI-compatible API). Used as a lower-level
  embedding backend independent from `Candil.Llm` — this module accepts
  raw provider parameters (URL, model, api_key) rather than Candil structs.
  """

  @typedoc "Embedding vector"
  @type embedding :: [float()]

  @doc """
  Generates an embedding vector for a single text string.

  ## Provider-specific behaviour

  - `"ollama"` — POST /api/embed with `model` and `input`
  - `"local"` — POST /v1/embeddings with `model` and `input`
  - `"openai"` — POST /v1/embeddings with `model`, `input`, auth header

  ## Options

    - `:provider` — provider type (default: "local")
    - `:url` — base URL
    - `:model` — model name
    - `:api_key` — API key for authenticated providers
    - `:timeout` — request timeout in ms (default: 30_000)
  """
  @spec embed(String.t(), keyword()) :: {:ok, embedding()} | {:error, String.t()}
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
  @spec embed_batch([String.t()], keyword()) :: {:ok, [embedding()]} | {:error, String.t()}
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    provider = Keyword.get(opts, :provider, "local")

    case provider do
      "ollama" -> embed_batch_ollama(texts, opts)
      _ -> embed_batch_openai_compat(texts, opts)
    end
  end

  # ── Ollama ──────────────────────────────────────────────────────────

  defp embed_ollama(text, url, model, timeout) do
    body = Jason.encode!(%{model: model, input: text})

    case req_post("#{url}/api/embed", body, timeout) do
      {:ok, %{"embeddings" => [vec | _]}} when is_list(vec) ->
        {:ok, vec}

      {:ok, _} ->
        {:error, "unexpected Ollama response format"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embed_batch_ollama(texts, opts) do
    url = Keyword.get(opts, :url, "http://127.0.0.1:11434")
    model = Keyword.get(opts, :model, "llama3.2")
    timeout = Keyword.get(opts, :timeout, 60_000)

    body = Jason.encode!(%{model: model, input: texts})

    case req_post("#{url}/api/embed", body, timeout) do
      {:ok, %{"embeddings" => vectors}} when is_list(vectors) ->
        {:ok, vectors}

      {:ok, _} ->
        {:error, "unexpected Ollama batch response format"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── OpenAI-compatible (llama.cpp, vLLM, Groq, Together, etc.) ──────

  defp embed_openai_compat(text, url, model, api_key, timeout) do
    req_body = %{model: model, input: text, encoding_format: "float"}

    headers =
      if api_key && api_key != "" do
        [{"authorization", "Bearer #{api_key}"}]
      else
        []
      end

    case req_post("#{url}/v1/embeddings", Jason.encode!(req_body), timeout, headers) do
      {:ok, %{"data" => [%{"embedding" => vec} | _]}} when is_list(vec) ->
        {:ok, vec}

      {:ok, _} ->
        {:error, "unexpected OpenAI-compat response format"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embed_batch_openai_compat(texts, opts) do
    # Some providers (e.g., llama.cpp) don't support true batching;
    # fall back to sequential individual calls.
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

  # ── HTTP helpers ───────────────────────────────────────────────────

  defp req_post(url, body, timeout, headers \\ []) do
    case Req.post(url,
           body: body,
           headers: [{"content-type", "application/json"} | headers],
           receive_timeout: timeout
         ) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e in [Mint.TransportError] -> {:error, Exception.message(e)}
  end
end
