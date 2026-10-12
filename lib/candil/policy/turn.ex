defmodule Candil.Policy.Turn do
  @moduledoc """
  One turn, on one destination, held by one request.

  A turn is the receipt of `Candil.Policy.enter/2` and the only thing that
  `Candil.Policy.finish/1` and `Candil.Policy.yield/1` accept. It is what
  carries the two facts the destination needs to recognise its own holder —the
  destination and the token it minted— and the two facts a reader wants: the
  mode the turn was granted under, and the number it was.

  ## Por qué hay un token y no solo un contador

  El contador dice *qué* turno es; dice nada de *quién* lo tiene. Sin el token,
  un `finish/1` con un turno ya obsoleto —el que devuelve el que fue expulsado
  con `yield/1` en `:one_for_all`, por ejemplo— soltaría el turno de **otro**, que
  ahora lo tiene quien espera. El token es lo que convierte "me llamo turn 3" en
  "sigo siendo yo el que tiene el turno 3".

  ## Los dos `nil` de `:one_for_one`

  En el modo por defecto no hay turno ni cola: `%Turn{turn: nil, token: nil}`.
  No es un turno a medio hacer. Es la respuesta correcta a "el destino no es
  exclusivo", y por eso `finish/1` sobre un `%Turn{token: nil}` no toca ningún
  proceso —que es justamente lo que el test del camino caliente comprueba.
  """

  @typedoc "Los tres modos, y solo tres. Ver `Candil.Policy`."
  @type mode :: :one_for_one | :rest_for_one | :one_for_all

  @typedoc """
  Lo que se puede poner delante de un destino: el `alias` de un modelo, de un
  engine o de un provider. Los tres son un `atom`, y los tres son un destino
  distinto aunque se llamen igual.
  """
  @type destination :: atom()

  @typedoc """
  El turno. `:turn` y `:token` son `nil` en `:one_for_one`, y solo en
  `:one_for_one`.
  """
  @type t :: %__MODULE__{
          destination: destination(),
          mode: mode(),
          turn: pos_integer() | nil,
          token: reference() | nil
        }

  defstruct [:destination, :mode, :turn, :token]
end
