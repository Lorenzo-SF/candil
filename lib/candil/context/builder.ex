defmodule Candil.Context.Builder do
  @moduledoc """
  Turns a session into the message list actually sent to a model.

  Order is: system prompt, summary, then as much recent history as fits.

  ## Failing loudly instead of truncating

  When the new messages alone do not fit in the context window, this returns
  `{:error, :context_exceeded}`. It does not quietly drop the oldest turns.

  A truncated conversation is a conversation where the model answers a
  question it was not asked, with no way for the caller to tell. An error is
  recoverable; a plausible wrong answer is not.
  """

  alias Candil.Context.Session
  alias Candil.Inference

  @default_margin 512
  @default_context_size 4096

  @doc """
  Builds the message list for a request.

  ## Options

    * `:context_size` — the model's window. Not a property of the session: a
      session can be routed to a 4k model and then to a 131k one, and the
      window travels with the model, not with the conversation.
    * `:system_prompt` — prepended as a `system` message.
    * `:margin_tokens` — room left for the response. Default 512.

  ## Examples

      iex> session = Candil.Context.Session.new(:c, "s1")
      iex> Candil.Context.Builder.build(session, [%{role: "user", content: "hola"}])
      {:ok, [%{role: "user", content: "hola"}]}

      iex> session = Candil.Context.Session.new(:c, "s1")
      iex> Candil.Context.Builder.build(session, [%{role: "user", content: "hola"}], context_size: 4)
      {:error, :context_exceeded}
  """
  @spec build(Session.t(), [Inference.message()], keyword()) ::
          {:ok, [Inference.message()]} | {:error, :context_exceeded}
  def build(session, messages, opts \\ []) do
    margin = Keyword.get(opts, :margin_tokens, @default_margin)
    window = Keyword.get(opts, :context_size, @default_context_size) - margin

    new_tokens = estimate(messages)

    if new_tokens > window do
      {:error, :context_exceeded}
    else
      # The new messages come last, and they are always included. An earlier
      # version built prefix ++ summary ++ history and never appended them,
      # so the question being asked was silently dropped — the worst thing a
      # context builder can do.
      {:ok,
       prefix(opts) ++ summary(session) ++ take_history(session, window - new_tokens) ++ messages}
    end
  end

  defp prefix(opts) do
    case Keyword.get(opts, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" -> [%{role: "system", content: prompt}]
      _ -> []
    end
  end

  defp summary(%{summary: summary}) when is_binary(summary) and summary != "" do
    [%{role: "system", content: "Summary of the earlier conversation:\n\n" <> summary}]
  end

  defp summary(_session), do: []

  # Newest first, then put back in order. Dropping from the front is what a
  # context window actually does; dropping from the end would throw away the
  # question that was just asked.
  defp take_history(%Session{messages: messages, summarised_upto: upto}, budget) do
    messages
    |> Enum.drop(upto)
    |> Enum.reverse()
    |> take_while_within(budget)
    |> Enum.reverse()
  end

  defp take_while_within([], _budget), do: []

  defp take_while_within([message | rest], budget) do
    cost = div(String.length(message.content), 4)

    if cost <= budget do
      [message | take_while_within(rest, budget - cost)]
    else
      []
    end
  end

  defp estimate(messages) do
    Enum.reduce(messages, 0, fn message, acc ->
      acc + div(String.length(to_string(message[:content] || "")), 4)
    end)
  end
end
