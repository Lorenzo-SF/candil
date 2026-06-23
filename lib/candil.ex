defmodule Candil do
  @moduledoc """
  Candil — LLM inference and model management for Elixir.

  Run local models via llama.cpp or remote models via OpenAI-compatible APIs.

  ## Quick start — local model

      engine = %Candil.Engine{alias: :llama_server, use_precompiled: true, host: "127.0.0.1", port: 8080}
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

      Candil.Config.register_engine(engine)
      Candil.Config.register_model(model)
      Candil.Config.register_provider(provider)
  """

  alias Candil.Llm

  defdelegate download_engine(engine), to: Llm
  defdelegate download_model(model), to: Llm
  defdelegate start_engine(engine, model), to: Llm
  defdelegate stop_engine(model_alias), to: Llm
  defdelegate engine_healthy?(model_alias), to: Llm
  defdelegate chat(model_alias, messages), to: Llm
  defdelegate chat(model_alias, messages, opts), to: Llm
  defdelegate chat(model, provider, messages, opts), to: Llm
  defdelegate embed(model_alias, texts), to: Llm
  defdelegate embed(model_alias, texts, opts), to: Llm
  defdelegate embed(model, provider, texts, opts), to: Llm
  defdelegate stream(model_alias, messages, callback), to: Llm
  defdelegate stream(model_alias, messages, callback, opts), to: Llm
  defdelegate stream(model, provider, messages, callback, opts), to: Llm
end
