defmodule Candil do
  @moduledoc """
  Candil — LLM inference and model management for Elixir.

  Run local models via llama.cpp or remote models via OpenAI-compatible APIs.

  ## Quick start — local model

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
  Runs a chat completion against a **local** model (identified by alias).

  The engine must already be running via `start_engine/2`.

  ## Options

    * `:temperature` — sampling temperature (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `512`)
    * `:stop` — list of stop sequences

  """
  defdelegate chat(model_alias, messages), to: Llm

  @doc """
  Runs a chat completion against a **local** model (identified by alias).

  The engine must already be running via `start_engine/2`.

  ## Options

    * `:temperature` — sampling temperature (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `512`)
    * `:stop` — list of stop sequences

  """
  defdelegate chat(model_alias, messages, opts), to: Llm

  @doc """
  Runs a chat completion against a **local** model (identified by alias).

  The engine must already be running via `start_engine/2`.

  ## Options

    * `:temperature` — sampling temperature (default: `0.7`)
    * `:max_tokens` — maximum tokens to generate (default: `512`)
    * `:stop` — list of stop sequences

  """
  defdelegate chat(model, provider, messages, opts), to: Llm

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
