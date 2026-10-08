defmodule Candil.Provider.AdapterTest do
  @moduledoc """
  El tipo de un provider tiene que estar en UN sitio, no en dos.

  ## El problema

  Hoy el conjunto de tipos que Candil reconoce vive en DOS listas que tienen que
  coincidir y no pueden:

  ```elixir
  # lib/candil/provider.ex
  @provider_types [:openai, :anthropic, :ollama, :openai_compatible, :azure_openai]

  # lib/candil/inference/chat.ex
  defp build_request_body(:anthropic, ...), do: ...
  defp build_request_body(:ollama, ...), do: ...
  defp build_request_body(:openai, ...), do: ...
  defp build_request_body(:openai_compatible, ...), do: ...
  defp build_request_body(:azure_openai, ...), do: ...
  ```

  Añadir un tipo obliga a editar los dos ficheros. Olvidar el primero da
  «unknown type: X» al validar; olvidar el segundo da un `FunctionClauseError`
  en mitad de una llamada, con el token ya gastado.

  Eso no es una molestia de estilo: es **la misma verdad en dos sitios**, que es
  lo que lleva toda la semana produciéndonos bugs.

  ## Lo que este test fija

  Que el registro es la única fuente, y que añadir un provider de verdad no
  toca Candil. Que ese segundo test es el que decide si Candil es un framework
  o un programa con muchos modulos.
  """

  use ExUnit.Case, async: false

  alias Candil.Provider
  alias Candil.Provider.Adapter

  # ── un provider de verdad, de un tercero ─────────────────────────────────────

  defmodule Biblioteca do
    @moduledoc """
    El provider que haria falta para el chatbot de una biblioteca municipal:
    OpenAI-compatible, pero con su propio dialecto de errores.
    """
    @behaviour Adapter

    @impl true
    def chat_url(%Provider{base_url: base}), do: base <> "/v1/chat/completions"

    @impl true
    def build_body(model, messages, opts) do
      %{
        "model" => model,
        "messages" => messages,
        "stream" => Keyword.get(opts, :stream, false),
        # La diferencia que lo hace propio: el limite de contexto lo pide el
        # servidor en cada llamada, no solo en /models.
        "contexto_maximo" => 32_000
      }
    end

    @impl true
    def auth_headers(%Provider{api_key: key}) when is_binary(key),
      do: [{"authorization", "Bearer " <> key}]

    def auth_headers(_provider), do: []

    @impl true
    def parse_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}, _provider),
      do: {:ok, %{content: content}}

    def parse_response(%{"error" => %{"message" => message}}, _provider),
      do: {:error, {:provider_error, message}}

    def parse_response(_body, _provider), do: {:error, :unparseable}

    @impl true
    def requires_api_key?, do: true

    @impl true
    def models(_provider), do: []
  end

  setup do
    # Los cinco de Candil se registran al arrancar la aplicacion. En un test
    # que no la levanta, el registro esta vacio y `validate/1` no puede saber
    # nada. Es el mismo motivo por el que el `test_helper.exs` levanta el
    # Registry: no es que falte codigo, es que este test corre en otro contexto.
    :ok = Candil.Provider.Adapters.builtin!()

    on_exit(fn -> Adapter.reset() end)
    :ok
  end

  defp provider(overrides \\ []) do
    struct!(
      Provider,
      Keyword.merge(
        [
          alias: :biblioteca,
          type: :biblioteca,
          base_url: "http://localhost:9999",
          api_key: "clave"
        ],
        overrides
      )
    )
  end

  # ── lo que ya existe ─────────────────────────────────────────────────────────

  describe "los providers que ya hay" do
    test "los cinco de siempre se validan" do
      for type <- Provider.provider_types() do
        assert :ok = Provider.validate(provider(type: type, alias: type))
      end
    end

    test "un tipo desconocido NO se valida" do
      assert {:error, errors} = Provider.validate(provider())
      assert "unknown type: biblioteca" in errors
    end
  end

  # ── lo que este test quiere, y hoy falla ─────────────────────────────────────

  describe "un provider de un tercero, SIN tocar Candil" do
    test "se registra y a partir de ahi se valida" do
      assert :ok = Adapter.register(:biblioteca, Biblioteca)

      # Este es EL test. Si pasa, Candil deja construir un provider.
      assert :ok = Provider.validate(provider())
    end

    test "su dialecto es el suyo: el body lleva lo que el peer pone" do
      Adapter.register(:biblioteca, Biblioteca)
      p = provider()

      assert {:ok, a} = Adapter.adapter_for(:biblioteca)

      body =
        a.build_body(
          "modelo",
          [%{role: "user", content: "hola"}],
          []
        )

      assert body["model"] == "modelo"
      assert body["contexto_maximo"] == 32_000
    end

    test "su URL es suya, no la de openai" do
      Adapter.register(:biblioteca, Biblioteca)

      assert {:ok, a} = Adapter.adapter_for(:biblioteca)

      assert a.chat_url(provider()) ==
               "http://localhost:9999/v1/chat/completions"
    end

    test "sus errores se parsean como errores, no como excepcion" do
      Adapter.register(:biblioteca, Biblioteca)

      assert {:ok, a} = Adapter.adapter_for(:biblioteca)

      assert a.parse_response(
               %{"error" => %{"message" => "te has quedado sin cuota"}},
               provider()
             ) ==
               {:error, {:provider_error, "te has quedado sin cuota"}}
    end
  end

  describe "el registro es la UNICA fuente" do
    test "lo que valida Provider es lo que esta registrado" do
      # Este es el invariante. Hoy es falso por construccion: son dos listas.
      # Cuando un tipo esta registrado, `validate/1` lo tiene que aceptar; y
      # cuando NO esta registrado, lo tiene que rechazar. Si algun dia las dos
      # listas se separan, este test se cae — y con el, el bug.
      Adapter.register(:biblioteca, Biblioteca)
      assert :ok = Provider.validate(provider(type: :biblioteca))

      assert {:error, _} = Provider.validate(provider(type: :otro_tipo))
    end

    test "y todo provider de Candil tiene su adaptador en el registro" do
      # Los de Candil, uno por uno. No como una lista escrita al lado: se mira
      # que el registro los tenga, que es lo unico que `validate/1` consulta.
      faltantes =
        Provider.provider_types()
        |> Enum.reject(&Adapter.registered?/1)

      assert faltantes == [],
             """
             Estos tipos los valida Provider pero no tienen adaptador:
             #{inspect(faltantes)}

             O se les anade un adaptador, o dejan de ser tipos validos. Lo que
             no puede ser es que uno valide y el otro no sepa construirse.
             """
    end
  end
end
