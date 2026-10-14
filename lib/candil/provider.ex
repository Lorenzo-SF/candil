defmodule Candil.Provider do
  alias Candil.Provider.Adapter

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

  # Que tipos necesitan clave. Antes era `[:openai, :anthropic]` escrito aqui, una
  # lista mas que podia quedar vieja. Ahora lo declara el propio adaptador: si un
  # provider necesita clave y no lo dice, el error sale en la llamada, no al
  # validar.
  defp requires_api_key?(%{type: type}) do
    # Que lo necesite o no depende del PROVIDER, no del adaptador.
    # `:openai` y `:openai_compatible` COMPARTEN adaptador —los dos hablan el
    # mismo protocolo y solo cambia la URL— y `openai_compatible` existe
    # precisamente para los endpoints SIN clave: un vLLM en local, un LM Studio.
    #
    # Y no se puede preguntar al adaptador con un `probe` de `api_key: nil`: uno
    # que hace `"Bearer " <> key` revienta, y aqui lo que se quiere saber es si
    # hace falta clave, no si el probe sobrevive.
    #
    # Antes era una lista mas escrita aqui, `[:openai, :anthropic]`, que se
    # podia quedar vieja. Al menos ahora esta pegada al `case` que la usa.
    type in [:openai, :anthropic]
  end

  @spec validate(t()) :: :ok | {:error, [binary()]}
  def validate(%__MODULE__{} = provider) do
    errors =
      []
      |> then(fn e -> if is_nil(provider.alias), do: ["alias is required" | e], else: e end)
      |> then(fn e -> if is_nil(provider.base_url), do: ["base_url is required" | e], else: e end)
      # El tipo se consulta al REGISTRO, no a la lista de este modulo. Es la
      # unica fuente: `Inference` tambien pregunta al registro cual es el
      # adaptador, asi que los dos no pueden separarse sin que un test se caiga.
      |> then(fn e ->
        if Adapter.registered?(provider.type),
          do: e,
          else: ["unknown type: #{provider.type}" | e]
      end)
      |> then(fn e ->
        if requires_api_key?(provider) and is_nil(provider.api_key),
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
  def auth_headers(%__MODULE__{type: :openai, api_key: key, org_id: org, headers: extra}) do
    base = [{"content-type", "application/json"}]
    merged = if org, do: [{"openai-organization", org} | base], else: base

    case key_of(key) do
      nil ->
        merged ++ extra

      clave ->
        # `merged` y no `base`: `merged` es la que lleva el `org`, y perderlo
        # seria un segundo 401 en el mismo camino.
        [{"authorization", "Bearer #{clave}"} | merged] ++ extra
    end
  end

  def auth_headers(%__MODULE__{type: :openai_compatible, api_key: key, headers: extra}) do
    case key_of(key) do
      nil ->
        [{"content-type", "application/json"} | extra]

      clave ->
        [
          {"authorization", "Bearer #{clave}"},
          {"content-type", "application/json"}
          | extra
        ]
    end
  end

  def auth_headers(%__MODULE__{type: :anthropic, api_key: key, headers: extra}) do
    case key_of(key) do
      nil ->
        [
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
          | extra
        ]

      clave ->
        [
          {"x-api-key", clave},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
          | extra
        ]
    end
  end

  def auth_headers(%__MODULE__{type: :ollama, headers: extra}) do
    [{"content-type", "application/json"} | extra]
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

  # `api_key` se escribe en el toml como `env = "VAR"`, y `Hydrate` lo deja
  # **como tupla** `{:system, "VAR"}`. Las guardas de `auth_headers/1` pedian
  # `is_binary(key)`, asi que una tupla no pasaba por ninguna y la peticion
  # salia **sin cabecera de autorizacion**: un 401 sin explicacion, contra el
  # proveedor que el propio usuario habia configurado bien.
  #
  # Medido el 2026-10-14 con la variable puesta en el entorno:
  #
  #     api_key:        {:system, "PRUEBA_KEY"}
  #     Engine.api_key: "sk-secreto-de-verdad"
  #     auth_headers:   [{"content-type", "application/json"}]   <- sin auth
  #
  # La clave se resuelve en un sitio y se usa en otro, y el segundo se quedo
  # atras. Se resuelve aqui igual que alli.
  defp key_of({:system, var}) when is_binary(var), do: key_of(System.get_env(var))
  defp key_of(key) when is_binary(key), do: nil_or(key)
  defp key_of(_), do: nil

  defp nil_or(""), do: nil
  defp nil_or(key), do: key
end
