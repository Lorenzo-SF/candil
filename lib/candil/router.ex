defmodule Candil.Router do
  @moduledoc """
  Deciding which model answers a given request.

  Borrowed from ElPaso's router, which had the right idea and the wrong
  coupling: it hung the decision off a `PersonalityManager` and read every
  model from Ecto. Here the unit is a `Candil.Model` and the catalogue is
  `Candil.Store`, and nothing in this module knows what a database is.

  ## Four layers, cheapest first

  1. **Cache** — the same prompt has already been routed.
  2. **Rules** — keyword matches from the config file. Free.
  3. **Embeddings** — cosine similarity against labelled prompts. One request.
  4. **LLM classifier** — ask a small model. Expensive.

  Layer 4 is off by default (`enable_llm_classifier = false`). It costs an
  inference to make a routing decision, and a router that spends a completion
  to save a tenth of one is usually a bad trade. Turn it on when the cheap
  layers demonstrably misroute.

  ## Errors are data

  `route/2` returns `{:error, :no_models_for_consumer}` when a consumer has no
  usable candidate. It does not fall back to `hd(models)`, which is how a
  consumer asking for chat ends up talking to an embeddings model and getting
  silence.
  """

  alias Candil.{Error, Model, Store}
  alias Candil.Router.{Cache, Consumer, DecisionEngine}

  @type strategy :: :cache | :rule | :embedding | :llm | :default | :pinned | :forced

  defmodule Decision do
    @moduledoc """
    Which model to use, and why.

    `reason` and `alternatives` exist so `candil router test "..."` can explain
    itself. A router that returns a model and no explanation is a router you
    debug by turning it off.
    """

    @enforce_keys [:model_alias, :strategy, :score]
    defstruct model_alias: nil,
              strategy: nil,
              score: 0.0,
              reason: nil,
              alternatives: [],
              # Las capas que se SALTAN se anotan en vez de desaparecer. Un
              # router que decide con menos informacion y no lo dice se
              # parece a uno que decide con la misma informacion, y la
              # diferencia se descubre cuando ya no enruta bien.
              degraded: [],
              # QUE CAPAS CORRIERON, en orden. No es decoracion: es lo que
              # faltaba para que «la cache se come el forzado» se viera en la
              # primera peticion y no en tres horas de mediciones.
              #
              # Se documenta como lo que CORRIO, no como lo que alguien queria
              # que corriera: un `force_strategy` que se respeta mal es
              # justamente el bug que la hizo necesaria.
              layers_ran: [],
              # `{:capa, candidatas_antes, candidatas_despues}` por capa.
              #
              # `layers_ran` a secas no distingue «esta capa se salto» de «esta
              # capa corrio y no cambio nada», y esa confusion costo tres horas
              # de mediciones. Con las dos mitades se ve de un vistazo.
              trail: [],
              confidence: :full,
              timestamp: nil

    @type t :: %__MODULE__{
            model_alias: atom(),
            strategy: Candil.Router.strategy(),
            score: float(),
            reason: String.t() | nil,
            alternatives: [{atom(), float()}],
            degraded: [:rule | [atom()]],
            confidence: :full | :degraded,
            timestamp: DateTime.t() | nil
          }
  end

  @type decision :: %Decision{
          model_alias: atom(),
          strategy: strategy(),
          score: float(),
          reason: String.t() | nil,
          alternatives: [{atom(), float()}],
          timestamp: DateTime.t() | nil
        }

  @default_threshold 0.70
  @default_embedding_threshold 0.55

  @doc """
  Decides which model should answer `messages`.

  ## Options

    * `:consumer` — the consumer asking. Sets the candidate set and the
      default. Required in practice; without it the candidate set is every
      model in the store, which includes embedding-only models.
    * `:candidates` — explicit list of aliases, overriding the consumer's.
    * `:skip_cache` — bypass layer 1.
    * `:force_strategy` — run exactly one layer, for testing a rule.
  """
  @spec route([map()], keyword()) :: {:ok, decision()} | {:error, Error.t() | atom()}
  def route(messages, opts \\ []) when is_list(messages) do
    consumer = Keyword.get(opts, :consumer, :default)

    with {:ok, candidates} <- resolve_candidates(consumer, opts),
         {:ok, decision} <-
           DecisionEngine.decide(messages, candidates, opts) do
      Cache.put(messages, decision, Keyword.put(opts, :consumer, consumer))
      {:ok, decision}
    end
  end

  @doc """
  The aliases eligible to answer for a consumer, in preference order.
  """
  @spec candidates(atom()) :: {:ok, [atom()]} | {:error, :no_models_for_consumer}
  def candidates(consumer) do
    case Consumer.candidates(consumer) do
      [] -> {:error, :no_models_for_consumer}
      aliases -> {:ok, aliases}
    end
  end

  defp resolve_candidates(consumer, opts) do
    case Keyword.get(opts, :candidates) do
      nil -> candidates(consumer)
      list when is_list(list) and list == [] -> {:error, :no_models_for_consumer}
      list -> {:ok, list}
    end
  end

  @doc """
  Forces every request from `consumer` to `model_alias`, whatever the rules
  say.

  This is what stops `posadero` and `opencode` fighting over the same model
  while a local engine is starting: pin it, and the argument is settled.

  Pins live in this process, so they are per-node and do not survive a
  restart. That is deliberate; a pin written to disk outlives the reason for
  it.
  """
  @spec pin(atom(), atom()) :: :ok | {:error, term()}
  def pin(consumer, model_alias) when is_atom(consumer) and is_atom(model_alias) do
    case Store.get_model(model_alias) do
      {:ok, _model} ->
        :ok = Consumer.pin(consumer, model_alias)
        # Pinear cambia a donde va una peticion, asi que **invalida la cache**.
        # Sin esto, `candil pin` no hace nada hasta que caduca el TTL, y la
        # primera peticion tras el pin se va al modelo viejo desde la cache.
        # Parecia funcionar y no hacia nada, que es la peor forma de fallar.
        Cache.flush()
        :ok

      {:error, :not_found} ->
        {:error, {:unknown_model, model_alias}}
    end
  end

  @doc """
  Removes a pin.
  """
  @spec unpin(atom()) :: :ok
  def unpin(consumer) do
    :ok = Consumer.unpin(consumer)
    # Por lo mismo que en `pin/2`: quitar un pin tambien cambia el destino, y
    # una entrada cacheada seguiria mandando al modelo pineado.
    Cache.flush()
    :ok
  end

  @doc """
  The pinned model for a consumer, if any.
  """
  @spec pinned(atom()) :: {:ok, atom()} | :error
  def pinned(consumer), do: Consumer.pinned(consumer)

  @doc """
  Turns a decision into the model and the engine or provider that serves it.

  The caller is responsible for making sure the engine is started. The
  Router's job is choosing; the Gateway's job is starting.
  """
  @spec resolve(decision()) :: {:ok, Candil.Model.t(), term()} | {:error, term()}
  def resolve(%Decision{model_alias: alias}) do
    case Store.get_model(alias) do
      {:ok, model} ->
        with {:ok, target} <- target_for(model) do
          {:ok, model, target}
        end

      {:error, :not_found} ->
        {:error, {:unknown_model, alias}}
    end
  end

  defp target_for(%Model{type: :remote, provider: provider}) do
    case Store.get_provider(provider) do
      {:ok, p} -> {:ok, p}
      {:error, :not_found} -> {:error, {:unknown_provider, provider}}
    end
  end

  defp target_for(%Model{type: :external, base_url: base_url}) do
    {:ok, {:external, base_url}}
  end

  defp target_for(%Model{engine: engine}) do
    case Store.get_engine(engine) do
      {:ok, e} -> {:ok, e}
      {:error, :not_found} -> {:error, {:unknown_engine, engine}}
    end
  end

  @doc """
  The thresholds and feature flags, with the defaults filled in.

  ## Los dos nombres

  `:classifier` y `:embedder` son el **nombre con el que algo esta registrado**,
  no el modulo. Se escriben en `[router]` del TOML y son `nil` por omision,
  porque no hay ninguno de los dos por defecto: los dos eligen —por omision—
  cuanto se gasta o en que se miden las distancias entre vectores.

  Un nombre que no este registrado no es un error de arranque: la capa no
  existe y devuelve `:miss`, que es lo que se deduce de «no hay embedder
  registrado». El sitio ruidoso del registro es
  `Candil.Embeddings.Adapter.register/2`, que falla si el modulo no implementa
  el behaviour entero.
  """
  @defaults %{
    # See Candil.Router.DecisionEngine.threshold_for/2: the rule layer is a
    # keyword ratio and the semantic layers are similarities, and they do
    # not share a scale.
    confidence_threshold: @default_threshold,
    rule_threshold: 0.20,
    embedding_threshold: @default_embedding_threshold,
    enable_llm_classifier: false,
    enable_cache: true,
    cache_ttl_seconds: 300,
    # Los dos nombres de la fase 3 del enrutado. `nil` = la capa no existe.
    # No es un descuido: un clasificador o un embedder por defecto se toman
    # sin que nadie los pidiera, y son los dos los que eligen cuanto se gasta.
    classifier: nil,
    embedder: nil,
    # El vocabulario de la capa `:rule`, por **alias de modelo**.
    #
    # Antes no estaba aqui y por eso la capa no se podia tocar: `Scorer` tenia
    # su tabla en un `@rules` de modulo y `[router.rules]` —que la plantilla ya
    # prometia— no lo leia nadie. Un toml que promete una cosa y el codigo hace
    # otra es peor que un toml que no dice nada, porque el que lo escribe
    # comprueba que no le pasa nada y se lo cree.
    #
    # `nil` = la capa usa su vocabulario de reserva. Ausente es **inerte**, y
    # tiene que serlo: una capa que decide por su cuenta con unas reglas que
    # nadie ha puesto es lo contrario de configurable.
    rules: nil,
    # Que pasa cuando NINGUNA capa sabe. `:last` es el defecto y es lo que
    # habia siempre: el ultimo candidato, que es lo que el consumer declaro
    # como default. Se cambia desde `[router]`.
    fallback: :last,
    # Las reglas de DECISION: declarativas, con condicion sobre lo que ya ha
    # pasado y una accion sobre el veredicto. `[router.decision]`.
    #
    # Distinto de `rules:` —que es el DICCIONARIO de palabras de la capa
    # `:rule`—. Aqui no hay vocabulario: hay `when` y hay `force`/`prefer`/`veto`.
    # En SINGULAR, que es como lo escribe el toml: `[[router.decision]]`. Con
    # `decisions` aqui, el `Map.take` de `config_settings/0` se lo lleva entero y
    # las reglas desaparecen sin decir nada —que es lo que hacia esta pieza.
    decision: []
  }

  @spec settings() :: map()
  def settings do
    @defaults
    |> Map.merge(config_settings())
  end

  # Los flags tienen que poder ACTIVARSE. Esta funcion devolvia constantes
  # duras y no leia nada, de modo que `enable_llm_classifier` era `false` para
  # siempre y no habia forma de encender la cuarta capa — el mismo disease que
  # `--cpu` en el arranque: un flag que parece una opcion y no hace nada.
  #
  # Se lee de `[router]` en la configuracion, con estos valores por defecto. Un
  # flag que no se puede poner a `true` no es una opcion, es decoracion.
  defp config_settings do
    case Candil.Config.File.load() do
      {:ok, %{"router" => router}} when is_map(router) ->
        # El TOML da claves como STRINGS y los defaults son ATOMOS, asi que un
        # `Map.take/2` directo devuelve `%{}` siempre y el flag se queda en su
        # valor por defecto sin decir por que. Convertir de uno en otro antes.
        router
        |> Enum.reduce(%{}, fn {key, value}, acc ->
          case safe_key(key) do
            nil -> acc
            key -> Map.put(acc, key, value)
          end
        end)
        |> Map.take(Map.keys(@defaults))
        |> normalise_names()

      _ ->
        %{}
    end
  rescue
    # Sin fichero de configuracion se usan los defaults, que es lo de antes.
    _kind -> %{}
  end

  # `classifier = "etiquetas"` en el TOML es un string, y el registro de
  # `Router.Classifier` y de `Embeddings.Adapter` es por atomos. Sin esta
  # conversion, un nombre escrito con la forma que tiene en un fichero —con
  # comillas— no encuentra nunca nada, y la capa no existe sin que nadie
  # entienda por que.
  defp normalise_names(settings) do
    Enum.reduce([:classifier, :embedder], settings, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, nil} -> acc
        {:ok, value} when is_atom(value) -> acc
        {:ok, value} when is_binary(value) -> Map.put(acc, key, alias_of(value))
        # Un valor que no es un nombre —un numero, una tabla— se deja como
        # estaba: la capa lo buscara y no lo encontrara. Un nombre con una
        # forma rara no se convierte en un atomo nuevo.
        {:ok, _other} -> acc
        :error -> acc
      end
    end)
  end

  # El mismo criterio que `Candil.Config.Hydrate.alias_of/1`: solo un
  # identificador, y solo si parece uno. Un nombre de un fichero de
  # configuracion no es entrada de nadie, asi que no hay denegacion de servicio
  # que evitar; lo que si hay es basura que no merece un atomo.
  defp alias_of(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      String.to_atom(name)
    else
      name
    end
  end

  defp safe_key(key) when is_binary(key) do
    Enum.find(Map.keys(@defaults), &(Atom.to_string(&1) == key))
  end

  defp safe_key(key), do: key
end
