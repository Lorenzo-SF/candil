defmodule Candil.Router.Classifier do
  @moduledoc """
  Qué tan difícil es un prompt. No **qué modelo** lo contesta.

  ## El hueco que llena — y que ya no está

  `Candil.Router.Scorer` declara:

  ```elixir
  @type layer :: :rule | :embedding | :llm
  ```

  y **solo implementaba `:rule`**. Las otras dos capas caian en un `:miss` de
  catch-all, y sin embargo `DecisionEngine` ya las llamaba:

  ```elixir
  _alias -> Scorer.score(messages, candidates, :llm, settings)
  ```

  **Ya están escritas** (fase 3, 2026-10-11). `:llm` es ESTE behaviour, usado
  para filtrar por `usage`: `:deep` deja solo los modelos con `:reasoning`, y
  si no deja ninguno la capa devuelve `:miss` en vez de caer de vuelta a
  «todos». `:embedding` compara el prompt con la `description` de cada modelo
  por similitud del coseno, usando `Candil.Embeddings.Adapter`.

  ## Lo que sigue igual

  **No hay clasificador por defecto, y no hay embedder por defecto.** Los dos
  eligen por omision cuanto se gasta o en que se miden las distancias entre
  vectores, y tomarlos sin que nadie los pidiera es tomarlos sin querer. Sin
  ninguno registrado, las dos capas devuelven `:miss` y el router sigue bajando.

  ## Lo que un clasificador NO es

  **No elige el modelo.** Dice *qué tan difícil* es esto; el filtro y la
  afinidad eligen el modelo. Un clasificador que devuelve un alias se está
  contestando a la misma pregunta dos veces, y con dos respuestas que pueden
  discrepar.

  ## Por qué un behaviour

  Igual que `Provider`, `Chunker` y `Embeddings`: **la capa es código y la
  activación es un valor** en `[router]`. Un clasificador propio —un modelo
  local, unas reglas del proyecto, uno afinado a tu dominio— se registra y decide
  sin recompilar Candil.

  ## `:unknown` es una respuesta, no un fallo

  Un clasificador que no sabe **tiene que poder decirlo**. Con una sola salida
  ("no hay decisión"), un clasificador tímido se ve obligado a elegir a la fuerza,
  y ahi es donde se manda un prompt a un modelo caro sin querer. Tres salidas,
  como el resto del motor: un resultado, `{:error, :unknown}`, o un error de
  verdad.

  ## Lo que NO se decide aquí

  La confianza **no** se normaliza contra nada. Se devuelve tal cual la da el
  clasificador, con su escala, y quien combine capas sabe lo que significa. Es lo
  que dijo la fase 7: la confianza se arregla en la afinidad, no aquí.
  """

  @type name :: atom()
  @type t :: module()
  @type difficulty :: :fast | :normal | :deep

  @type verdict :: %{
          difficulty: difficulty(),
          confidence: number(),
          why: String.t()
        }

  @doc """
  Dice qué tan difícil es un prompt.

  Devuelve `{:ok, verdict}`, `{:error, :unknown}` cuando no sabe, o
  `{:error, razon}` cuando ha fallado de verdad. **Las tres cosas son distintas**
  y confundirlas hace que un clasificador inseguro parezca seguro.

  ## LA REGLA: llame al modelo, no al router

  > **Un clasificador llama al MODELO directamente —el `Candil.Store`, el
  > engine, el provider que toque—, saltándose el router. El router es lo que
  > llama al clasificador.**

  No es una recomendacion de estilo. `Candil.Router.DecisionEngine` coge
  **cualquier** modelo con `usage: [:chat]` para clasificar y la capa `:llm` lo
  llama, asi que un clasificador que pida un modelo al router **se llama a si
  mismo para siempre**. El sintoma es un proceso muerto por stack, que no
  menciona al router ni al clasificador.

  Por eso no es solo documentacion: `Candil.Router.DecisionEngine.decide/3`
  comprueba, **en la puerta**, si esta dentro de una llamada a un clasificador, y
  si lo esta revienta diciendo quien ha montado el bucle y que hacer. La
  comprobacion esta en la puerta y no junto a esta llamada a proposito: un
  clasificador puede llamar al router por mas de un camino —`Router.route/2`,
  `DecisionEngine.decide/3`— y todos son el mismo bucle.
  """
  @callback classify(messages :: [map()], opts :: keyword()) ::
              {:ok, verdict()} | {:error, term()}

  @doc "Como se llama este clasificador. Va en el `reason` de la decisión."
  @callback name() :: String.t()

  @doc """
  Si este clasificador se usa con estos ajustes.

  Para que `enable_llm_classifier = false` signifique algo: un clasificador
  registrado pero apagado **existe y no se usa**, que es distinto de no existir.
  """
  @callback enabled?(opts :: keyword()) :: boolean()

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
  Registra un clasificador.

  Falla en el registro, no a mitad de una decisión, si el módulo no implementa
  el behaviour entero.
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
      {:error, {:incomplete_classifier, module, missing}}
    end
  end

  @doc "Si hay un clasificador registrado con ese nombre."
  @spec registered?(name()) :: boolean()
  def registered?(name) do
    ensure_table()
    :ets.member(@table, name)
  end

  @doc "Los nombres registrados."
  @spec available() :: [name()]
  def available do
    ensure_table()

    @table
    |> :ets.match({:"$1", :_})
    |> Enum.map(fn
      [name] -> name
      [name, _] -> name
    end)
    |> Enum.sort()
  end

  @doc "El clasificador con ese nombre, si existe y esta encendido."
  @spec classifier_for(name() | nil, keyword()) :: {:ok, t()} | :error
  def classifier_for(name, opts \\ []) do
    ensure_table()

    case :ets.lookup(@table, name) do
      [{^name, module}] ->
        if module.enabled?(opts), do: {:ok, module}, else: :error

      [] ->
        :error
    end
  end

  @doc """
  Clasifica con el clasificador indicado en `:classifier`, o con el de por
  defecto.

  Un clasificador que no sabe devuelve `{:error, :unknown}` **sin que sea un
  error del motor**: quien llama puede seguir con las capas que sí saben.
  """
  @spec classify([map()], keyword()) :: {:ok, verdict()} | {:error, term()}
  def classify(messages, opts \\ []) do
    name = Keyword.get(opts, :classifier, default_classifier())

    case classifier_for(name, opts) do
      {:ok, module} -> module.classify(messages, opts)
      :error -> {:error, {:no_classifier, name}}
    end
  end

  @doc "Si el clasificador existe y esta encendido con estos ajustes."
  @spec enabled?(name(), keyword()) :: boolean()
  def enabled?(name, opts \\ []) do
    match?({:ok, _}, classifier_for(name, opts))
  end

  @doc """
  El clasificador por defecto.

  ## Y todavía no hay ninguno

  `nil` significa que **elegirlo es una decisión pendiente**. El clasificador
  por defecto decide con qué criterio un prompt va a un modelo caro, y
  tomarlo por omisión es tomarlo sin querer.

  Cuando se elija, se escribe aquí y en un solo sitio más: el
  `classifier` de `[router]` en el TOML.
  """
  @spec default_classifier() :: name() | nil
  def default_classifier, do: nil
end
