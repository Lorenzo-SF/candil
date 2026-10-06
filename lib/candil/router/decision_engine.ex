defmodule Candil.Router.DecisionEngine do
  @moduledoc """
  Runs the four routing layers in cost order and returns the first decision
  that clears its threshold.

  Cheapest first is not an optimisation, it is the whole design. Layer 2 is a
  keyword match against a table in memory; layer 4 is a completion. A router
  that started with the classifier would spend a model call on every request
  to save a fraction of one.

  Each layer reports which one produced the decision, because a router that
  cannot say why it chose a model cannot be tuned, only tolerated.
  """

  alias Candil.{Error, Router, Store}
  alias Candil.Router.{Cache, Decision, Scorer}

  @doc """
  Decides, or explains why it cannot.

  Returns a `t:Decision.t/0` or `:no_models_for_consumer`.
  """
  @spec decide([map()], [atom()], keyword()) ::
          {:ok, Decision.t()} | {:error, :no_models_for_consumer}
  def decide(_messages, [], _opts), do: {:error, :no_models_for_consumer}

  def decide(messages, candidates, opts) do
    settings = Router.settings()

    degraded = skip_embeddings(messages, candidates, settings)

    # El orden es el de §19.2 y no se toca: cache, pin, forzado, reglas,
    # embeddings y por ultima el clasificador LLM, que es el que cuesta una
    # inferencia. Un `pin` gana a todo lo demas, y se comprueba antes de que
    # corra ninguna otra cosa.
    with :miss <- forced_model(candidates, opts, degraded),
         :miss <- cached(messages, opts, settings),
         :miss <- pinned(candidates, degraded),
         :miss <- forced(messages, candidates, opts, settings, degraded),
         :miss <- by_rules(messages, candidates, settings, degraded) do
      # `||` NO vale aqui: solo funciona con booleanos, y estas capas devuelven
      # `:miss` o una tupla. Un `||` sobre `:miss` revienta con BadBooleanError
      # en la PRIMERA peticion que llega a la capa de embeddings.
      case by_embeddings(messages, candidates, settings, degraded) do
        :miss -> by_llm(messages, candidates, settings)
        other -> other
      end
    end
    |> finish(messages, candidates, settings, degraded)
  end

  # Que una capa se salte es un hecho de la DECISIÓN, no un detalle interno: si
  # el embedder no estaba, el score que gana no viene de la similitud y el
  # consumidor tiene derecho a saberlo. Sin esto, la decision con 0.42 de una
  # regla se parece exactamente a la decision con 0.42 de una similitud.
  defp skip_embeddings(_messages, _candidates, _settings) do
    if embedder_available?(), do: [], else: [:embedding]
  end

  defp finish({:ok, decision}, _messages, _candidates, _settings, _degraded), do: {:ok, decision}

  # La capa LLM encendida y sin modelo se propaga TAL CUAL. Sin esta clausula
  # el error caia en el `FunctionClauseError` de abajo, que es peor que el
  # fallo que queria comunicar: el llamante recibia un crash por una capa
  # apagada, en vez de un `{:classifier_unavailable, error}` con el motivo.
  defp finish({:classifier_unavailable, error}, _messages, _candidates, _settings, _degraded),
    do: {:classifier_unavailable, error}

  defp finish({:model_not_eligible, error}, _messages, _candidates, _settings, _degraded),
    do: {:error, error}

  defp finish(:miss, _messages, candidates, _settings, degraded) do
    # The last candidate, not the first. The list is ordered most preferred
    # first, and when nothing scored, the most conservative choice is the one
    # the consumer listed last as its default.
    {:ok,
     %Decision{
       model_alias: List.last(candidates),
       strategy: :default,
       score: 0.5,
       reason: "no layer cleared its threshold; fell back to the default",
       alternatives: [],
       degraded: degraded,
       confidence: confidence(degraded),
       timestamp: DateTime.utc_now()
     }}
  end

  defp consumer(opts), do: Keyword.get(opts, :consumer, :default)

  defp cached(messages, opts, settings) do
    cond do
      not settings.enable_cache -> :miss
      Keyword.get(opts, :skip_cache, false) -> :miss
      true -> Cache.get(messages, consumer(opts))
    end
  end

  # `--model` gana a TODO, pin incluido. Es por peticion y explicito, asi que
  # va por delante del pin, que es del consumidor y dura mas.
  #
  # Y DICE POR QUE, como todo lo demas: un forzado sin motivo es una decision
  # que hay que debugar apagando el forzado, que es peor que no forzar.
  defp forced_model(candidates, opts, degraded) do
    case Keyword.get(opts, :force_model) do
      nil ->
        :miss

      alias ->
        cond do
          alias in candidates ->
            {:ok,
             %Decision{
               model_alias: alias,
               strategy: :forced,
               score: 1.0,
               reason: "forzado a mano con --model #{alias}; el resto de capas ni se miran",
               alternatives: List.delete(candidates, alias),
               degraded: degraded,
               confidence: confidence(degraded),
               timestamp: DateTime.utc_now()
             }}

          true ->
            {:model_not_eligible, Error.model_not_in_candidates(alias, candidates)}
        end
    end
  end

  defp pinned(candidates, degraded) do
    case candidates do
      [only] ->
        {:ok,
         %Decision{
           model_alias: only,
           strategy: :pinned,
           score: 1.0,
           reason: "the consumer has a pin, and it outranks every other signal",
           degraded: degraded,
           confidence: confidence(degraded),
           timestamp: DateTime.utc_now()
         }}

      _ ->
        :miss
    end
  end

  defp forced(messages, candidates, opts, settings, degraded) do
    case Keyword.get(opts, :force_strategy) do
      nil ->
        :miss

      :rule ->
        decide_by(messages, candidates, :rule, settings, degraded)

      :embedding ->
        decide_by(messages, candidates, :embedding, settings, degraded)

      :llm ->
        decide_by(messages, candidates, :llm, settings, degraded)

      other ->
        {:ok,
         %Decision{
           model_alias: List.last(candidates),
           strategy: :default,
           score: 0.0,
           reason: "force_strategy: #{inspect(other)} is not a layer; used the default",
           timestamp: DateTime.utc_now()
         }}
    end
  end

  defp by_rules(messages, candidates, settings, degraded) do
    decide_by(messages, candidates, :rule, settings, degraded)
  end

  defp by_embeddings(messages, candidates, settings, degraded) do
    # Never reached without a model that can embed. Asking for embeddings from
    # a chat-only setup should be a no-op, not an error: the layer is an
    # optimisation and there is a cheaper one above it. Pero NO es lo mismo que
    # un acierto, y la decision lo lleva marcado.
    if embedder_available?() do
      decide_by(messages, candidates, :embedding, settings, degraded)
    else
      :miss
    end
  end

  # El clasificador LLM esta APAGADO por defecto, y apagado se significa
  # apagado: si `enable_llm_classifier` es false, la capa no corre y no se nota.
  #
  # Si esta ENCENDIDO y no puede funcionar, **reventamos**, y decimos que modelo
  # falta. Degradar en silencio seria peor: el router cairia a las capas de
  # arriba, enrutaria "razonablemente" y no habria forma de saber que la capa
  # que activaste lleva semanas sin hacer nada. Un router que se rompe cuando
  # le falta algo es preferible a uno que responde mal y no lo dice.
  defp by_llm(messages, candidates, settings) do
    if settings.enable_llm_classifier do
      case classify(messages, candidates, settings) do
        {:error, :no_classifier_model} ->
          {:classifier_unavailable, no_classifier_model(candidates)}

        # El scorer devuelve `:miss` porque la capa es un stub. No es un
        # fallo: la capa se encendio pero todavia no hace nada, y eso se dice
        # con `reason`, no con un error.
        _miss_or_decision ->
          :miss
      end
    else
      :miss
    end
  end

  defp classify(messages, candidates, settings) do
    case classifier_model() do
      nil -> {:error, :no_classifier_model}
      _alias -> Scorer.score(messages, candidates, :llm, settings)
    end
  end

  # Cualquier modelo de chat sirve: clasificar es una peticion mas corta, y
  # obligar a un modelo "de clasificacion" seria inventar un concepto que el
  # toml no tiene.
  defp classifier_model do
    Store.list_models()
    |> Enum.find(fn model -> :chat in model.usage or :completion in model.usage end)
    |> case do
      nil -> nil
      model -> model.alias
    end
  end

  defp no_classifier_model(candidates) do
    Error.no_classifier_model(
      List.first(candidates),
      "enable_llm_classifier: true necesita un modelo para CLASIFICAR. Declara uno " <>
        "con usage = [\"chat\"] y arrancalo, o pon enable_llm_classifier: false."
    )
  end

  defp decide_by(messages, candidates, layer, settings, degraded) do
    case Scorer.score(messages, candidates, layer, settings) do
      :miss ->
        :miss

      [{model_alias, score} | rest] ->
        if score >= threshold_for(layer, settings) do
          {:ok,
           %Decision{
             model_alias: model_alias,
             strategy: layer,
             score: score,
             reason: Scorer.explain(layer, messages),
             alternatives: rest,
             degraded: degraded,
             confidence: confidence(degraded),
             timestamp: DateTime.utc_now()
           }}
        else
          :miss
        end
    end
  end

  # A keyword ratio and a cosine similarity are not the same kind of number.
  #
  # The `code` rule has eight words, and a real code prompt hits two or three
  # of them — "refactoriza este módulo de Elixir y arregla el bug" scores
  # 3/8 = 0.375. Against a 0.70 threshold borrowed from the semantic layers,
  # the rule layer could never fire, and every prompt would silently fall
  # through to the default.
  #
  # So each layer gets its own threshold, and the rule one is set where a
  # plausible prompt actually lands. Two words out of eight is a clear signal.
  @rule_threshold 0.20

  defp threshold_for(:rule, settings), do: Map.get(settings, :rule_threshold, @rule_threshold)
  defp threshold_for(:embedding, settings), do: settings.embedding_threshold
  defp threshold_for(_layer, settings), do: settings.confidence_threshold

  # Confianza degradada, scores SIN renormalizar. Renormalizar haria que un
  # modelo con 0.2 pareciera competir con uno de 0.9, que es mentir sobre lo
  # poco que se sabe.
  defp confidence([]), do: :full
  defp confidence(_degraded), do: :degraded

  defp embedder_available? do
    Store.list_models()
    |> Enum.any?(&(:embeddings in &1.usage))
  end
end
