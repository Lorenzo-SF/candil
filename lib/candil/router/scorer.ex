defmodule Candil.Router.Scorer do
  @moduledoc """
  Scores each candidate model against a message list, per routing layer.

  Rule scoring is a keyword ratio and nothing more clever: how many of the
  rule's words appear, over how many words the rule has. It is deliberately
  crude. A keyword router that pretends to understand the prompt is worse than
  one that admits it is counting words, because you can debug the first.

  The embedding and LLM layers are stubs until their phases. They return
  `:miss` rather than a fabricated score, because a layer that returns a
  plausible number for something it did not compute is the worst outcome
  available: it routes on noise and reports confidence.
  """

  @type layer :: :rule | :embedding | :llm

  @rules %{
    code: ["code", "function", "refactor", "bug", "compile", "elixir", "python", "test"],
    reasoning: ["reason", "explain", "why", "analyze", "prove", "compare"],
    fast: ["quick", "short", "summarize", "list", "translate"]
  }

  # English, deliberately. These are the fallbacks when `[router.rules]` is
  # absent from the config file; the real vocabulary belongs there, where it
  # can be written in whatever language the prompts are in. A near-miss across
  # languages does not match, and pretending otherwise would make the score a
  # lie.
  @default_rules %{
    code: :coder,
    reasoning: :verifier,
    fast: :gpt4o
  }

  @doc """
  The keyword rules, for `candil router test` to display.
  """
  @spec rules() :: map()
  def rules, do: @rules

  @doc """
  Scores candidates for a layer, best first.
  """
  @spec score([map()], [atom()], layer(), map()) :: [{atom(), float()}] | :miss
  def score(messages, candidates, :rule, _settings) do
    ranked =
      candidates
      |> Enum.map(fn alias -> {alias, rule_score(messages, alias)} end)
      |> Enum.reject(fn {_alias, score} -> score == 0.0 end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    if ranked == [], do: :miss, else: ranked
  end

  def score(_messages, _candidates, layer, _settings) do
    # Not computed yet. Returning zeros would clear no threshold but would
    # make `candil router stats` claim the layer ran.
    _ = layer
    :miss
  end

  @doc """
  The rule score of one model: matched keywords over rule size.
  """
  @spec rule_score([map()], atom()) :: float()
  def rule_score(messages, model_alias) do
    text = prompt_text(messages)
    lowered = String.downcase(text)

    @rules
    |> Enum.filter(fn {category, _words} -> target_for(category) == model_alias end)
    |> Enum.map(fn {_category, words} ->
      hits = Enum.count(words, &String.contains?(lowered, &1))
      hits / length(words)
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  @doc """
  A human-readable explanation of what a layer looked at.
  """
  @spec explain(layer(), [map()]) :: String.t()
  def explain(:rule, messages) do
    "keyword rule matched #{inspect(matched_keywords(prompt_text(messages)))}"
  end

  def explain(layer, _messages) do
    "#{layer} layer did not clear its threshold"
  end

  @doc """
  Which keywords from any rule appear in the text.
  """
  @spec matched_keywords(String.t()) :: [String.t()]
  def matched_keywords(text) do
    lowered = String.downcase(text)

    @rules
    |> Enum.flat_map(fn {_category, words} -> words end)
    |> Enum.filter(&String.contains?(lowered, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The prompt text a router actually looks at: the last user turn.
  """
  @spec prompt_text([map()]) :: String.t()
  def prompt_text([]), do: ""

  def prompt_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} -> content
      _ -> nil
    end)
  end

  defp target_for(category), do: Map.get(@default_rules, category)
end
