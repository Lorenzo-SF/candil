defmodule Candil.ConfigManager do
  @moduledoc """
  Reads, validates, and normalizes LLM/embedding provider configuration.

  Provides a consistent interface for configuration that may come from
  JSON files, environment variables, or application env. Used by
  diagnostics tools to validate provider settings before probing.

  This is complementary to `Candil.Config` — while `Candil.Config` stores
  structured engine/model/provider definitions in ETS, `Candil.ConfigManager`
  handles raw map-based config validation and normalization for ad-hoc
  provider connections.
  """

  @typedoc "Normalized provider config"
  @type provider_config :: %{
          required(String.t()) => String.t(),
          optional(String.t()) => term()
        }

  @doc """
  Validates a provider configuration map.

  Returns `:ok` or `{:error, list(String.t())}` with all validation failures.
  """
  @spec validate(map()) :: :ok | {:error, [String.t()]}
  def validate(config) when is_map(config) do
    errors =
      []
      |> check_required_field(config, "provider")
      |> check_required_field(config, "url")
      |> check_required_field(config, "model")
      |> check_url_format(config)
      |> check_timeout_range(config)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Returns default config for a given provider type.
  """
  @spec defaults(String.t()) :: map()
  def defaults("ollama") do
    %{
      "provider" => "ollama",
      "url" => "http://127.0.0.1:11434",
      "model" => "llama3.2",
      "timeout_ms" => 30_000
    }
  end

  def defaults("local") do
    %{
      "provider" => "local",
      "url" => "http://127.0.0.1:8080",
      "model" => "Qwen2.5-Coder-3B-Instruct",
      "timeout_ms" => 45_000
    }
  end

  def defaults("openai") do
    %{
      "provider" => "openai",
      "url" => "https://api.openai.com",
      "model" => "gpt-4o",
      "timeout_ms" => 45_000
    }
  end

  def defaults(_), do: %{}

  @doc """
  Normalizes a config map: fills in missing keys with defaults for the
  given provider type.
  """
  @spec normalize(map()) :: map()
  def normalize(config) when is_map(config) do
    provider = Map.get(config, "provider", "local")
    defaults = defaults(provider)
    Map.merge(defaults, config)
  end

  @doc """
  Returns the list of known embed providers.
  """
  @spec embed_providers() :: [String.t()]
  def embed_providers, do: ["ollama", "local", "openai"]

  @doc """
  Returns the list of known LLM providers.
  """
  @spec llm_providers() :: [String.t()]
  def llm_providers, do: ["ollama", "local", "openai", "anthropic"]

  # ── Validation helpers ────────────────────────────────────────────────

  defp check_required_field(errors, config, field) do
    case Map.get(config, field) do
      nil -> [errors | "missing required field: #{field}"]
      v when v in [nil, "", " "] -> [errors | "#{field} is empty"]
      _ -> errors
    end
  end

  defp check_url_format(errors, config) do
    case Map.get(config, "url") do
      nil ->
        errors

      url when is_binary(url) ->
        if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
          errors
        else
          [errors | "url must start with http:// or https://"]
        end

      _ ->
        errors
    end
  end

  defp check_timeout_range(errors, config) do
    case Map.get(config, "timeout_ms") do
      nil -> errors
      t when is_integer(t) and t > 0 and t <= 300_000 -> errors
      _ -> [errors | "timeout_ms must be between 1 and 300000"]
    end
  end
end
