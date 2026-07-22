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
    message_total = Enum.reduce(messages, 0, &(&1 + estimate_message(&2)))
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
      _, acc -> acc + 100  # rough estimate for image content
    end)
  end

  def estimate_message(_msg), do: 0

  defp estimate_system(nil), do: 0
  defp estimate_system(text) when is_binary(text), do: estimate_content(text)

  @doc """
  Estimates token count for a raw text string using the
  4-chars-per-token heuristic.
  """
  @spec estimate_content(String.t()) :: non_neg_integer()
  def estimate_content(text) when is_binary(text) do
    ceil(byte_size(text) / 4)
  end

  def estimate_content(_), do: 0

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