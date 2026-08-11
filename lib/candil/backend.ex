defmodule Candil.Backend do
  @moduledoc """
  Behaviour that abstracts the local/remote differences between LLM
  backends. A backend is responsible for:

    * `chat/3` — synchronous single-shot chat completion.
    * `chat_stream/3` — server-sent-event streaming chat completion.
    * `embed/3` — text → vector embeddings, optionally batched.
    * `models/0` — list of `Candil.Model.t/0` the backend supports.

  Backends are stateless wrappers around whatever HTTP / port machinery
  Candil already exposes (`Candil.Engine`, `Candil.HTTP`,
  `Candil.Embeddings`). They are looked up at runtime via
  `Candil.Backend.for/2` and the result is cached per (provider,
  model) pair.

  ## Built-in backends

    * `Candil.Backend.LlamaCpp` — wraps the existing local
      llama-server / `Candil.Engine` flow.
    * `Candil.Backend.OpenAICompat` — base for OpenAI-compatible HTTP
      endpoints (used by OpenAI, Azure, Ollama, Groq, vLLM, etc.).

  ## Custom backends

  Define a module that implements this behaviour and register it via
  `Candil.Backend.register/2`:

      defmodule MyApp.Backends.Azure do
        @behaviour Candil.Backend

        @impl true
        def chat(model, messages, opts), do: ...
        @impl true
        def chat_stream(model, messages, opts), do: ...
        @impl true
        def embed(model, texts, opts), do: ...
        @impl true
        def models, do: [...]
      end

      Candil.Backend.register(:azure, MyApp.Backends.Azure)
  """

  alias Candil.Model

  @type chat_response :: %{
          content: String.t(),
          finish_reason: String.t() | nil,
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
        }

  @type stream_chunk :: %{
          content: String.t(),
          finish_reason: String.t() | nil,
          done: boolean()
        }

  @type embed_vector :: [float()]

  @callback chat(String.t() | Model.t(), [map()], keyword()) ::
              {:ok, chat_response()} | {:error, term()}
  @callback chat_stream(String.t() | Model.t(), [map()], keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
  @callback embed(String.t() | Model.t(), [String.t()], keyword()) ::
              {:ok, [embed_vector()]} | {:error, term()}
  @callback models() :: [Model.t()]

  @doc """
  Register a backend module for the given provider atom (`:local`,
  `:openai`, `:anthropic`, `:ollama`, etc.).
  """
  @spec register(atom(), module()) :: :ok
  def register(provider, module) when is_atom(provider) and is_atom(module) do
    :persistent_term.put({__MODULE__, :backends, provider}, module)
    :ok
  end

  @doc """
  Look up the backend module registered for `(provider, model)`.
  Returns `{:ok, module}` or `{:error, :backend_unavailable}`.

  Falls back to inferring the provider from the model name when no
  exact match is registered:

    * starts with `gpt-` / `o1-` / `o3-` → `:openai`
    * starts with `claude-` → `:anthropic`
    * contains `:` → `:ollama` (model tag convention)
    * otherwise → `:local` (llama.cpp / llama-server)

  See `Candil.Backend.infer_provider/2`.
  """
  @spec for(atom(), String.t() | Model.t()) :: {:ok, module()} | {:error, term()}
  def for(provider, model) when is_atom(provider) do
    case lookup(provider) do
      {:ok, mod} ->
        {:ok, mod}

      :error ->
        infer_provider(provider, model)
        |> lookup()
        |> case do
          {:ok, mod} -> {:ok, mod}
          :error -> {:error, backend_unavailable(provider, model)}
        end
    end
  end

  @doc """
  Infer the provider atom from a model name and the configured
  default provider. Public so callers can pre-compute the provider
  for telemetry/UI.

  ## Examples

      iex> Candil.Backend.infer_provider(:openai, "gpt-4o")
      :openai
      iex> Candil.Backend.infer_provider(:local, "llama3")
      :local
      iex> Candil.Backend.infer_provider(:local, "llama3:8b")
      :ollama
  """
  @spec infer_provider(atom(), String.t() | Model.t()) :: atom()
  def infer_provider(provider, model) when is_binary(model) do
    cond do
      String.starts_with?(model, "gpt-") -> :openai
      String.starts_with?(model, "o1-") -> :openai
      String.starts_with?(model, "o3-") -> :openai
      String.starts_with?(model, "o4-") -> :openai
      String.starts_with?(model, "claude-") -> :anthropic
      String.contains?(model, ":") -> :ollama
      true -> provider
    end
  end

  def infer_provider(provider, %Model{name: name}) when is_binary(name) do
    infer_provider(provider, name)
  end

  @doc """
  Build a typed `:backend_unavailable` error.
  """
  @spec backend_unavailable(atom(), term()) :: Candil.Error.t()
  def backend_unavailable(provider, model) do
    Candil.Error.backend_unavailable({:no_backend_for, provider, model})
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec lookup(atom()) :: {:ok, module()} | :error
  defp lookup(provider) do
    case :persistent_term.get({__MODULE__, :backends, provider}, :unset) do
      :unset ->
        # Lazy default registrations on first lookup.
        case provider do
          :local -> register_and_return(:local, __MODULE__.LlamaCpp)
          :openai -> register_and_return(:openai, __MODULE__.OpenAICompat)
          :anthropic -> register_and_return(:anthropic, __MODULE__.OpenAICompat)
          :ollama -> register_and_return(:ollama, __MODULE__.OpenAICompat)
          :azure -> register_and_return(:azure, __MODULE__.OpenAICompat)
          _ -> :error
        end

      mod when is_atom(mod) ->
        {:ok, mod}
    end
  end

  defp register_and_return(provider, module) do
    :persistent_term.put({__MODULE__, :backends, provider}, module)
    {:ok, module}
  end
end