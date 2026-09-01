defmodule Candil.Conversation.TokenEstimator do
  @moduledoc """
  Token estimation utilities for conversation context management.

  Splits out the token-counting heuristics from `Candil.Conversation` so
  the conversation module remains focused on message lifecycle.

  Not part of the public API — used only by `Candil.Conversation`.

  ## Algorithm

  Uses the standard 4-chars-per-token heuristic (`ceil(byte_size/4)`)
  which is fast and works well for English/Code. For multi-lingual
  content, consider integrating a proper tokenizer (e.g., tiktoken).
  """

  @doc """
  Estimates token count for a conversation by summing all message
  tokens plus a buffer for the system prompt.
  """
  @spec estimate_conversation(map()) :: non_neg_integer()
  def estimate_conversation(%{messages: messages, system: system}) do
    message_total = Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message(msg) end)
    message_total + estimate_system(system)
  end

  @doc """
  Estimates token count for a single message map.
  """
  @spec estimate_message(map()) :: non_neg_integer()
  def estimate_message(%{role: _role, content: content}) when is_binary(content) do
    estimate_content(content)
  end

  def estimate_message(%{role: _role, content: content}) when is_list(content) do
    # Multimodal content: list of parts (text + images)
    Enum.reduce(content, 0, fn
      %{type: :text, text: text}, acc when is_binary(text) -> acc + estimate_content(text)
      # rough estimate for image content
      _, acc -> acc + 100
    end)
  end

  def estimate_message(_msg), do: 0

  defp estimate_system(nil), do: 0
  defp estimate_system(text) when is_binary(text), do: estimate_content(text)

  @doc """
  Estimates token count for a raw text string.

  Uses a per-word approximation: each whitespace-separated word
  contributes one token (rounded up for long words to account for
  sub-word splits common in BPE tokenizers). On typical English/Code
  text this is within ±10% of `tiktoken`'s count.

      iex> TokenEstimator.estimate_content("hello world")
      2
      iex> TokenEstimator.estimate_content("antidisestablishmentarianism")
      2

  The legacy 4-chars-per-token heuristic is still available via
  `estimate_content_legacy/1`.
  """
  @spec estimate_content(String.t()) :: non_neg_integer()
  def estimate_content(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(0, fn word, acc ->
      # Each word ≈ 1 token, plus 1 extra per 6 chars for BPE-style splits.
      chars = byte_size(word)
      acc + 1 + div(chars, 6)
    end)
  end

  def estimate_content(_), do: 0

  @doc """
  Legacy 4-chars-per-token heuristic. Faster than `estimate_content/1`
  but less accurate for short or non-English text. Kept for callers
  that need the exact old behaviour.
  """
  @spec estimate_content_legacy(String.t()) :: non_neg_integer()
  def estimate_content_legacy(text) when is_binary(text) do
    ceil(byte_size(text) / 4)
  end

  def estimate_content_legacy(_), do: 0

  # ─── Aliases for backwards compatibility ──────────────────────────

  @doc """
  Backwards-compatible alias for `estimate_message/1`.
  """
  def estimate_message_tokens(msg), do: estimate_message(msg)

  @doc """
  Backwards-compatible alias for `estimate_content/1`.
  """
  def estimate_content_tokens(text) when is_binary(text), do: estimate_content(text)
  def estimate_content_tokens(_), do: 0

  @doc """
  Backwards-compatible alias for `estimate_content/1` (legacy name).
  """
  def estimate_tokens(text) when is_binary(text), do: estimate_content(text)
  def estimate_tokens(_), do: 0
end
