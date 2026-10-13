defmodule Candil.GatewayTest do
  use ExUnit.Case, async: true

  alias Candil.Gateway
  alias Candil.Gateway.{Auth, Endpoint}

  doctest Candil.Gateway

  describe "route table" do
    test "every OpenAI route exists, with and without a consumer prefix" do
      paths = Endpoint.routes() |> Enum.map(& &1.path)

      for path <- [
            "/v1/chat/completions",
            "/c/:consumer/v1/chat/completions",
            "/v1/messages",
            "/c/:consumer/v1/messages",
            "/v1/embeddings",
            "/c/:consumer/v1/embeddings",
            "/v1/models",
            "/c/:consumer/v1/models"
          ] do
        assert path in paths, "missing route #{path}"
      end
    end

    test "health and metrics take no consumer" do
      for path <- ["/health", "/metrics"] do
        assert {:ok, %{consumer: :none}} = Endpoint.match("GET", path)
      end
    end

    test "matching is exact, not forgiving" do
      # A gateway that accepts a trailing slash on one day and not the next
      # is a gateway you debug by watching logs.
      assert Endpoint.match("GET", "/v1/models") ==
               {:ok, Endpoint.routes() |> Enum.find(&(&1.path == "/v1/models"))}

      assert Endpoint.match("GET", "/v1/models/") == :error
      assert Endpoint.match("GET", "/v1/model") == :error
      assert Endpoint.match("POST", "/v1/models") == :error
    end

    test "a bare route falls back to the default consumer" do
      {:ok, route} = Endpoint.match("POST", "/v1/chat/completions")
      assert {:ok, :default} = Endpoint.consumer(route, nil, :default)
    end

    test "a prefixed route needs the prefix" do
      # match/2 resolves the template; consumer/3 is what carries the name
      # out of a concrete request path.
      {:ok, route} = Endpoint.match("POST", "/c/:consumer/v1/chat/completions")
      assert {:error, :missing_consumer} = Endpoint.consumer(route, nil, :default)
      assert {:ok, :opencode} = Endpoint.consumer(route, "opencode", :default)
    end

    test "y un path concreto SI casa con el, porque sin esto no hay gateway" do
      # Este test afirmaba lo contrario, y **fijaba el bug**. Las ocho rutas con
      # `/c/<consumer>` declaraban `/c/:consumer/v1/...` y `match/2` comparaba
      # cadenas enteras: ninguna peticion real lleva los dos puntos y la palabra,
      # asi que el prefijo de consumer —lo que permite servir a varios clientes
      # sin que colisionen sus configuraciones— no podia funcionar.
      #
      # No se notaba porque no habia servidor. El mismo patron que el test de
      # «la prioridad manda»: **un test que afirma que algo esta roto, y por eso
      # nadie lo arregla.**
      assert {:ok, %{consumer: :required}} =
               Endpoint.match("POST", "/c/opencode/v1/chat/completions")

      # Y lo que SI debe seguir fallando: una ruta parecida no es la misma.
      assert Endpoint.match("POST", "/v1/chat/completions/") == :error
      assert Endpoint.match("POST", "/v1/chat/completion") == :error
    end
  end

  describe "consumer names are never turned into fresh atoms" do
    test "an unknown consumer is an error, not a new atom" do
      {:ok, route} = Endpoint.match("POST", "/c/:consumer/v1/chat/completions")

      random = "consumer_#{System.unique_integer([:positive])}"
      assert {:error, {:unknown_consumer, ^random}} = Endpoint.consumer(route, random, :default)
    end
  end

  describe "error bodies" do
    test "are shaped like an OpenAI error, so a client can parse them" do
      {:error, body} = Gateway.error_body(:no_models_for_consumer)
      assert body.error.type == "invalid_request_error"
      assert body.error.message =~ "candil.toml"
    end

    test "name the model or the engine that is missing" do
      {:error, %{error: %{message: m1}}} = Gateway.error_body({:unknown_model, :coder})
      assert m1 =~ "coder"

      {:error, %{error: %{message: m2}}} = Gateway.error_body({:unknown_engine, :llama})
      assert m2 =~ "llama"
    end

    test "a Candil.Error keeps its reason visible" do
      {:error, %{error: %{message: message, type: "server_error"}}} =
        Gateway.error_body(%Candil.Error{reason: :timeout, context: %{model: :coder}})

      assert message =~ "timeout"
      assert message =~ "coder"
    end
  end

  describe "start/1" do
    test "validates auth before anything else" do
      assert {:error, "auth = \"api_key\" needs at least one key"} =
               Gateway.start(auth: :api_key, api_keys: [])
    end

    test "refuses an unknown auth mode" do
      assert {:error, reason} = Gateway.start(auth: :oauth)
      assert reason =~ "auth must be"
    end

    test "arranca, y devuelve el puerto REAL, no el pedido" do
      # Antes este test fijaba `{:error, :not_implemented}`: no habia servidor.
      # Ahora hay, y lo que importa es que el puerto que devuelve sea el que de
      # verdad se ha cogido — con `port: 0` lo elige el sistema, y devolver el
      # pedido seria el mismo bug que `candil run`, que anunciaba un engine que
      # no habia arrancado.
      assert {:ok, %{pid: pid, port: puerto}} = Gateway.start(port: 0)
      assert is_pid(pid)
      refute puerto == 0

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    end

    test "con una clave valida tambien arranca" do
      assert {:ok, %{pid: pid}} = Gateway.start(port: 0, auth: :api_key, api_keys: ["sk-test"])
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    end

    test "pero una configuracion mala se dice ANTES de coger el puerto" do
      # Un `auth = "api_key"` sin claves tiene que fallar aqui, y no coger un
      # puerto para devolver 401 a todo mientras el owner cree que hay servidor.
      assert {:error, reason} = Gateway.start(port: 0, auth: :api_key, api_keys: [])
      assert reason =~ "at least one key"
    end
  end

  describe "Auth" do
    test "none mode accepts anything, which is why it only listens on loopback" do
      assert Auth.verify(:none, [], nil) == :ok
      assert Auth.verify(:none, [], "Bearer cualquiera") == :ok
    end

    test "api_key mode rejects a missing header" do
      assert {:error, "missing Authorization header"} = Auth.verify(:api_key, ["sk"], nil)
    end

    test "api_key mode accepts the right key, with or without the scheme" do
      assert Auth.verify(:api_key, ["sk-test"], "Bearer sk-test") == :ok
      assert Auth.verify(:api_key, ["sk-test"], "sk-test") == :ok
    end

    test "api_key mode rejects the wrong key" do
      assert {:error, "invalid API key"} = Auth.verify(:api_key, ["sk-test"], "Bearer sk-nope")
    end

    test "a key of a different length is refused without a timing difference" do
      # Length is compared first, which leaks the length and nothing else.
      # Two strings of different lengths cannot be equal.
      assert Auth.verify(:api_key, ["sk-test"], "Bearer sk") == {:error, "invalid API key"}

      assert Auth.verify(:api_key, ["sk-test"], "Bearer sk-test-extra") ==
               {:error, "invalid API key"}
    end

    test "any of several keys works" do
      keys = ["sk-one", "sk-two"]
      assert Auth.verify(:api_key, keys, "Bearer sk-two") == :ok
    end

    test "validate rejects a non-string key" do
      assert {:error, "every api key must be a string"} = Auth.validate(:api_key, [123])
    end
  end

  describe "chat_completion/3" do
    test "is the envelope an OpenAI client expects" do
      body = Gateway.chat_completion("chatcmpl-1", "hola")
      assert body.object == "chat.completion"
      assert [choice] = body.choices
      assert choice.message.role == "assistant"
      assert choice.message.content == "hola"
      assert choice.finish_reason == "stop"
    end
  end
end
