# Candil

Inferencia de LLMs y gestión de modelos para Elixir. Ejecuta modelos locales
vía llama.cpp o modelos remotos vía APIs compatibles con OpenAI.

## Instalación

```elixir
def deps do
  [
    {:candil, "~> 0.2"}
  ]
end
```

## Dependencias

Candil requiere:
- `:apero` — Utilidades de sistema (incluido vía path en dev)
- `:arrea` — Ejecución paralela (incluido vía path en dev)
- `:jason` — Codificación/decodificación JSON
- `:req` — Cliente HTTP

## Configuración

### Engines

Un engine representa un binario local `llama-server` que sirve un modelo a la vez.

```elixir
# Binario precompilado (auto-descargado)
engine = %Candil.Engine{
  alias: :llama_server,
  use_precompiled: true,
  precompiled_version: :latest,
  host: "127.0.0.1",
  port: 8080,
  start_args: ["--n-gpu-layers", "35"]
}

# Ruta de binario personalizada
engine = %Candil.Engine{
  alias: :llama_server,
  binary_dir: "/usr/local/bin",
  use_precompiled: false,
  host: "127.0.0.1",
  port: 8080
}

Candil.Config.register_engine(engine)
```

### Modelos

#### Modelo local

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

#### Modelo remoto

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
  base_url: "https://api.openai.com/v1",
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

#### Compatible con OpenAI (Groq, LM Studio, etc.)

```elixir
provider = %Candil.Provider{
  alias: :groq,
  type: :openai_compatible,
  base_url: "https://api.groq.com/openai",
  api_key: System.get_env("GROQ_API_KEY")
}

Candil.Config.register_provider(provider)
```

## Uso

### Modelo local (llama.cpp)

```elixir
# Descargar binario (automático si use_precompiled: true)
:ok = Candil.download_engine(engine)

# Descargar modelo
{:ok, _path} = Candil.download_model(model)

# Arrancar engine
{:ok, pid} = Candil.start_engine(engine, model)

# Ejecutar inferencia
{:ok, response} = Candil.chat(:llama3, [
  %{role: "user", content: "¡Hola!"}
])

IO.puts(response.content)

# Detener cuando termines
:ok = Candil.stop_engine(:llama3)
```

### Modelo remoto (OpenAI)

```elixir
# Inferencia directa
{:ok, response} = Candil.chat(model, provider, [
  %{role: "user", content: "¡Hola!"}
])

IO.puts(response.content)
```

### Respuestas en streaming

```elixir
# Streaming local
Candil.stream(:llama3, [
  %{role: "user", content: "Escribe un cuento"}
], fn chunk ->
  IO.write(chunk.content)
end)

# Streaming remoto
Candil.stream(model, provider, [
  %{role: "user", content: "Escribe un cuento"}
], fn chunk ->
  IO.write(chunk.content)
end)
```

### Embeddings

```elixir
# Embeddings locales (el engine debe estar corriendo y el modelo debe soportar :embeddings)
{:ok, embeddings} = Candil.embed(:llama3, ["Hola mundo", "¿Cómo estás?"])

# Embeddings remotos
{:ok, embeddings} = Candil.embed(model, provider, ["Hola mundo", "¿Cómo estás?"])
```

### Gestión de conversación

```elixir
conv = Candil.Conversation.new(
  model: :llama3,
  system: "Eres un asistente útil.",
  max_context_tokens: 4096
)

{:ok, conv, response} = Candil.Conversation.chat(conv, "¿Qué es Elixir?")
IO.puts(response.content)

{:ok, conv, response} = Candil.Conversation.chat(conv, "Dame un ejemplo de código.")
IO.puts(response.content)
```

## Arquitectura

- **Candil.Llm** — Punto de entrada principal para todas las operaciones LLM
- **Candil.Engine** — Gestiona procesos locales de llama-server
- **Candil.Engine.Server** — GenServer que envuelve el proceso OS de llama-server
- **Candil.Inference** — Maneja chat completions y embeddings
- **Candil.Stream** — Soporte de streaming SSE
- **Candil.Provider** — Abstracción de provider remoto (OpenAI, Anthropic, Ollama)
- **Candil.Model** — Definiciones de modelos (local o remoto)
- **Candil.Config** — Registro ETS para engines, modelos y providers
- **Candil.Detector** — Detección de OS/GPU para selección de binario
- **Candil.Installer** — Utilidades de descarga y extracción
- **Candil.Conversation** — Historial de conversación con gestión de context window
- **Candil.RequestBuilder** — Constructores de request body para todas las APIs

## Licencia

MIT