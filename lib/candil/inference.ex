defmodule Candil.Inference do
  @moduledoc """
  Inference execution for Candil.

  Handles chat completions and embeddings for both local engines and remote
  providers. Normalises the request/response format across the supported
  provider APIs (OpenAI, Anthropic, Ollama, OpenAI-compatible).

  ## Message format

  All messages are plain maps with `:role` and `:content` string keys:

      %{role: "system", content: "You are a helpful assistant."}
      %{role: "user", content: "Hello!"}
      %{role: "assistant", content: "Hi there!"}

  ## Response format

  All chat functions return a `response()` map:

      %{
        content: "Hello, how can I help?",
        role: "assistant",
        model: "llama-3-8b",
        finish_reason: "stop",
        usage: %{prompt_tokens: 12, completion_tokens: 8, total_tokens: 20}
      }

  """

  alias Candil.{Config, Error, Model, Provider}

  alias Candil.Inference.{Chat, Embeddings}

  @type message :: %{required(:role) => binary(), required(:content) => binary()}

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @type response :: %{
          content: binary(),
          role: binary(),
          model: binary(),
          finish_reason: binary() | nil,
          usage: usage() | nil
        }

  @type embed_response :: [[float()]]

  @doc """
  Runs a chat completion against a local llama-server.

  The engine must be running and healthy. Resolves the server URL from the
  registry via the model alias.

  ## Options

    * `:temperature` — sampling temperature 0.0–2.0 (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `512`)
    * `:stop` — list of stop sequences (default: `[]`)
    * `:system` — system prompt string (prepended to messages if set)

  """
  @spec chat_local(atom(), [message()], keyword()) :: {:ok, response()} | {:error, Error.t()}
  def chat_local(model_alias, messages, opts \\ []) do
    with {:ok, model} <- Config.get_model(model_alias),
         false <- model.type == :remote,
         true <- :chat in model.usage || :completion in model.usage do
      Chat.do_chat_local(model_alias, messages, opts)
    else
      {:error, :not_found} ->
        {:error, Error.model_not_found(model_alias)}

      true ->
        {:error, Error.invalid_request("Model #{model_alias} is remote, use chat_remote/4")}

      false ->
        {:error, Error.invalid_request("Model #{model_alias} does not support chat")}
    end
  end

  @doc """
  Runs a chat completion against a remote provider.

  Dispatches to the appropriate provider module based on `provider.type`.

  ## Options

  Same as `chat_local/3`.
  """
  @spec chat_remote(Model.t(), Provider.t(), [message()], keyword()) ::
          {:ok, response()} | {:error, Error.t()}
  def chat_remote(%Model{} = model, %Provider{} = provider, messages, opts) do
    Chat.do_chat_remote(model, provider, messages, opts)
  end

  @doc """
  Generates embeddings for a list of texts against a local engine.

  The model must have `:embeddings` in its `usage` list.
  """
  @spec embed_local(atom(), [binary()], keyword()) ::
          {:ok, embed_response()} | {:error, Error.t()}
  def embed_local(model_alias, texts, _opts \\ []) do
    with {:ok, model} <- Config.get_model(model_alias),
         false <- model.type == :remote,
         true <- :embeddings in model.usage do
      Embeddings.do_embed_local(model_alias, texts)
    else
      {:error, :not_found} ->
        {:error, Error.model_not_found(model_alias)}

      true ->
        {:error, Error.invalid_request("Model #{model_alias} is remote, use embed_remote/4")}

      false ->
        {:error, Error.invalid_request("Model #{model_alias} does not support embeddings")}
    end
  end

  @doc """
  Generates embeddings for a list of texts against a remote provider.
  """
  @spec embed_remote(Model.t(), Provider.t(), [binary()], keyword()) ::
          {:ok, embed_response()} | {:error, Error.t()}
  def embed_remote(%Model{} = model, %Provider{type: :ollama} = provider, texts, opts) do
    Embeddings.do_embed_remote(model, provider, texts, opts)
  end

  def embed_remote(%Model{} = model, %Provider{} = provider, texts, opts) do
    Embeddings.do_embed_remote(model, provider, texts, opts)
  end
end
