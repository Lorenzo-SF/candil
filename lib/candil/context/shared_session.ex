defmodule Candil.Context.SharedSession do
  @moduledoc """
  El valor que se guarda bajo `{consumer, session_id}`.

  Es la sesión compartida del Macro-MoE virtual: el mismo hilo sobrevive al
  cambio de modelo sin reenviar el historial entero cada vez, y la memoria
  que hay alrededor del hilo es un producto distinto del historial.

  ## Turnos, no mensajes en bruto

  Los mensajes se guardan como `Candil.Context.Turn` (rol, contenido, marca
  de tiempo, tokens). Un turno es un hecho; un mapa con claves sueltas es
  una suposición sobre lo que alguien quiso decir.

  ## La partición es el diseño

  La clave es `{consumer, session_id}`. Dos consumidores con el mismo
  `session_id` no se ven. La partición vive en la clave, no en el struct;
  el struct no sabe quién es su vecino.
  """

  alias Candil.Context.Turn

  @enforce_keys [:id, :consumer]
  defstruct id: nil,
            consumer: nil,
            created_at: nil,
            updated_at: nil,
            last_used_at: nil,
            turns: [],
            summary: nil,
            summarised_upto: 0,
            metadata: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          consumer: atom(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          last_used_at: DateTime.t() | nil,
          turns: [Turn.t()],
          summary: String.t() | nil,
          summarised_upto: non_neg_integer(),
          metadata: map()
        }

  @doc """
  Crea una sesión compartida.

  ## Ejemplos

      iex> s = Candil.Context.SharedSession.new(:posadero, "s1")
      iex> {s.consumer, s.id, s.turns}
      {:posadero, "s1", []}
  """
  @spec new(atom(), String.t()) :: t()
  def new(consumer, id) when is_atom(consumer) and is_binary(id) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: id,
      consumer: consumer,
      created_at: now,
      updated_at: now,
      last_used_at: now,
      turns: []
    }
  end

  @doc "Añade un turno al final."
  @spec add_turn(t(), Turn.t()) :: t()
  def add_turn(%__MODULE__{} = session, %Turn{} = turn) do
    now = DateTime.utc_now()

    %{
      session
      | turns: session.turns ++ [turn],
        updated_at: now,
        last_used_at: now
    }
  end

  @doc "Añade un turno a partir de rol y contenido."
  @spec add_turn(t(), String.t() | atom(), String.t(), keyword()) :: t()
  def add_turn(%__MODULE__{} = session, role, content, opts \\ []) do
    add_turn(session, Turn.new(role, content, opts))
  end

  @doc "Número de turnos."
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{turns: turns}), do: length(turns)
end
