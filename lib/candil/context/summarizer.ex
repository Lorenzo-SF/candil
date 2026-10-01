defmodule Candil.Context.Summarizer do
  @moduledoc """
  Compresses a long session into a summary, without ever destroying it.

  ## The old messages stay

  When a session crosses a threshold, the summariser writes a summary and
  moves the `summarised_upto` marker. The messages are still in the struct.
  `Candil.Context.Builder` stops using them; nothing deletes them.

  That is deliberate. A user who wants to know what was summarised can read
  the actual messages, and — more importantly — a summariser that fails
  halfway leaves the session exactly as it was. A design that deletes first
  and summarises second loses the conversation when the model call fails.

  ## Failure is not an error

  `maybe_summarize/2` returns the session untouched when the summariser model
  is missing or the call fails. A context system that can destroy history
  because a model was down is worse than one that never summarises.
  """

  alias Candil.Context.Session
  alias Candil.{Inference, Store}

  @default_after_messages 50
  @default_after_tokens 8_000

  @prompt """
  Summarise the conversation so far in one paragraph. Keep decisions,
  constraints, file paths, names and anything the user said must not be
  forgotten. Leave out pleasantries.
  """

  @doc """
  Summarises a session if it has grown past its thresholds.

  Returns `{:ok, session}` always, including when it did nothing.
  """
  @spec maybe_summarize(Session.t(), keyword()) :: {:ok, Session.t()}
  def maybe_summarize(%Session{} = session, opts \\ []) do
    after_messages = Keyword.get(opts, :after_messages, @default_after_messages)
    after_tokens = Keyword.get(opts, :after_tokens, @default_after_tokens)

    if Session.needs_summary?(session, after_messages: after_messages, after_tokens: after_tokens) do
      do_summarize(session, opts)
    else
      {:ok, session}
    end
  end

  defp do_summarize(session, opts) do
    case summarizer_model(opts) do
      nil -> {:ok, session}
      alias_ -> summarize_with(session, alias_)
    end
  end

  defp summarizer_model(opts) do
    case Keyword.get(opts, :model) do
      nil ->
        case Application.get_env(:candil, :context, [])[:summarizer_model] do
          nil -> nil
          model -> model
        end

      model ->
        model
    end
  end

  defp summarize_with(session, alias_) do
    case Store.get_model(alias_) do
      {:ok, model} ->
        case call_model(model, session) do
          {:ok, summary} -> {:ok, mark(session, summary)}
          {:error, _reason} -> {:ok, session}
        end

      {:error, :not_found} ->
        {:ok, session}
    end
  end

  # Dispatches on the model's own type rather than assuming a local engine.
  # A summariser pinned to a remote model has to work, and hardcoding
  # chat_local/3 would make the failure depend on the config.
  defp call_model(%{type: :remote} = model, session) do
    case Store.get_provider(model.provider) do
      {:ok, provider} -> infer(&Inference.chat_remote(model, provider, &1, []), session)
      {:error, :not_found} -> {:error, :unknown_provider}
    end
  end

  defp call_model(model, session),
    do: infer(&Inference.chat_local(model.alias, &1, []), session)

  defp infer(call, session) do
    messages = [%{role: "user", content: @prompt}] ++ Session.live_messages(session)

    case call.(messages) do
      {:ok, %{content: summary}} -> {:ok, summary}
      other -> other
    end
  end

  # The marker moves to the end of the existing messages, not to the end of
  # the list as it grows: messages appended after the summary are not
  # summarised yet.
  defp mark(session, summary) do
    %{
      session
      | summary: summary,
        summarised_upto: length(session.messages),
        model_current: session.model_current
    }
  end
end
