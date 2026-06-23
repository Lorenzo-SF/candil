# `Candil.Llm` — Internal implementation (preserved documentation)

> **Note:** `Candil.Llm` is the internal implementation of the LLM management
> layer. The public API is exposed through the `Candil` facade. This document
> preserves the original moduledoc for reference; consult `Candil` for the
> current public API.

## Concepts

### Engine

An engine is a local `llama-server` binary that serves one model at a time
over an OpenAI-compatible HTTP API. You can use a pre-existing binary on the
machine or let Apero download the official precompiled release from the
[llama.cpp releases page](https://github.com/ggml-org/llama.cpp/releases).

### Provider

A provider is a remote HTTP API (OpenAI, Anthropic, Ollama, or any
OpenAI-compatible endpoint). Ollama is treated as a remote provider because
it manages its own process and model storage independently.

### Model

A model is either:

- **Local** — a `.gguf` file on disk, associated with an engine.
- **Remote** — a model name / ID offered by a provider.

## Lifecycle — local model

```elixir
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
```

## Lifecycle — remote model

```elixir
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
```
