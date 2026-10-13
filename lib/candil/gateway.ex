defmodule Candil.Gateway do
  @moduledoc """
  An OpenAI-compatible HTTP server in front of the whole catalogue.

  This is what makes Candil usable without writing Elixir. `opencode`, the
  `openai-python` client, `curl`, anything that speaks the OpenAI API: point
  it at `http://127.0.0.1:7777/v1` and it works.

  ## The consumer is in the path

  Every route has a `/c/:consumer` prefix as well as a bare form:

      POST /c/opencode/v1/chat/completions
      POST /v1/chat/completions          → consumer "default"

  Without it, two consumers sharing one gateway would share a default model
  and fight over it. The prefix is what lets a gateway serve several clients
  without configuration colliding.

  ## `model: "auto"` is opt-in per request

  A request naming a concrete model skips the router entirely, so a client
  keeps working if the router decides badly. A request with `"auto"` goes
  through it. Both are supported on purpose: a router you cannot bypass is a
  router whose mistakes you cannot work around.

  ## Auth

  `auth = "none"` by default, and it only listens on loopback. Setting
  `auth = "api_key"` requires a key on every request, compared in constant
  time. JWT is not here and does not belong in v4: it is a few hundred lines,
  nobody asked for it, and `auth = "none"` on loopback is the honest default
  for a local process. Adding it later is one more clause in `Auth`.
  """

  alias Candil.Error
  alias Candil.Gateway.{Auth, Endpoint}

  @type auth_mode :: :none | :api_key

  @doc """
  Arranca el servidor HTTP.

  Devuelve `{:ok, info}` con el **puerto que de verdad se ha cogido**, que no es
  necesariamente el pedido: con `port: 0` lo elige el sistema, y un gateway que
  dice `:0` no sirve para lo unico que se le pide, que es conectarse.

  ## Lo que esta escrito y lo que no

  | Handler | |
  |---|---|
  | `ChatCompletions` | ✅ — pasa por el router con `"model": "auto"` |
  | `Models`, `Health`, `Metrics` | ✅ |
  | `Embeddings`, `Messages` | **501 con motivo**: la ruta existe, el cuerpo no |

  Las dos ultimas estan en la tabla de rutas porque el cliente de escritorio mas
  usado habla la forma de Anthropic, y declarar la ruta dice la verdad sobre lo
  que falta. Devuelven un **501 explicito**, no un 404 ni un crash: un 404
  diria que la ruta no existe, y un crash daria un 500 sin cuerpo.

  ## Por que Bandit y no otra cosa

  Porque ya es una dependencia, y `plug` tambien. Escribir un servidor HTTP a
  mano seria rehacer lo que ya esta. El **pipeline** es
  `Candil.Gateway.Plug`, que consulta a `Endpoint.match/2`; el listener lo pone
  Bandit. La tabla de rutas vive en un sitio solo.
  """
  @spec start(keyword()) :: {:ok, map()} | {:error, term()}
  def start(opts \\ []) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 7777)

    mode = Keyword.get(opts, :auth, :none)
    keys = Keyword.get(opts, :api_keys, [])

    # La configuracion se valida ANTES de coger el puerto: un
    # `auth = "api_key"` sin claves tiene que decirselo aqui, y no coger un
    # puerto para devolver 401 a todo lo que llegue mientras el owner cree que
    # hay un servidor.
    with {:ok, _mode} <- Auth.validate(mode, keys) do
      plug_opts = [auth: mode, api_keys: keys, route: Keyword.get(opts, :route, [])]

      bandit_opts = [
        scheme: :http,
        plug: {Candil.Gateway.Plug, plug_opts},
        port: port,
        ip: parse_ip(host)
      ]

      case Bandit.start_link(bandit_opts) do
        {:ok, pid} ->
          {:ok, %{pid: pid, host: host, port: bound_port(pid) || port}}

        {:error, reason} ->
          # No se envuelve en `Error.http_error/2`: ese pide un status
          # `pos_integer` y **no hay peticion a la que responder**. Un puerto
          # que no se pudo coger no es un 500 de nada, es un fallo de arranque.
          {:error, "the gateway could not bind #{host}:#{port}: #{inspect(reason)}"}
      end
    end
  end

  # El puerto real. Con `port: 0` Bandit elige uno, y sin esto el `start`
  # devolveria un puerto donde no escucha nadie: exactamente lo que hacia
  # `candil run`, que anunciaba un engine que no habia arrancado.
  #
  # `listener_info/1` devuelve `{:ok, {ip, port}}`: una tupla, no un mapa. Es
  # la misma forma que usa `source_fetch_test.exs`, y se copia de ahi a proposito
  # en vez de inventarse una.
  defp bound_port(pid) do
    case ThousandIsland.listener_info(pid) do
      {:ok, {_ip, port}} -> port
      _ -> nil
    end
  end

  defp parse_ip("0.0.0.0"), do: {0, 0, 0, 0}

  defp parse_ip(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> address
      # Un host que no es una IP se deja como cadena y lo decide la resolucion
      # del sistema. Falla al arrancar, con su mensaje, y no aqui con un
      # `MatchError` que no dice de que host hablaba.
      {:error, _} -> host
    end
  end

  defp parse_ip(_), do: {127, 0, 0, 1}

  @doc """
  The full route table: one map per method and path.

  The handlers are named but not written; they land with the listener in
  phase 8. The table is real now so the start banner and the handler tests
  have something to iterate over.
  """
  @spec routes() :: [Endpoint.route()]
  defdelegate routes(), to: Endpoint

  @doc """
  Turns a router error into the JSON body an OpenAI client expects.

  A client that gets an HTML error page or an Elixir crash dump has no way to
  tell a routing problem from a network problem, and will retry the wrong
  thing.

  ## Examples

      iex> {:error, body} = Candil.Gateway.error_body(:no_models_for_consumer)
      iex> {body.error.type, body.error.param, body.error.code}
      {"invalid_request_error", nil, nil}
  """
  @spec error_body(term()) :: {:error, map()}
  def error_body(:no_models_for_consumer) do
    openai_error(
      "no models are configured for this consumer. " <>
        "Check [consumer.<name>] in candil.toml.",
      "invalid_request_error"
    )
  end

  def error_body({:unknown_model, alias}) do
    openai_error("no model named #{inspect(alias)} is registered", "invalid_request_error")
  end

  def error_body({:unknown_engine, alias}) do
    openai_error("no engine named #{inspect(alias)} is registered", "invalid_request_error")
  end

  def error_body({:unknown_provider, alias}) do
    openai_error("no provider named #{inspect(alias)} is registered", "invalid_request_error")
  end

  # Un error que ya trae su mensaje seense tal cual, en la forma que un cliente
  # sabe leer. Antes caia en la clausula de abajo y salia
  # `:invalid_request: %{message: "…"}`, que es la Struct impresa: util para
  # quien depura, inservible para quien recibe el 400.
  #
  # El `context[:message]` es una convencion, no un contrato, asi que si no esta
  # se cae al caso general — que sigue siendo lo que hay.
  def error_body(%Error{reason: reason, context: %{message: message}})
      when is_binary(message) do
    openai_error(message, error_type(reason))
  end

  def error_body(%Error{reason: reason, context: context}) do
    openai_error("#{inspect(reason)}: #{inspect(context)}", "server_error")
  end

  def error_body(other) do
    openai_error(inspect(other), "server_error")
  end

  defp openai_error(message, type) do
    {:error, %{error: %{message: message, type: type, param: nil, code: nil}}}
  end

  # El `type` que ve el cliente. Un 400 con `type: "server_error"` hace que
  # openai-sdk retry, y un reintento sobre una peticion mal formada es trabajo
  # tirado: va a fallar igual.
  defp error_type(reason)
       when reason in [:invalid_request, :context_overflow, :auth_error],
       do: "invalid_request_error"

  defp error_type(_reason), do: "server_error"

  @doc """
  The chat-completions response envelope, for handler tests.
  """
  @spec chat_completion(binary(), binary(), integer()) :: map()
  def chat_completion(id, content, created \\ 0) do
    %{
      id: id,
      object: "chat.completion",
      created: created,
      model: "",
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: content},
          finish_reason: "stop"
        }
      ],
      usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }
  end
end
