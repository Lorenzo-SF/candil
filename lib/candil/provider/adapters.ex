defmodule Candil.Provider.Adapters do
  @moduledoc """
  Los cinco providers que trae Candil, como adaptadores.

  No ha cambiado lo que hacen: hacen exactamente lo mismo que las clausulas de
  `Inference.Chat.build_request_body/4`. Lo que cambia es **donde viven**: en un
  behaviour con un registro, en vez de en una lista de atomos aqui y cinco
  clausulas de `case` alli.

  Que esto exista en vez de haberse movido de sitio sin mas, es el punto. Lo que
  se puede anadir a partir de ahora es un provider **sin tocar Candil**.

  Este modulo no es un proceso: se llama una vez al arrancar, desde
  `Candil.Application`, y registra los cinco.
  """

  defmodule OpenAI do
    @moduledoc """
    OpenAI y Azure OpenAI. Mismo cuerpo de peticion; lo que cambia es la URL y
    las cabeceras de Azure, que son distintas por completo.
    """
    @behaviour Candil.Provider.Adapter

    alias Candil.Inference.Chat, as: Chat
    alias Candil.Provider
    alias Candil.RequestBuilder

    @impl true
    def build_body(model, messages, opts),
      do: RequestBuilder.build_openai_body(model, messages, opts)

    @impl true
    def chat_url(%Provider{base_url: base, api_version: nil}), do: base <> "/v1/chat/completions"

    def chat_url(%Provider{base_url: base, api_version: v}),
      do: base <> "/openai/deployments/#{v}"

    @impl true
    def auth_headers(%Provider{type: :azure_openai, api_key: key, headers: extra}),
      do: [{"api-key", key} | extra]

    def auth_headers(%Provider{api_key: key, org_id: org, headers: extra}) do
      [{"authorization", "Bearer " <> key}] ++
        if(org, do: [{"openai-organization", org}], else: []) ++ extra
    end

    @impl true
    def parse_response(body, _provider), do: Chat.parse_openai_response(body)

    @impl true
    def models(_provider), do: []
  end

  defmodule Anthropic do
    @moduledoc """
    Anthropic. El unico de los cinco con el `system` FUERA de `messages`, con
    `max_tokens` obligatorio —su API lo rechaza si no viene— y con la cabecera de
    version que hay que mandar siempre.
    """
    @behaviour Candil.Provider.Adapter

    alias Candil.Inference.Chat, as: Chat
    alias Candil.Provider
    alias Candil.RequestBuilder

    @impl true
    def build_body(model, messages, opts),
      do: RequestBuilder.build_anthropic_body(model, messages, opts)

    @impl true
    def chat_url(%Provider{base_url: base}), do: base <> "/v1/messages"

    @impl true
    def auth_headers(%Provider{api_key: key, headers: extra}),
      do: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"} | extra]

    @impl true
    def parse_response(body, _provider), do: Chat.parse_anthropic_response(body)

    @impl true
    def models(_provider), do: []
  end

  defmodule Ollama do
    @moduledoc """
    Ollama. Local, **sin clave**, y con un cuerpo que no es el de OpenAI: el
    modelo va en `model` y `stream` es un booleano explicito.
    """
    @behaviour Candil.Provider.Adapter

    alias Candil.Inference.Chat, as: Chat
    alias Candil.Provider
    alias Candil.RequestBuilder

    @impl true
    def build_body(model, messages, opts),
      do: RequestBuilder.build_ollama_chat_body(model, messages, opts)

    @impl true
    def chat_url(%Provider{base_url: base}), do: base <> "/api/chat"

    @impl true
    def auth_headers(%Provider{headers: extra}), do: extra

    @impl true
    def parse_response(body, _provider), do: Chat.parse_ollama_response(body)

    @impl true
    def models(_provider), do: []
  end

  alias Candil.Provider.Adapter

  @doc """
  Registra los cinco. Se llama una vez al arrancar, desde `Candil.Application`,
  y va ANTES que `Store` porque `Provider.validate/1` consulta el registro.
  """
  @spec builtin!() :: :ok
  def builtin! do
    :ok = Adapter.register(:openai, OpenAI)
    :ok = Adapter.register(:azure_openai, OpenAI)
    :ok = Adapter.register(:anthropic, Anthropic)
    :ok = Adapter.register(:ollama, Ollama)

    # `:openai_compatible` ES OpenAI. No es un dialecto distinto: es el mismo
    # protocolo con otra URL, que es justo lo que significa "compatible".
    :ok = Adapter.register(:openai_compatible, OpenAI)
    :ok
  end
end
