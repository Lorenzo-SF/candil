defmodule Candil.Conversation do
  @moduledoc """
  Conversation history management for `Candil.Llm`.

  Maintains a message history and automatically manages context window
  limits. When the accumulated token estimate exceeds `max_context_tokens`,
  older messages are trimmed while always preserving the system prompt.

  ## Usage

      conv = Candil.Conversation.new(
        model: :llama3,
        system: "You are a helpful Elixir assistant.",
        max_context_tokens: 4096
      )

      {:ok, conv, response} = Candil.Conversation.chat(conv, "What is a GenServer?")
      {:ok, conv, response} = Candil.Conversation.chat(conv, "Give me a code example.")

      IO.puts(response.content)

  ## Remote provider

      conv = Candil.Conversation.new(
        model: gpt4o_model,
        provider: openai_provider,
        system: "You are a code reviewer.",
        max_context_tokens: 16_000
      )

  ## Token estimation

  Token counts are estimated using a more accurate approximation that accounts for:

  - Per-message overhead (role, content wrapper): ~4 tokens
  - Per-message overhead for message arrays: ~3 tokens
  - Content itself: approximately `ceil(byte_size / 4)` for English text

  The formula used is: `4 + ceil(content_bytes / 4)` per message.

  For more precise estimation, consider using a tokenizer library like `tiktoken`
  if available for your model.

  ## Configuration

  The following options can be set in application config:

      config :candil, Candil.Conversation,
        max_tokens: 512,  # default max_tokens for responses
        estimation_mode: :default  # :default or :tiktoken (when available)
  """

  alias Candil.{Inference, Model, Provider}

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
    * Any other options are forwarded to `Candil.chat/3` on each turn
      (`:temperature`, `:max_tokens`, etc.)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      model: Keyword.fetch!(opts, :model),
      provider: Keyword.get(opts, :provider),
      system: Keyword.get(opts, :system),
      max_context_tokens: Keyword.get(opts, :max_context_tokens, 4096),
      max_response_tokens: Keyword.get(opts, :max_response_tokens, default_max_response_tokens()),
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

    # Account for max_response_tokens when calculating available context
    available = conv.max_context_tokens - conv.max_response_tokens
    trimmed = trim_to_context(messages_with_user, conv.system, available)

    # Merge opts with max_response_tokens for this call
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
    conv
    |> messages()
    |> Enum.reduce(0, fn msg, acc -> acc + estimate_message_tokens(msg) end)
  end

  @doc """
  Returns the number of turns (user+assistant pairs) in the conversation.
  """
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{messages: msgs}) do
    msgs |> Enum.count(&(&1[:role] == "user" || &1["role"] == "user"))
  end

  @doc """
  Returns the available context tokens (accounting for max_response_tokens).
  """
  @spec available_context_tokens(t()) :: non_neg_integer()
  def available_context_tokens(%__MODULE__{} = conv) do
    conv.max_context_tokens - conv.max_response_tokens
  end

  # Private functions

  defp trim_to_context(messages, system, max_tokens) do
    system_tokens =
      if system, do: estimate_message_tokens(%{role: "system", content: system}), else: 0

    limit = max_tokens - system_tokens

    {trimmed, _} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn msg, {acc, used} ->
        cost = estimate_message_tokens(msg)

        if used + cost <= limit do
          {:cont, {[msg | acc], used + cost}}
        else
          {:halt, {acc, used}}
        end
      end)

    trimmed
  end

  @doc """
  Estimates tokens for a message, accounting for role and overhead.

  The formula is:
  - Base overhead per message: ~4 tokens
  - Content: `ceil(byte_size / 4)` for typical English text
  """
  @spec estimate_message_tokens(message()) :: non_neg_integer()
  def estimate_message_tokens(msg) do
    content = msg[:content] || msg["content"] || ""
    # Per-message overhead: ~4 tokens for role/formatting + content estimation
    4 + estimate_content_tokens(content)
  end

  @doc """
  Estimates tokens for text content.

  Uses `ceil(byte_size / 4)` as a rough approximation for English text.
  Note: This is a rough estimate. For precise counts, use a tokenizer
  like tiktoken.
  """
  @spec estimate_content_tokens(binary()) :: non_neg_integer()
  def estimate_content_tokens(text) when is_binary(text) do
    # Base approximation: ~4 characters per token for English
    # Add extra buffer for special characters and formatting
    bytes = byte_size(text)
    (div(bytes, 4) + div(bytes, 5)) |> max(1)
  end

  def estimate_content_tokens(_), do: 0

  # Legacy alias for backward compatibility
  @doc false
  @spec estimate_tokens(binary()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    estimate_content_tokens(text)
  end

  def estimate_tokens(_), do: 0

  # Configuration helpers

  defp default_max_response_tokens do
    Application.get_env(:candil, Candil.Conversation, [])
    |> Keyword.get(:max_response_tokens, 512)
  end
end
