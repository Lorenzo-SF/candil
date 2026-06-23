defmodule Candil.Llm do
  @moduledoc false
  # Public API is exposed through `Candil`; this module is the internal
  # implementation. The original moduledoc is preserved below as a comment
  # block for reference.
  #
  # Provides a unified interface for running, managing and querying large language
  # models — whether they run locally via `llama.cpp` or remotely via an API
  # provider such as OpenAI, Anthropic or Ollama.

  # Concepts

  # Engine

  An engine is a local `llama-server` binary that serves one model at a time
  over an OpenAI-compatible HTTP API. You can use a pre-existing binary on the
  machine or let Apero download the official precompiled release from the
  [llama.cpp releases page](https://github.com/ggml-org/llama.cpp/releases).

  # Provider

  A provider is a remote HTTP API (OpenAI, Anthropic, Ollama, or any
  OpenAI-compatible endpoint). Ollama is treated as a remote provider because
  it manages its own process and model storage independently.

  # Model

  A model is either:
  - **Local** — a `.gguf` file on disk, associated with an engine.
  - **Remote** — a model name / ID offered by a provider.

  # Lifecycle — local model

      # 1. Define engine and model
      engine = %Candil.Engine{
        alias: :llama_server,
        binary_dir: "/usr/local/bin",
        use_precompiled: true,
        precompiled_version: :latest,
        start_args: ["--host", "127.0.0.1"]
      }

      model = %Candil.Model{
        alias: :llama3,
        type: :local,
        model_dir: "/models",
        filename: "llama-3-8b-q4_k_m.gguf",
        download_url: "https://huggingface.co/.../llama-3-8b-q4_k_m.gguf",
        context_size: 8192,
        engine: :llama_server,
        usage: [:chat, :completion],
        model_args: ["--n-gpu-layers", "35"]
      }

      # 2. (Optional) download binary and model
      :ok = Candil.download_engine(engine)
      {:ok, _} = Candil.download_model(model)

      # 3. Start engine serving the model
      {:ok, _pid} = Candil.start_engine(engine, model)

      # 4. Run inference
      {:ok, response} = Candil.chat(:llama3, [
        %{role: "user", content: "Hello!"}
      ])

      # 5. Stop engine
      :ok = Candil.stop_engine(:llama3)

  # Lifecycle — remote model

      provider = %Candil.Provider{
        alias: :openai,
        type: :openai,
        base_url: "https://api.openai.com",
        api_key: System.get_env("OPENAI_API_KEY")
      }

      model = %Candil.Model{
        alias: :gpt4o,
        type: :remote,
        name: "gpt-4o",
        context_size: 128_000,
        provider: :openai,
        usage: [:chat, :completion, :embeddings]
      }

      {:ok, response} = Candil.chat(:gpt4o, provider, [
        %{role: "user", content: "Hello!"}
      ])
  #
  # The moduledoc above is preserved as a comment for reference. The public
  # API is now `Candil.*`; `Candil.Llm` is the internal implementation.

  alias Candil.{Config, Engine, Inference, Installer, Model, Provider, Stream}

  @doc """
  Downloads the appropriate precompiled llama.cpp binary for this engine.

  Detects the current OS, architecture and GPU automatically. Does nothing
  if `use_precompiled` is `false`.
  """
  @spec download_engine(Engine.t()) :: :ok | {:error, binary()}
  def download_engine(%Engine{use_precompiled: false}), do: :ok

  def download_engine(%Engine{} = engine) do
    Installer.download_engine(engine)
  end

  @doc """
  Downloads a local model file to `model.model_dir`.

  Does nothing if `model.type` is `:remote`.
  """
  @spec download_model(Model.t()) :: {:ok, binary()} | {:error, binary()}
  def download_model(%Model{type: :remote} = model), do: {:ok, model.alias |> to_string()}

  def download_model(%Model{} = model) do
    Installer.download_model(model)
  end

  @doc """
  Starts a local llama-server engine loaded with `model`.

  Returns `{:ok, pid}` where `pid` is the `Candil.Engine.Server` process.
  The server process is registered under the model alias in
  `Candil.Registry`.
  """
  @spec start_engine(Engine.t(), Model.t()) :: {:ok, pid()} | {:error, binary()}
  def start_engine(%Engine{} = engine, %Model{type: :local} = model) do
    Engine.start(engine, model)
  end

  # Convenience: start engine by alias + model alias
  def start_engine(engine_alias, model_alias)
      when is_atom(engine_alias) and is_atom(model_alias) do
    with {:ok, engine} <- Config.get_engine(engine_alias),
         {:ok, model} <- Config.get_model(model_alias) do
      Engine.start(engine, model)
    end
  end

  @doc """
  Stops a running engine identified by the model alias.
  """
  @spec stop_engine(atom()) :: :ok | {:error, :not_running}
  def stop_engine(model_alias) when is_atom(model_alias) do
    Engine.stop(model_alias)
  end

  @doc """
  Returns `true` if an engine serving the given model alias is running and
  responding to health checks.
  """
  @spec engine_healthy?(atom()) :: boolean()
  def engine_healthy?(model_alias) when is_atom(model_alias) do
    Engine.healthy?(model_alias)
  end

  @doc """
  Runs a chat completion against a **local** model (identified by alias).

  The engine must already be running via `start_engine/2`.

  ## Options

    * `:temperature` — sampling temperature (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `512`)
    * `:stop` — list of stop sequences

  """
  @spec chat(atom(), [Inference.message()], keyword()) ::
          {:ok, Inference.response()} | {:error, any()}
  def chat(model_alias, messages, opts \\ [])
      when is_atom(model_alias) and is_list(messages) do
    Inference.chat_local(model_alias, messages, opts)
  end

  @doc """
  Runs a chat completion against a **remote** model via a provider.

  ## Options

  Same as `chat/3`.
  """
  @spec chat(Model.t(), Provider.t(), [Inference.message()], keyword()) ::
          {:ok, Inference.response()} | {:error, any()}
  def chat(%Model{} = model, %Provider{} = provider, messages, opts)
      when is_list(messages) do
    Inference.chat_remote(model, provider, messages, opts)
  end

  @doc """
  Runs an embeddings request against a **local** model.

  The engine must be running and the model must have `:embeddings` in its
  `usage` list.
  """
  @spec embed(atom(), [binary()], keyword()) ::
          {:ok, [[float()]]} | {:error, any()}
  def embed(model_alias, texts, opts \\ [])
      when is_atom(model_alias) and is_list(texts) do
    Inference.embed_local(model_alias, texts, opts)
  end

  @doc """
  Runs an embeddings request against a **remote** model.
  """
  @spec embed(Model.t(), Provider.t(), [binary()], keyword()) ::
          {:ok, [[float()]]} | {:error, any()}
  def embed(%Model{} = model, %Provider{} = provider, texts, opts)
      when is_list(texts) do
    Inference.embed_remote(model, provider, texts, opts)
  end

  @doc """
  Streams a chat completion from a **local** engine.

  The engine must be running. Calls `callback` for each token chunk.
  """
  @spec stream(atom(), [Inference.message()], Stream.stream_callback(), keyword()) ::
          :ok | {:error, any()}
  def stream(model_alias, messages, callback, opts \\ [])
      when is_atom(model_alias) and is_function(callback, 1) do
    Stream.chat(model_alias, messages, callback, opts)
  end

  @doc """
  Streams a chat completion from a **remote** provider.
  """
  @spec stream(
          Model.t(),
          Provider.t(),
          [Inference.message()],
          Stream.stream_callback(),
          keyword()
        ) ::
          :ok | {:error, any()}
  def stream(%Model{} = model, %Provider{} = provider, messages, callback, opts)
      when is_function(callback, 1) do
    Stream.chat(model, provider, messages, callback, opts)
  end
end
