defmodule Candil.Conversation do
  @moduledoc """
  Conversation history management for the `Candil` public API.

  Maintains a message history and automatically manages context window
  limits. When the accumulated token estimate exceeds `max_context_tokens`,
  older messages are trimmed while always preserving the system prompt.

  > #### Deprecated {: .warning}
  >
  > This module keeps the history **in the process that calls it**, which is
  > exactly the thing `Candil.Context` exists to fix: two consumers in the
  > same VM each get their own, and the two cannot be shared, summarised or
  > moved between models. The replacement is a `chat_with_context/4` on the
  > `Candil` module, which stores the history in ETS partitioned by consumer.
  > Removed in 4.1.0.
  >
  > It stays in 4.0 because there are consumers outside this ecosystem, and
  > `Candil.Agent` is one of them inside it.
  >
  > **Why the deprecation is in this paragraph and not in an `@deprecated`
  > attribute:** the attribute is a compiler warning, and `Candil.Agent` still
  > calls four of these functions, so marking them would turn
  > `mix compile --warnings-as-errors` red on the repo's own code. Suppressing
  > that with `@compile {:no_warn_deprecated, Candil.Conversation}` was tried
  > and **does not work when both modules are in the same parallel compilation
  > batch** — measured, not assumed. The attribute goes on when `Agent`
  > migrates to `Candil.Context`, in 4.1.0.

  Token estimation lives in `Candil.Context.TokenEstimator` (moved here by
  amendment D8, from `Candil.Conversation.TokenEstimator`).

  `Candil.Conversation.Context` no longer exists: it had never left the house,
  so it is removed rather than deprecated. Its trimming and counting moved in
  here as private functions, with their arithmetic unchanged.

  ## Usage

      conv = Candil.Conversation.new(
        model: :llama3,
        system: "You are a helpful Elixir assistant.",
        max_context_tokens: 4096
      )

      {:ok, conv, response} = Candil.Conversation.chat(conv, "What is a GenServer?")
      {:ok, conv, response} = Candil.Conversation.chat(conv, "Give me a code example.")

      IO.puts(response.content)
  """

  alias Candil.Context.TokenEstimator
  alias Candil.Inference
  alias Candil.Model
  alias Candil.Provider

  # Moved from `Candil.Conversation.Context`, which D8 removes. It is a
  # constant of this module's own policy, not of the estimator.
  @default_max_response_tokens 2048

  @type message :: Inference.message()

  @type t :: %__MODULE__{
          model: atom() | Model.t(),
          provider: Provider.t() | nil,
          system: binary() | nil,
          messages: [message()],
          max_context_tokens: pos_integer(),
          max_response_tokens: pos_integer(),
          opts: keyword()
        }

  defstruct model: nil,
            provider: nil,
            system: nil,
            messages: [],
            max_context_tokens: 4096,
            max_response_tokens: 512,
            opts: []

  @doc """
  Creates a new conversation.

  ## Options

    * `:model` — atom alias (local engine) or `Candil.Model` struct (required)
    * `:provider` — `Candil.Provider` struct for remote models
    * `:system` — system prompt (default: `nil`)
    * `:max_context_tokens` — approximate token limit for history (default: `4096`)
    * `:max_response_tokens` — max tokens to generate in responses (default: `512`)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      model: Keyword.fetch!(opts, :model),
      provider: Keyword.get(opts, :provider),
      system: Keyword.get(opts, :system),
      max_context_tokens: Keyword.get(opts, :max_context_tokens, 4096),
      max_response_tokens: Keyword.get(opts, :max_response_tokens, @default_max_response_tokens),
      opts:
        Keyword.drop(opts, [:model, :provider, :system, :max_context_tokens, :max_response_tokens])
    }
  end

  @doc """
  Sends a user message and returns `{:ok, updated_conv, response}`.

  Appends the user message to history, calls the model, appends the
  assistant response, and trims history if needed.
  """
  @spec chat(t(), binary()) :: {:ok, t(), Inference.response()} | {:error, any()}
  def chat(%__MODULE__{} = conv, user_message) when is_binary(user_message) do
    user_msg = %{role: "user", content: user_message}
    messages_with_user = conv.messages ++ [user_msg]

    available = conv.max_context_tokens - conv.max_response_tokens
    trimmed = trim_to_context(messages_with_user, conv.system, available)

    call_opts = Keyword.merge(conv.opts, max_tokens: conv.max_response_tokens)
    call_opts = if(conv.system, do: Keyword.put(call_opts, :system, conv.system), else: call_opts)

    result =
      case conv.provider do
        nil ->
          Inference.chat_local(conv.model, trimmed, call_opts)

        %Provider{} = provider ->
          Inference.chat_remote(conv.model, provider, trimmed, call_opts)
      end

    case result do
      {:ok, response} ->
        assistant_msg = %{role: "assistant", content: response.content}
        updated = %{conv | messages: messages_with_user ++ [assistant_msg]}
        {:ok, updated, response}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Appends a message to the history without calling the model.

  Useful for agent loops that manage their own backend calls. Returns the
  updated conversation.
  """
  @spec add_message(t(), binary(), binary()) :: t()
  def add_message(%__MODULE__{} = conv, role, content)
      when role in ["user", "assistant", "system"] do
    %{conv | messages: conv.messages ++ [%{role: role, content: content}]}
  end

  @doc """
  Resets the conversation history, keeping the system prompt and config.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = conv), do: %{conv | messages: []}

  @doc """
  Returns the full message list including the system prompt as the first
  message (if set).
  """
  @spec messages(t()) :: [message()]
  def messages(%__MODULE__{system: nil, messages: msgs}), do: msgs

  def messages(%__MODULE__{system: system, messages: msgs}) do
    [%{role: "system", content: system} | msgs]
  end

  @doc """
  Returns the approximate token count for the current history.
  """
  @spec token_estimate(t()) :: non_neg_integer()
  def token_estimate(%__MODULE__{} = conv) do
    token_total(conv.messages, conv.system)
  end

  @doc """
  Returns the number of turns (user+assistant pairs) in the conversation.
  """
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{messages: msgs}) do
    Enum.count(msgs, &(&1[:role] == "user" || &1["role"] == "user"))
  end

  @doc """
  Returns the available context tokens (accounting for max_response_tokens).
  """
  @spec available_context_tokens(t()) :: non_neg_integer()
  def available_context_tokens(%__MODULE__{} = conv) do
    conv.max_context_tokens - conv.max_response_tokens
  end

  @doc false
  @spec estimate_content_tokens(binary()) :: non_neg_integer()
  def estimate_content_tokens(text), do: TokenEstimator.estimate_content_tokens(text)

  @doc false
  def estimate_content_tokens(_, _), do: 0

  @doc false
  @spec estimate_message_tokens(map()) :: non_neg_integer()
  def estimate_message_tokens(msg), do: message_tokens(msg)

  @doc false
  @spec estimate_tokens(binary()) :: non_neg_integer()
  def estimate_tokens(text), do: TokenEstimator.estimate_tokens(text)

  # ─── Moved from `Candil.Conversation.Context` (removed by D8) ──────────────
  #
  # The arithmetic is unchanged on purpose. `message_tokens/1` here adds 4 for
  # the role and separators, which `TokenEstimator.estimate_message/1` does not:
  # they are different numbers and swapping one for the other would silently
  # change when history gets trimmed.

  # Total tokens for a conversation's messages, plus its system prompt.
  @spec token_total([map()], String.t() | nil) :: non_neg_integer()
  defp token_total(messages, system) do
    system_tokens = if system, do: TokenEstimator.estimate_content_tokens(system), else: 0
    history_tokens = Enum.reduce(messages, 0, &(&2 + message_tokens(&1)))
    system_tokens + history_tokens
  end

  # Drops the oldest messages that do not fit, never the system prompt.
  @spec trim_to_context([map()], String.t() | nil, non_neg_integer()) :: [map()]
  defp trim_to_context(messages, system, max_tokens) do
    system_tokens = if system, do: TokenEstimator.estimate_content_tokens(system), else: 0
    max_history = max_tokens - system_tokens

    messages
    |> Enum.reverse()
    |> Enum.reduce({[], 0}, fn msg, {acc, tokens} ->
      msg_tokens = message_tokens(msg)

      if tokens + msg_tokens <= max_history do
        {[msg | acc], tokens + msg_tokens}
      else
        {acc, tokens}
      end
    end)
    |> elem(0)
  end

  # Deliberately NOT `TokenEstimator.estimate_message/1`: this one counts the
  # role and the separators, on top of the content.
  @spec message_tokens(map()) :: non_neg_integer()
  defp message_tokens(msg) do
    text =
      case msg do
        %{content: content} when is_binary(content) -> content
        %{content: content} when is_list(content) -> Enum.map_join(content, & &1)
        _ -> ""
      end

    TokenEstimator.estimate_content_tokens(text) + 4
  end
end
