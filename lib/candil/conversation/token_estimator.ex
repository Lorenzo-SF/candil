defmodule Candil.Conversation.TokenEstimator do
  @moduledoc """
  Moved to `Candil.Context.TokenEstimator` by amendment D8, and kept here only
  so consumers outside the ecosystem keep compiling until 4.1.0.

  This is a facade with no logic of its own. The implementation lives in
  `Candil.Context.TokenEstimator`, because `Candil.Context` needs the estimator
  and the conversation facade is on its way out; two copies of the same
  heuristics is the thing D8 was written to prevent.
  """

  alias Candil.Context.TokenEstimator

  @deprecated "Usa Candil.Context.TokenEstimator. Se elimina en 4.1.0"

  @doc "See `Candil.Context.TokenEstimator.estimate_conversation/1`."
  @spec estimate_conversation(map()) :: non_neg_integer()
  defdelegate estimate_conversation(conversation), to: TokenEstimator

  @doc "See `Candil.Context.TokenEstimator.estimate_message/1`."
  @spec estimate_message(map()) :: non_neg_integer()
  defdelegate estimate_message(message), to: TokenEstimator

  @doc "See `Candil.Context.TokenEstimator.estimate_content/1`."
  @spec estimate_content(String.t()) :: non_neg_integer()
  defdelegate estimate_content(text), to: TokenEstimator

  @doc "See `Candil.Context.TokenEstimator.estimate_content_legacy/1`."
  @spec estimate_content_legacy(String.t()) :: non_neg_integer()
  defdelegate estimate_content_legacy(text), to: TokenEstimator

  @doc "See `Candil.Context.TokenEstimator.estimate_message_tokens/1`."
  @spec estimate_message_tokens(map()) :: non_neg_integer()
  defdelegate estimate_message_tokens(message), to: TokenEstimator

  @doc "See `Candil.Context.TokenEstimator.estimate_content_tokens/1`."
  @spec estimate_content_tokens(String.t()) :: non_neg_integer()
  defdelegate estimate_content_tokens(text), to: TokenEstimator

  @doc "See `Candil.Context.TokenEstimator.estimate_tokens/1`."
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  defdelegate estimate_tokens(text), to: TokenEstimator
end
