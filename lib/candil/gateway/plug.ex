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
  """

  @behaviour Plug

  alias Candil.Gateway.{Endpoint, Handlers}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    case Endpoint.match(conn.method, conn.request_path) do
      {:ok, route} ->
        case Endpoint.consumer(route, name_from_path(conn.request_path), :default) do
          {:ok, consumer} ->
            handler(route).call(conn, %{consumer: consumer, opts: opts})

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
