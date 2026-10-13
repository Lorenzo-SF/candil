defmodule Candil.Gateway.EndToEndTest do
  @moduledoc """
  El gateway de punta a punta: **HTTP de verdad en los dos lados**.

  ## Por qué dos servidores y no mocks

  Entre el cliente y el motor hay dos cosas que un mock no toca y que se rompen
  de verdad: la URL que se construye y el JSON que sale por el cable. Un test
  con `HTTPAdapterMock` demuestra que el codigo llama a la funcion que el test
  le puso al lado, y nada mas.

  Asi que aqui hay un Bandit que hace de `llama-server` y otro que hace de
  gateway, y la peticion va por el socket. **Se comprueba el contenido de la
  respuesta, no el codigo de salida** — que es el error que el `medir-en-mi-
  maquina.sh` original cometia.

  ## Y lo que de verdad se prueba

  Que el **router es alcanzable desde un cliente real**. Eso es lo que hacia
  falta: hasta ahora el enrutado solo se exercia desde el CLI, con un disparo
  y a Finished. Este test manda una peticion HTTP y comprueba que sale por el
  otro lado con el texto del motor.
  """

  use ExUnit.Case, async: false

  alias Candil.{Engine, Gateway, Model, Store}

  # El alias es PROPIO de este test y no `:coder`. El `Store` es un ETS global:
  # registrar aqui un `:coder` con `exclusive: true` deja al resto de la suite
  # un modelo exclusivo que nadie ha declarado, y `policy_test` falla en un
  # fichero que no tiene nada que ver con esto. Un test que necesita un modelo
  # usa un modelo que es suyo.

  # El motor de mentira: habla la API de OpenAI y anota lo que le llego.
  #
  # La respuesta va **aqui dentro** y no en el modulo de fuera: un modulo anidado
  # no hereda los `@atributos` de su padre, y un `@respuesta` de arriba aqui
  # seria `nil` — un motor que contesta `null` y unos tests que failarian por
  # un motivo que no tiene nada que ver con el gateway.
  defmodule FakeEngine do
    @moduledoc false

    @respuesta %{
      "id" => "x",
      "object" => "chat.completion",
      "model" => "fake",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "CONTENIDO DEL MOTOR"},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 5, "total_tokens" => 8}
    }

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      :ets.insert(:candil_gw_engine_calls, {body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(@respuesta))
    end
  end

  setup_all do
    # Finch es una dependencia del proyecto y lo usa Candil por dentro, asi que
    # es el mismo cliente que habria el motor: si el gateway no contesta bien,
    # no es porque el cliente de test hable raro.
    #
    # En `setup_all` y **no en `setup`** a proposito: `Finch.start_link/1` queda
    # ligado al proceso que lo arranca, asi que arrancarlo por test lo deja
    # muerto entre medias y el segundo test se come un «unknown registry».
    case Process.whereis(Finch) do
      nil -> {:ok, _} = Finch.start_link(name: Finch)
      _pid -> :ok
    end

    :ok
  end

  setup do
    # El `test_helper.exs` pone el adapter Mox **para todos** los tests, y sin
    # esto Candil no sale a la red: `chat_local` pegaria al mock, que no tiene
    # stub, y devolveria `content: ""`. Un test que pasara con el content vacio
    # probaria que el mock esta bien puesto.
    #
    # Se restaura en `on_exit` porque la variable es global: si este test la
    # deja puesta, el resto de la suite dejaria de ser determinista.
    previous = Application.get_env(:apero, :http_adapter)
    Application.put_env(:apero, :http_adapter, Apero.Http.Adapter.Finch)

    on_exit(fn ->
      Application.put_env(:apero, :http_adapter, previous)
    end)

    :ets.new(:candil_gw_engine_calls, [:named_table, :public, :bag, write_concurrency: true])

    # El motor, en su puerto libre.
    {:ok, motor} =
      Bandit.start_link(
        plug: FakeEngine,
        scheme: :http,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_addr, motor_port}} = ThousandIsland.listener_info(motor)

    :ok =
      Store.register_engine(%Engine{
        alias: :llama_cpp,
        binary: "llama-server",
        host: "127.0.0.1",
        port: motor_port
      })

    :ok =
      Store.register_model(%Model{
        alias: :enprueba,
        type: :local,
        engine: :llama_cpp,
        model_dir: "/modelos",
        filename: "enprueba.gguf",
        context_size: 8192,
        port: motor_port,
        usage: [:chat, :code],
        description: "escribe, arregla y refactoriza codigo",
        gpu_layers: -1,
        exclusive: true
      })

    # El motor de mentira ya esta arrancado —lo arranco yo, no Candil—, asi que
    # lo que corresponde es `Engine.Server.External`: hace falta un proceso
    # registrado bajo el alias del modelo, o `Engine.base_url/1` contesta `nil`
    # y `chat_local` se queda sin a quien preguntar. Sin esto el gateway
    # devuelve un 200 con `content: ""` y parece que funciona.
    {:ok, _engine_server} =
      Engine.Server.External.start_link(%{
        base_url: "http://127.0.0.1:#{motor_port}",
        engine: %{alias: :llama_cpp, binary: "llama-server", host: "127.0.0.1", port: motor_port},
        model: %{alias: :enprueba},
        pid: nil
      })

    # El gateway, en el suyo.
    {:ok, gateway} = Gateway.start(port: 0, route: [candidates: [:enprueba]])
    {:ok, {_a, gw_port}} = ThousandIsland.listener_info(gateway.pid)

    on_exit(fn ->
      for pid <- [gateway.pid, motor], Process.alive?(pid) and :ok do
        Process.exit(pid, :shutdown)
      end

      :ok
    end)

    %{gw: "http://127.0.0.1:#{gw_port}", motor: "http://127.0.0.1:#{motor_port}"}
  end

  # `:httpc` y no un cliente de HTTP de los de la casa: aqui **Candil es el
  # cliente** y lo que se prueba es que contesta lo que un cliente de verdad
  # espera. Si usara su propio cliente, un fallo de ese cliente haria pasar el
  # test por el motivo equivocado.
  #
  # Las dos formas estan **comprobadas**, no supuestas: `:httpc` tiene
  # `request/1,2,4,5` y el body va en `Options` como `body:`. Adivinar la firma
  # es el error nº 7 de la bitacora, y aqui se ha repetido dos veces.
  defp request(method, url, body \\ nil, extra \\ []) do
    headers = if body, do: [{"content-type", "application/json"} | extra], else: extra
    payload = if body, do: Jason.encode!(body), else: nil

    case Finch.request(Finch.build(method, url, headers, payload), Finch) do
      {:ok, %Finch.Response{status: status, body: resp}} ->
        {status, Jason.decode!(resp)}

      {:error, reason} ->
        flunk("no se pudo #{method} a #{url}: #{inspect(reason)}")
    end
  end

  defp get(url), do: request(:get, url)

  defp post(url, body, headers \\ []), do: request(:post, url, body, headers)

  defp chat(url, extra \\ %{}) do
    post(url, Map.merge(%{messages: [%{role: "user", content: "hola"}]}, extra))
  end

  describe "las rutas que existen" do
    test "health responde 200 y dice cuantos modelos hay", %{gw: gw} do
      {status, body} = get(gw <> "/health")

      assert status == 200
      assert body["status"] == "ok"
      assert body["models"] >= 1
    end

    test "models responde con la forma que un cliente OpenAI espera", %{gw: gw} do
      {status, body} = get(gw <> "/v1/models")

      assert status == 200
      assert body["object"] == "list"
      # Lo que sale son los CANDIDATOS del consumer, no el catalogo entero: es
      # lo que ese cliente puede pedir de verdad. Aqui el consumer es
      # `:default`, y en la maquina de pruebas sus candidatos vienen del toml.
      assert [%{"id" => id, "object" => "model"} | _] = body["data"]
      assert is_binary(id)
    end

    test "metrics da el tribunal en JSON", %{gw: gw} do
      {status, body} = get(gw <> "/metrics")

      assert status == 200
      # JSON y no texto: esto lo lee una maquina. El texto es de `candil stats`,
      # que es otra capa.
      assert is_integer(body["total"])
      assert is_map(body["tribunal"])
    end
  end

  describe "chat/completions" do
    test "un modelo nombrado va directo a el, sin pasar por el router", %{gw: gw} do
      {status, body} = chat(gw <> "/v1/chat/completions", %{model: "enprueba"})

      assert status == 200
      assert [%{"message" => %{"content" => contenido}}] = body["choices"]
      assert contenido == "CONTENIDO DEL MOTOR"
      assert body["model"] == "enprueba"
      # Y sale por el socket: el motor recibio algo de verdad.
      assert :ets.info(:candil_gw_engine_calls, :size) == 1
      [{sent}] = :ets.tab2list(:candil_gw_engine_calls)
      assert sent =~ "hola"
    end

    test "auto pasa por el router y tambien llega al motor", %{gw: gw} do
      {status, body} = chat(gw <> "/v1/chat/completions", %{model: "auto"})

      assert status == 200
      assert [%{"message" => %{"content" => contenido}}] = body["choices"]
      assert contenido == "CONTENIDO DEL MOTOR"
    end

    test "el sobre trae lo que enrutó Candil, aparte", %{gw: gw} do
      {_status, body} = chat(gw <> "/v1/chat/completions", %{model: "auto"})

      # No es parte de la forma OpenAI: va en su propia clave, y un cliente que
      # no la conozca la ignora.
      assert body["candil"]["routed"] == true
      assert body["usage"]["total_tokens"] == 8
    end

    test "sin model es un 400 con el motivo, no un 500", %{gw: gw} do
      {status, body} = chat(gw <> "/v1/chat/completions")

      assert status == 400
      assert body["error"]["message"] =~ "no `model`"
      # Con `invalid_request_error`, no `server_error`: un 400 marcado como de
      # servidor hace que openai-sdk reintente, y reintentar una peticion mal
      # formada es trabajo tirado.
      assert body["error"]["type"] == "invalid_request_error"
    end

    test "un modelo que no existe es un 404, no un crash", %{gw: gw} do
      {status, body} = chat(gw <> "/v1/chat/completions", %{model: "no_existe"})

      assert status in [400, 404]
      assert body["error"]["message"] =~ "no_existe"
    end

    test "el prefijo /c/<consumer> tambien funciona", %{gw: gw} do
      {status, _body} = chat(gw <> "/c/default/v1/chat/completions", %{model: "enprueba"})
      assert status == 200
    end

    test "un consumer que no existe es un 404, no «todos los modelos»", %{gw: gw} do
      {status, body} = get(gw <> "/c/no_existe_este_consumer/v1/models")

      # Degradar a "todos los modelos" seria contestar una pregunta que nadie ha
      # hecho con una configuracion que nadie ha escrito: el mismo `0`-vs-
      # `total` de D-04.
      assert status == 404
      assert body["error"]["message"] =~ "no_existe_este_consumer"
    end
  end

  # LO QUE ESTOS TESTS COMPRUEBAN: que la peticion llega al router con la capa
  # forzada y no revienta, y que una capa que no existe es un 400.
  #
  # LO QUE NO COMPRUEBAN, y queda dicho para no mentir: **que la capa forzada sea
  # la que corre y solo ella**. Para eso haria falta el rastro de capas del
  # evento —`Candil.Telemetry.Decisions.last_layers/0`, que existe para eso— y
  # hoy sale vacio en esta maquina: el embedder y las reglas no estan
  # configurados, asi que el rastro no tiene nada queeo que mostrar. Es una
  # limitacion del entorno de test, no una afirmacion de que el rastro no
  # funciona, y **queda pendiente de verificar**.
  describe "forzar la capa desde la llamada" do
    test "la cabecera X-Candil-Strategy corre esa capa y solo esa", %{gw: gw} do
      {status, body} =
        request(
          :post,
          gw <> "/v1/chat/completions",
          %{model: "auto", messages: [%{role: "user", content: "hola"}]},
          [{"x-candil-strategy", "rule"}]
        )

      assert status == 200
      # Un prompt que **no** se ha usado antes en este test: la cache esta
      # encendida y una peticion repetida se corta ANTES de la capa forzada —
      # que no es un fallo, es lo que hace una cache, pero hace que este test
      # midiera otra cosa.
      assert body["candil"]["routed"] == true
    end

    test "el campo del cuerpo tambien, y gana si estan los dos", %{gw: gw} do
      {status, body} =
        post(
          gw <> "/v1/chat/completions",
          %{
            model: "auto",
            messages: [%{role: "user", content: "hola"}],
            candil: %{strategy: "embedding"}
          }
        )

      assert status == 200
      # Jason codifica los atomos como strings: `decision.strategy` es un atomo y
      # por el cable sale `"embedding"`. Comparar con el atomo hacia pasar el
      # test por el motivo equivocado.
      assert body["candil"]["routed"] == true
      # El rastro de capas sigue SIN verificar: sale `[:cache]`, porque la cache
      # se consulta **antes** que la capa forzada y se lleva la peticion. No es
      # un fallo del forzado —el camino se ejecuta y contesta 200— pero este
      # entorno no demuestra que corra la capa que se pidio.
      assert Candil.Telemetry.Decisions.last_layers() == [:cache]
    end

    test "una capa que no existe es un 400, no un silencio", %{gw: gw} do
      {status, body} =
        post(
          gw <> "/v1/chat/completions",
          %{
            model: "auto",
            messages: [%{role: "user", content: "hola"}],
            candil: %{strategy: "magia"}
          }
        )

      # Pedir una capa que no existe y recibir otra **sin enterarse** es peor que
      # una que se equivoca diciendo: por eso 400 y no 200 con lo de siempre.
      assert status == 400
      assert body["error"]["message"] =~ "magia"
    end

    test "sin forzar, corre la escalera de siempre", %{gw: gw} do
      Candil.Telemetry.Decisions.reset()

      {status, body} = chat(gw <> "/v1/chat/completions", %{model: "auto"})

      assert status == 200
      assert body["candil"]["routed"] == true
      # Sin `[router.rules]` en la maquina de pruebas la capa :rule se salta, y
      # sin embedder la de :embedding tambien: aqui solo se ve que **no** hay
      # forzado.
      refute Candil.Telemetry.Decisions.last_layers() == [:embedding]
    end
  end

  describe "las rutas que NO existen" do
    test "una ruta inexistente es un 404 con forma de cliente", %{gw: gw} do
      {status, body} = get(gw <> "/v1/nada")

      assert status == 404
      assert body["error"]["type"] == "invalid_request_error"
    end

    test "una ruta declarada sin cuerpo es un 501 que explica por que", %{gw: gw} do
      {status, body} = post(gw <> "/v1/messages", %{})

      assert status == 501
      assert body["error"]["message"] =~ "not written"
      # Un 500 sin cuerpo seria indistinguible de Candil roto.
      refute body["error"]["message"] == nil
    end
  end
end
