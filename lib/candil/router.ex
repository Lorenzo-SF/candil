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

  @type strategy :: :cache | :rule | :embedding | :llm | :default | :pinned

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
      Cache.put(messages, decision, consumer: consumer)
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
      {:ok, _model} -> Consumer.pin(consumer, model_alias)
      {:error, :not_found} -> {:error, {:unknown_model, model_alias}}
    end
  end

  @doc """
  Removes a pin.
  """
  @spec unpin(atom()) :: :ok
  def unpin(consumer), do: Consumer.unpin(consumer)

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
    cache_ttl_seconds: 300
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

      _ ->
        %{}
    end
  rescue
    # Sin fichero de configuracion se usan los defaults, que es lo de antes.
    _kind -> %{}
  end

  defp safe_key(key) when is_binary(key) do
    Enum.find(Map.keys(@defaults), &(Atom.to_string(&1) == key))
  end

  defp safe_key(key), do: key
end
