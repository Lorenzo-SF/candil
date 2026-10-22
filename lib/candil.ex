defmodule Candil do
  @moduledoc """
  Candil — LLM inference and model management for Elixir.

  Run local models via llama.cpp or remote models via OpenAI-compatible APIs.

  ## Quick start — the easy way

      # One line: auto-resolves the model, auto-starts the engine.
      {:ok, response} = Candil.chat("llama3", "Hello!")
      IO.puts(response.content)

      # Download a model (like Ollama's pull):
      :ok = Candil.pull("llama3")

      # Start the OpenAI-compatible gateway with zero config:
      {:ok, _pid} = Candil.serve()

  ## Quick start — local model (full control)

      engine = %Candil.Engine{alias: :llama_server, binary: "llama-server",
                              host: "127.0.0.1", port: 8080}
      model  = %Candil.Model{alias: :llama3, type: :local, model_dir: "/models",
                              filename: "llama-3-8b-q4_k_m.gguf", engine: :llama_server,
                              context_size: 8192, usage: [:chat]}

      :ok = Candil.download_engine(engine)
      {:ok, _} = Candil.download_model(model)
      {:ok, _pid} = Candil.start_engine(engine, model)

      {:ok, response} = Candil.chat(:llama3, [%{role: "user", content: "Hello!"}])
      IO.puts(response.content)

      :ok = Candil.stop_engine(:llama3)

  ## Quick start — remote model

      provider = %Candil.Provider{alias: :openai, type: :openai,
                                   base_url: "https://api.openai.com",
                                   api_key: System.get_env("OPENAI_API_KEY")}
      model = %Candil.Model{alias: :gpt4o, type: :remote, name: "gpt-4o",
                             provider: :openai, usage: [:chat]}

      {:ok, response} = Candil.chat(model, provider, [%{role: "user", content: "Hello!"}])

  ## Configuration

      Candil.Store.register_engine(engine)
      Candil.Store.register_model(model)
      Candil.Store.register_provider(provider)
  """

  alias Candil.Context
  alias Candil.Inference
  alias Candil.Llm

  @doc """
  Downloads the appropriate precompiled llama.cpp binary for this engine.

  Detects the current OS, architecture and GPU automatically. Does nothing
  when the engine declares no `:install` plan.
  """
  defdelegate download_engine(engine), to: Llm

  @doc """
  Downloads a local model file to `model.model_dir`.

  Does nothing if `model.type` is `:remote`.
  """
  defdelegate download_model(model), to: Llm

  @doc """
  Starts a local llama-server engine loaded with `model`.

  Returns `{:ok, pid}` where `pid` is the `Candil.Engine.Server` process.
  The server process is registered under the model alias in
  `Candil.Registry`.
  """
  defdelegate start_engine(engine, model), to: Llm

  @doc """
  Stops a running engine identified by the model alias.
  """
  defdelegate stop_engine(model_alias), to: Llm

  @doc """
  Returns `true` if an engine serving the given model alias is running and
  responding to health checks.
  """
  defdelegate engine_healthy?(model_alias), to: Llm

  @doc """
  Runs a chat completion against a model.

  Accepts a model alias (atom or string) and a message (string or list of
  messages). If the engine is not running, it is started automatically —
  the common case needs no `start_engine/2` call.

  ## Examples

      # The simplest thing that works:
      {:ok, response} = Candil.chat("llama3", "Hello!")

      # With a list of messages:
      {:ok, response} = Candil.chat(:llama3, [%{role: "user", content: "Hello!"}])

      # With options:
      {:ok, response} = Candil.chat("llama3", "Hello!", temperature: 0.5)

  Returns `{:error, :model_not_found}` if the model is not in the catalogue,
  and `{:error, :start_timeout}` if the engine could not start in time.
  """
  @spec chat(String.t() | atom(), String.t() | [Inference.message()], keyword()) ::
          {:ok, Inference.response()} | {:error, term()}
  def chat(model, message, opts \\ []) do
    messages = normalize_message(message)
    alias_ = resolve_model_alias(model)

    case alias_ do
      nil ->
        {:error, :model_not_found}

      atom ->
        case ensure_engine_running(atom, opts) do
          :ok -> Candil.Llm.chat(atom, messages, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Downloads the engine and model for `model` (engine + model files).

  Like Ollama's `pull`: one command, everything needed. Does nothing if
  already downloaded.

  Returns `:ok` on success.
  """
  @spec pull(String.t() | atom()) :: :ok | {:error, term()}
  def pull(model) do
    alias_ = resolve_model_alias(model)

    case alias_ do
      nil ->
        {:error, :model_not_found}

      atom ->
        with {:ok, model_struct} <- Candil.Store.get_model(atom),
             {:ok, engine} <- Candil.Store.get_engine(model_struct.engine) do
          :ok = Candil.Llm.download_engine(engine)
          {:ok, _} = Candil.Llm.download_model(model_struct)
          :ok
        end
    end
  end

  @doc """
  Starts the gateway with zero configuration.

  Uses the first model available in the catalogue. Arranges for its engine
  to be running before accepting requests.
  """
  @spec serve(keyword()) :: {:ok, pid()} | {:error, term()}
  def serve(opts \\ []) do
    models = Candil.Store.list_models()

    case models do
      [] ->
        {:error, :no_models}

      [first | _] ->
        case ensure_engine_running(first.alias, opts) do
          :ok -> Candil.Gateway.start(opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Runs a chat completion against a **remote** model via a provider.

  The engine must already be running via `start_engine/2`.

  ## Options

    * `:temperature` — sampling temperature (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `4096`, or the model's own `max_tokens` when it declares one)
    * `:stop` — list of stop sequences

  """
  defdelegate chat(model, provider, messages, opts), to: Llm

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp normalize_message(msg) when is_binary(msg), do: [%{role: "user", content: msg}]
  defp normalize_message(msgs) when is_list(msgs), do: msgs

  @doc false
  def resolve_model_alias(name) when is_atom(name) do
    # Check if it exists in the store
    case Candil.Store.get_model(name) do
      {:ok, _} -> name
      {:error, _} -> nil
    end
  end

  @doc false
  def resolve_model_alias(name) when is_binary(name) do
    Candil.Store.list_models()
    |> Enum.find(fn m -> to_string(m.alias) == name end)
    |> case do
      nil -> nil
      model -> model.alias
    end
  end

  @doc false
  def ensure_engine_running(model_alias, opts) do
    if Candil.Llm.engine_healthy?(model_alias) do
      :ok
    else
      case Candil.Store.get_model(model_alias) do
        {:ok, model} -> ensure_engine_for_model(model, opts)
        {:error, _} -> {:error, :model_not_found}
      end
    end
  end

  defp ensure_engine_for_model(model, opts) do
    case model.engine do
      nil ->
        {:error, :no_engine}

      engine_alias ->
        start_engine_if_found(engine_alias, model, opts)
    end
  end

  defp start_engine_if_found(engine_alias, model, opts) when is_atom(engine_alias) do
    case Candil.Store.get_engine(engine_alias) do
      {:ok, engine} ->
        # Colocar y arrancar por el camino UNICO (`Engine.start_placed/2`): el
        # scheduler decide donde va, se reserva la VRAM, y quien expulsa a las
        # víctimas es el que ejecuta. Es el mismo camino que usa el CLI, y esa
        # es la gracia: no pueden divergir.
        case Candil.Engine.start_placed(engine, model) do
          {:ok, _pid} ->
            Process.sleep(Keyword.get(opts, :start_wait_ms, 3_000))
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} ->
        {:error, :engine_not_found}
    end
  end

  @doc """
  Chats against a model using the shared, consumer-partitioned context.

  The replacement for `Candil.Conversation`, which kept its history in the
  calling process. Here the history lives in ETS under `{consumer, session_id}`,
  so two consumers in the same VM never see each other's turns, not even with
  the same `session_id`.

  ## Options

    * `:consumer` — required. Which consumer this conversation belongs to.
    * `:context_size` — the model's window.
    * `:system_prompt`, `:margin_tokens` — context building.
    * the rest go to `chat/3`.

  ## Examples

      iex> Candil.chat_with_context(:coder, "s1", [%{role: "user", content: "hola"}], consumer: :posadero)
      {:error, :not_started}

  """
  defdelegate chat_with_context(model_alias, session_id, messages, opts),
    to: Context,
    as: :chat

  @doc """
  Runs an embeddings request against a **local** model.

  The engine must be running and the model must have `:embeddings` in its
  `usage` list.
  """
  defdelegate embed(model_alias, texts), to: Llm

  @doc """
  Runs an embeddings request against a **local** model.

  The engine must be running and the model must have `:embeddings` in its
  `usage` list.
  """
  defdelegate embed(model_alias, texts, opts), to: Llm

  @doc """
  Runs an embeddings request against a **local** model.

  The engine must be running and the model must have `:embeddings` in its
  `usage` list.
  """
  defdelegate embed(model, provider, texts, opts), to: Llm

  @doc """
  Streams a chat completion from a **local** engine.

  The engine must be running. Calls `callback` for each token chunk.
  """
  defdelegate stream(model_alias, messages, callback), to: Llm

  @doc """
  Streams a chat completion from a **local** engine.

  The engine must be running. Calls `callback` for each token chunk.
  """
  defdelegate stream(model_alias, messages, callback, opts), to: Llm

  @doc """
  Streams a chat completion from a **local** engine.

  The engine must be running. Calls `callback` for each token chunk.
  """
  defdelegate stream(model, provider, messages, callback, opts), to: Llm
end
