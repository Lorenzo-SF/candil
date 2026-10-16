defmodule Candil.Gateway.Handlers.Models do
  @moduledoc """
  `GET /v1/models`. Un cliente de escritorio lo llama antes que nada para llenar
  su lista, y si contesta 404 se rinde antes de enviar una sola peticion.

  Lo que sale son los **candidatos del consumer**, no el catalogo entero: es lo
  que ese cliente puede pedir de verdad. Con `/c/<consumer>` son los suyos; sin
  el, los del `default`. Solo si un consumer no tiene ninguno salen todos, que
  es peor que salir vacio pero es lo que hay.

  ## Una errata en el toml se contesta, no se revienta

  Medido el 2026-10-15: con `[consumer.default] models` nombrando un alias que
  no existe como atomo, `Consumer.candidates/1` levantaba `ArgumentError` y este
  handler se llevaba el socket por delante: el cliente recibia un **500 con el
  cuerpo vacio**. Ahora ese caso sale por `Handlers.reason/2` —el 400 de
  `Gateway.error_body/1`, que ya nombraba el modelo que falta—, y **no** se
  degrada a la lista entera: contestar con un catalogo que el fichero no ha
  pedido es la misma falta que el `/c/<consumer>` que no existe, y esa ya se
  contesta con un 404.
  """

  @behaviour Plug

  alias Candil.Gateway.Handlers
  alias Candil.Router.Consumer
  alias Candil.Store

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, context) do
    consumer = context.consumer || :default

    case aliases(consumer) do
      {:ok, aliases} ->
        body = %{
          object: "list",
          data: Enum.map(aliases, &%{id: to_string(&1), object: "model", owned_by: "candil"})
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))

      {:error, reason} ->
        Handlers.reason(conn, reason)
    end
  end

  defp aliases(consumer) do
    case Consumer.candidates(consumer) do
      {:ok, []} -> {:ok, Store.list_models() |> Enum.map(& &1.alias)}
      {:ok, list} -> {:ok, list}
      {:error, reason} -> {:error, reason}
    end
  end
end
