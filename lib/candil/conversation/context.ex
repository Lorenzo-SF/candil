defmodule Candil.Conversation.Context do
  @moduledoc """
  Context window management for conversation history.

  Provides token estimation and window trimming helpers used by
  `Candil.Conversation` to stay within model context limits.
  """

  alias Candil.Conversation.TokenEstimator

  @doc """
  Estimates the total token count for a conversation's messages.
  """
  @spec token_estimate([map()], String.t() | nil, map()) :: non_neg_integer()
  def token_estimate(messages, system, _opts \\ %{}) do
    system_tokens = if system, do: estimate_content_tokens(system), else: 0
    history_tokens = Enum.reduce(messages, 0, &(&2 + estimate_message_tokens(&1)))
    system_tokens + history_tokens
  end

  @doc "Trims old messages from a list while preserving the system prompt."
  @spec trim_to_context([map()], String.t() | nil, non_neg_integer()) :: [map()]
  def trim_to_context(messages, system, max_tokens) do
    system_tokens = if system, do: estimate_content_tokens(system), else: 0
    max_history = max_tokens - system_tokens

    messages
    |> Enum.reverse()
    |> Enum.reduce({[], 0}, fn msg, {acc, tokens} ->
      msg_tokens = estimate_message_tokens(msg)

      if tokens + msg_tokens <= max_history do
        {[msg | acc], tokens + msg_tokens}
      else
        {acc, tokens}
      end
    end)
    |> elem(0)
  end

  @doc "Estimates the tokens in a single message."
  @spec estimate_message_tokens(map()) :: non_neg_integer()
  def estimate_message_tokens(msg) do
    text =
      case msg do
        %{content: content} when is_binary(content) -> content
        %{content: content} when is_list(content) -> Enum.map_join(content, & &1)
        _ -> ""
      end

    estimate_content_tokens(text) + 4
  end

  @doc "Estimates the tokens in a text string."
  @spec estimate_content_tokens(binary()) :: non_neg_integer()
  def estimate_content_tokens(text) when is_binary(text) do
    TokenEstimator.estimate_content(text)
  end

  def estimate_content_tokens(_), do: 0

  @doc "Estimates tokens for any input."
  @spec estimate_tokens(binary()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    TokenEstimator.estimate_tokens(text)
  end

  def estimate_tokens(_), do: 0

  @doc "Default max response tokens."
  @spec default_max_response_tokens() :: pos_integer()
  def default_max_response_tokens, do: 2048
end
