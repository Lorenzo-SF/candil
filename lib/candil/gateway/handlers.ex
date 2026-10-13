defmodule Candil.Gateway.Handlers do
  @moduledoc """
  Lo que los handlers comparten y **no es de ninguno en concreto**: la respuesta
  de error, y el `501` honesto de una ruta que existe en la tabla pero cuyo
  cuerpo no esta escrito.

  ## Por que el 501 y no el 404

  La tabla de rutas las declara las diez, incluidas `/v1/messages` y
  `/v1/embeddings`. Si un handler no existe, el `Plug` revienta con
  `UndefinedFunctionError` y el cliente recibe un **500 sin cuerpo**, que es
  indistinguible de que Candil este roto.

  Un **501 con un mensaje que dice que falta y por que** es la respuesta
  honesta: la ruta esta, el cuerpo no. Es la misma diferencia que entre *«no
  cabe»* y *«no lo se»* que D-04 establecio para las cifras de VRAM, y por la
  misma razon.
  """

  @doc """
  404 con la forma de un cliente OpenAI.
  """
  @spec unknown(Plug.Conn.t()) :: Plug.Conn.t()
  def unknown(conn) do
    error(
      conn,
      404,
      "no such route: #{conn.method} #{conn.request_path}",
      "invalid_request_error"
    )
  end

  @doc """
  501 para una ruta declarada cuyo cuerpo no esta escrito.
  """
  @spec not_written(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def not_written(conn, handler) do
    error(
      conn,
      501,
      "#{inspect(handler)} is in the route table but not written yet: #{inspect(handler)}.call/2 does not exist. The route exists; the body does not.",
      "server_error"
    )
  end

  @doc """
  Envia un error con la forma que un cliente OpenAI sabe leer.
  """
  @spec error(Plug.Conn.t(), pos_integer(), String.t(), String.t()) :: Plug.Conn.t()
  def error(conn, status, message, type) do
    body = %{error: %{message: message, type: type, param: nil, code: nil}}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  @doc """
  Lee el cuerpo JSON de una peticion.
  """
  @spec read_json(Plug.Conn.t()) :: {:ok, map()} | {:error, String.t()}
  def read_json(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", _conn} ->
        {:error, "empty body"}

      {:ok, raw, _conn} ->
        case Jason.decode(raw) do
          {:ok, body} when is_map(body) -> {:ok, body}
          _ -> {:error, "the body is not a JSON object"}
        end

      {:error, _} ->
        {:error, "could not read the body"}
    end
  end

  @doc """
  Un id de peticion con la forma que espera un cliente OpenAI.
  """
  @spec request_id() :: String.t()
  def request_id do
    "chatcmpl-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end
end
