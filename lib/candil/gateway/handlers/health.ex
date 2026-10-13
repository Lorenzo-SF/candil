defmodule Candil.Gateway.Handlers.Health do
  @moduledoc """
  `GET /health`. Lo primero que se mira para saber si el proceso esta vivo.

  No dice «ok» porque si: dice si el **catalogo** tiene algo que servir. Un
  gateway sano con cero modelos es un gateway que devuelve 404 a todo, y
  descubrirlo con un health que contesta `ok` es esconderlo. Por eso el `503`
  cuando no hay nada: es el mismo *«no lo sé»* que D-04, con otro formato.
  """

  @behaviour Plug

  alias Candil.Store

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _context) do
    total = length(Store.list_models())
    status = if total > 0, do: 200, else: 503

    body = %{status: if(total > 0, do: "ok", else: "empty"), models: total}

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
