defmodule Candil.Context.Session do
  @moduledoc """
  One conversation, belonging to one consumer.

  Sessions are keyed by `{consumer, session_id}`, never by `session_id`
  alone. That partitioning is the whole point: two consumers may legitimately
  use the same session id — a client that numbers its conversations from 1
  will — and sharing an ETS key between them would put one consumer's history
  in the other one's context window.

  ## The summary is additive, not destructive

  When a session grows past its thresholds, `Candil.Context.Summarizer`
  writes a summary and marks the older messages as summarisable. The messages
  stay in the struct. `Candil.Context.Builder` stops using them; nothing
  deletes them. A user who wants to know what was summarised can read the
  actual messages, and a summariser that fails leaves the session untouched
  rather than having already discarded the evidence.
  """

  @enforce_keys [:id, :consumer]
  defstruct id: nil,
            consumer: nil,
            created_at: nil,
            updated_at: nil,
            last_used_at: nil,
            model_current: nil,
            messages: [],
            summary: nil,
            summarised_upto: 0,
            metadata: %{}

  @type role :: String.t()
  @type message :: %{role: role(), content: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          consumer: atom(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          last_used_at: DateTime.t(),
          model_current: atom() | nil,
          messages: [message()],
          summary: String.t() | nil,
          summarised_upto: non_neg_integer(),
          metadata: map()
        }

  @doc """
  Creates a session.

  ## Examples

      iex> session = Candil.Context.Session.new(:posadero, "s1")
      iex> {session.consumer, session.id, session.messages}
      {:posadero, "s1", []}
  """
  @spec new(atom(), String.t()) :: t()
  def new(consumer, id) when is_atom(consumer) and is_binary(id) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: id,
      consumer: consumer,
      created_at: now,
      updated_at: now,
      last_used_at: now
    }
  end

  @doc """
  Appends a message and stamps the session as just used.
  """
  @spec add_message(t(), role(), String.t()) :: t()
  def add_message(%__MODULE__{} = session, role, content)
      when is_binary(role) and is_binary(content) do
    now = DateTime.utc_now()

    %{
      session
      | messages: session.messages ++ [%{role: role, content: content}],
        updated_at: now,
        last_used_at: now
    }
  end

  @doc """
  Marks the session as used without adding a message.
  """
  @spec touch(t()) :: t()
  def touch(%__MODULE__{} = session) do
    now = DateTime.utc_now()
    %{session | last_used_at: now, updated_at: now}
  end

  @doc """
  Approximate token count of the session's own messages.

  Deliberately an estimate. An exact count means a tokenizer load on every
  read, and the Builder only needs to know roughly how full the context is.
  """
  @spec tokens(t()) :: non_neg_integer()
  def tokens(%__MODULE__{messages: messages, summary: summary}) do
    # A plain `&div(String.length(&1.content), 4)` would be a unary capture,
    # and Enum.reduce/3 calls it with two arguments. Worth writing out.
    message_tokens =
      Enum.reduce(messages, 0, fn message, acc ->
        acc + div(String.length(message.content), 4)
      end)

    summary_tokens = if summary, do: div(String.length(summary), 4), else: 0
    message_tokens + summary_tokens
  end

  @doc """
  The messages from `summarised_upto` onwards: the ones the Builder uses.

  ## Examples

      iex> session = Candil.Context.Session.new(:c, "s")
      iex> session = Enum.reduce(["a", "b", "c"], session, &Candil.Context.Session.add_message(&2, "user", &1))
      iex> length(Candil.Context.Session.live_messages(session))
      3
      iex> session = %{session | summarised_upto: 2}
      iex> Candil.Context.Session.live_messages(session)
      [%{role: "user", content: "c"}]
  """
  @spec live_messages(t()) :: [message()]
  def live_messages(%__MODULE__{messages: messages, summarised_upto: n}) do
    Enum.drop(messages, n)
  end

  @doc """
  Whether the session has grown past the summarisation thresholds.
  """
  @spec needs_summary?(t(), keyword()) :: boolean()
  def needs_summary?(%__MODULE__{} = session, opts \\ []) do
    after_tokens = Keyword.get(opts, :after_tokens, 8_000)
    after_messages = Keyword.get(opts, :after_messages, 50)

    length(live_messages(session)) > after_messages or
      tokens(session) > after_tokens
  end
end
