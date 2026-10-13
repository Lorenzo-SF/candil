defmodule Candil.Gateway.Handlers.Embeddings do
  @moduledoc """
  `POST /v1/embeddings` y `POST /c/<consumer>/v1/embeddings`.

  **La ruta esta en la tabla y el cuerpo no.** Se devuelve un **501 con el
  motivo**, no un 404 y no un crash: un 404 diria que la ruta no existe ( untrue,
  esta en la tabla) y un crash daria al cliente un 500 sin cuerpo, que es
  indistinguible de Candil roto.

  Cuando se escriba, el camino ya esta: `Candil.Inference.embed_local/3` con un
  modelo que tenga `:embeddings` en su `usage`. Lo que hay que decidir antes es
  **el enrutado de un embedding**, que no es el del chat: no hay `messages` que
  comparar contra una `description`, y por eso no se copia el handler de chat
  con otros nombres.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _context) do
    Candil.Gateway.Handlers.not_written(conn, __MODULE__)
  end
end

defmodule Candil.Gateway.Handlers.Messages do
  @moduledoc """
  `POST /v1/messages` y `POST /c/<consumer>/v1/messages` — **la forma de
  Anthropic**, la que habla Claude Code.

  **La ruta esta en la tabla y el cuerpo no.** Mismo **501 con motivo** que
  `Embeddings`.

  Y conviene decir por que esta en la tabla siendo un gateway «de la forma de
  OpenAI»: porque el cliente de escritorio mas usado habla la de Anthropic, y
  dejar la ruta declarada dice la verdad sobre lo que falta. Lo que **no** se ha
  hecho es una traduccion a medias: `messages` de Anthropic lleva bloques con
  tipo, `system` aparte, y `content` que es una lista. Convertir eso a la forma
  de OpenAI es una pieza propia, con sus casos, y no un `map` con otros nombres.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _context) do
    Candil.Gateway.Handlers.not_written(conn, __MODULE__)
  end
end
