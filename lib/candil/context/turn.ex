defmodule Candil.Context.Turn do
  @moduledoc """
  Un turno de una conversación: quién habló, qué dijo y cuándo.

  Es la unidad mínima que se guarda en una `SharedSession`. Un turno es un
  **hecho**, no un mensaje en bruto: lleva el rol, el contenido, la marca de
  tiempo y los tokens que costó. Sin `timestamp` no se puede saber qué se
  dijo primero cuando dos turnos llegan al mismo tiempo; sin `tokens` no se
  puede medir cuánto costó la vuelta.

  ## Por qué un struct y no un mapa

  Un mapa acepta cualquier clave y se confunde con otra cosa. Un struct con
  `@enforce_keys` falla al construirse si falta lo esencial, que es justo lo
  que se quiere al guardar un hecho.
  """

  @enforce_keys [:role, :content]
  defstruct role: nil,
            content: nil,
            timestamp: nil,
            tokens: 0,
            metadata: %{}

  @type role :: String.t()
  @type t :: %__MODULE__{
          role: role(),
          content: String.t(),
          timestamp: DateTime.t() | nil,
          tokens: non_neg_integer(),
          metadata: map()
        }

  @doc """
  Crea un turno.

  ## Ejemplos

      iex> turn = Candil.Context.Turn.new(:user, "hola")
      iex> {turn.role, turn.content}
      {"user", "hola"}

      iex> Candil.Context.Turn.new("assistant", "respuesta", tokens: 42).tokens
      42
  """
  @spec new(String.t() | atom(), String.t(), keyword()) :: t()
  def new(role, content, opts \\ []) when is_list(opts) do
    %__MODULE__{
      role: to_string(role),
      content: to_string(content),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      tokens: Keyword.get(opts, :tokens, 0),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
