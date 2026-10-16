defmodule Candil.Gateway.Plug do
  @moduledoc """
  El pipeline del gateway. **No vuelve a escribir la tabla de rutas, ni el
  consumer.**

  `Candil.Gateway.Endpoint.routes/0` es la unica fuente: este modulo pregunta a
  `Endpoint.match/2` y llama al handler que esa tabla nombra. Escribir las rutas
  otra vez en un `Plug.Router` seria tener dos listas que un dia divergen, y esa
  divergencia se descubre cuando un cliente recibe un 404 en produccion.

  Y el **consumer sale de `Endpoint.consumer/3`**, no de aqui: ese modulo ya
  hacia lo correcto —`to_existing_atom/1`, que no crea un atomo por peticion, y
  un error de lo contrario— y reimplementarlo «un poco mejor» es como se
  termina con dos reglas distintas para lo mismo.

  ## La auth, aqui y no en los handlers

  Una peticion **sin credencial valida no llega a un handler**. `Auth.verify/3`
  estaba escrito, documentado y probado —constante tiempo incluido— y **no lo
  llamaba nadie**: medido el 2026-10-16, un gateway arrancado con
  `auth: :api_key` contestaba 200 a una peticion sin `Authorization`. La
  promesa de `Candil.Gateway.Auth` («requires a key on every request») era una
  promesa que el pipeline no cumplia.

  Va antes de resolver la ruta: una peticion sin clave no necesita saber si la
  ruta existe. Y va aqui, en el unico sitio por el que pasan todas, en vez de
  en cada handler: diez handlers son diez sitios donde olvidarse.
  """

  @behaviour Plug

  require Logger

  alias Candil.Gateway.{Auth, Endpoint, Handlers}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    case Auth.verify(
           Keyword.get(opts, :auth, :none),
           Keyword.get(opts, :api_keys, []),
           bearer(conn)
         ) do
      :ok -> route(conn, opts)
      {:error, reason} -> unauthorized(conn, reason)
    end
  end

  # El header tal cual: `Auth.strip_bearer/1` acepta `Bearer <clave>` y la clave
  # a secas, y un header ausente llega como `nil`, que es la rama que convierte
  # en «missing Authorization header» y no en un 500.
  defp bearer(conn), do: List.first(Plug.Conn.get_req_header(conn, "authorization"))

  defp unauthorized(conn, reason) do
    conn
    # RFC 7235: un 401 dice como autenticarse. Un cliente que no lo mira no se
    # entera igual, pero uno que si lo mira no tiene que adivinarlo.
    |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
    |> Handlers.error(401, reason, "invalid_request_error")
  end

  defp route(conn, opts) do
    case Endpoint.match(conn.method, conn.request_path) do
      {:ok, route} ->
        case Endpoint.consumer(route, name_from_path(conn.request_path), :default) do
          {:ok, consumer} ->
            dispatch(conn, handler(route), %{consumer: consumer, opts: opts})

          {:error, reason} ->
            # Un `/c/<lo que sea>` que no es un consumer del toml NO se degrada
            # a "todos los modelos": seria contestar una pregunta que nadie ha
            # hecho con una configuracion que nadie ha escrito. Es el mismo
            # `0`-vs-`total` de D-04, y se responde con un 404.
            Handlers.error(conn, 404, message(reason), "invalid_request_error")
        end

      :error ->
        # Una ruta que no existe es un 404 con la forma de un cliente OpenAI.
        # Un 404 de Plug dejaria al cliente adivinar si el fallo es suyo, del
        # proxy o del servidor, y reintentaria lo que no hay que reintentar.
        Handlers.unknown(conn)
    end
  end

  @doc """
  Llama a un handler, y **nunca deja el socket sin cuerpo**.

  ## Por que hace falta una red

  Medido el 2026-10-15: un handler que levanta una excepcion sale por Bandit
  como un **500 con el cuerpo vacio**. Un cliente OpenAI que recibe eso no puede
  distinguir «Candil esta roto» de «mi peticion estaba mal» ni de «el proxy
  contesta cualquier cosa», y varios reintentan: sobre una peticion que revienta
  siempre, eso es trabajo tirado y un log lleno.

  Es la misma doctrina que el `501` de `Handlers.not_written/2` —«la ruta esta,
  el cuerpo no»— y que el `404` de arriba: **lo que sale por el socket es
  siempre JSON con la forma que el cliente sabe leer**. El mensaje lleva el de
  la excepcion porque es lo unico que dice que ha pasado; el stacktrace entero
  va al log, que es para quien mantiene Candil.

  Publica porque el test que la prueba no puede provocar un handler que
  reviente a traves de la tabla de rutas: la tabla la declara el modulo, y
  inventarse una ruta para el test seria probar otra cosa. Ver
  `Candil.GatewayTest`.
  """
  @spec dispatch(Plug.Conn.t(), module(), map()) :: Plug.Conn.t()
  def dispatch(conn, handler, context) do
    handler.call(conn, context)
  rescue
    error -> crash(conn, handler, error, __STACKTRACE__)
  end

  defp crash(conn, handler, error, stacktrace) do
    Logger.error(
      "[Candil.Gateway] #{inspect(handler)} reviento atendiendo " <>
        "#{conn.method} #{conn.request_path}: " <>
        Exception.format(:error, error, stacktrace)
    )

    # Si ya se habia empezado a contestar, mandar otra respuesta es un
    # `AlreadySentError` —un segundo error, encima del primero, y ninguno de los
    # dos llega al cliente—. Lo unico honesto que queda es devolver la conexion
    # como esta y dejar el log.
    if conn.state in [:unset, :set] do
      Handlers.error(
        conn,
        500,
        "Candil: #{Exception.message(error)}",
        "server_error"
      )
    else
      conn
    end
  end

  defp handler(%{handler: module}), do: module

  # El segundo segmento de `/c/<consumer>/...`. **De la peticion, no de la
  # ruta**: en la ruta ese segmento es el texto `":consumer"`, y leerlo de ahi
  # seria pedirle al usuario que se llame `:consumer`.
  defp name_from_path(request_path) do
    case String.split(request_path, "/", trim: true) do
      ["c", name | _rest] -> name
      _other -> nil
    end
  end

  # El motivo va con `inspect` y no deshecho a mano: `Endpoint.consumer/3` lo
  # construye en un `rescue`, y dialyzer no ve ese camino — desarmar aqui el
  # `{:unknown_consumer, nombre}` le daria un patron que no puede dar, y un
  # aviso que obliga a anadir codigo para silenciar. El nombre del consumer
  # viaja igual dentro del motivo, que es lo que el cliente necesita leer.
  defp message(reason), do: "cannot resolve the consumer: #{inspect(reason)}"
end
