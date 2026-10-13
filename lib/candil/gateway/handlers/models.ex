defmodule Candil.Gateway.Handlers.Models do
  @moduledoc """
  `GET /v1/models`. Un cliente de escritorio lo llama antes que nada para llenar
  su lista, y si contesta 404 se rinde antes de enviar una sola peticion.

  Lo que sale son los **candidatos del consumer**, no el catalogo entero: es lo
  que ese cliente puede pedir de verdad. Con `/c/<consumer>` son los suyos; sin
  el, los del `default`. Solo si un consumer no tiene ninguno salen todos, que
  es peor que salir vacio pero es lo que hay.
  """

  @behaviour Plug

  alias Candil.Store
  alias Candil.Router.Consumer

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, context) do
    consumer = context.consumer || :default

    aliases =
      case Consumer.candidates(consumer) do
        [] -> Store.list_models() |> Enum.map(& &1.alias)
        list -> list
      end

    body = %{
      object: "list",
      data: Enum.map(aliases, &%{id: to_string(&1), object: "model", owned_by: "candil"})
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
