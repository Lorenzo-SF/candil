defmodule Candil.Provider do
  @moduledoc """
  Remote LLM provider definition for Candil.

  A provider represents an external API endpoint. Apero ships with built-in
  support for OpenAI-compatible, Anthropic and Ollama APIs. Any
  OpenAI-compatible endpoint (Together AI, Fireworks AI, Groq, LM Studio,
  vLLM, etc.) can be used with `:openai_compatible`.

  ## Fields

    * `:alias` — unique atom identifier
    * `:type` — provider protocol (see below)
    * `:base_url` — base URL of the API (without trailing slash)
    * `:api_key` — authentication key
    * `:org_id` — optional organisation ID (OpenAI only)
    * `:api_version` — optional API version header (Azure OpenAI)
    * `:timeout_ms` — request timeout in milliseconds (default: `60_000`)
    * `:headers` — additional HTTP headers as `[{name, value}]` tuples

  ## Provider types

    * `:openai` — OpenAI API (`https://api.openai.com`)
    * `:anthropic` — Anthropic Messages API (`https://api.anthropic.com`)
    * `:ollama` — Ollama local server (`http://localhost:11434`)
    * `:openai_compatible` — any endpoint following the OpenAI REST spec
    * `:azure_openai` — Azure OpenAI Service

  ## Examples

      %Candil.Provider{
        alias: :openai,
        type: :openai,
        base_url: "https://api.openai.com",
        api_key: System.get_env("OPENAI_API_KEY")
      }

      %Candil.Provider{
        alias: :anthropic,
        type: :anthropic,
        base_url: "https://api.anthropic.com",
        api_key: System.get_env("ANTHROPIC_API_KEY")
      }

      %Candil.Provider{
        alias: :ollama,
        type: :ollama,
        base_url: "http://localhost:11434"
      }

      %Candil.Provider{
        alias: :groq,
        type: :openai_compatible,
        base_url: "https://api.groq.com/openai",
        api_key: System.get_env("GROQ_API_KEY")
      }

  """

  @type alias :: atom()

  @provider_types [:openai, :anthropic, :ollama, :openai_compatible, :azure_openai]

  @type provider_type :: :openai | :anthropic | :ollama | :openai_compatible | :azure_openai

  @enforce_keys [:alias, :type, :base_url]

  defstruct alias: nil,
            type: :openai_compatible,
            base_url: nil,
            api_key: nil,
            org_id: nil,
            api_version: nil,
            timeout_ms: 60_000,
            headers: []

  @type t :: %__MODULE__{
          alias: atom(),
          type: provider_type(),
          base_url: binary(),
          api_key: binary() | nil,
          org_id: binary() | nil,
          api_version: binary() | nil,
          timeout_ms: pos_integer(),
          headers: [{binary(), binary()}]
        }

  @doc """
  Returns all valid provider type atoms.
  """
  @spec provider_types() :: [provider_type()]
  def provider_types, do: @provider_types

  @doc """
  Validates a provider struct. Returns `:ok` or `{:error, [reasons]}`.
  """
  @spec validate(t()) :: :ok | {:error, [binary()]}
  def validate(%__MODULE__{} = provider) do
    errors =
      []
      |> then(fn e -> if is_nil(provider.alias), do: ["alias is required" | e], else: e end)
      |> then(fn e -> if is_nil(provider.base_url), do: ["base_url is required" | e], else: e end)
      |> then(fn e ->
        if provider.type in @provider_types,
          do: e,
          else: ["unknown type: #{provider.type}" | e]
      end)
      |> then(fn e ->
        if provider.type in [:openai, :anthropic] and is_nil(provider.api_key),
          do: ["api_key is required for #{provider.type}" | e],
          else: e
      end)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  @doc """
  Builds the HTTP request headers for this provider.

  Includes authentication headers appropriate to the provider type.
  """
  @spec auth_headers(t()) :: [{binary(), binary()}]
  def auth_headers(%__MODULE__{type: :openai, api_key: key, org_id: org}) when is_binary(key) do
    base = [{"authorization", "Bearer #{key}"}, {"content-type", "application/json"}]
    if org, do: [{"openai-organization", org} | base], else: base
  end

  def auth_headers(%__MODULE__{type: :openai_compatible, api_key: key}) when is_binary(key) do
    [{"authorization", "Bearer #{key}"}, {"content-type", "application/json"}]
  end

  def auth_headers(%__MODULE__{type: :openai_compatible}) do
    [{"content-type", "application/json"}]
  end

  def auth_headers(%__MODULE__{type: :anthropic, api_key: key}) when is_binary(key) do
    [
      {"x-api-key", key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  def auth_headers(%__MODULE__{type: :ollama}) do
    [{"content-type", "application/json"}]
  end

  def auth_headers(%__MODULE__{headers: extra}) do
    [{"content-type", "application/json"} | extra]
  end

  @doc """
  Returns the chat completions endpoint URL for this provider.
  """
  @spec chat_url(t()) :: binary()
  def chat_url(%__MODULE__{type: :anthropic, base_url: base}), do: "#{base}/v1/messages"
  def chat_url(%__MODULE__{type: :ollama, base_url: base}), do: "#{base}/api/chat"
  def chat_url(%__MODULE__{base_url: base}), do: "#{base}/v1/chat/completions"

  @doc """
  Returns the embeddings endpoint URL for this provider.
  """
  @spec embeddings_url(t()) :: binary()
  def embeddings_url(%__MODULE__{type: :ollama, base_url: base}), do: "#{base}/api/embeddings"
  def embeddings_url(%__MODULE__{base_url: base}), do: "#{base}/v1/embeddings"
end
