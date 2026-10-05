defmodule Candil.Context.TokenEstimator do
  @moduledoc """
  Token estimation for a shared context session.

  Moved here from `Candil.Conversation.TokenEstimator` by amendment D8: the
  conversation facade is on its way out and the estimator is not, because
  `Candil.Context` needs it. Duplicating it instead of moving it is worse than
  either.

  `Candil.Conversation.TokenEstimator` still exists and delegates here, so
  consumers outside the ecosystem keep working until 4.1.0.

  ## Algorithm

  A per-word approximation: each whitespace-separated word contributes one
  token, plus one extra per six characters, which covers the sub-word splits a
  BPE tokenizer does on long words. On typical English/Code text this is
  within about ±10% of `tiktoken`.

  The 4-chars-per-token heuristic is still available as
  `estimate_content_legacy/1`.
  """

  @doc """
  Estimates the token count for a whole conversation: every message plus the
  system prompt.
  """
  @spec estimate_conversation(map()) :: non_neg_integer()
  def estimate_conversation(%{messages: messages, system: system}) do
    message_total = Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message(msg) end)
    message_total + estimate_system(system)
  end

  @doc """
  Estimates the token count of a single message.
  """
  @spec estimate_message(map()) :: non_neg_integer()
  def estimate_message(%{role: _role, content: content}) when is_binary(content) do
    estimate_content(content)
  end

  def estimate_message(%{role: _role, content: content}) when is_list(content) do
    # Multimodal: a list of parts (text + images).
    Enum.reduce(content, 0, fn
      %{type: :text, text: text}, acc when is_binary(text) -> acc + estimate_content(text)
      # Rough estimate for an image part: nobody is going to be precise here.
      _, acc -> acc + 100
    end)
  end

  def estimate_message(_msg), do: 0

  defp estimate_system(nil), do: 0
  defp estimate_system(text) when is_binary(text), do: estimate_content(text)

  @doc """
  Estimates the token count of a raw string.

      iex> Candil.Context.TokenEstimator.estimate_content("hello world")
      2
      iex> Candil.Context.TokenEstimator.estimate_content("antidisestablishmentarianism")
      5
  """
  @spec estimate_content(String.t()) :: non_neg_integer()
  def estimate_content(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(0, fn word, acc ->
      # One token per word, plus one extra per 6 characters for BPE-style splits.
      acc + 1 + div(byte_size(word), 6)
    end)
  end

  def estimate_content(_), do: 0

  @doc """
  Legacy 4-chars-per-token heuristic. Faster, less accurate on short or
  non-English text. Kept for callers that need the exact old behaviour.
  """
  @spec estimate_content_legacy(String.t()) :: non_neg_integer()
  def estimate_content_legacy(text) when is_binary(text) do
    ceil(byte_size(text) / 4)
  end

  def estimate_content_legacy(_), do: 0

  # ─── Aliases kept from the old home ───────────────────────────────

  @doc "Alias for `estimate_message/1`."
  def estimate_message_tokens(msg), do: estimate_message(msg)

  @doc "Alias for `estimate_content/1`."
  def estimate_content_tokens(text) when is_binary(text), do: estimate_content(text)
  def estimate_content_tokens(_), do: 0

  @doc "Alias for `estimate_content/1` under its oldest name."
  def estimate_tokens(text) when is_binary(text), do: estimate_content(text)
  def estimate_tokens(_), do: 0
end
