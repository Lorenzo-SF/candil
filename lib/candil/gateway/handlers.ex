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
  Un error del router o de la inferencia, pintado entero: cuerpo y status.

  ## Por que vive aqui y no en `ChatCompletions`

  Vivia alli, y `Models` necesita ya el mismo mapa: un `[consumer.X] models` con
  una errata tiene que contestar 400, no 500. Dos copias de esta tabla son dos
  sitios donde arreglar el proximo `reason` que se anada, y el que se olvide es
  el que un cliente vera como un 500.

  `:no_models_for_consumer` y `{:unknown_model, _}` van al 400 porque son
  configuracion y no un fallo de Candil, y porque un 500 en un cliente OpenAI
  significa «reintenta»: sobre una errata, reintentar es trabajo tirado.
  """
  @spec reason(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def reason(conn, reason) do
    {:error, body} = Candil.Gateway.error_body(reason)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status_for(reason), Jason.encode!(body))
  end

  @doc """
  El status HTTP de un `reason`. Ver `reason/2`.
  """
  @spec status_for(term()) :: pos_integer()
  def status_for(:rate_limited), do: 429
  def status_for(:no_models_for_consumer), do: 400
  def status_for({:unknown_model, _alias}), do: 400
  def status_for(%Candil.Error{reason: :context_overflow}), do: 400
  def status_for(%Candil.Error{reason: :invalid_request}), do: 400
  def status_for(%Candil.Error{reason: :model_not_found}), do: 404
  def status_for(%Candil.Error{reason: :provider_not_found}), do: 404
  def status_for(%Candil.Error{reason: :auth_error}), do: 401
  def status_for(_reason), do: 500

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
