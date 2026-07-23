defmodule Candil.Conversation do
  @moduledoc """
  Conversation history management for `Candil.Llm`.

  Maintains a message history and automatically manages context window
  limits. When the accumulated token estimate exceeds `max_context_tokens`,
  older messages are trimmed while always preserving the system prompt.

  Token estimation is delegated to `Candil.Conversation.Context`.

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

  alias Candil.Conversation.Context
  alias Candil.Inference
  alias Candil.Model
  alias Candil.Provider

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
      max_response_tokens:
        Keyword.get(opts, :max_response_tokens, Context.default_max_response_tokens()),
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
    trimmed = Context.trim_to_context(messages_with_user, conv.system, available)

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
    Context.token_estimate(conv.messages, conv.system)
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
  def estimate_content_tokens(text), do: Context.estimate_content_tokens(text)

  @doc false
  def estimate_content_tokens(_, _), do: 0

  @doc false
  @spec estimate_message_tokens(map()) :: non_neg_integer()
  def estimate_message_tokens(msg), do: Context.estimate_message_tokens(msg)

  @doc false
  @spec estimate_tokens(binary()) :: non_neg_integer()
  def estimate_tokens(text), do: Context.estimate_tokens(text)
end
