defmodule Candil.Gateway.Handlers.Metrics do
  @moduledoc """
  `GET /metrics`. El **tribunal**, en JSON, para quien no quiera abrir una
  terminal.

  `DISENO-MOTOR.md` §10: *«se mide que fraccion de decisiones resolvio la
  politica. Si es el 97%, al LLM se le llama el 3% y es ruido caro. Si es el
  60%, el motor estatico esta mal hecho»*. Ese numero salia de un script que
  hay que saber ejecutar. **Sale de una URL.**

  Y sale en **JSON, no en texto**, a proposito: esto lo lee una maquina. El
  texto es de `candil stats`, que es otra capa y no el mismo fichero.
  """

  @behaviour Plug

  alias Candil.Telemetry.Decisions

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _context) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(Decisions.snapshot()))
  end
end
