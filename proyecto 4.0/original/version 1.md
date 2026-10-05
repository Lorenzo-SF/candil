# Candil 4.0 — Diseño, migración y plan de ejecución

**Fecha**: 2026-09-30
**Estado**: decidido, no empezado
**Decide**: Lorenzo · **Ejecuta**: por asignar
**Destino del documento**: `~/workspace/github/lasaca/PENDIENTE/principal/candil-4.md`

---

## 0. Resumen ejecutivo

Candil 3.0.0 es una **base sólida con tres bugs y una capa de producto sin construir**.
Tiene 5.923 LOC, 30 test files, y una arquitectura limpia (Engine / Backend / Provider /
Inference separados). Lo que falta no es reescribirla, es **terminarla**: config en TOML,
CLI con Alaja, Router (de ElPaso), Gateway, Context compartido, MCP, RAG.

**La misión de Candil 4.0** es convertirse en la **librería IA de Elixir** del ecosistema
`lasaca`, absorbiendo:

- **Ropero** (bash) — gestión de modelos y engines locales → se convierte en config TOML.
- **ElPaso** (Elixir) — router + gateway OpenAI-compatible → se convierte en
  `Candil.Router` + `Candil.Gateway`.

**El lema**: _Candil es el señor de los LLM_. Todo lo que huela a inferencia, embeddings,
modelos, routing, MCP, RAG — vive aquí. Los demás proyectos (`posadero`, `opencode`,
`arriero` antes de morir) **consumen** Candil, no lo reimplementan.

---

## 1. Las cinco librerías del ecosistema y su rol

| Librería    | Rol                                                            | LOC        | Estado                                     |
| ----------- | -------------------------------------------------------------- | ---------- | ------------------------------------------ |
| **candil**  | LLM: engines, modelos, inferencia, router, gateway, MCP, RAG   | 5.923      | Base sólida, 3 bugs, capa producto ausente |
| **alaja**   | CLI framework (DSL declarativo) + rendering kit ANSI           | 24.506     | Hex 3.1.2, maduro                          |
| **arrea**   | Orquestación: circuit breakers, workers, supervisión, intercom | (no vista) | Integrada en Candil.Engine.Server          |
| **apero**   | Utilidades: HTTP transport, OS, system                         | (no vista) | Integrada en Candil                        |
| **trebejo** | Wrappers shell/OS                                              | (no vista) | Usada por Candil.Detector (opcional)       |
| **pote**    | Themes (colores, fonts, spacing, JSON)                         | (no vista) | Dep de Alaja                               |
| **botica**  | Doctor: health checks + fix                                    | 33 módulos | Dep de Posadero                            |

**Filosofía de las 5**:

- `apero` + `trebejo` + `arrea` = base infra (HTTP, OS, procesos, supervisión).
- `candil` = producto IA (usa las 3 anteriores).
- `alaja` = presentación (CLI + rendering; usa pote).
- `botica` = diagnóstico (usa apero + arrea).

**No hay solapamiento.** Cada una tiene su dominio. La regla dura: **candil no reimplementa
lo que ya está en apero/trebejo/arrea, y alaja no sabe nada de LLMs.**

---

## 2. Estado actual de Candil 3.0.0

### 2.1 Lo que tiene (y funciona)

**Ciclo de vida de engines** (llama-server):

- `Candil.Engine` — struct + `start/stop/healthy?/base_url`
- `Candil.Engine.Server` — GenServer que envuelve el OS process vía `Arrea.LongRunning`
- `Candil.Engine.Launcher` — **behaviour** para motores externos (vLLM, TGI, systemd) — no los arranca Candil, solo habla con ellos
- `Candil.Engine.HealthPoller` — /health cada 5s
- `Candil.EnginePool` — LRU de engines (pero ver §2.2.7)
- `Candil.Detector` + `Candil.Detector.GPU` + `Candil.Detector.Models` + `Candil.Detector.Release` — detección de OS/arch/GPU
- `Candil.Installer` — descarga binarios + verifica SHA256 + streaming a disco

**Modelos y providers**:

- `Candil.Model` — struct (`:local` o `:remote`)
- `Candil.Provider` — struct (openai/anthropic/ollama/openai_compatible/azure_openai)
- `Candil.Config` — ETS registry de engines/models/providers

**Backends**:

- `Candil.Backend` — behaviour con `chat/chat_stream/embed/models`
- `Candil.Backend.LlamaCpp` — ⚠️ **stub** (ver §2.2.1)
- `Candil.Backend.OpenAICompat` — ⚠️ **dos métodos stub** (ver §2.2.2, §2.2.3)

**Inferencia**:

- `Candil.Inference` — API pública (chat_local, chat_remote, embed_local, embed_remote)
- `Candil.Inference.Chat` — **la implementación real** (parse de OpenAI, Anthropic, Ollama)
- `Candil.Inference.Embeddings`
- `Candil.RequestBuilder` — bodies para cada API
- `Candil.Stream` — SSE
- `Candil.HTTP` + `Candil.HTTP.Client` + `Candil.HTTP.Retry`

**Conversación**:

- `Candil.Conversation` + `Candil.Conversation.Context` + `Candil.Conversation.TokenEstimator`

**Tools y agentes**:

- `Candil.Tool` — struct + macro `use Candil.Tool` (define name/description/schema/function)
- `Candil.Tools` — `schemas_to_prompt/1`, `parse_tool_calls/1` (soporta OpenAI **y** llama.cpp `<|tool_call|>`)
- `Candil.Agent` — loop ReAct mínimo con tools ⚠️ **usa el stub del backend** (ver §2.2.1)
- `Candil.Structured` — output JSON con schema + retry ⚠️ **usa el stub del backend**

**Runtime**:

- `Candil.Telemetry` — eventos
- `Candil.Cancellation` — cancelación cooperativa
- `Candil.RateLimiter`
- `Candil.Cost` — estimación de costes
- `Candil.Health` — probes
- `Candil.Error` — errores unificados

**App**:

- `Candil.Application` — supervisor tree

### 2.2 Los tres bugs (bloquean todo lo demás)

#### 2.2.1 `Backend.LlamaCpp.chat/3` es un stub

```elixir
# lib/candil/backend/llama_cpp.ex (actual)
@impl true
def chat(_model, _messages, _opts) do
  {:error, %Candil.Error{reason: :backend_unavailable}}
end
```

**Por qué importa**: `Candil.Agent.run/3` y `Candil.Structured.complete/4` llaman a
`backend.chat/3`. Con este stub, **el agente y el structured nunca funcionan**, aunque
todo lo demás esté bien.

**El código real ya existe** en `Candil.Inference.Chat.do_chat_local/3`. La solución es
que `LlamaCpp.chat/3` delegue:

```elixir
@impl true
def chat(model, messages, opts) do
  alias Candil.Inference.Chat
  alias Candil.Config

  model_alias = case model do
    %Candil.Model{alias: a} -> a
    a when is_atom(a) -> a
    a when is_binary(a) -> String.to_existing_atom(a)
  end

  with {:ok, _model} <- Config.get_model(model_alias) do
    Chat.do_chat_local(model_alias, messages, opts)
  end
end
```

#### 2.2.2 `Backend.OpenAICompat.chat_stream/3` es un stub

```elixir
# lib/candil/backend/openai_compat.ex (actual)
defp build_chunk_stream(_body) do
  # The actual streaming happens via HTTP.post_streaming + SSE parser
  # in Candil.Stream. This stub returns an empty stream
  Stream.repeatedly(fn ->
    Process.sleep(50)
    %{content: "", finish_reason: nil, done: true}
  end)
  |> Stream.take(1)
end
```

**Por qué importa**: un stream vacío es **peor que no soportar streaming**, porque el
llamador cree que funciona.

**La solución**: `Candil.Stream` ya tiene el SSE parser. `chat_stream/3` debe usarlo y
devolver un `Enumerable.t()` real. La firma del callback debe ser
`fn chunk -> :cont | :halt end`.

#### 2.2.3 `Backend.OpenAICompat.embed/3` no es batch

```elixir
# actual
def embed(model, texts, opts) do
  results = Enum.map(texts, fn text ->
    # ... hace una request por texto
  end)
  # ...
end
```

**Por qué importa**: la doc dice `embed/3` con lista, pero internamente hace N round-trips.
Para 100 textos son 100 requests. La API de OpenAI acepta `input: [t1, t2, ...]` en una
sola request.

**La solución**: reemplazar `Enum.map` por una sola request con `input: texts` (los
proveedores OpenAI-compat lo soportan). Excepción: Ollama (que usa `/api/embed` con
`input` de un solo elemento o lista, depende de versión).

#### 2.2.4 `Config.register_provider/1` exige `{:system, "ENV_VAR"}` para api_key

El README muestra strings planos:

```elixir
provider = %Candil.Provider{
  alias: :openai,
  api_key: System.get_env("OPENAI_API_KEY")  # string
}
Candil.Config.register_provider(provider)  # ← raise ArgumentError
```

Pero el código exige:

```elixir
defp validate_api_key({:system, var}) when is_binary(var), do: :ok
defp validate_api_key(_), do: {:error, "api_key must be {:system, ...} tuple or nil"}
```

**Solución**: aceptar ambos. Un string plano se envuelve en `{:literal, string}` internamente
y se resuelve en `get_provider/1` sin más.

#### 2.2.5 `Candil.Detector` usa `Trebejo.OS.arch/0` con `apply/3` defensivo

```elixir
defp safe_arch do
  if Code.ensure_loaded?(Trebejo.OS) and function_exported?(Trebejo.OS, :arch, 0) do
    apply(Trebejo.OS, :arch, [])
  else
    :unknown
  end
end
```

**Por qué importa**: si `trebejo` no está instalado, `:unknown` y la descarga del binario
falla sin decir por qué. Además, `trebejo` no está declarado como dep en `mix.exs`.

**Solución**: `trebejo` como dep **opcional** (`optional: true, runtime: false`), y si no
está, **fallar con mensaje claro** en `download_engine/1` ("trebejo no disponible, no puedo
detectar arquitectura"). No fallar silenciosamente a `:unknown`.

#### 2.2.6 `Candil.Engine.Server` hardcodea puerto

`build_args/2` construye siempre `--port #{engine.port}`. `Engine.port` es del struct
(8080 por defecto). No hay estrategia de asignación.

**Solución**: dos modos.

- **Modo estructurado** (default): `Engine.port` fijo. Para engines externos o tests.
- **Modo pool** (nuevo): si `Engine.port` es `:auto`, Candil asigna puerto libre del rango
  `[base_port, base_port + 99]`. Lo pide al `EnginePool`.

#### 2.2.7 `EnginePool` es LRU de 1

```elixir
def handle_call(:get, _from, state) do
  {least, rest} = List.pop_at(state, -1)
  new_state = [least | rest]
  {:reply, least, new_state}
end
```

Es un LRU de **N**, pero el nombre "pool" sugiere N concurrentes. Hoy `EnginePool.put/1`
guarda el engine y `EnginePool.evict/0` lo saca. **Pero nadie llama `evict`**. Solo hay
un engine a la vez por puerto.

**Solución**: `EnginePool` deja de ser LRU y pasa a ser **registro de engines vivos**.
Con N puertos distintos, N engines conviven. El router decide cuál usar. Esto es lo que
hoy hace `ropero` (dos slots :9998 y :9999) pero **generalizado a N**.

#### 2.2.8 `mix test` no corre (deps sin descargar)

El snapshot muestra:

```
Unchecked dependencies for environment test:
* jason (Hex package) — run "mix deps.get"
* mox (Hex package) — run "mix deps.get"
* apero (github) — run "mix deps.get"
* arrea (github) — run "mix deps.get"
...
```

**Solución**: `mix deps.get && mix test` y ver qué falla de verdad. Necesario antes de
tocar nada.

---

## 3. Decisiones tomadas (C1-C7)

| #              | Decisión                                                                 | Razón                                                                           |
| -------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| **C1**         | Alaja como **dep Git apuntando a `main`**                                | Hex no siempre está al día; queremos la última                                  |
| **C2**         | **ETS por defecto**, Postgres opcional                                   | Menos complejidad operativa; Postgres implica docker o instalación local        |
| **C3**         | **Solo CLI + Gateway + MCP**; sin web propia                             | La web es de Posadero. Candil es librería + gateway                             |
| **C4**         | El **Gateway OpenAI-compatible vive en Candil**                          | Candil es "el señor de los LLM"; Posadero y opencode lo consumen                |
| **C5**         | `arrea`, `apero`, `trebejo`, `botica` como deps                          | Ya disponibles; se usan donde aportan                                           |
| **C6**         | Repo Ecto **opcional**                                                   | Solo si se activa Postgres                                                      |
| **C7**         | **Un solo `mix.exs`**                                                    | Todo dentro, sin submódulos                                                     |
| **C8 (nuevo)** | **Consumidores etiquetados** (`consumer: :posadero \| :opencode \| ...`) | Posadero y opencode pueden usar Candil a la vez sin mezclar contextos; ver §4.7 |
| **C9 (nuevo)** | **Puertos múltiples** con `Engine.port = :auto \| integer`               | Generaliza el modelo de ropero (dos slots) a N slots                            |

---

## 4. Arquitectura de Candil 4.0

### 4.1 Visión general

```
┌──────────────────────────────────────────────────────────────────┐
│                         Consumidores                              │
│                                                                   │
│   posadero (daemon)     opencode (CLI)     cualquier app Elixir  │
│        │                       │                     │            │
│        └───────────────┬───────┴─────────────────────┘            │
│                        │                                          │
│                        ▼                                          │
│            ┌───────────────────────┐                              │
│            │   Candil (librería)   │                              │
│            │                       │                              │
│            │  Router ──► Engine    │                              │
│            │  Gateway (HTTP)       │                              │
│            │  MCP (stdio + HTTP)   │                              │
│            │  RAG                  │                              │
│            │  Context (ETS)        │                              │
│            │  Tools / Agents       │                              │
│            └───────────┬───────────┘                              │
│                        │                                          │
│                        ▼                                          │
│            ┌───────────────────────┐                              │
│            │  Engines locales      │                              │
│            │  (llama-server × N)   │                              │
│            │  + providers remotos  │                              │
│            └───────────────────────┘                              │
└──────────────────────────────────────────────────────────────────┘
```

### 4.2 Estructura de directorios definitiva

```
lib/candil/
  # ─────────────────────────────────────────────────────────────
  # CAPA 1: lo que ya existe (se queda, se arregla)
  # ─────────────────────────────────────────────────────────────
  application.ex
  error.ex

  engine/                     # ciclo de vida (con Launcher, HealthPoller, Server)
  engine/server.ex
  engine/launcher.ex
  engine/health_poller.ex
  engine/server/external.ex
  engine_pool.ex              # ⚠️ cambiar de LRU a registro de N

  backend.ex                  # behaviour
  backend/llama_cpp.ex        # ⚠️ arreglar chat/3
  backend/openai_compat.ex    # ⚠️ arreglar chat_stream/3, embed/3

  inference.ex
  inference/chat.ex
  inference/embeddings.ex

  request_builder.ex
  stream.ex
  http.ex
  http/client.ex
  http/retry.ex

  conversation.ex
  conversation/context.ex
  conversation/token_estimator.ex

  tool.ex
  tools.ex
  agent.ex                    # ⚠️ arreglar (usa backend roto)
  structured.ex               # ⚠️ arreglar (usa backend roto)

  detector.ex
  detector/gpu.ex
  detector/models.ex
  detector/release.ex
  installer.ex                # ⚠️ arreglar (fallar fuerte si trebejo ausente)

  model.ex
  provider.ex
  config.ex                   # ⚠️ pasa a ser cache de config/file.ex

  cost.ex
  health.ex
  telemetry.ex
  cancellation.ex
  rate_limiter.ex

  # ─────────────────────────────────────────────────────────────
  # CAPA 2: lo nuevo
  # ─────────────────────────────────────────────────────────────

  # Config TOML
  config/
    file.ex                   # ⭐ load/save/validate TOML
    schema.ex                 # ⭐ NimbleOptions con campos de Engine/Model/Provider
    migrate.ex                # ⭐ lee ropero.d/*.sh → TOML

  # CLI con Alaja
  cli.ex                      # ⭐ use Alaja.CLI.Definition
  cli/commands/
    models.ex                 # list | pull | info | rm
    run.ex                    # arrancar modelo
    stop.ex                   # parar modelo
    status.ex                 # estado de engines
    config.ex                 # show | edit | validate | migrate
    router.ex                 # stats | test | tune
    gateway.ex                # start | stop | status
    mcp.ex                    # serve | call
    rag.ex                    # index | query | list

  # Router (de ElPaso)
  router/
    router.ex                 # ⭐ punto de entrada
    decision_engine.ex        # ⭐ orquesta las estrategias
    cache.ex                  # ⭐ decision_cache
    embedding_matcher.ex      # ⭐ clasificación por embedding
    llm_classifier.ex         # ⭐ clasificación por LLM
    scorer.ex                 # ⭐ score multi-señal
    task_categories.ex        # ⭐ code / reasoning / fast / embed
    analyzer.ex               # ⭐ router_analyzer
    auto_tuner.ex             # ⭐ ajuste periódico
    policy.ex                 # ⭐ swap policy (local vs remoto)

  # Gateway OpenAI-compatible (de ElPaso)
  gateway/
    endpoint.ex               # ⭐ Plug/Bandit
    router.ex                 # ⭐ Plug.Router
    handlers/
      chat_completions.ex     # ⭐ POST /v1/chat/completions
      messages.ex             # ⭐ POST /v1/messages (Anthropic)
      embeddings.ex           # ⭐ POST /v1/embeddings
      models.ex               # ⭐ GET /v1/models
      health.ex               # ⭐ GET /health
      metrics.ex              # ⭐ GET /metrics (Prometheus text)
    auth.ex                   # ⭐ API key + JWT
    normalizer.ex             # ⭐ normaliza request de distintos formatos

  # Context compartido (ETS + opcional Postgres)
  context/
    store.ex                  # ⭐ GenServer + ETS (default)
    session.ex                # ⭐ ciclo de vida de una sesión
    session_supervisor.ex     # ⭐ DynamicSupervisor
    builder.ex                # ⭐ construye contexto para el LLM
    summarizer.ex             # ⭐ resumen de conversación larga
    prefix_manager.ex         # ⭐ cache de prefijos (system prompts)
    token_counter.ex          # (ya existe en conversation/)

  # MCP
  mcp/
    protocol.ex               # ⭐ JSON-RPC 2.0 sobre stdlib
    client.ex                 # ⭐ conectar a servers MCP externos
    server.ex                 # ⭐ exponer tools de Candil
    transport/
      stdio.ex                # ⭐ shim stdio
      http.ex                 # ⭐ cliente HTTP

  # RAG
  rag/
    chunker.ex                # ⭐ divide texto en chunks
    index.ex                  # ⭐ in-memory (default) + pgvector (opcional)
    retrieval.ex              # ⭐ hybrid BM25 + vector + RRF
    rerank.ex                 # ⭐ opcional
    embedder.ex               # ⭐ wrapper de inference/embeddings.ex
```

### 4.3 Las seis capas de Candil

| Capa             | Módulos                                                           | Rol                                 |
| ---------------- | ----------------------------------------------------------------- | ----------------------------------- |
| **Base**         | `engine`, `installer`, `detector`, `http`                         | Hablar con motores (procesos, HTTP) |
| **Modelo**       | `model`, `provider`, `config`, `config/file`, `config/schema`     | Definir qué existe                  |
| **Inferencia**   | `inference`, `backend`, `request_builder`, `stream`, `structured` | Ejecutar chat/embed/stream          |
| **Inteligencia** | `router`, `context`, `agent`, `tool`, `tools`                     | Decidir y recordar                  |
| **Consumo**      | `gateway`, `mcp`, `cli`                                           | Exponer a consumidores              |
| **Conocimiento** | `rag`                                                             | Construir y consultar índices       |

### 4.4 La regla de una sola dirección

Las capas superiores pueden llamar a las inferiores. **Nunca al revés.**

```
rag ─────┐
         │
gateway ─┼─► router ─► context ─► inference ─► backend ─► engine ─► llama-server
         │                                                            ▲
mcp ─────┤                                                            │
         │                                                         (HTTP)
cli ─────┘
```

- `rag` **no** sabe que existe un gateway.
- `router` **no** sabe que existe MCP.
- `inference` **no** sabe que existe RAG.

Cada módulo hace una cosa. La comunicación entre ellos es por funciones puras o por
GenServer + mensajes (nunca por estado global compartido fuera de `Config` y `Context`).

### 4.5 El sistema de config TOML

**Ubicación**: `~/.config/candil/candil.toml` (override con `CANDIL_CONFIG`).

**Formato**:

```toml
# ~/.config/candil/candil.toml

# Ruta base de binarios y modelos
[candil]
binary_dir = "~/.candil/llm/bin"
model_dir = "~/.candil/models"
log_dir = "~/.candil/logs"
consumer = "default"           # consumer por defecto si no se especifica

# ─── ENGINES ────────────────────────────────────────────────
[engine.llama_server]
binary_dir = "~/.candil/llm/bin"
use_precompiled = true
precompiled_version = "latest"
host = "127.0.0.1"

[engine.external_vllm]
# No lo arranca Candil; ya está corriendo
launcher = "Candil.Engine.Launcher.Noop"
base_url = "http://192.168.1.10:8000"

# ─── MODELOS LOCALES ────────────────────────────────────────
[model.coder]
type = "local"
engine = "llama_server"
model_dir = "~/.candil/models/devstral"
filename = "Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf"
download_url = "https://huggingface.co/..."
checksum_sha256 = "abc123..."
context_size = 131072
port = 9999
usage = ["chat", "code"]
model_args = [
  "--n-gpu-layers", "999",
  "--cache-type-k", "q4_0",
  "--cache-type-v", "q4_0",
  "--jinja",
  "--temp", "0.7"
]

[model.verifier]
type = "local"
engine = "llama_server"
model_dir = "~/.candil/models/gpt-oss"
filename = "openai_gpt-oss-20b-MXFP4.gguf"
context_size = 131072
port = 9998
usage = ["chat", "reasoning"]
model_args = [
  "--n-gpu-layers", "0",
  "--chat-template-kwargs", "{\"reasoning_effort\":\"high\"}"
]

# ─── PROVEEDORES REMOTOS ────────────────────────────────────
[provider.openai]
type = "openai"
base_url = "https://api.openai.com"
api_key = { env = "OPENAI_API_KEY" }

[provider.anthropic]
type = "anthropic"
base_url = "https://api.anthropic.com"
api_key = { env = "ANTHROPIC_API_KEY" }

[provider.ollama]
type = "ollama"
base_url = "http://localhost:11434"

# ─── MODELOS REMOTOS ────────────────────────────────────────
[model.gpt4o]
type = "remote"
name = "gpt-4o"
provider = "openai"
context_size = 128000
usage = ["chat", "completion", "embeddings"]

[model.claude_sonnet]
type = "remote"
name = "claude-3-5-sonnet-latest"
provider = "anthropic"
context_size = 200000
usage = ["chat", "reasoning"]

# ─── ROUTER ─────────────────────────────────────────────────
[router]
enabled = true
default_strategy = "auto"   # auto | first_match | cheapest | fastest

# Reglas simples: si task contiene estas palabras, va a este modelo.
[router.rules.code]
match = ["code", "function", "refactor", "bug", "compile"]
model = "coder"

[router.rules.reasoning]
match = ["reason", "explain", "why", "analyze"]
model = "verifier"

[router.rules.fast]
match = ["quick", "short", "summarize"]
model = "gpt4o"

# ─── CONTEXT ────────────────────────────────────────────────
[context]
enabled = true
max_sessions = 1000            # LRU de sesiones
session_ttl_seconds = 86400    # 24h
summarize_after_messages = 50
summarize_after_tokens = 8000

# ─── GATEWAY ────────────────────────────────────────────────
[gateway]
enabled = false                # arrancarlo con `candil gateway start`
host = "127.0.0.1"
port = 9999                    # ⚠️ comparte con engines; ver §4.8
auth = "api_key"               # api_key | jwt | none

# ─── MCP ────────────────────────────────────────────────────
[mcp]
enabled = false
transport = "stdio"            # stdio | http
# si http:
# host = "127.0.0.1"
# port = 9997

# ─── RAG ────────────────────────────────────────────────────
[rag]
backend = "memory"             # memory | pgvector
# si pgvector:
# postgres_url = "postgres://..."
embedding_model = "jina_code"  # alias de un modelo con usage: ["embeddings"]
chunk_size = 512
chunk_overlap = 50

# ─── LOGGING / TELEMETRY ────────────────────────────────────
[log]
level = "info"
file = "~/.candil/logs/candil.log"

[telemetry]
enabled = true
```

**Carga**:

1. `Candil.Config.File.load/1` lee el TOML.
2. `Candil.Config.File.validate/1` valida con `Candil.Config.Schema`.
3. `Candil.Config` (ETS) se hidrata con los structs.

**Config legacy** (Elixir `config.exs`) sigue funcionando: si el TOML no existe, se cae
a `Application.get_env(:candil, Candil.Config, [])`.

**Migración desde ropero**:

```bash
mix candil.migrate --from-ropero ~/workspace/github/lasaca/ropero/ropero.d/
```

Lee cada `.sh`, extrae `MODEL_ALIAS`, `MODEL_GGUF`, `MODEL_CTX`, `MODEL_NGL`, etc., y
genera un TOML. Se corre **una sola vez**. Después se borra ropero.

### 4.6 Config vs ETS

- **`Candil.Config.File`** — fuente de verdad en disco (TOML).
- **`Candil.Config` (ETS)** — cache en memoria, hidratado al arrancar.
- **Escritura**: `Config.File.save/2` + reload → ETS.
- **Lectura**: siempre desde ETS (O(1)).

**Compatibilidad**: los tests que registran a mano (`Config.register_model/1` sobre un
struct en memoria) siguen funcionando. `Config.File` es **una fuente más**, no la única.

### 4.7 Consumidores etiquetados (C8)

**Problema**: Posadero y opencode pueden usar Candil a la vez. Si ambos comparten la misma
sesión de conversation, se mezclan.

**Solución**: `consumer` como parámetro.

```elixir
Candil.chat(:coder, messages, consumer: :posadero)
Candil.chat(:coder, messages, consumer: :opencode)
```

Efectos:

- **Context.Store** aísla por consumer. Dos sesiones separadas.
- **EnginePool** comparte engines (un modelo cargado sirve a los dos consumers).
- **Cost** agrega por consumer.
- **Metrics** etiqueta por consumer.

El consumer por defecto es `:default`, configurable en `[candil] consumer`.

### 4.8 El problema de los puertos

En ropero, los puertos eran fijos por convención: `:9999` GPU, `:9998` CPU. Funciona con
dos slots.

Con N modelos, esto se rompe. Dos estrategias:

**Estrategia A — puerto fijo por modelo**:

- Cada `%Model{}` declara `port`. El usuario asigna puertos.
- Ventaja: predecible, `curl` sabes dónde va.
- Desventaja: colisiones manuales.

**Estrategia B — puerto auto del pool**:

- `Model.port = :auto`. `EnginePool` asigna libre de `[9990..9999]`.
- Ventaja: no hay colisiones.
- Desventaja: no predecible.

**Recomendación**: **A por defecto, B cuando `port = :auto`**. En el TOML, `port = 9999`
es fijo, `port = "auto"` es auto.

**El gateway escucha en 9999 por defecto**. Si un modelo ocupa el 9999, hay colisión.
**Solución**: el gateway escucha en 9999 y los modelos a partir de 10000. Actualizar el
TOML de ejemplo.

### 4.9 Consumidor externo (OpenAI-compat)

Si el gateway está corriendo en `127.0.0.1:9999`, cualquier cliente OpenAI-compatible
(openai-python, curl, opencode) puede hablar con él:

```bash
curl -X POST http://127.0.0.1:9999/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer candil-xxx" \
  -d '{
    "model": "auto",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

El router decide qué modelo local/remoto responde. Si el modelo no está arrancado, el
router lo arranca (con `Engine.start/2`) antes de responder.

---

## 5. Plan por fases

**Total estimado**: 25-35 días de trabajo concentrado. Repartible en 8-10 semanas.

### Fase 0 — Saneamiento (1-2 días)

**Objetivo**: que Candil 3.0.1 funcione sin bugs conocidos. Sin añadir nada.

#### 0.1 — Baseline

```bash
cd ~/workspace/github/candil
mix deps.get
mix compile --warnings-as-errors
mix test
mix credo --strict
mix dialyzer
```

Guardar el output. **Es la línea base**.

Si algo no compila, arreglar **solo eso** antes de seguir.

#### 0.2 — Arreglar `Backend.LlamaCpp.chat/3`

`lib/candil/backend/llama_cpp.ex`:

```elixir
@impl true
def chat(model, messages, opts) do
  alias Candil.{Config, Inference.Chat}

  model_alias =
    case model do
      %Candil.Model{alias: a} -> a
      a when is_atom(a) -> a
      a when is_binary(a) -> String.to_existing_atom(a)
    end

  case Config.get_model(model_alias) do
    {:ok, _m} -> Chat.do_chat_local(model_alias, messages, opts)
    {:error, _} -> {:error, Candil.Error.model_not_found(model_alias)}
  end
end
```

Test: `test/candil/backend/llama_cpp_test.exs` debe tener un caso con un engine mockeado.

#### 0.3 — Arreglar `Backend.OpenAICompat.chat_stream/3`

El módulo `Candil.Stream` ya tiene el SSE parser. `chat_stream/3` debe:

1. Hacer la request con `HTTP.post_streaming/5`.
2. Devolver un `Enumerable.t()` que itere los chunks SSE parseados.
3. Respetar `:halt` del callback.

Firma esperada:

```elixir
{:ok, stream} = Backend.OpenAICompat.chat_stream(model, messages, stream: true)
Enum.each(stream, fn chunk ->
  IO.write(chunk.content)
end)
```

#### 0.4 — Arreglar `Backend.OpenAICompat.embed/3` (batch)

Una sola request con `input: texts`:

```elixir
def embed(model, texts, opts) do
  with {:ok, base_url, token} <- config_for(provider_of(model), opts) do
    url = "#{base_url}/v1/embeddings"
    body = %{model: model_id(model), input: texts, encoding_format: "float"}
    headers = auth_headers(token)

    case HTTP.post_json(url, body, headers, timeout_ms: ..., retry: ...) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, Enum.map(data, & &1["embedding"])}
      # ...
    end
  end
end
```

#### 0.5 — Arreglar `Config.register_provider/1` (aceptar strings)

```elixir
defp validate_api_key(nil), do: :ok
defp validate_api_key({:system, var}) when is_binary(var), do: :ok
defp validate_api_key(s) when is_binary(s), do: :ok
defp validate_api_key(_), do: {:error, "api_key must be string, {:system, VAR}, or nil"}
```

Y en `get_provider/1`:

```elixir
defp resolve_provider(%Provider{api_key: s} = p) when is_binary(s), do: p
defp resolve_provider(%Provider{api_key: {:system, var}} = p), do: %{p | api_key: System.get_env(var)}
defp resolve_provider(p), do: p
```

#### 0.6 — Arreglar `Detector` (trebejo opcional)

`mix.exs`:

```elixir
{:trebejo, github: "Lorenzo-SF/trebejo", optional: true, runtime: false}
```

Y en `detector.ex`, si `trebejo` no está, **no devolver `:unknown`**. Devolver un error
claro:

```elixir
defp safe_arch do
  if Code.ensure_loaded?(Trebejo.OS) and function_exported?(Trebejo.OS, :arch, 0) do
    apply(Trebejo.OS, :arch, [])
  else
    {:error, :trebejo_not_available}
  end
end
```

`detect/0` propaga el error en vez de devolver un mapa con `:unknown`.

#### 0.7 — Quitar `EnginePool` LRU

Reescribir `EnginePool` como registro de engines vivos:

```elixir
defmodule Candil.EnginePool do
  use GenServer

  # state: %{alias => %{engine: Engine.t(), pid: pid(), started_at: DateTime.t()}}

  def put(alias, pid, engine), do: GenServer.cast(__MODULE__, {:put, alias, pid, engine})
  def delete(alias), do: GenServer.cast(__MODULE__, {:delete, alias})
  def list, do: GenServer.call(__MODULE__, :list)
  def get(alias), do: GenServer.call(__MODULE__, {:get, alias})
  def count, do: GenServer.call(__MODULE__, :count)
end
```

Test: `EnginePool.put(:a, pid, engine)` → `EnginePool.list()` devuelve `[:a]`.
`EnginePool.delete(:a)` → `EnginePool.list()` devuelve `[]`.

#### 0.8 — Tag `candil-3.0.1`

Con los 6 bugs arreglados:

```bash
git add .
git commit -m "fix(candil): 6 bugs pre-4.0 (backend stubs, config, detector, pool)"
git tag candil-3.0.1
```

**Salida de la Fase 0**: Candil 3.0.1 con tests verdes, credo limpio, dialyzer limpio.
Los 3 stubs de backend arreglados. El pool deja de mentir.

---

### Fase 1 — Config TOML (2-3 días)

**Objetivo**: Candil lee `~/.config/candil/candil.toml`. `mix candil.migrate` convierte
los `.sh` de ropero.

#### 1.1 — Dependencias

`mix.exs`:

```elixir
{:toml, "~> 0.7"},
{:nimble_options, "~> 1.1"}
```

#### 1.2 — `Candil.Config.Schema`

`lib/candil/config/schema.ex` — NimbleOptions con los campos de Engine, Model, Provider,
Router, Context, Gateway, MCP, RAG, Log.

```elixir
defmodule Candil.Config.Schema do
  @moduledoc false

  @engine_schema [
    alias: [type: :atom, required: true],
    binary_dir: [type: :string],
    use_precompiled: [type: :boolean, default: true],
    precompiled_version: [type: {:or, [:atom, :string]}, default: :latest],
    host: [type: :string, default: "127.0.0.1"],
    port: [type: {:or, [:integer, :atom]}, default: 8080],
    start_args: [type: {:list, :string}, default: []],
    launcher: [type: :atom]
  ]

  @model_schema [
    alias: [type: :atom, required: true],
    type: [type: {:in, [:local, :remote]}, required: true],
    # ... resto
  ]

  @spec validate(keyword()) :: {:ok, map()} | {:error, term()}
  def validate(raw) do
    # valida cada sección
  end
end
```

#### 1.3 — `Candil.Config.File`

`lib/candil/config/file.ex`:

```elixir
defmodule Candil.Config.File do
  @moduledoc """
  Reads and writes `~/.config/candil/candil.toml`.
  """

  alias Candil.Config.Schema

  @default_path "~/.config/candil/candil.toml"

  @spec path() :: String.t()
  def path do
    System.get_env("CANDIL_CONFIG") || Path.expand(@default_path)
  end

  @spec load(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def load(file \\ nil) do
    file = file || path()
    case File.read(file) do
      {:ok, content} ->
        with {:ok, toml} <- Toml.decode(content),
             {:ok, validated} <- Schema.validate(toml) do
          {:ok, validated}
        end
      {:error, :enoent} -> {:ok, empty()}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  @spec save(map(), String.t() | nil) :: :ok | {:error, term()}
  def save(config, file \\ nil) do
    file = file || path()
    File.mkdir_p!(Path.dirname(file))
    content = Toml.encode(config)
    # escritura atómica (tmp + rename)
    tmp = file <> ".tmp"
    File.write!(tmp, content)
    File.rename!(tmp, file)
    :ok
  end

  defp empty, do: %{candil: %{}, engines: [], models: [], providers: []}
end
```

#### 1.4 — `Candil.Config` (ETS) hidrata desde `Config.File`

Modificar `Candil.Config.init/1`:

```elixir
def init(_opts) do
  :ets.new(@table_engines, [...])
  :ets.new(@table_models, [...])
  :ets.new(@table_providers, [...])

  # Primero: config.exs (Elixir) - retrocompat
  load_from_app_config()

  # Segundo: TOML - sobreescribe
  case Candil.Config.File.load() do
    {:ok, config} -> hydrate_from_toml(config)
    {:error, _} -> :ok
  end

  {:ok, %{}}
end
```

#### 1.5 — `Candil.Config.Migrate`

`lib/candil/config/migrate.ex`:

```elixir
defmodule Candil.Config.Migrate do
  @moduledoc """
  Reads ropero.d/*.sh files and generates a candil.toml.
  """

  @spec from_ropero(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def from_ropero(ropero_dir, output_file \\ nil) do
    ropero_dir
    |> Path.join("*.sh")
    |> Path.wildcard()
    |> Enum.reject(&excluded?/1)
    |> Enum.map(&parse_script/1)
    |> Enum.reject(&is_nil/1)
    |> build_toml()
    |> write_toml(output_file)
  end

  defp parse_script(path) do
    content = File.read!(path)
    # regex para extraer:
    # - MODEL_ALIAS="coder"
    # - MODEL_GGUF="...gguf"
    # - MODEL_CTX=131072
    # - MODEL_PORT=9999
    # - get_model_args_<alias>() { ... }
    # ...
  end
end
```

**Test**: con un ropero.d/ de ejemplo, verificar que el TOML resultante es válido y
contiene los engines/modelos.

#### 1.6 — Mix task

`lib/mix/tasks/candil.migrate.ex`:

```elixir
defmodule Mix.Tasks.Candil.Migrate do
  use Mix.Task

  @shortdoc "Migrate ropero.d/*.sh to candil.toml"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [from_ropero: :string, output: :string])
    ropero_dir = Keyword.fetch!(opts, :from_ropero)
    output = Keyword.get(opts, :output)
    Candil.Config.Migrate.from_ropero(ropero_dir, output)
  end
end
```

**Salida de la Fase 1**: Candil lee TOML. `mix candil.migrate --from-ropero <dir>` genera
un TOML válido. Tests verifican el ciclo completo (leer .sh → TOML → cargar → structs).

---

### Fase 2 — CLI con Alaja (2 días)

**Objetivo**: `candil models list`, `candil run coder`, etc.

#### 2.1 — Deps

`mix.exs`:

```elixir
{:alaja, github: "Lorenzo-SF/alaja"},
{:pote, "~> 3.0"}
```

#### 2.2 — `Candil.CLI`

`lib/candil/cli.ex`:

```elixir
defmodule Candil.CLI do
  use Alaja.CLI.Definition, otp_app: :candil, halt_on_error: true

  command "models", "Manage models" do
    subcommand "list", "List registered models" do
      run fn _opts -> Candil.CLI.Commands.Models.list() end
    end

    subcommand "pull", "Download a model" do
      argument :alias, :string, required: true
      run fn opts -> Candil.CLI.Commands.Models.pull(opts.alias) end
    end

    subcommand "info", "Show model details" do
      argument :alias, :string, required: true
      run fn opts -> Candil.CLI.Commands.Models.info(opts.alias) end
    end
  end

  command "run", "Start a model" do
    argument :alias, :string, required: true
    flag :port, :integer
    flag :background, :boolean, default: false
    run fn opts -> Candil.CLI.Commands.Run.start(opts.alias, opts) end
  end

  command "stop", "Stop a model" do
    argument :alias, :string, required: true
    run fn opts -> Candil.CLI.Commands.Stop.stop(opts.alias) end
  end

  command "status", "Show engines status" do
    flag :json, :boolean, default: false
    run fn opts -> Candil.CLI.Commands.Status.show(opts) end
  end

  command "config", "Manage config" do
    subcommand "show", "Show current config" do
      run fn _opts -> Candil.CLI.Commands.Config.show() end
    end

    subcommand "validate", "Validate config" do
      run fn _opts -> Candil.CLI.Commands.Config.validate() end
    end

    subcommand "migrate", "Migrate from ropero.d" do
      flag :from_ropero, :string
      run fn opts -> Candil.CLI.Commands.Config.migrate(opts) end
    end
  end

  command "gateway", "Manage OpenAI-compatible gateway" do
    subcommand "start", "Start the gateway" do
      flag :port, :integer, default: 9999
      run fn opts -> Candil.CLI.Commands.Gateway.start(opts) end
    end

    subcommand "stop", "Stop the gateway" do
      run fn _opts -> Candil.CLI.Commands.Gateway.stop() end
    end
  end

  command "mcp", "MCP server" do
    subcommand "serve", "Start MCP server" do
      flag :transport, :string, default: "stdio", values: ~w(stdio http)
      run fn opts -> Candil.CLI.Commands.MCP.serve(opts) end
    end
  end

  command "rag", "RAG operations" do
    subcommand "index", "Index a directory" do
      argument :path, :string, required: true
      run fn opts -> Candil.CLI.Commands.RAG.index(opts.path) end
    end

    subcommand "query", "Query the index" do
      argument :text, :string, required: true
      flag :top_k, :integer, default: 5
      run fn opts -> Candil.CLI.Commands.RAG.query(opts.text, opts) end
    end
  end
end
```

#### 2.3 — Subcomandos

Cada comando en `lib/candil/cli/commands/`:

```elixir
# lib/candil/cli/commands/models.ex
defmodule Candil.CLI.Commands.Models do
  alias Candil.Config
  alias Alaja.Components.Table
  alias Alaja.Printer

  def list do
    models = Config.list_models()

    if models == [] do
      Printer.print_info("No models registered. Add some in ~/.config/candil/candil.toml")
    else
      Table.print(
        headers: ["Alias", "Type", "Engine/Provider", "Context", "Usage"],
        rows: Enum.map(models, fn m ->
          [m.alias, m.type, m.engine || m.provider, m.context_size, Enum.join(m.usage, ",")]
        end),
        table_border: :rounded
      )
    end
  end

  def pull(alias) do
    # descarga con progress bar de Alaja
  end

  def info(alias) do
    # muestra struct formateado
  end
end
```

**Salida de la Fase 2**: `candil` CLI funciona con Alaja. Tests del DSL (que los comandos
responden sin crashear, con output de ejemplo).

---

### Fase 3 — Router + Gateway (3-4 días)

**Objetivo**: endpoint OpenAI-compatible que decide y arranca modelos.

#### 3.1 — `Candil.Router`

Portar de ElPaso `lib/el_paso/domain/router.ex`, `decision_engine.ex`, `scorer.ex`,
`task_categories.ex`.

Estructura nueva:

```
router/
  router.ex             # Candil.Router (punto de entrada)
  decision_engine.ex    # orquesta
  cache.ex              # decision cache
  embedding_matcher.ex  # clasificación por embedding
  llm_classifier.ex     # clasificación por LLM
  scorer.ex             # multi-señal
  task_categories.ex    # code / reasoning / fast / embed
  analyzer.ex           # stats
  auto_tuner.ex         # ajuste periódico
  policy.ex             # swap policy
```

**API**:

```elixir
@spec route(String.t(), [message()], keyword()) ::
  {:ok, %{model: atom(), reason: String.t(), score: float()}}
  | {:error, term()}
def route(prompt_or_messages, opts \\ [])
```

**Estrategias** (en `decision_engine.ex`):

1. **Cache hit** (por hash del prompt).
2. **Rule match** (reglas del TOML).
3. **Embedding matcher** (si hay índice de embeddings de prompts).
4. **LLM classifier** (último recurso, con un modelo barato).
5. **Fallback** (default).

**Modelo de decisión** (`%RoutingDecision{}`):

- model_alias
- strategy (`:cache | :rule | :embedding | :llm | :fallback`)
- score (0..1)
- reason
- timestamp

#### 3.2 — `Candil.Gateway`

Portar de ElPaso `lib/el_paso/http/server.ex` y `anthropic/proxy.ex`. Reescribir con
**Bandit** (no Cowboy) y **Plug**.

```
gateway/
  endpoint.ex           # arranca Bandit
  router.ex             # Plug.Router con las rutas
  handlers/
    chat_completions.ex # POST /v1/chat/completions
    messages.ex         # POST /v1/messages (Anthropic)
    embeddings.ex       # POST /v1/embeddings
    models.ex           # GET /v1/models
    health.ex           # GET /health
    metrics.ex          # GET /metrics
  auth.ex               # Plug para API key / JWT
  normalizer.ex         # normaliza OpenAI ↔ Anthropic ↔ Ollama
```

**Flujo**:

1. `POST /v1/chat/completions` con `{model: "auto", messages: [...]}`.
2. Auth → verifica API key.
3. Normalizer → convierte a mensajes internos.
4. Router → decide model_alias.
5. Si el modelo es local y no está arrancado → `Engine.start/2`.
6. `Inference.chat_local/3` o `chat_remote/4`.
7. Respuesta → normalizer → JSON OpenAI-compatible.

**Streaming**: usar `Candil.Stream`.

#### 3.3 — Auth

```elixir
defmodule Candil.Gateway.Auth do
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, opts) do
    case verify_key(conn) do
      :ok -> conn
      {:error, :unauthorized} ->
        conn
        |> Plug.Conn.put_status(401)
        |> Plug.Conn.send_resp(401, "unauthorized")
        |> Plug.Conn.halt()
    end
  end

  defp verify_key(conn) do
    # Bearer <key> en Authorization
    # comparación contra la lista de keys válidas en config
  end
end
```

**JWT**: opcional. En la v1, solo API key.

#### 3.4 — Config del gateway

En el TOML:

```toml
[gateway]
enabled = false
host = "127.0.0.1"
port = 10000  # ⚠️ fuera del rango de engines
auth = "api_key"
api_keys = ["candil-xxx", "candil-yyy"]
```

**Salida de la Fase 3**: `candil gateway start` arranca Bandit. `curl` a
`/v1/chat/completions` con `model: "auto"` funciona y enruta.

---

### Fase 4 — Context compartido (2-3 días)

**Objetivo**: sesiones compartidas entre consumers, con LRU y resumen.

#### 4.1 — `Candil.Context.Store`

```elixir
defmodule Candil.Context.Store do
  use GenServer

  # ETS: :candil_context_sessions
  # key: {consumer, session_id}
  # value: %Session{}

  def put(consumer, session_id, session)
  def get(consumer, session_id)
  def delete(consumer, session_id)
  def list(consumer)
  def count(consumer)
  def gc()  # elimina expiradas
end
```

#### 4.2 — `Candil.Context.Session`

```elixir
defmodule Candil.Context.Session do
  defstruct [
    :id, :consumer, :created_at, :updated_at, :last_used_at,
    :messages, :summary, :metadata
  ]
end
```

#### 4.3 — `Candil.Context.Builder`

Construye el array de mensajes a enviar al LLM:

1. System prompt (del prefix_manager).
2. Summary (si hay).
3. Últimos N mensajes que quepan en el context_size.

#### 4.4 — `Candil.Context.Summarizer`

Cuando la sesión tiene > `summarize_after_messages` o > `summarize_after_tokens`:

1. Llama a un modelo barato (configurable).
2. Resume en un párrafo.
3. Guarda el resumen en `session.summary`.
4. Trunca mensajes viejos.

#### 4.5 — `Candil.Context.PrefixManager`

Cache de system prompts. Evita re-enviar el system prompt en cada request si el proveedor
soporta prefix caching.

**Salida de la Fase 4**: sesiones persistentes en ETS. `consumer` aísla. Resumen
automático. Tests de ciclo completo.

---

### Fase 5 — MCP (3-4 días)

**Objetivo**: Candil como MCP client y server.

#### 5.1 — `Candil.MCP.Protocol`

JSON-RPC 2.0 sobre stdlib. Sin deps.

```elixir
defmodule Candil.MCP.Protocol do
  @version "2024-11-05"

  def encode(%{method: m, params: p, id: id}), do: Jason.encode!(%{jsonrpc: "2.0", method: m, params: p, id: id})
  def decode(binary), do: Jason.decode(binary)

  # Métodos:
  # - initialize
  # - tools/list
  # - tools/call
  # - resources/list
  # - prompts/list
end
```

#### 5.2 — `Candil.MCP.Transport.Stdio`

Lee de stdin, escribe a stdout. El shim.

#### 5.3 — `Candil.MCP.Transport.HTTP`

Cliente HTTP para hablar con MCP servers remotos.

#### 5.4 — `Candil.MCP.Client`

```elixir
{:ok, client} = Candil.MCP.Client.connect("http://127.0.0.1:9997")
{:ok, tools} = Candil.MCP.Client.list_tools(client)
{:ok, result} = Candil.MCP.Client.call_tool(client, "read_file", %{path: "..."})
```

#### 5.5 — `Candil.MCP.Server`

Expone las tools registradas vía `Candil.Tool`.

```elixir
Candil.MCP.Server.start_link(transport: :stdio)
# o
Candil.MCP.Server.start_link(transport: :http, port: 9997)
```

**Salida de la Fase 5**: `candil mcp serve --transport stdio` expone las tools. OpenCode
puede conectarse.

---

### Fase 6 — RAG (3-4 días)

**Objetivo**: indexar y consultar documentos.

#### 6.1 — `Candil.RAG.Chunker`

Divide texto en chunks de `chunk_size` con `chunk_overlap`.

#### 6.2 — `Candil.RAG.Index`

Backend in-memory (default): ETS con vectores. Backend pgvector opcional.

#### 6.3 — `Candil.RAG.Retrieval`

Hybrid:

1. BM25 sobre el texto.
2. Cosine similarity sobre embeddings.
3. RRF (Reciprocal Rank Fusion).

#### 6.4 — `Candil.RAG.Rerank`

Opcional. Modelo de cross-encoder.

**Salida de la Fase 6**: `candil rag index <dir>` y `candil rag query "<text>"` funcionan.

---

### Fase 7 — Migrar ropero (1-2 días)

**Objetivo**: correr `mix candil.migrate` sobre ropero real y verificar.

#### 7.1 — Correr

```bash
cd ~/workspace/github/candil
mix candil.migrate --from-ropero ~/workspace/github/lasaca/ropero/ropero.d/ --output ~/.config/candil/candil.toml
```

#### 7.2 — Revisar el TOML

Verificar que cada modelo tiene:

- `type`, `engine`, `model_dir`, `filename`, `context_size`, `port`, `usage`, `model_args`
- Los `MODEL_ALIAS` en `.sh` con alias se convierten en modelos con el mismo nombre.

#### 7.3 — Arrancar cada modelo

```bash
candil models list
candil run coder
candil run verifier
candil status
```

Verificar que arrancan y responden.

#### 7.4 — Borrar ropero

En `lasaca/repos.yaml`: quitar ropero. Commit `chore(ropero): remove, absorbed by candil`.

**Salida de la Fase 7**: candil reemplaza ropero al 100%.

---

### Fase 8 — Cablear Posadero (3-4 días)

**Objetivo**: Posadero usa Candil en vez de su cliente HTTP suelto.

#### 8.1 — Dep

`posadero/mix.exs`:

```elixir
{:candil, path: "../candil"}
```

#### 8.2 — Reemplazar cliente HTTP

En `posadero/lib/posadero/llm.ex` (o equivalente):

- Antes: `HTTPoison.post(...)` a `localhost:9999`.
- Después: `Candil.chat(:coder, messages, consumer: :posadero)`.

#### 8.3 — Reemplazar embeddings

En `posadero/lib/posadero/vault/rag.ex`:

- Antes: cliente HTTP.
- Después: `Candil.embed(:embed, texts, consumer: :posadero)`.

#### 8.4 — Exponer MCP de las 29 tools

Posadero usa `Candil.MCP.Server` para exponer sus tools del vault:

```elixir
Candil.MCP.Server.start_link(
  transport: :stdio,
  tools: Posadero.Tools.all()
)
```

**Salida de la Fase 8**: Posadero usa Candil como librería. No hay HTTP suelto.

---

### Fase 9 — Migrar arriero (5-7 días)

Ya está documentado en `PENDIENTE/principal/migracion-arriero-a-posadero.md`. En esta
fase:

1. CLI con Alaja replicando los comandos de arriero.
2. Los 4 que faltan (`version`, `wiki adr`, `wiki new`, `wiki summary`, `wiki recent`).
3. Cablear las 29 tools.

**Salida de la Fase 9**: posadero tiene CLI completo con Alaja. Arriero puede borrarse.

---

### Fase 10 — Borrar (1 día)

- `gunter` fuera.
- `arriero` fuera.
- `ropero` fuera.
- `elpaso` fuera.
- Actualizar `repos.yaml`, `README.md`, `ARCHITECTURE.md`.

**Salida de la Fase 10**: el ecosistema tiene: candil, alaja, apero, arrea, trebejo,
pote, botica, posadero + los que no se tocan.

---

## 6. Cuadro resumen de fases

| Fase      | Qué                            | Días      | Salida              |
| --------- | ------------------------------ | --------- | ------------------- |
| 0         | Saneamiento (3 bugs + 3 fixes) | 1-2       | Candil 3.0.1        |
| 1         | Config TOML + migrate          | 2-3       | Candil 4.0-alpha1   |
| 2         | CLI con Alaja                  | 2         | Candil 4.0-alpha2   |
| 3         | Router + Gateway               | 3-4       | Candil 4.0-beta     |
| 4         | Context compartido             | 2-3       | Candil 4.0-beta2    |
| 5         | MCP                            | 3-4       | Candil 4.0-rc1      |
| 6         | RAG                            | 3-4       | Candil 4.0-rc2      |
| 7         | Migrar ropero                  | 1-2       | ropero borrado      |
| 8         | Cablear Posadero               | 3-4       | posadero usa candil |
| 9         | Migrar arriero                 | 5-7       | arriero borrado     |
| 10        | Borrar (gunter, elpaso)        | 1         | elpaso borrado      |
| **Total** |                                | **25-35** |                     |

---

## 7. Qué NO se toca

- **Alaja** — se usa como dep. Si se necesita un feature nuevo, se añade a Alaja, no a Candil.
- **Apero / Trebejo / Arrea / Pote / Botica** — deps. Solo se usan.
- **El vault** — otro documento (`rediseño-vault.md`).
- **Las skills de opencode** — otro documento (`skills-y-metodologia.md`).
- **La web de Posadero** — otra sesión.

---

## 8. Reglas duras de Candil 4.0

1. **Un solo `mix.exs`**. Sin submódulos.
2. **`consumer` como parámetro** en todo lo que tenga estado por sesión (chat, context,
   cost).
3. **Config en TOML**. La config de Elixir (`config.exs`) sigue funcionando para
   retrocompat, pero el TOML es la fuente de verdad para el usuario.
4. **ETS por defecto**, Postgres opcional. Nada obliga a Postgres.
5. **Ningún proceso GenServer gigante**. Cada GenServer tiene una responsabilidad clara.
6. **Ningún `Process.sleep`** en código de producción, salvo health polling.
7. **Ningún `String.to_atom/1`** con input del usuario. Los aliases vienen del TOML
   (confiable) o de la API (validar contra existentes).
8. **Cero deps para JSON-RPC**. Se escribe con stdlib (Jason para JSON).
9. **Candil no depende de Posadero**. Posadero depende de Candil. Nunca al revés.
10. **Candil no depende de Alaja**... espera, sí depende, pero solo para el CLI. El resto
    de Candil no usa Alaja.
11. **Toda API pública tiene `@spec`**. Dialyzer limpio.
12. **Toda config tiene valor por defecto razonable**. Si el TOML no está, el CLI arranca.

---

## 9. Testing

- **Unit**: cada módulo con tests.
- **Integration**: engine lifecycle, gateway HTTP, MCP protocol.
- **Property**: para el router (misma entrada → misma salida).
- **Fixtures**: `test/support/` con un `candil.toml` de ejemplo y un `ropero.d/` de
  ejemplo.

Comando:

```bash
mix test
mix test --cover
mix credo --strict
mix dialyzer
```

Cobertura mínima: 70% (como hoy).

---

## 10. Lo que necesito antes de empezar

Para arrancar la **Fase 0** no necesito nada más que este documento.

Para la **Fase 1** necesito ver los `.sh` reales de ropero (`~/workspace/github/lasaca/ropero/ropero.d/*.sh`).

Para la **Fase 3** necesito ver el router de ElPaso (`~/workspace/github/ElPaso/lib/el_paso/domain/router.ex` + `decision_engine.ex`).

Para la **Fase 5** necesito el spec de MCP (URL pública) y una decisión: si el shim
stdio es Elixir o Go. **Recomendación**: Elixir, para no añadir otro lenguaje.

Para la **Fase 8** necesito ver cómo Posadero habla con Candil hoy (el cliente HTTP
suelto que hay que reemplazar).

---

**Fin del documento.**

_Cualquier cambio de alcance debe reflejarse aquí antes de tocar código._
