defmodule Candil.Context do
  @moduledoc """
  Conversation history shared between consumers, partitioned by consumer.

  Why this exists: `Candil.Conversation` keeps history in the process that
  calls it. Two consumers in the same VM each have their own, they cannot be
  shared, nothing can be summarised, and nothing survives a restart. That is
  the right default for a library and the wrong one for an agent that talks to
  several tools over several turns.

  ## The partition is the design

  Everything is keyed by `{consumer, session_id}`. `posadero` and `opencode`
  may both call a session `"s1"` and must not see each other's messages. A
  plain `session_id` key would collide, and the failure would be silent: the
  right number of messages from the wrong conversation.

  ## Eviction is both LRU and TTL

  A TTL alone collects sessions nobody returns to, but not a process that
  opens a new session on every request. An LRU alone bounds memory but keeps
  dead entries alive until pressure arrives. Both, because they fail
  differently.
  """

  use GenServer

  alias Candil.Context.{Builder, Session}
  alias Candil.Inference

  @table :candil_context_sessions

  @default_max_sessions 1_000
  @default_ttl_seconds 86_400

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a session, or returns the existing one.

  Idempotent, because two processes racing to create the same session should
  not produce a lost update or a crash.
  """
  @spec create(atom(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def create(consumer, id) do
    case get(consumer, id) do
      {:ok, session} ->
        {:ok, session}

      {:error, :not_found} ->
        session = Session.new(consumer, id)

        if :ets.insert_new(@table, {{consumer, id}, session}) do
          {:ok, session}
        else
          get(consumer, id)
        end
    end
  end

  @doc """
  Reads a session.
  """
  @spec get(atom(), String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get(consumer, id) do
    case :ets.lookup(@table, {consumer, id}) do
      [{_key, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Appends a message, creating the session if it does not exist.
  """
  @spec append_message(atom(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def append_message(consumer, session_id, role, content) do
    with {:ok, session} <- create(consumer, session_id) do
      updated = Session.add_message(session, role, content)
      :ets.insert(@table, {{consumer, session_id}, updated})
      :ok
    end
  end

  @doc """
  Applies a function to a session and stores the result.
  """
  @spec update(atom(), String.t(), (Session.t() -> Session.t())) :: :ok | {:error, :not_found}
  def update(consumer, session_id, fun) when is_function(fun, 1) do
    case get(consumer, session_id) do
      {:ok, session} ->
        :ets.insert(@table, {{consumer, session_id}, fun.(session)})
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Chats against a model with the session's history, and records the exchange.

  The session is keyed by `{consumer, session_id}`, so the history a consumer
  sends is not the history another one sees — not even with the same
  `session_id`. That partitioning is the whole point of this module, and it is
  invisible in the return value, which is why it is worth a function of its own
  instead of three calls a caller has to remember to make in the right order.

  ## Options

    * `:consumer` — required. Which consumer this conversation belongs to.
    * `:context_size` — the model's window. Travels with the model, not with
      the conversation: the same session can be routed to a 4k model and then
      to a 131k one.
    * `:system_prompt`, `:margin_tokens` — passed through to the builder.
    * anything else goes to `Candil.chat/3`.

  Returns what `Candil.Inference.chat_local/3` returns. The new messages are
  recorded before the call, so a model that dies mid-request does not lose the
  question; the assistant's reply is only recorded once it exists whole, never
  in chunks.

  It calls `Inference` and not the `Candil` facade on purpose. `Candil` delegates
  `chat_with_context/4` here, so going back through it closes a cycle between
  the two modules, and dialyzer answers a call inside a cycle with the most
  pessimistic typing it can justify — which here meant deciding that the model
  could never answer, and that the whole success branch was dead code. The
  facade is a pass-through; calling the layer underneath breaks the cycle and
  says the same thing.
  """
  @spec chat(atom(), String.t(), [Inference.message()], keyword()) ::
          {:ok, Inference.response()} | {:error, term()}
  def chat(model_alias, session_id, messages, opts \\ []) do
    consumer = Keyword.fetch!(opts, :consumer)
    build_opts = Keyword.take(opts, [:context_size, :system_prompt, :margin_tokens])
    call_opts = Keyword.drop(opts, [:consumer, :context_size, :system_prompt, :margin_tokens])

    with {:ok, session} <- create(consumer, session_id),
         :ok <- record(consumer, session_id, messages),
         {:ok, built} <- Builder.build(session, messages, build_opts),
         {:ok, response} <- Inference.chat_local(model_alias, built, call_opts) do
      _ = append_message(consumer, session_id, "assistant", content_of(response))
      {:ok, response}
    end
  end

  defp record(consumer, session_id, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      role = to_string(Map.get(message, :role) || Map.get(message, "role"))
      content = to_string(Map.get(message, :content) || Map.get(message, "content") || "")

      case append_message(consumer, session_id, role, content) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # The response shape is the backend's, not ours: a string, or a struct with
  # `:content`. Guessing wrong here would write "nil" into somebody's history
  # and call it a conversation.
  defp content_of(%{content: content}) when is_binary(content), do: content
  defp content_of(response) when is_binary(response), do: response
  defp content_of(%{"content" => content}) when is_binary(content), do: content

  defp content_of(response) do
    content =
      case response do
        %{choices: [%{message: %{content: c}}]} -> c
        _ -> nil
      end

    to_string(content || "")
  end

  @doc """
  Deletes one session. The consumer's other sessions are untouched.
  """
  @spec delete(atom(), String.t()) :: :ok
  def delete(consumer, session_id) do
    :ets.delete(@table, {consumer, session_id})
    :ok
  end

  @doc """
  Lists a consumer's sessions, most recently used first.
  """
  @spec list(atom()) :: [Session.t()]
  def list(consumer) do
    :ets.match_object(@table, {{consumer, :"$1"}, :"$2"})
    |> Enum.map(fn {_key, session} -> session end)
    |> Enum.sort_by(& &1.last_used_at, {:desc, DateTime})
  end

  @doc """
  Lists every consumer that has at least one session.
  """
  @spec consumers() :: [atom()]
  def consumers do
    :ets.match_object(@table, {{:"$1", :_}, :_})
    |> Enum.map(fn {key, _session} -> elem(key, 0) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  How many sessions a consumer has.
  """
  @spec count(atom()) :: non_neg_integer()
  def count(consumer), do: length(list(consumer))

  @doc """
  Collects expired sessions, and evicts the least recently used above
  `max_sessions`.

  Returns `{:ok, %{ttl: n, lru: m}}` with how many of each were removed.
  """
  @spec gc(keyword()) :: {:ok, %{ttl: non_neg_integer(), lru: non_neg_integer()}}
  def gc(opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    max = Keyword.get(opts, :max_sessions, @default_max_sessions)
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_seconds, :second)

    all = :ets.tab2list(@table)

    expired =
      Enum.filter(all, fn {_key, session} ->
        DateTime.compare(session.last_used_at, cutoff) == :lt
      end)

    Enum.each(expired, fn {key, _session} -> :ets.delete(@table, key) end)

    {lru, _} = evict_lru(all -- expired, max)

    {:ok, %{ttl: length(expired), lru: lru}}
  end

  defp evict_lru(sessions, max) when length(sessions) <= max, do: {0, sessions}

  defp evict_lru(sessions, max) do
    sorted = Enum.sort_by(sessions, fn {_key, session} -> session.last_used_at end)
    # max(excess, 0), NOT max(-excess, 0). Negating before calling max/2 gives
    # 0 for every over-limit case, because the negative side always wins, and
    # Enum.split(sorted, 0) removes nothing. The collection silently never
    # collected anything.
    excess = max(length(sorted) - max, 0)
    {to_remove, keep} = Enum.split(sorted, excess)
    Enum.each(to_remove, fn {key, _session} -> :ets.delete(@table, key) end)
    {length(to_remove), keep}
  end

  @doc false
  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_gc()
    {:ok, %{}}
  end

  defp schedule_gc do
    Process.send_after(self(), :gc, max(div(@default_ttl_seconds * 1000, 10), 3_600_000))
  end

  @doc false
  @impl GenServer
  def handle_info(:gc, state) do
    # A collection failure must not take the GenServer down: the table is the
    # only state and a crash here loses every session.
    _ = gc()
    interval = div(@default_ttl_seconds * 1000, 10)
    Process.send_after(self(), :gc, max(interval, 3_600_000))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
