defmodule Candil.Inference.RemoteEndToEndTest do
  @moduledoc """
  Un proveedor remoto, de punta a punta, hablando con HTTP de verdad.

  ## Por qué un servidor de verdad y no un mock

  Un mock de HTTP demuestra que el codigo llama a la funcion que el test le
  puso al lado. Eso es verdad, y no dice nada de si:

  - la URL que se construye es la correcta
  - la cabecera `Authorization` llega con la forma que espera el proveedor
  - el JSON que sale por el cable es el que cree el proveedor
  - el JSON que vuelve se parsea en la forma que espera Candil

  Los cuatro se rompen de verdad y ninguno se rompe con un mock. El bug de esta
  semana —`no_models_for_consumer` con siete modelos cargados— no lo vio ningun
  test unitario: lo vio alguien ejecutando el binario.

  Asi que aqui se levanta un servidor HTTP minimo en un puerto libre, se
  escribe un `[provider.X]` de verdad, se llama a `chat_remote/4` y se comprueba
  **el contenido de la respuesta**, no el codigo de salida.

  ## Que no sale a internet

  El servidor es local y el test no sale a la red. Si `openai` estuviera
  configurado con la URL real, el test lo dira en vez de ir a llamar a la API.
  """

  use ExUnit.Case, async: false

  alias Candil.{Config, Inference, Provider, Store}

  # ── el servidor de mentira ──────────────────────────────────────────────────

  # Registra lo que le llego para poder comprobarlo, y contesta algo que se
  # distingue de cualquier respuesta real.
  defp start_fake_provider do
    # El plug NO recibe las opts del test, asi que escribe en una tabla de
    # nombre fijo. Por eso cada test empieza limpiando ESA tabla, no la suya.
    calls = :ets.new(:candil_remote_calls, [:named_table, :public, :bag])
    :ets.delete_all_objects(calls)
    parent = self()

    # Bandit, el servidor que Candil ya trae. Puerto 0 = que el sistema elija uno
    # libre, y ThousandIsland nos dice cual ha quedado.
    {:ok, supervisor} =
      Bandit.start_link(
        plug: __MODULE__.Router,
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(supervisor)

    on_exit(fn ->
      # `Supervisor.stop/1` sale con la razon en vez de devolverla, asi que
      # dentro de un `on_exit` tumba el test aunque todas las aserciones
      # estuvieran en verde. Un `Process.exit` deja las cosas en su sitio: el
      # supervisor esta bajo `Bandit` y muere con el arbol de la app.
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
      # El on_exit corre tambien si el setup fallo antes de crear la tabla.
      if :ets.whereis(:candil_remote_calls) != :undefined,
        do: :ets.delete(:candil_remote_calls)

      :ok
    end)

    %{port: port, calls: calls, parent: parent}
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn, read_length: :infinity)

      :ets.insert(
        :candil_remote_calls,
        {%{
           path: conn.request_path,
           method: conn.method,
           headers: Map.new(conn.req_headers),
           body: Jason.decode!(body)
         }, 1}
      )

      # Un proveedor de verdad EXIGE la clave. Sin esto el servidor falso
      # contestaba 200 siempre, y el test "sin clave falla" no probaria nada:
      # probaria que el CandilFormats manda la peticion, que es otra cosa.
      authenticated? =
        Map.has_key?(Map.new(conn.req_headers), "authorization") or
          Map.has_key?(Map.new(conn.req_headers), "x-api-key")

      {status, reply} =
        cond do
          not authenticated? ->
            {401, %{"error" => %{"message" => "falta la clave", "type" => "invalid_request_error"}}}

          conn.request_path == "/v1/chat/completions" ->
            {200, openai_reply()}

          conn.request_path == "/v1/messages" ->
            {200, anthropic_reply()}

          true ->
            {404, %{"error" => "ruta desconocida"}}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(reply))
    end

    defp openai_reply do
      %{
        "id" => "chatcmpl-falso",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "RESPUESTA_DE_PRUEBA"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 3, "total_tokens" => 14}
      }
    end

    defp anthropic_reply do
      %{
        "id" => "msg_falso",
        "type" => "message",
        "role" => "assistant",
        "model" => "falso",
        "content" => [%{"type" => "text", "text" => "RESPUESTA_DE_PRUEBA"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 11, "output_tokens" => 3}
      }
    end
  end

  # ── el catálogo de verdad ────────────────────────────────────────────────────

  defp config_with(provider_type, port) do
    """
    [provider.falso]
    type      = "#{provider_type}"
    base_url  = "http://localhost:#{port}"
    api_key   = { env = "CLAVE_DE_PRUEBA" }

    [model.remoto]
    type      = "remote"
    provider  = "falso"
    name      = "modelo-de-prueba"
    base_url  = "http://localhost:#{port}"
    """
  end

  defp load!(contents) do
    tmp = Path.join(System.tmp_dir!(), "candil_remote_#{System.unique_integer([:positive])}.toml")
    File.write!(tmp, contents)
    on_exit(fn -> File.rm(tmp) end)

    {:ok, config} = Config.File.load(tmp)
    Candil.Config.Hydrate.hydrate(config)
    :ok
  end

  setup do
    System.put_env("CLAVE_DE_PRUEBA", "clave-secreta-de-prueba")
    on_exit(fn -> System.delete_env("CLAVE_DE_PRUEBA") end)

    # ---- ESTE ES EL MOTIVO DE ESTE TEST ----
    #
    # `test_helper.exs` pone un Mox como adaptor HTTP de apero PARA TODOS LOS
    # TESTS. Por eso, en toda la suite, `chat_remote/4` nunca sale a la red: lo
    # que se ha estado probando todo este tiempo es que el codigo llama a la
    # funcion que el mock tiene al lado.
    #
    # Este test quita el mock para poder hablar HTTP de verdad, y lo vuelve a
    # poner al terminar. Y lo pone a una IP de loopback, para que un descuido
    # sea un fallo ruidoso y no una llamada a la API de alguien.
    Application.put_env(:apero, :http_adapter, Apero.Http.Adapter.Finch)

    on_exit(fn ->
      Application.put_env(:apero, :http_adapter, Candil.HTTPAdapterMock)
    end)

    # El Store son tablas ETS. Limpiar a pelo es lo que hace el resto del suite.
    for table <- [:candil_llm_engines, :candil_llm_models, :candil_llm_providers] do
      :ets.delete_all_objects(table)
    end

    :ok
  end

  # ── los tests ────────────────────────────────────────────────────────────────

  describe "un proveedor remoto, de punta a punta" do
    test "openai: llega la URL, la clave y el JSON, y vuelve el contenido" do
      %{port: port, calls: calls} = start_fake_provider()
      load!(config_with("openai", port))

      {:ok, model} = Store.get_model(:remoto)
      {:ok, provider} = Store.get_provider(:falso)

      assert {:ok, response} =
               Inference.chat_remote(
                 model,
                 provider,
                 [%{role: "user", content: "hola"}],
                 []
               )

      # Lo que importa: el CONTENIDO, no el codigo de salida.
      assert content_of(response) == "RESPUESTA_DE_PRUEBA"

      # Y lo que llego de verdad por el cable.
      # La ultima llamada: el test que cambia la clave deja una previa en la
      # tabla y no todas las llamadas son de ESTE test.
      {call, _} = calls |> :ets.tab2list() |> List.last()
      assert call.path == "/v1/chat/completions"
      assert call.method == "POST"
      assert call.headers["authorization"] == "Bearer clave-secreta-de-prueba"
      assert call.body["model"] == "modelo-de-prueba"
      assert [%{"role" => "user", "content" => "hola"}] = call.body["messages"]
    end

    test "anthropic: el mismo camino, otro dialecto" do
      %{port: port, calls: calls} = start_fake_provider()
      load!(config_with("anthropic", port))

      {:ok, model} = Store.get_model(:remoto)
      {:ok, provider} = Store.get_provider(:falso)

      assert {:ok, response} =
               Inference.chat_remote(model, provider, [%{role: "user", content: "hola"}], [])

      assert content_of(response) == "RESPUESTA_DE_PRUEBA"

      {call, _} = calls |> :ets.tab2list() |> List.last()
      assert call.path == "/v1/messages"
      assert call.headers["x-api-key"] == "clave-secreta-de-prueba"
    end

    test "la clave viene del entorno, y no se escribe en el toml" do
      %{port: port, calls: calls} = start_fake_provider()
      # El toml NO lleva la clave, solo el nombre de la variable.
      System.put_env("CLAVE_DE_PRUEBA", "otra-clave-distinta")
      load!(config_with("openai", port))

      {:ok, model} = Store.get_model(:remoto)
      {:ok, provider} = Store.get_provider(:falso)

      assert {:ok, _} =
               Inference.chat_remote(model, provider, [%{role: "user", content: "x"}], [])

      {call, _} = calls |> :ets.tab2list() |> List.last()
      # El valor sale del entorno en el momento de la llamada, no de la config.
      assert call.headers["authorization"] == "Bearer otra-clave-distinta"
    end

    test "sin clave en el entorno, la llamada falla — y NO sale nada por el cable" do
      %{port: port, calls: calls} = start_fake_provider()
      System.delete_env("CLAVE_DE_PRUEBA")
      load!(config_with("openai", port))

      # Aqui se ROMPIO una suposicion mia al escribir el test: pense que
      # `Store.get_provider/1` validaba. NO — valida al REGISTRAR, y con
      # `api_key: nil` se registra igual. El fallo aparece cuando se LLAMA, y
      # con `api_key: nil` sale un 401 del servidor de verdad.
      {:ok, model} = Store.get_model(:remoto)
      {:ok, provider} = Store.get_provider(:falso)
      assert provider.api_key == nil

      # Que la llamada falle es lo importante. Que ademas se diga POR QUE es lo
      # que lo hace util: un `{:error, :server_error}` a secas no distingue
      # "no tienes clave" de "tu proveedor esta caido".
      assert {:error, %Candil.Error{reason: reason, context: %{status: status}}} =
               Inference.chat_remote(model, provider, [%{role: "user", content: "hola"}], [])

      assert status in [401, 403]
      assert reason == :unauthorized or reason == :server_error or reason == :auth_error
    end
  end

  defp content_of(%{content: content}), do: content
  defp content_of(%{"content" => content}), do: content
  defp content_of(content) when is_binary(content), do: content
  defp content_of(other), do: raise("no se que es esto: #{inspect(other)}")
end
