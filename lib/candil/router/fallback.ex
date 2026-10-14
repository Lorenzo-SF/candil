defmodule Candil.Router.Fallback do
  @moduledoc """
  Que pasa cuando **ninguna capa sabe**.

  Eso no es una excepcion: es el caso mayoritario. Con las señales de hoy, sobre
  peticiones reales, 74 de 84 llegaron aqui. Lo que hay **abajo del enrutado**
  es la decision que mas veces se toma, y era una linea de codigo:

      model_alias: List.last(candidates)

  El ultimo de la lista. Ni round-robin, ni afinidad, ni «el menos usado». Un
  «coge el ultimo y ya» escrito como si fuera una politica.

  ## Que hay aqui

  | estrategia | |
  |---|---|
  | `:last` | el ultimo candidato. **El defecto**, y el de antes: lo que el consumer declaro como default |
  | `:first` | el primero. Para consumers que ya vienen ordenados por preferencia |
  | `:round_robin` | **uno por turno**, alternando. Cada peticion sin senal va a un sitio distinto, en vez de machacar siempre el mismo |
  | `:least_used` | **el menos usado desde que se arranco Candil**. Reparte de verdad, y reparte entre los que existen |

  Se elige desde el toml:

      [router]
      fallback = "round_robin"

  ## Y por que NO es un registro de modulos

  Hay tres sitios en Candil donde el desarrollador mete codigo —`Classifier`,
  `Embeddings.Adapter`— y por ahi va el cuarto. No aqui, **todavia**.

  D-11 pregunta *«¿Candil.Provider es un registro o una lista cerrada?»* y no
  esta contestada. Abrir un registro nuevo antes de contestar esa es abrir la
  puerta sin haber decidido que hay detras. Una lista cerrada de cuatro
  estrategias, con su sintaxis en el toml y sus tests, **no cierra ninguna puerta
  y se amplia cuando la pregunta tenga respuesta**.

  ## Lo que estas estrategias NO hacen

  **No deciden a quien le toca mejor.** Reparten, o eligen la mas
  conservadora. La diferencia con una capa es que estas no MIRAN la peticion:
  cualquier cosa que necesite mirar el prompt es una capa mas, no un fallback.

  Y el estado es **del proceso, no del disco**. Un reinicio pone el contador a
  cero, y es lo correcto: un contador de «cuantas veces ha ido cada uno» que
  sobrevive a un reinicio seria una verdad sobre el pasado en un sitio que solo
  sabe del presente.
  """

  use GenServer

  @table __MODULE__

  # Un mapa literal y no un `Enum.find` sobre una lista de strings con
  # `to_atom`: las cuatro son las cuatro, estan escritas aqui, y un `to_atom`
  # sobre texto del toml es un `String.to_atom` disfrazado — se lleva el chequeo
  # del长度 pero no el problema.
  @estrategias %{
    "last" => :last,
    "first" => :first,
    "round_robin" => :round_robin,
    "least_used" => :least_used
  }

  # Siempre una CADENA: el mapa de arriba es de strings, y un atomo que se
  # busca en un mapa de strings sale `:last` siempre —que es como un
  # `fallback = :least_used` en el toml se ignoraba en silencio—.
  @doc """
  Que estrategia pide la configuracion, o `:last` si no dice nada.

  Una estrategia **desconocida no es un error**: es un nombre mal escrito, y
  reventar el router entero por eso dejaria sin servicio a quien solo queria
  una lista mal escrita. Cae en `:last`, que es lo que habria pasado siempre,
  y el `reason` de la decision lo dice.
  """
  @spec configured(map() | nil) :: atom()
  def configured(nil), do: :last

  def configured(%{fallback: fallback}) do
    case normalise(fallback) do
      nil -> :last
      clave -> Map.get(@estrategias, clave, :last)
    end
  end

  def configured(_settings), do: :last

  defp normalise(name) when is_atom(name), do: name |> Atom.to_string() |> normalise()
  defp normalise(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalise(_other), do: nil

  @doc """
  Elige el modelo cuando nada ha puntuado.
  """
  @spec pick(atom(), [atom()] | [], atom()) :: {:ok, atom()}
  def pick(_strategy, [], _consumer), do: {:error, :no_candidates}
  def pick(:last, candidates, _consumer), do: {:ok, List.last(candidates)}
  def pick(:first, candidates, _consumer), do: {:ok, List.first(candidates)}

  def pick(:round_robin, candidates, consumer), do: {:ok, rotate(candidates, consumer)}

  def pick(:least_used, candidates, consumer), do: {:ok, least_used(candidates, consumer)}
  def pick(_unknown, candidates, _consumer), do: {:ok, List.last(candidates)}

  # Un turno por peticion, y el turno es **por consumer**: dos consumers con la
  # misma lista de candidatos no son el mismo reparto, igual que no son la misma
  # peticion.
  defp rotate(candidates, consumer) do
    total = length(candidates)
    elegido = Enum.at(candidates, rem(count(consumer), total))
    bump(consumer, 1)
    elegido
  end

  # El menos usado. `pick/3` **decide y no puede fallar**: si hay lista, hay
  # ganador, y el contador sube solo a quien le toco. Un contador que sube a
  # a la vez seria un promedio que no decide nada.
  #
  # El desempate es **la posicion en la lista**, no un hash del mundo: dos
  # candidatos con el mismo contador ganan el que el consumer puso antes, y eso
  # es una respuesta estable y comprobable.
  defp least_used(candidates, consumer) do
    {ganador, _indice} =
      candidates
      |> Enum.with_index()
      |> Enum.min_by(fn {alias, indice} -> {count({consumer, alias}), indice} end)

    bump({consumer, ganador}, 1)
    ganador
  end

  defp count(key) do
    case :ets.whereis(@table) do
      :undefined -> 0
      _ -> :ets.lookup_element(@table, key, 2)
    end
  rescue
    ArgumentError -> 0
  end

  defp bump(key, by) do
    if :ets.whereis(@table) != :undefined, do: :ets.update_counter(@table, key, by, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Pone los contadores a cero. Para medir una ventana sin reiniciar Candil.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end
end
