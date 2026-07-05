defmodule Candil.Health do
  @moduledoc """
  Health checks for LLM/embedding providers.

  Probes a provider endpoint and returns connectivity status, latency,
  and model availability. Used by higher-level diagnostics tools
  (e.g., Botica.Doctor) to surface actionable status to the user.
  """

  @typedoc "Health status for a single provider"
  @type t :: %__MODULE__{
          provider: String.t(),
          reachable: boolean(),
          latency_ms: non_neg_integer() | nil,
          models_available: non_neg_integer() | nil,
          error: String.t() | nil
        }

  defstruct [:provider, :reachable, :latency_ms, :models_available, :error]

  @doc """
  Probes a provider endpoint and returns its health status.

  ## Options
    - `:timeout` — request timeout in ms (default: 5_000)
    - `:api_key` — optional API key for authenticated providers
  """
  @spec probe(String.t(), keyword()) :: t()
  def probe(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    start = System.monotonic_time(:millisecond)

    # Normalize URL with /v1 if it looks like an API base
    probe_url = build_probe_url(url)

    case http_get(probe_url, timeout) do
      {:ok, _status, body} ->
        latency = System.monotonic_time(:millisecond) - start
        models = extract_model_count(body)

        %__MODULE__{
          provider: detect_provider(url),
          reachable: true,
          latency_ms: latency,
          models_available: models,
          error: nil
        }

      {:error, reason} ->
        %__MODULE__{
          provider: detect_provider(url),
          reachable: false,
          latency_ms: nil,
          models_available: nil,
          error: reason
        }
    end
  end

  @doc """
  Runs a quick SELECT-1 equivalent for LLM providers: sends a minimal
  embedding request to verify the model is actually loaded and responding.
  """
  @spec ping(String.t(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def ping(url, model, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    body = Jason.encode!(%{model: model, input: "ping", encoding_format: "float"})

    case http_post("#{url}/v1/embeddings", body, timeout) do
      {:ok, status, _} when status in 200..299 -> :ok
      {:ok, status, _} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp build_probe_url(url) do
    cond do
      String.contains?(url, "/v1/") -> url
      String.ends_with?(url, "/") -> "#{url}v1/models"
      true -> "#{url}/v1/models"
    end
  end

  defp http_get(url, timeout) do
    # Use Req if available, fall back to :httpc
    case Req.get(url, receive_timeout: timeout) do
      {:ok, %{status: s, body: body}} -> {:ok, s, body}
      {:error, %{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e in [Mint.TransportError] -> {:error, Exception.message(e)}
  end

  defp http_post(url, body, timeout) do
    case Req.post(url, body: body, headers: [{"content-type", "application/json"}],
                   receive_timeout: timeout) do
      {:ok, %{status: s, body: body}} -> {:ok, s, body}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e in [Mint.TransportError] -> {:error, Exception.message(e)}
  end

  defp detect_provider(url) do
    cond do
      String.contains?(url, "api.openai.com") -> "openai"
      String.contains?(url, "api.anthropic.com") -> "anthropic"
      String.contains?(url, "localhost") or url =~ ~r/127\.0\.0\.1/ -> "local"
      true -> "external"
    end
  end

  defp extract_model_count(body) when is_map(body) do
    case Map.get(body, "data") do
      models when is_list(models) -> length(models)
      _ -> nil
    end
  end

  defp extract_model_count(_), do: nil
end
