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

  alias Candil.{Router, Store}
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

    with :miss <- cached(messages, opts, settings),
         :miss <- pinned(candidates),
         :miss <- forced(messages, candidates, opts, settings),
         :miss <- by_rules(messages, candidates, settings),
         :miss <- by_embeddings(messages, candidates, settings) do
      by_llm(messages, candidates, settings)
    end
    |> finish(messages, candidates, settings)
  end

  defp finish({:ok, decision}, _messages, _candidates, _settings), do: {:ok, decision}

  defp finish(:miss, _messages, candidates, _settings) do
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

  defp pinned(candidates) do
    case candidates do
      [only] ->
        {:ok,
         %Decision{
           model_alias: only,
           strategy: :pinned,
           score: 1.0,
           reason: "the consumer has a pin, and it outranks every other signal",
           timestamp: DateTime.utc_now()
         }}

      _ ->
        :miss
    end
  end

  defp forced(messages, candidates, opts, settings) do
    case Keyword.get(opts, :force_strategy) do
      nil ->
        :miss

      :rule ->
        decide_by(messages, candidates, :rule, settings)

      :embedding ->
        decide_by(messages, candidates, :embedding, settings)

      :llm ->
        decide_by(messages, candidates, :llm, settings)

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

  defp by_rules(messages, candidates, settings) do
    decide_by(messages, candidates, :rule, settings)
  end

  defp by_embeddings(messages, candidates, settings) do
    # Never reached without a model that can embed. Asking for embeddings from
    # a chat-only setup should be a no-op, not an error: the layer is an
    # optimisation and there is a cheaper one above it.
    if embedder_available?(),
      do: decide_by(messages, candidates, :embedding, settings),
      else: :miss
  end

  defp by_llm(messages, candidates, settings) do
    if settings.enable_llm_classifier,
      do: decide_by(messages, candidates, :llm, settings),
      else: :miss
  end

  defp decide_by(messages, candidates, layer, settings) do
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

  defp embedder_available? do
    Store.list_models()
    |> Enum.any?(&(:embeddings in &1.usage))
  end
end
