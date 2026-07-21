# Candil

LLM inference and model management for Elixir. Run local models via llama.cpp or remote models via OpenAI-compatible APIs.

## Installation

```elixir
def deps do
  [
    {:candil, "~> 2.1"}
  ]
end
```

## Dependencies

Candil requires:
- `:apero` - HTTP transport, retry, and system utilities
- `:arrea` - Circuit breakers and long-running process supervision
- `:trebejo` - OS and architecture detection
- `:jason` - JSON encoding/decoding

## Configuration

### Engines

An engine represents a local `llama-server` binary that serves one model at a time.

```elixir
# Precompiled binary (auto-downloaded)
engine = %Candil.Engine{
  alias: :llama_server,
  use_precompiled: true,
  precompiled_version: :latest,
  host: "127.0.0.1",
  port: 8080,
  start_args: ["--n-gpu-layers", "35"]
}

# Custom binary path
engine = %Candil.Engine{
  alias: :llama_server,
  binary_dir: "/usr/local/bin",
  use_precompiled: false,
  host: "127.0.0.1",
  port: 8080
}

Candil.Config.register_engine(engine)
```

### Models

#### Local Model

```elixir
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

Candil.Config.register_model(model)
```

#### Remote Model

```elixir
model = %Candil.Model{
  alias: :gpt4o,
  type: :remote,
  name: "gpt-4o",
  context_size: 128_000,
  provider: :openai,
  usage: [:chat, :completion, :embeddings]
}

Candil.Config.register_model(model)
```

### Providers

#### OpenAI

```elixir
provider = %Candil.Provider{
  alias: :openai,
  type: :openai,
  base_url: "https://api.openai.com",
  api_key: System.get_env("OPENAI_API_KEY")
}

Candil.Config.register_provider(provider)
```

#### Anthropic

```elixir
provider = %Candil.Provider{
  alias: :anthropic,
  type: :anthropic,
  base_url: "https://api.anthropic.com",
  api_key: System.get_env("ANTHROPIC_API_KEY")
}

Candil.Config.register_provider(provider)
```

#### Ollama

```elixir
provider = %Candil.Provider{
  alias: :ollama,
  type: :ollama,
  base_url: "http://localhost:11434"
}

Candil.Config.register_provider(provider)
```

#### OpenAI-Compatible (Groq, LM Studio, etc.)

```elixir
provider = %Candil.Provider{
  alias: :groq,
  type: :openai_compatible,
  base_url: "https://api.groq.com/openai",
  api_key: System.get_env("GROQ_API_KEY")
}

Candil.Config.register_provider(provider)
```

## Usage

### Local Model (llama.cpp)

```elixir
# Download binary (automatic if use_precompiled: true)
:ok = Candil.download_engine(engine)

# Download model
{:ok, _path} = Candil.download_model(model)

# Start engine
{:ok, pid} = Candil.start_engine(engine, model)

# Run inference
{:ok, response} = Candil.chat(:llama3, [
  %{role: "user", content: "Hello!"}
])

IO.puts(response.content)

# Stop when done
:ok = Candil.stop_engine(:llama3)
```

### Remote Model (OpenAI)

```elixir
# Run inference directly
{:ok, response} = Candil.chat(model, provider, [
  %{role: "user", content: "Hello!"}
], [])

IO.puts(response.content)
```

### Streaming Responses

```elixir
# Local streaming
Candil.stream(:llama3, [
  %{role: "user", content: "Write a story"}
], fn chunk ->
  IO.write(chunk.content)
end)

# Remote streaming
Candil.stream(model, provider, [
  %{role: "user", content: "Write a story"}
], fn chunk ->
  IO.write(chunk.content)
end, [])
```

### Embeddings

```elixir
# Local embeddings (engine must be running and model must support :embeddings)
{:ok, embeddings} = Candil.embed(:llama3, ["Hello world", "How are you?"])

# Remote embeddings
{:ok, embeddings} = Candil.embed(model, provider, ["Hello world", "How are you?"], [])
```

### Conversation Management

```elixir
conv = Candil.Conversation.new(
  model: :llama3,
  system: "You are a helpful assistant.",
  max_context_tokens: 4096
)

{:ok, conv, response} = Candil.Conversation.chat(conv, "What is Elixir?")
IO.puts(response.content)

{:ok, conv, response} = Candil.Conversation.chat(conv, "Give me a code example.")
IO.puts(response.content)
```

## Architecture

- **Candil.Llm** - Main entry point for all LLM operations
- **Candil.Engine** - Manages local llama-server processes
- **Candil.Engine.Server** - GenServer wrapping the llama-server OS process
- **Candil.EnginePool** - LRU tracking for active engines
- **Candil.Inference** - Handles chat completions and embeddings
- **Candil.HTTP** - Shared HTTP client with retries, circuit breaking, and rate limiting
- **Candil.Stream** - SSE streaming support
- **Candil.Provider** - Remote API provider abstraction (OpenAI, Anthropic, Ollama)
- **Candil.Model** - Model definitions (local or remote)
- **Candil.Config** - ETS-based registry for engines, models, and providers
- **Candil.ConfigManager** - Config validation and normalization for ad-hoc provider connections
- **Candil.Error** - Unified inference and transport errors
- **Candil.Cost** - Token cost estimation for known models
- **Candil.Health** - Health probes (ping, latency, model availability) for LLM providers
- **Candil.Embeddings** - Embedding generation across ollama, local, and OpenAI-compatible APIs
- **Candil.Detector** - OS/GPU detection for binary selection
- **Candil.Installer** - Download and extraction utilities
- **Candil.Conversation** - Conversation history with context window management
- **Candil.RequestBuilder** - Request body builders for all provider APIs

---

## Project history

This library was developed as part of a larger internal toolkit and extracted
to open source in mid-2026. The canonical releases are `1.0.0` and `2.0.0`;
the codebase is currently in the `2.1.0` development cycle.

## License

MIT
