defmodule Candil.Embeddings.Adapter do
  @moduledoc """
  Qué embedder se usa, en un sitio y con un nombre.

  ## Por qué existe

  `Candil.Embeddings.embed/3` decide el backend con un `case` sobre **strings**:

  ```elixir
  provider = Keyword.get(opts, :provider, "local")
  case provider do
    "ollama" -> ...
    _ -> ...
  end
  ```

  Eso son dos cosas malas a la vez:

  1. **Un typo no falla donde debe.** `"local "` con un espacio no dice «no
     conozco ese provider»: cae en la rama por defecto y **habla con el
     embedder equivocado creyendo que es el correcto**. Un fallo que dice que
     todo va bien.
  2. **Añadir un embedder es tocar Candil.**

  Es el mismo patrón que `Provider` antes de su behaviour: el tipo en dos sitios
  —uno que valida y otro que construye—, y por eso un olvido producía
  «unknown type» en un sitio y un `FunctionClauseError` con el token ya gastado
  en otro.

  ## Lo que NO se decide aquí

  **La normalización del vector.** La normaliza quien indexa, no quien embebe, y
  hacerlo en los dos sitios es exactamente como la distancia coseno acaba
  siendo distinta de la que uno cree.

  ## Lo que un embedder NO sabe

  Que hay un indice, una cola, una VRAM o un presupuesto. Un embedder convierte
  texto en vectores. Lo que se hace después con ellos no es suyo, y por eso su
  superficie es deliberadamente pequeña.
  """

  @type name :: atom()
  @type t :: module()
  @type opts :: keyword()

  @doc "Convierte textos en vectores. Uno por texto, en el mismo orden."
  @callback embed(texts :: [binary()], opts :: opts()) :: {:ok, [[float()]]} | {:error, term()}

  @doc "De que dimension son los vectores que devuelve."
  @callback dimension(opts :: opts()) :: pos_integer()

  @doc "Si este embedder sabe leer este tipo de contenido."
  @callback supports?(modality :: atom()) :: boolean()

  @table __MODULE__

  @doc false
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, read_concurrency: true])
      _ -> :ok
    end

    :ok
  end

  @doc """
  Registra un embedder.

  Devuelve `{:error, {:incomplete_embedder, …}}` si el módulo no implementa el
  behaviour entero: es preferible que falle aquí, al registrar, que en mitad de
  una indexación de 40.000 chunks.
  """
  @spec register(name(), t()) :: :ok | {:error, term()}
  def register(name, module) when is_atom(name) and is_atom(module) do
    ensure_table()
    _ = Code.ensure_loaded(module)

    missing =
      __MODULE__.behaviour_info(:callbacks)
      |> Enum.reject(fn {callback, arity} -> function_exported?(module, callback, arity) end)

    if missing == [] do
      :ets.insert(@table, {name, module})
      :ok
    else
      {:error, {:incomplete_embedder, module, missing}}
    end
  end

  @doc "Si hay un embedder registrado con ese nombre."
  @spec registered?(name()) :: boolean()
  def registered?(name) do
    ensure_table()
    :ets.member(@table, name)
  end

  @doc "Los nombres registrados."
  @spec available() :: [name()]
  def available do
    ensure_table()

    # `:ets.match/2` con un patron de una variable devuelve los NOMBRES sueltos,
    # no los pares. `[{:prueba, _}]` es lo que devuelve `match_object`, no
    # `match`. Con `elem/2` sobre un atomo revienta con
    # `:erlang.element(1, [:prueba])`, que no dice nada de embedders.
    @table
    |> :ets.match({:"$1", :_})
    |> Enum.map(fn
      [name] -> name
      [name, _] -> name
    end)
    |> Enum.sort()
  end

  @doc "El embedder con ese nombre, o `:error`."
  @spec adapter_for(name() | nil) :: {:ok, t()} | :error
  def adapter_for(name) do
    ensure_table()

    case :ets.lookup(@table, name) do
      [{^name, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc """
  Convierte textos en vectores con el embedder indicado.

  Sin `:provider` usa `default_embedder/0`.
  """
  @spec embed([binary()], opts()) :: {:ok, [[float()]]} | {:error, term()}
  def embed(texts, opts \\ []) when is_list(texts) do
    name = Keyword.get(opts, :provider, default_embedder())

    case adapter_for(name) do
      {:ok, module} -> module.embed(texts, opts)
      :error -> {:error, {:unknown_embedder, name}}
    end
  end

  @doc """
  El embedder por defecto.

  ## Y todavía no hay ninguno

  `nil` significa que **elegirlo es una decisión pendiente**, no que esté mal
  hecho: un embedder por defecto global decide, para todo el mundo, en qué se
  calculan las distancias entre vectores. Eso es una decisión de arquitectura, y
  tomarla por omisión es tomarla sin querer — que es justo lo que hacía el
  `case` de `"local"`.

  Cuando se elija, se escribe aquí y en un solo sitio más: el `embedder` de la
  política.
  """
  @spec default_embedder() :: name() | nil
  def default_embedder, do: nil
end
