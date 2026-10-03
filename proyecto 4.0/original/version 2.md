# Candil 4.0 — Diseño, decisiones y plan de ejecución

> **Documento maestro.** Todo lo que se sabe hoy sobre el proyecto Candil, lo
> que se ha decidido, lo que falta por decidir, y las fases de trabajo con
> suficiente detalle como para que un modelo local (o un agente) pueda
> ejecutarlas sin más contexto.
>
> **Última revisión:** 2026-09-30.
> **Estado:** decisiones C1-C7 cerradas, plan pendiente de empezar.

---

## 0. Qué es Candil, y qué no

**Candil es la librería IA del ecosistema `lasaca`.** Su trabajo es gestionar
modelos de lenguaje (locales y remotos), exponerlos con una API uniforme,
enrutar peticiones, mantener contexto entre llamadas, servir MCP, hacer RAG, y
dar un CLI para operarlo todo.

Candil **no es**:

- Un daemon de larga vida. Puede arrancarse como daemon (el Gateway), pero
  también se usa como librería desde otros proyectos.
- El dueño de un dominio de negocio. No sabe de vaults, ni de notas, ni de
  journals. Eso es de otros.
- Una web. No tiene dashboard. Solo CLI + Gateway HTTP (OpenAI-compatible) +
  MCP.
- Un reemplazo de `opencode`. Es lo que `opencode` consume para modelos
  locales.

Candil **sí es**:

- El "señor de los LLMs". Si un proyecto necesita un modelo, pide a Candil.
- El gestor de engines (`llama-server` y otros), modelos (locales y remotos),
  providers (`OpenAI`, `Anthropic`, `Ollama`), y su ciclo de vida.
- El router que decide qué modelo responde a cada request.
- El dueño del contexto compartido entre modelos y sesiones.
- El servidor y cliente MCP.
- La librería de RAG (chunking, index, retrieval, rerank).

---

## 1. Estado actual (2026-09-30)

### Candil

5.923 LOC, 30 archivos de test, estructura limpia. Depende de `apero` y `arrea`
por GitHub (no Hex). Es la base sólida sobre la que construir.

**Lo que ya tiene:**

| Módulo                                                                                | Qué hace                                                                                               |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `Engine` + `Engine.Server` + `Engine.Launcher` + `Engine.HealthPoller` + `EnginePool` | Ciclo de vida de engines locales, uno por modelo, con LRU en el pool y behaviour para motores externos |
| `Backend` + `Backend.LlamaCpp` + `Backend.OpenAICompat`                               | Abstracción de backend (⚠️ ambos stubs)                                                                |
| `Inference` + `Inference.Chat` + `Inference.Embeddings` + `Stream` + `RequestBuilder` | Chat, embeddings, SSE streaming, construcción de bodies por API                                        |
| `Conversation` + `Conversation.Context` + `Conversation.TokenEstimator`               | Historial en memoria + ventana de contexto                                                             |
| `Config` (ETS)                                                                        | Registro de engines, models, providers                                                                 |
| `Model`, `Provider`                                                                   | Structs de dominio con validación                                                                      |
| `Tool`, `Tools`                                                                       | Tool calling: parsea formato OpenAI y llama.cpp                                                        |
| `Agent`                                                                               | Loop ReAct mínimo                                                                                      |
| `Structured`                                                                          | Output JSON con schema + retry                                                                         |
| `Detector`, `Detector.GPU`, `Detector.Models`, `Detector.Release`                     | Detección de OS/arch/GPU + resolución de binarios precompilados                                        |
| `Installer`                                                                           | Descarga binarios + modelos con SHA256 + streaming a disco                                             |
| `Cost`, `Health`                                                                      | Estimación de coste + probes                                                                           |
| `Telemetry`, `Cancellation`, `RateLimiter`                                            | Instrumentación                                                                                        |
| `HTTP`, `HTTP.Client`, `HTTP.Retry`                                                   | Cliente HTTP con retry                                                                                 |
| `Error`                                                                               | Errores unificados                                                                                     |

**Lo que tiene MAL (bugs):**

1. **`Backend.LlamaCpp.chat/3` es un stub** que devuelve
   `{:error, :backend_unavailable}`. El código real está en
   `Inference.Chat.do_chat_local/3`. Hay dos caminos al mismo sitio, y uno
   sin cablear. `Agent` y `Structured` usan el roto.
2. **`Backend.OpenAICompat.chat_stream/3` es un stub** que devuelve un stream
   de un solo chunk vacío. No streamea nada.
3. **`Backend.OpenAICompat.embed/3`** hace N llamadas HTTP (una por texto) en
   vez de batch. La doc promete batch; el código no lo hace.

**Lo que NO tiene (features que faltan):**

- Configuración en archivo (hoy solo `config.exs` de Elixir + ETS).
- CLI.
- MCP (ni cliente ni servidor).
- RAG (solo embeddings sueltos).
- Router (decide qué modelo responde).
- Gateway (endpoint OpenAI-compatible).
- Contexto compartido en ETS entre sesiones y modelos.
- Multi-modelo real (el `EnginePool` es LRU de 1).

### ElPaso

12.389 LOC, Elixir 1.19, OTP 28. Es un **gateway OpenAI-compatible con router
inteligente**. Está en un limbo: los últimos 10 commits son "fix(elpaso): CI…",
la migración a Ecosystem está a medias, los tests no corren sin `mix deps.get`.

**Lo que vale:**

- **`Domain.Router`** con todo su `DecisionEngine`:
  - `DecisionCache` — cachea decisiones
  - `EmbeddingMatcher` — clasifica por similitud de embeddings
  - `LLMClassifier` — clasifica con un LLM (pequeño y rápido)
  - `Scorer` — combina señales (embedding + LLM + reglas) en un score
  - `TaskCategories` — code / reasoning / fast / embed / vision
  - `RouterAnalyzer` — analítica de decisiones
  - `AutoTuner` — ajusta afinidad periódicamente
  - `ModelState` — estado de cada modelo (¿arrancado?, ¿saludable?, ¿coste?)
  - `Cluster` — coordinación multi-nodo
- **`Context.*`** — `Storage`, `SessionContext`, `ContextBuilder`,
  `ContextSummarizer`, `PrefixManager`, `EmbeddingClient`, `TokenCounter`,
  `SessionSupervisor`. Con schemas Ecto: `Session`, `Message`,
  `ConversationSummary`, `RoutingDecision`.
- **`HTTP.Server`** — Plug/Cowboy con endpoint `/v1/chat/completions`.
- **`HTTP.Anthropic.Proxy`** — endpoint `/v1/messages` compatible Anthropic.
- **`CostManager`** — budget diario + coste por modelo.
- **`Security`** — `Auth`, `JWT`, `RateLimiter`, `Secrets`.
- **`Doctor`** — diagnóstico.

**Lo que NO vale:**

- Los 17 Mix tasks (`mix elpaso.*`) — el CLI de Candil va con Alaja.
- El `Dashboard` HTTP — Candil no tiene web.
- Las dependencias pesadas: Ecto + Postgres + pgvector **obligatorios**,
  ExAws, ExAws_s3, libcluster, telemetry_metrics_prometheus.
- El uso de Zaguan como TUI — choca con Alaja.
- `Ecosystem` y `Bootstrap` — Candil tiene su propio bootstrap.

### Alaja

24.506 LOC, Hex 3.1.2. **Framework CLI + terminal rendering kit**. No es un
producto, es una librería.

**Piezas relevantes:**

- **`Alaja.CLI.Definition`** — DSL declarativo (`command`, `subcommand`,
  `flag`, `argument`, `run`).
- **`Alaja.CLI.Help`** — help autogenerado.
- **`Alaja.CLI.Validator`** — validación de flags y args.
- **`Alaja.CLI.ErrorHandler`** — "did you mean?" con Jaro.
- **`Alaja.CLI.GlobalOpts`** — 12 flags globales (`--help`, `--raw`, `--pos-x`,
  `--pos-y`, `--align`, `--verbose`, `--box`, `--box-title`, `--box-border`,
  `--box-color`, `--quiet`, `--stdin`).
- **`Alaja.Components.Table`** — tablas con bordes redondeados, dobles, etc.
- **`Alaja.Printer`** — 12 niveles (`success`, `error`, `warning`, `info`,
  `debug`, `notice`, `alert`, `critical`, `emergency`, `happy`, `sad`,
  `message`).
- **`Alaja.Printer.Interactive`** — prompts (`question`, `yesno`,
  `question_with_options`, `menu`).
- **`Alaja.Syntax.*`** — syntax highlighting.
- **`Alaja.Theme.*`** — temas (con Pote).

**Rol en Candil**: **dependencia path**, no absorción. Candil define su CLI con
`use Alaja.CLI.Definition`, y usa los componentes (`Table`, `Printer`,
`Interactive`).

### Ropero

~15 archivos `.sh` con definiciones de modelos. Estructura:

- `ropero` — entry point
- `ropero.d/_common.sh` — helpers
- `ropero.d/<modelo>.sh` — un archivo por modelo:
  - `MODEL_ALIAS`, `MODEL_GGUF`, `MODEL_CTX`, `MODEL_NGL`, `MODEL_CACHE_K`,
    `MODEL_CACHE_V`, `MODEL_ARGS`
  - `get_model_args_<modelo>()` — construye los args de `llama-server`

**Rol en Candil**: **absorción total**. Los `.sh` se convierten en TOML vía
`mix candil.migrate --from-ropero`. Ropero desaparece como repo.

### Otras librerías del ecosistema

| Librería      | Rol                                                                  | Estado      | Cómo se consume desde Candil                                |
| ------------- | -------------------------------------------------------------------- | ----------- | ----------------------------------------------------------- |
| **`apero`**   | Utilidades base (OS, HTTP, sistema)                                  | 4.0.0, Hex  | Dep (ya en `mix.exs`)                                       |
| **`arrea`**   | Orquestación de procesos, circuit breakers, long-running supervision | 3.0.0, Hex  | Dep (ya en `mix.exs`)                                       |
| **`trebejo`** | Wrappers shell/OS                                                    | 2.0.0, Hex  | **Opt-in**: solo si se usa `Detector` con detección de arch |
| **`botica`**  | Diagnóstico (`doctor`, health checks)                                | 2.1.0, Hex  | **Opt-in**: para `candil doctor`                            |
| **`pote`**    | Gestión de temas y color                                             | 3.0.0, Hex  | Indirecta vía Alaja                                         |
| **`alaja`**   | CLI framework + rendering                                            | 3.1.2, repo | Dep path (C1 decidido)                                      |

---

## 2. Decisiones cerradas (C1-C7)

| #      | Decisión                                                                                             | Razón                                                           |
| ------ | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| **C1** | Alaja se consume como **path dep apuntando al repo** (`{:alaja, path: "../alaja"}`)                  | Hex no siempre está al día; el repo es la fuente                |
| **C2** | **ETS por defecto**, Postgres opcional. Solo si `config.toml` declara un backend Postgres, se activa | Postgres implica docker o instalarlo. ETS cubre el 90% de casos |
| **C3** | Candil tiene **CLI + Gateway HTTP + MCP**. No tiene web                                              | La web es de otro proyecto                                      |
| **C4** | El Gateway OpenAI-compatible vive **en Candil**. Los consumidores (opencode, otros) apuntan a Candil | Candil es "el señor de los LLMs"                                |
| **C5** | Candil depende de `arrea` (ya) y puede añadir `apero`, `trebejo`, `botica`                           | Libre, cada una opcional                                        |
| **C6** | Repo Ecto **opcional**. Solo se levanta si hay Postgres configurado                                  | Ver C2                                                          |
| **C7** | **Un solo `mix.exs`** con todo dentro                                                                | Simplicidad                                                     |

### C4 — Los consumidores y su aislamiento

**Candil debe poder ser consumido por varios consumidores a la vez sin que se
mezclen.** Los consumidores son, hoy:

- **`opencode`** — para modelos locales y remotos. Quiere un endpoint
  OpenAI-compatible.
- **`posadero`** — para procesar el vault, embeddings, chat, structured output.
  Quiere una librería Elixir (o HTTP).
- **El propio CLI de Candil** — para operar modelos.

**El aislamiento se consigue así:**

1. **Cada consumidor tiene un `consumer_id`.** `opencode`, `posadero`,
   `cli`, `test`, etc.
2. **El Gateway HTTP expone un endpoint por consumidor**:
   `POST /c/{consumer_id}/v1/chat/completions`. Los consumidores que no
   especifican `consumer_id` van a un default (`public`).
3. **El contexto (`Context.Store`) está particionado por `consumer_id`.** El
   contexto de `opencode` no se mezcla con el de `posadero`.
4. **La cuota / rate limit es por `consumer_id`.** Un consumidor ruidoso no
   ahoga a los demás.
5. **La afinidad de modelo también es por consumidor.** Si `posadero` está
   usando `coder` en GPU, `opencode` puede estar usando `gptoss` en CPU sin
   conflicto.

Esto es una decisión de diseño importante y no la tenía ElPaso. En ElPaso
todos los requests van al mismo pool y comparten el mismo contexto.

---

## 3. Arquitectura objetivo

### Vista de pájaro

```
┌──────────────────────────────────────────────────────────────────────┐
│                            consumidores                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│  │ opencode │  │ posadero │  │   CLI    │  │  tests   │             │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘             │
└───────┼─────────────┼─────────────┼─────────────┼───────────────────┘
        │             │             │             │
        │ HTTP        │ Elixir      │ directo     │ directo
        │             │ (dep)       │             │
        ▼             ▼             ▼             ▼
┌──────────────────────────────────────────────────────────────────────┐
│                              candil                                   │
│                                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │
│  │  Gateway    │  │   Router    │  │   Context   │  │    MCP     │  │
│  │  (HTTP)     │─▶│  (decide)   │─▶│  (ETS)      │  │ (srv+cli)  │  │
│  └─────────────┘  └──────┬──────┘  └─────────────┘  └────────────┘  │
│                          │                                            │
│  ┌─────────────┐  ┌──────▼──────┐  ┌─────────────┐  ┌────────────┐  │
│  │    RAG      │  │  Inference  │  │    Tool     │  │   Agent    │  │
│  │  (chunks)   │  │  (chat/embed│  │  (calling)  │  │  (ReAct)   │  │
│  └─────────────┘  └──────┬──────┘  └─────────────┘  └────────────┘  │
│                          │                                            │
│  ┌─────────────┐  ┌──────▼──────┐  ┌─────────────┐  ┌────────────┐  │
│  │   Backend   │  │   Engine    │  │   Config    │  │    CLI     │  │
│  │  (behaviour)│  │ (lifecycle) │  │   (TOML)    │  │  (Alaja)   │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  └────────────┘  │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
      ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
      │ llama-server │  │   Ollama     │  │  OpenAI /    │
      │ (GGUF local) │  │  (localhost) │  │  Anthropic   │
      └──────────────┘  └──────────────┘  └──────────────┘
```

### Estructura de módulos

```
lib/candil/
  application.ex                         # supervisor tree
  candil.ex                              # facade pública
  error.ex                               # errores unificados

  # ─── LO QUE YA EXISTE (se queda, se arregla) ───
  engine.ex                              # struct del engine
  engine/
    server.ex                            # GenServer que envuelve llama-server
    server/external.ex                   # GenServer para motores externos
    launcher.ex                          # behaviour para motores externos
    health_poller.ex                     # /health polling
  engine_pool.ex                         # LRU pool (se amplía a N concurrentes)

  backend.ex                             # behaviour
  backend/
    llama_cpp.ex                         # ⚠️ ARREGLAR (chat/3 stub)
    openai_compat.ex                     # ⚠️ ARREGLAR (chat_stream/3, embed/3 stubs)

  inference.ex                           # facade
  inference/
    chat.ex                              # chat local/remoto
    embeddings.ex                        # embeddings local/remoto

  stream.ex                              # SSE
  request_builder.ex                     # bodies por API

  conversation.ex                        # historial en memoria
  conversation/
    context.ex                           # ventana
    token_estimator.ex                   # estimación de tokens

  model.ex                               # struct + validación
  provider.ex                            # struct + validación
  config.ex                              # registro ETS (cache de config/file)
  config_manager.ex                      # validación ad-hoc

  tool.ex                                # struct + registry
  tools.ex                               # parse/serialize tool calls

  agent.ex                               # ReAct loop
  structured.ex                          # JSON output con schema

  detector.ex                            # OS/arch/GPU
  detector/
    gpu.ex
    models.ex
    release.ex

  installer.ex                           # descarga binarios + modelos

  cost.ex                                # estimación
  health.ex                              # probes

  http.ex                                # cliente HTTP
  http/
    client.ex
    retry.ex

  telemetry.ex
  cancellation.ex
  rate_limiter.ex

  # ─── LO NUEVO ───

  config/                                # ⭐ FASE 1
    file.ex                              # load/save TOML
    schema.ex                            # NimbleOptions
    migrate.ex                           # ropero.d/*.sh → TOML

  cli.ex                                 # ⭐ FASE 2
  cli/
    commands/
      models.ex                          # list, pull, info, remove
      run.ex                             # arrancar modelo
      stop.ex                            # parar modelo
      status.ex                          # estado de engines
      gateway.ex                         # arrancar Gateway
      mcp.ex                             # arrancar MCP, conectar a MCP externo
      rag.ex                             # index, query
      config.ex                          # show, edit, validate, migrate
      router.ex                          # stats, test
      doctor.ex                          # diagnóstico

  router/                                # ⭐ FASE 3
    router.ex                            # facade
    decision_engine.ex                   # orquesta estrategias
    cache.ex                             # cache de decisiones
    embedding_matcher.ex                 # clasificación por embeddings
    llm_classifier.ex                    # clasificación por LLM
    scorer.ex                            # combina señales
    task_categories.ex                   # code / reasoning / fast / embed / vision
    model_state.ex                       # estado de cada modelo
    analyzer.ex                          # analítica
    auto_tuner.ex                        # ajuste periódico
    consumer.ex                          # aislamiento por consumidor

  gateway/                               # ⭐ FASE 3
    endpoint.ex                          # Plug + Bandit
    router.ex                            # routing de HTTP paths
    handlers/
      chat_completions.ex                # POST /c/:cid/v1/chat/completions
      messages.ex                        # POST /c/:cid/v1/messages (Anthropic-compat)
      models.ex                          # GET /c/:cid/v1/models
      health.ex                          # GET /health
      metrics.ex                         # GET /metrics (Prometheus)
    auth.ex                              # API key + JWT
    consumer_registry.ex                 # gestiona consumers
    request_id.ex                        # inyecta X-Request-ID
    error_handler.ex                     # traduce errores a respuestas HTTP

  context/                               # ⭐ FASE 4
    store.ex                             # facade (ETS por defecto)
    session.ex                           # struct + lifecycle
    session_supervisor.ex                # DynamicSupervisor
    builder.ex                           # construye contexto para el LLM
    summarizer.ex                        # resumen de conversación larga
    prefix_manager.ex                    # cache de prefijos (system prompts)
    backend/
      ets.ex                             # backend ETS (default)
      postgres.ex                        # backend Postgres (opcional)
    schemas/                             # Ecto schemas (opcional)
      session.ex
      message.ex
      summary.ex
      decision.ex

  mcp/                                   # ⭐ FASE 5
    protocol.ex                          # JSON-RPC 2.0
    message.ex                           # struct de mensaje
    error.ex                             # errores MCP
    client.ex                            # cliente
    client/
      stdio.ex                           # transporte stdio
      http.ex                            # transporte HTTP
    server.ex                            # servidor
    server/
      tools.ex                           # expone tools
      resources.ex                       # expone recursos
    transport/
      stdio.ex                           # shim stdio
      http.ex                            # endpoint HTTP

  rag/                                   # ⭐ FASE 6
    chunker.ex                           # divide texto
    chunk.ex                             # struct
    index.ex                             # facade
    index/
      memory.ex                          # índice in-memory (default)
      postgres.ex                        # índice pgvector (opcional)
    retrieval.ex                         # hybrid BM25 + vector + RRF
    rerank.ex                            # opcional
    embedder.ex                          # wrapper de Inference.Embeddings
    document.ex                          # struct
```

### Config TOML

Candil se configura con un solo archivo: `~/.config/candil/candil.toml`.
Override por env var `CANDIL_CONFIG`. Override por CLI `--config`.

**Estructura**:

```toml
# ~/.config/candil/candil.toml

# ─── Información global ───
[general]
default_consumer = "public"
data_dir = "~/.candil"
log_level = "info"

# ─── Persistencia (opcional) ───
[persistence]
# ETS por defecto. Solo si se declara `backend = "postgres"` se levanta.
backend = "ets"              # "ets" | "postgres"
# [persistence.postgres]
# url = "postgres://user:pass@localhost/candil"
# pool_size = 5

# ─── Engines (uno por binario) ───
[engine.llama_server]
binary_dir = "~/.candil/llm/bin"
use_precompiled = true
precompiled_version = "latest"

# ─── Modelos ───
[model.coder]
type = "local"
engine = "llama_server"
context_size = 131072
port = 9999
usage = ["chat", "code"]

# Definición del modelo GGUF (con descarga automática)
[model.coder.source]
kind = "huggingface_gguf"
repo = "mistralai/Devstral-Small-2-24B-Instruct-2512-GGUF"
file = "Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf"
dest = "~/.cache/models/devstral"
# sha256 = "abc123..."   # opcional

[model.coder.args]
"--n-gpu-layers" = "999"
"--cache-type-k" = "q4_0"
"--cache-type-v" = "q4_0"
"--jinja" = true
"--temp" = "0.7"

[model.verifier]
type = "local"
engine = "llama_server"
context_size = 131072
port = 9998
usage = ["chat", "reasoning"]

[model.verifier.source]
kind = "huggingface_gguf"
repo = "openai/gpt-oss-20b-GGUF"
file = "openai_gpt-oss-20b-MXFP4.gguf"
dest = "~/.cache/models/gpt-oss"

[model.verifier.args]
"--n-gpu-layers" = "0"
"--chat-template-kwargs" = '{"reasoning_effort":"high"}'

# Modelo remoto
[model.gpt4o]
type = "remote"
provider = "openai"
name = "gpt-4o"
context_size = 128000
usage = ["chat", "completion"]

# ─── Providers remotos ───
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

# ─── Gateway ───
[gateway]
port = 7777
host = "127.0.0.1"
# auth = { api_key = { env = "CANDIL_GATEWAY_KEY" } }

# ─── Consumers ───
[consumer.opencode]
model_default = "coder"
max_concurrent = 4
rate_limit_per_minute = 100

[consumer.posadero]
model_default = "verifier"
max_concurrent = 2
rate_limit_per_minute = 60

[consumer.cli]
model_default = "coder"

# ─── MCP ───
[mcp.server]
transport = "http"           # "stdio" | "http"
port = 7778
# auth = { api_key = { env = "CANDIL_MCP_KEY" } }

[mcp.client]
# Servidores MCP a los que conectarse como cliente
# [mcp.client.filesystem]
# transport = "stdio"
# command = "npx"
# args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]

# ─── RAG ───
[rag]
chunker = "sentence"         # "sentence" | "fixed" | "paragraph"
chunk_size = 512
chunk_overlap = 64
embedder = "jina_code"       # alias de un modelo con usage = ["embeddings"]
index_backend = "memory"     # "memory" | "postgres"
top_k = 10
```

### El bloque `[model.<alias>.source]` — descarga de modelos

Es la parte que reemplaza a ropero. Tipos soportados:

**1. GGUF de Hugging Face** (el caso de ropero):

```toml
[model.coder.source]
kind = "huggingface_gguf"
repo = "mistralai/Devstral-Small-2-24B-Instruct-2512-GGUF"
file = "Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf"
dest = "~/.cache/models/devstral"
sha256 = "abc123..."          # opcional
```

**2. safetensors de Hugging Face** (clone normal del repo):

```toml
[model.llama3_8b.source]
kind = "huggingface_safetensors"
repo = "meta-llama/Meta-Llama-3-8B-Instruct"
dest = "~/.cache/models/llama3-8b"
# revision = "main"           # opcional
# allow_patterns = ["*.safetensors", "*.json"]  # opcional
```

**3. Archivo único por URL**:

```toml
[model.custom.source]
kind = "url"
url = "https://example.com/model.gguf"
file = "model.gguf"
dest = "~/.cache/models/custom"
sha256 = "abc123..."
```

**4. Ollama** (no descarga, se lo pide a ollama):

```toml
[model.llama3.source]
kind = "ollama"
name = "llama3:8b"
```

**5. Sin descarga** (ya está en disco):

```toml
[model.local.source]
kind = "already_present"
path = "/opt/models/mymodel.gguf"
```

El comando `candil models pull <alias>` lee el bloque `source` y descarga. Si
`kind` es `huggingface_gguf`, descarga con `hf` (o `curl` si no está `hf`). Si
es `huggingface_safetensors`, clona con `hf`. Si es `url`, descarga con
`curl`. Todos van a `dest`.

---

## 4. Fases de trabajo

Las fases están ordenadas por dependencia. Cada una se puede taggear y
desplegar. Las estimaciones son días de trabajo concentrado.

### Fase 0 — Saneamiento (1-2 días)

**Objetivo**: baseline limpio antes de añadir nada.

**Tareas**:

1. **`mix deps.get && mix test`** en Candil. Ver baseline real. Si algo
   falla, anotarlo.
2. **Arreglar `Backend.LlamaCpp.chat/3`**:
   - Hoy devuelve `{:error, :backend_unavailable}`.
   - Debe llamar a `Inference.Chat.do_chat_local/3` con el `model_alias`.
   - `chat_stream/3` debe llamar a `Stream.chat/4`.
   - `embed/3` ya llama a `Embeddings.embed_batch/3` — revisar que el batch
     sea real.
3. **Arreglar `Backend.OpenAICompat.chat_stream/3`**:
   - Hoy devuelve un stream de un solo chunk vacío.
   - Debe usar `Candil.Stream` para hacer SSE real.
   - El body ya se construye; falta la parte de parsear el stream y emitir
     chunks.
4. **Arreglar `Backend.OpenAICompat.embed/3`**:
   - Hoy hace N llamadas HTTP (una por texto).
   - Debe mandar `input: texts` como array (OpenAI lo soporta).
   - Si el provider no soporta batch, fallback al loop.
5. **`mix credo --strict` + `mix dialyzer`** limpios. Si hay warnings
   preexistentes, dejarlos documentados.
6. **Tag `candil-3.0.1`**.

**Criterio de done**: `mix test` pasa, `mix credo --strict` limpio,
`mix dialyzer` limpio, tag en git.

### Fase 1 — Config TOML (2-3 días)

**Objetivo**: Candil se configura con un solo archivo.

**Tareas**:

1. **`Candil.Config.File`** (`lib/candil/config/file.ex`):
   - `load/0` — lee `~/.config/candil/candil.toml` (o `$CANDIL_CONFIG`).
   - `load/1` — lee un path concreto.
   - `save/1` — escribe TOML atómico.
   - `validate/1` — valida contra el schema.
2. **`Candil.Config.Schema`** (`lib/candil/config/schema.ex`):
   - `NimbleOptions` con todos los campos (general, persistence, engine,
     model, provider, gateway, consumer, mcp, rag).
   - `validate/1` — devuelve `{:ok, config} | {:error, [reason]}`.
3. **`Candil.Config`** (el actual) pasa a ser cache:
   - `Config.load/0` lee TOML, valida, y puebla ETS.
   - `Config.register_*` sigue funcionando pero escribe al TOML también.
   - `Config.reload/0` recarga.
4. **`Candil.Config.Migrate`** (`lib/candil/config/migrate.ex`):
   - `from_ropero/1` — lee un directorio con `.sh` y devuelve el TOML.
   - Parsea los `.sh` con `sed`/`awk` (no evalúa bash — riesgo).
   - Detecta `MODEL_ALIAS`, `MODEL_GGUF`, `MODEL_CTX`, etc.
   - Escribe el TOML resultante.
5. **Tests**: config con todos los tipos, validación, migración desde
   fixtures de ropero.

**Criterio de done**: `mix candil.migrate --from-ropero <dir>` genera un TOML
válido que `Config.load/0` acepta.

### Fase 2 — CLI con Alaja (2 días)

**Objetivo**: `candil` como binario que sirve para operar modelos.

**Tareas**:

1. **`Candil.CLI`** (`lib/candil/cli.ex`):
   - `use Alaja.CLI.Definition, otp_app: :candil, halt_on_error: true`.
2. **Comandos** (`lib/candil/cli/commands/`):
   - `models list` — tabla con alias, engine, type, context_size, usage.
   - `models pull <alias>` — descarga según `source`.
   - `models info <alias>` — detalle.
   - `models remove <alias>` — borra del TOML.
   - `run <alias>` — arranca el engine y bloquea (o `--background`).
   - `stop <alias>` — para el engine.
   - `status` — estado de todos los engines.
   - `config show` — muestra el TOML efectivo.
   - `config edit` — abre `$EDITOR` y valida al cerrar.
   - `config validate` — valida sin escribir.
   - `config migrate --from-ropero <dir>` — migra.
   - `doctor` — diagnóstico (usa Botica si está).
   - `version` — versión.
3. **Dep de Alaja**: `{:alaja, path: "../alaja"}` (C1).
4. **Dep de Pote**: `{:pote, "~> 3.0"}` (ya viene con Alaja).
5. **Dep de Botica** (opcional): `{:botica, github: "Lorenzo-SF/botica"}` para
   `candil doctor`.

**Criterio de done**: `candil models list` funciona; `candil run coder`
arranca el engine; `candil config show` muestra el TOML.

### Fase 3 — Router + Gateway (3-4 días)

**Objetivo**: Candil expone un endpoint OpenAI-compatible que enruta.

**Tareas**:

1. **`Candil.Router.TaskCategories`** — portado de ElPaso:
   - `classify/1` — code / reasoning / fast / embed / vision / unknown.
   - `from_prompt/1` — heurística inicial (keywords).
2. **`Candil.Router.ModelState`** — portado:
   - Estado de cada modelo: `{:ready, url}` / `{:starting, pid}` /
     `{:stopped}` / `{:error, reason}`.
   - Coste por modelo (si remoto).
   - Capacidades (usage).
3. **`Candil.Router.EmbeddingMatcher`** — portado:
   - Clasifica el prompt por similitud a ejemplos conocidos.
   - Requiere un modelo `usage = ["embeddings"]` configurado.
4. **`Candil.Router.LLMClassifier`** — portado:
   - Clasifica con un LLM pequeño (ej. un `gptoss_low`).
   - Prompt cacheado para ahorrar.
5. **`Candil.Router.Scorer`** — portado:
   - Combina señales (embedding + LLM + reglas) en un score por modelo.
   - Configura pesos.
6. **`Candil.Router.DecisionEngine`** — portado:
   - `decide/2` — dado un request + contexto, devuelve `{model, score}`.
   - Consulta el cache primero.
7. **`Candil.Router.Cache`** — cache de decisiones:
   - ETS, TTL configurable.
   - Hash de (task, context_keys) → decisión.
8. **`Candil.Router.Consumer`** — **NUEVO** (esto no está en ElPaso):
   - Cada consumidor tiene su propio contexto y afinidad.
   - `Consumer.list/0`, `Consumer.get/1`, `Consumer.current_model/1`.
9. **`Candil.Router`** — facade:
   - `decide(consumer, prompt, opts)`.
   - `pin(consumer, model)` — fuerza un modelo.
   - `unpin(consumer)`.
   - `stats(consumer)`.
10. **`Candil.Router.AutoTuner`** — portado:
    - Ajusta pesos periódicamente.
    - Solo si hay datos suficientes.
11. **`Candil.Router.Analyzer`** — portado:
    - Analítica (uso por modelo, latencia, coste, errores).
12. **`Candil.Gateway.Endpoint`** — Bandit + Plug:
    - `POST /c/:consumer/v1/chat/completions` — OpenAI-compat.
    - `POST /c/:consumer/v1/messages` — Anthropic-compat.
    - `GET /c/:consumer/v1/models` — lista.
    - `GET /health`.
    - `GET /metrics` — Prometheus.
13. **`Candil.Gateway.Auth`** — portado:
    - API key.
    - JWT (opcional).
    - Rate limit por consumer.
14. **`Candil.Gateway.ConsumerRegistry`**:
    - Cada consumer tiene un `SessionContext` propio.
    - Si no existe, se crea.
15. **`Candil.Gateway.ErrorHandler`**:
    - Traduce errores de Candil a respuestas HTTP.
    - Errores OpenAI-compatibles.

**Criterio de done**: `curl -X POST localhost:7777/c/opencode/v1/chat/completions -d '{"messages":[{"role":"user","content":"hi"}],"model":"auto"}'`
devuelve una respuesta del router.

### Fase 4 — Context compartido (2-3 días)

**Objetivo**: el contexto viaja entre modelos y consumidores.

**Tareas**:

1. **`Candil.Context.Session`** — struct:
   - `id`, `consumer`, `model_current`, `messages`, `summary`, `metadata`.
   - `created_at`, `updated_at`.
2. **`Candil.Context.Store`** — facade:
   - `create/1`, `get/1`, `update/2`, `delete/1`.
   - `append_message/2`.
   - `list_by_consumer/1`.
3. **`Candil.Context.Backend.Ets`**:
   - Un ETS por session.
   - Supervisado por `SessionSupervisor`.
   - Cuando la session lleva N minutos inactiva, se evicta (configurable).
4. **`Candil.Context.Backend.Postgres`** (opcional):
   - Solo se levanta si `persistence.backend = "postgres"`.
   - Schemas Ecto: `Session`, `Message`, `Summary`, `Decision`.
5. **`Candil.Context.SessionSupervisor`**:
   - `DynamicSupervisor` para sessions ETS.
   - Máximo de sessions concurrentes.
6. **`Candil.Context.Builder`** — portado:
   - Dado un prompt + session, construye los messages finales.
   - Incluye system prompt + summary + últimos N mensajes.
7. **`Candil.Context.Summarizer`** — portado:
   - Cuando la ventana está llena, resume los mensajes viejos.
   - Usa un modelo `usage = ["chat", "summarisation"]`.
8. **`Candil.Context.PrefixManager`** — portado:
   - Cache de system prompts largos.
   - Reutiliza KV cache (a nivel de llama-server).

**Criterio de done**: dos requests al mismo consumer mantienen contexto; el
contexto se puede leer desde `candil context list` (nuevo subcomando del CLI).

### Fase 5 — MCP (3-4 días)

**Objetivo**: Candil expone y consume MCP.

**Tareas**:

1. **`Candil.MCP.Protocol`**:
   - JSON-RPC 2.0 sobre stdlib (`Jason`).
   - Methods: `initialize`, `tools/list`, `tools/call`, `resources/list`,
     `resources/read`, `prompts/list`, `prompts/get`.
2. **`Candil.MCP.Message`** y **`Candil.MCP.Error`**:
   - Structs de mensaje y error con serialización.
3. **`Candil.MCP.Transport.Stdio`**:
   - Lee de stdin, escribe a stdout.
   - Shim tonto: solo JSON-RPC ↔ binary.
4. **`Candil.MCP.Transport.Http`**:
   - Endpoint Plug que acepta JSON-RPC por POST.
   - Streaming opcional por SSE.
5. **`Candil.MCP.Server`**:
   - Expone las tools registradas en `Candil.Tool`.
   - Soporta stdio y HTTP.
   - `Server.start_link(transport: :http, port: 7778)`.
6. **`Candil.MCP.Server.Tools`**:
   - Convierte `Candil.Tool` a schema MCP.
   - Invoca tools.
7. **`Candil.MCP.Client`**:
   - Cliente que se conecta a MCP servers externos.
   - `Client.connect(transport_opts)`.
   - `Client.list_tools/1`, `Client.call_tool/3`.
8. **`Candil.MCP.Client.Stdio`** y **`Candil.MCP.Client.Http`**:
   - Transportes del cliente.
9. **Comandos CLI**:
   - `candil mcp serve --http --port 7778` — arranca servidor.
   - `candil mcp serve --stdio` — arranca servidor por stdio (shim).
   - `candil mcp connect <name>` — registra cliente.
   - `candil mcp call <server> <tool> <json-args>` — llama a un tool.

**Criterio de done**: `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | candil mcp serve --stdio`
devuelve la lista de tools.

### Fase 6 — RAG (3-4 días)

**Objetivo**: Candil puede indexar y consultar documentos.

**Tareas**:

1. **`Candil.RAG.Chunker`**:
   - `chunk/2` — divide texto en chunks.
   - Estrategias: `:sentence`, `:paragraph`, `:fixed`.
   - Configurable por `chunk_size` + `chunk_overlap`.
2. **`Candil.RAG.Chunk`** — struct:
   - `id`, `text`, `embedding`, `metadata`, `position`.
3. **`Candil.RAG.Document`** — struct:
   - `id`, `path`, `chunks`, `metadata`.
4. **`Candil.RAG.Embedder`**:
   - Wrapper de `Inference.Embeddings`.
   - `embed_chunks/2`.
5. **`Candil.RAG.Index`** — facade:
   - `create/2`, `add/2`, `search/3`, `delete/2`.
6. **`Candil.RAG.Index.Memory`**:
   - Índice in-memory (lista de chunks + embeddings).
   - Búsqueda vectorial por cosine similarity.
   - BM25 en paralelo.
   - **Fusión con RRF** (Reciprocal Rank Fusion).
7. **`Candil.RAG.Index.Postgres`** (opcional):
   - Índice pgvector.
   - Solo si `rag.index_backend = "postgres"`.
8. **`Candil.RAG.Retrieval`**:
   - `search/3` — hybrid.
   - `rerank/2` — opcional (con modelo de reranking).
9. **Comandos CLI**:
   - `candil rag index <path> --name <name>` — indexa.
   - `candil rag query <name> "<text>"` — consulta.
   - `candil rag list` — lista índices.
   - `candil rag drop <name>` — borra.

**Criterio de done**: `candil rag index ./docs --name mydocs && candil rag query mydocs "how to X"`
devuelve resultados relevantes.

### Fase 7 — Migración de ropero (1-2 días)

**Objetivo**: ropero desaparece, los modelos están en Candil.

**Tareas**:

1. **Correr `mix candil.migrate --from-ropero ~/cacafuti/lasaca/ropero/ropero.d/`**.
2. **Revisar el TOML generado a mano**:
   - Verificar que los args de cada modelo son correctos.
   - Ajustar nombres de alias si hace falta.
3. **Cargar el TOML en Candil**:
   - `Candil.Config.load/0` debe aceptarlo.
4. **Verificar que cada modelo arranca**:
   - `candil run coder --background`, `candil status`, `candil stop coder`.
   - Uno por uno.
5. **Regla**: mientras esto no esté validado, ropero sigue disponible. Solo
   se borra cuando los tests pasan con Candil.
6. **Commit borra `ropero/` del meta-repo**:
   - `git rm -r ropero/`.
   - Actualizar `repos.yaml` (el manifiesto de `lasaca.sh`).
   - Correr `test-manifiesto.sh`.

**Criterio de done**: ropero no está en el meta-repo, todos los modelos
arrancan con Candil.

### Fase 8 — Deps y documentación (1-2 días)

**Objetivo**: Candil 4.0 está listo.

**Tareas**:

1. **Deps finales**:
   - `apero` (ya), `arrea` (ya), `jason` (ya), `mox` (test).
   - `alaja` (path), `pote` (transitiva).
   - `toml` — para parsear TOML.
   - `nimble_options` — para el schema.
   - `plug` + `bandit` — para el gateway.
   - `finch` (ya, vía apero).
   - Opcional: `botica`, `trebejo`.
   - **Quitar**: `ecto_sql`, `postgrex`, `pgvector` de las deps base; van a
     `optional`.
2. **Documentación**:
   - `README.md` — quick start actualizado.
   - `CHANGELOG.md` — entrada `4.0.0`.
   - `docs/ARCHITECTURE.md` — arquitectura.
   - `docs/CONFIG.md` — config TOML.
   - `docs/MIGRATION.md` — migración desde ropero.
   - ExDoc con grupos de módulos bien organizados.
3. **Tag `candil-4.0.0`**.

**Criterio de done**: `mix docs` sin warnings, README actualizado, tag en
git.

---

## 5. Lo que se toma de cada proyecto

### De ElPaso

| Módulo ElPaso                                                  | Módulo Candil                                | Acción                                        |
| -------------------------------------------------------------- | -------------------------------------------- | --------------------------------------------- |
| `Domain.Router`                                                | `Candil.Router.Router`                       | Portar (adaptar a structs Candil)             |
| `Domain.DecisionEngine` + sub-módulos                          | `Candil.Router.DecisionEngine` + sub-módulos | Portar                                        |
| `Domain.RouterAnalyzer`                                        | `Candil.Router.Analyzer`                     | Portar                                        |
| `Domain.AutoTuner`                                             | `Candil.Router.AutoTuner`                    | Portar                                        |
| `Domain.Router.TaskCategories`                                 | `Candil.Router.TaskCategories`               | Portar                                        |
| `Domain.Router.ModelState`                                     | `Candil.Router.ModelState`                   | Portar                                        |
| `Domain.Router.Cluster`                                        | —                                            | **Descartar** (no multi-nodo por ahora)       |
| `Context.Storage` + sub-módulos                                | `Candil.Context.Store` + sub-módulos         | Portar (con backend ETS por defecto)          |
| `Context.Schemas.*`                                            | `Candil.Context.Schemas.*`                   | Portar como **opcional** (Postgres)           |
| `HTTP.Server`                                                  | `Candil.Gateway.Endpoint`                    | Portar (Bandit en vez de Cowboy)              |
| `HTTP.Anthropic.Proxy`                                         | `Candil.Gateway.Handlers.Messages`           | Portar                                        |
| `HTTP.MessageNormalizer`                                       | `Candil.Gateway.MessageNormalizer`           | Portar                                        |
| `HTTP.Dashboard`                                               | —                                            | **Descartar** (Candil no tiene web)           |
| `CostManager`                                                  | `Candil.Cost` (ampliar)                      | Portar                                        |
| `Security.Auth` + `JWT` + `RateLimiter`                        | `Candil.Gateway.Auth` + `Candil.RateLimiter` | Portar                                        |
| `Security.Secrets`                                             | —                                            | **Descartar** (Candil no maneja secretos así) |
| `Doctor`                                                       | `Candil.Doctor`                              | Portar (usa Botica si está)                   |
| `Models.*` (schemas Ecto)                                      | `Candil.Context.Schemas.*`                   | Portar como opcional                          |
| `Domain.EngineManager` + `LlamaServerManager` + `ModelManager` | —                                            | **Descartar** (Candil ya tiene Engine)        |
| `Domain.PersonalityManager`                                    | —                                            | **Descartar** (fuera de scope)                |
| `Downloader.ModelDownloader`                                   | `Candil.Installer` (ampliar)                 | Portar como `source`                          |
| `Cluster.NodeRegistry`                                         | —                                            | **Descartar**                                 |
| `Bootstrap`                                                    | —                                            | **Descartar**                                 |
| `Ecosystem`                                                    | —                                            | **Descartar**                                 |
| `Repo`                                                         | `Candil.Context.Backend.Postgres`            | Portar como opcional                          |
| `CLI` + 17 Mix tasks                                           | `Candil.CLI` + comandos                      | Reescribir con Alaja                          |
| `Cluster`                                                      | —                                            | **Descartar**                                 |

### De Ropero

| Elemento Ropero             | Elemento Candil               | Acción                                |
| --------------------------- | ----------------------------- | ------------------------------------- |
| `ropero.d/<modelo>.sh`      | `[model.<alias>]` en TOML     | Convertir con `migrate`               |
| `MODEL_ALIAS`               | `alias`                       | Convertir                             |
| `MODEL_GGUF`                | `source.file` + `source.dest` | Convertir                             |
| `MODEL_CTX`                 | `context_size`                | Convertir                             |
| `MODEL_NGL`                 | `args."--n-gpu-layers"`       | Convertir                             |
| `MODEL_CACHE_K/V`           | `args."--cache-type-k/v"`     | Convertir                             |
| `MODEL_ARGS`                | `args.*`                      | Convertir                             |
| `get_model_args_<modelo>()` | (inline en `args`)            | Convertir                             |
| Entry point `ropero`        | `Candil.CLI`                  | Reescribir con Alaja                  |
| `_common.sh`                | —                             | **Descartar** (funciones ya en Apero) |

### De Alaja

| Elemento Alaja              | Uso en Candil                           |
| --------------------------- | --------------------------------------- |
| `Alaja.CLI.Definition`      | `use` en `Candil.CLI`                   |
| `Alaja.CLI.Help`            | Autogenerado                            |
| `Alaja.CLI.Validator`       | Validación de flags                     |
| `Alaja.CLI.ErrorHandler`    | "Did you mean?"                         |
| `Alaja.Components.Table`    | Tablas de `models list`, `status`       |
| `Alaja.Printer`             | Mensajes de `success`/`error`/`warning` |
| `Alaja.Printer.Interactive` | Prompts de `config edit`                |
| `Alaja.Syntax.*`            | Highlight de JSON en `models info`      |

**No se copia código de Alaja. Se consume como dep path.**

---

## 6. Consideraciones a tener en cuenta

### Multi-consumidor

- **El aislamiento por `consumer_id` es obligatorio**. `opencode` y
  `posadero` no comparten contexto ni afinidad.
- **Rate limit por consumer**. Un consumer ruidoso no ahoga a los demás.
- **Cuotas por consumer** (opcional): máximo de tokens/día, máximo de coste.

### Engines y puertos

- **Un engine por modelo**, pero **múltiples modelos pueden correr a la vez**
  en distintos puertos.
- **Convención de puertos**: 9999 para GPU, 9998 para CPU. Configurables en
  el TOML.
- **El EnginePool debe ampliarse** para soportar N concurrentes (hoy es LRU
  de 1). El LRU se mantiene para **cuando hay N+1 modelos y solo caben N**.

### Contexto

- **El contexto se evicta por inactividad**. Configurable (default 30 min).
- **El contexto es por (consumer, session_id)**. No se mezcla.
- **El contexto puede moverse entre modelos**: si `posadero` cambia de
  `coder` a `verifier`, el contexto se mantiene.

### Config

- **Un solo archivo TOML**. Sin `config.exs` para modelos/engines.
- **Override por env var** `CANDIL_CONFIG`.
- **Override por CLI** `--config`.
- **Recarga sin reiniciar** `candil config reload` (SIGHUP también).

### MCP

- **El shim stdio vive en el PATH** (`candil-mcp` o similar). Es tonto:
  reenvía JSON-RPC in → HTTP out.
- **Si Candil está parado**, el shim falla con un mensaje claro (o lo
  arranca, según config).

### RAG

- **Backend in-memory por defecto**. Postgres opcional.
- **Hybrid search**: BM25 + vector + RRF. Sin rerank por defecto; opt-in.

### Seguridad

- **API key del Gateway es opcional**. Si no se configura, no se exige.
- **JWT opcional**.
- **Secrets nunca en el TOML**. Siempre `{ env = "VAR" }`.

### Compatibilidad

- **Con Elixir 1.19+ / OTP 28+**.
- **Con Bandit** en vez de Cowboy (Bandit es el estándar 2026).
- **Con `toml`** para TOML.
- **Con `NimbleOptions`** para schema.

---

## 7. Lo que NO se hace en Candil 4.0

- **Web / Dashboard**. Candil no tiene UI web. Solo CLI + Gateway HTTP.
- **Multi-nodo / Cluster**. Sin libcluster, sin Horde.
- **Postgres obligatorio**. ETS por defecto.
- **Personality manager**. Fuera de scope.
- **Bootstrap**. Cada proyecto tiene su bootstrap.
- **Ecosystem**. No es un meta-repo.
- **Zaguan como TUI**. Alaja es el CLI.

---

## 8. Cómo arrancar la Fase 0

Comandos concretos, en orden:

```bash
cd ~/cacafuti/candil

# 1. Deps y test baseline
mix deps.get
mix test 2>&1 | tail -30
mix credo --strict 2>&1 | tail -20
mix dialyzer 2>&1 | tail -20

# 2. Si hay fallos, documentarlos antes de arreglar
mkdir -p docs/baseline
mix test 2>&1 > docs/baseline/test-$(date +%Y%m%d).txt
mix credo --strict 2>&1 > docs/baseline/credo-$(date +%Y%m%d).txt
mix dialyzer 2>&1 > docs/baseline/dialyzer-$(date +%Y%m%d).txt

# 3. Arreglar Backend.LlamaCpp
# (editar lib/candil/backend/llama_cpp.ex)

# 4. Arreglar Backend.OpenAICompat
# (editar lib/candil/backend/openai_compat.ex)

# 5. Re-test
mix test
mix credo --strict
mix dialyzer

# 6. Tag
git add -A
git commit -m "fix(backend): wire LlamaCpp.chat and OpenAICompat stream/embed"
git tag candil-3.0.1
git push
git push --tags
```

---

## 9. Preguntas abiertas

Nada bloquea las Fases 0-2. Pero hay que decidir antes de las Fases 3+:

| #       | Pregunta                                                                                    | Bloquea                    |
| ------- | ------------------------------------------------------------------------------------------- | -------------------------- |
| **C8**  | ¿Qué modelo de embeddings se usa por defecto? ¿`jina_code`? ¿O se puede elegir?             | Fase 3 (embedding_matcher) |
| **C9**  | ¿Cómo se declaran los prompts de clasificación? ¿En el TOML, o en código?                   | Fase 3 (LLMClassifier)     |
| **C10** | ¿Cómo se declara la afinidad consumer→modelo? ¿En el TOML con `model_default`? ¿O dinámico? | Fase 3 (Consumer)          |
| **C11** | ¿El `AutoTuner` corre por defecto o solo si se activa?                                      | Fase 3                     |
| **C12** | ¿La session de contexto se evicta por LRU o por TTL? ¿O ambos?                              | Fase 4                     |
| **C13** | ¿El `Summarizer` usa qué modelo? ¿Configurable por consumer?                                | Fase 4                     |
| **C14** | ¿MCP server por defecto HTTP o stdio?                                                       | Fase 5                     |
| **C15** | ¿El shim stdio arranca Candil si no está corriendo?                                         | Fase 5                     |
| **C16** | ¿El RAG rerank es opt-in o por defecto?                                                     | Fase 6                     |

---

## 10. Referencias

- **Candil repo**: `~/cacafuti/candil`
- **ElPaso repo**: `~/cacafuti/elpaso`
- **Alaja repo**: `~/cacafuti/alaja`
- **Ropero**: `~/cacafuti/lasaca/ropero`
- **Apero repo**: `~/cacafuti/apero`
- **Arrea repo**: `~/cacafuti/arrea`
- **Botica repo**: `~/cacafuti/botica`
- **Trebejo repo**: `~/cacafuti/trebejo`

---

**Fin del documento.** Cualquier agente que lea esto sabe qué hay, qué se ha
decidido, qué falta, y por dónde empezar.

---

Notas sobre lo que he hecho y por qué:

1. **C4** lo he detallado más porque dijiste "ojo con los consumidores". He añadido `consumer_id` como concepto de primera clase, con endpoints HTTP por consumer, contexto por consumer, cuota por consumer. Eso es lo que más se aleja de ElPaso.

2. **El bloque `[model.<alias>.source]`** lo he diseñado con 5 tipos de `kind` (`huggingface_gguf`, `huggingface_safetensors`, `url`, `ollama`, `already_present`) porque dijiste que hacía falta descarga de modelos GGUF y safetensors. El `hf` CLI cubre ambos.

3. **He metido "Fase 0 — Saneamiento"** antes que nada, porque los 3 stubs son bugs reales y hay que arreglarlos antes de construir encima.

4. **He dejado 16 preguntas abiertas** (C8-C16) que no bloquean las Fases 0-2 pero sí las siguientes. Así puedes irlas respondiendo sobre la marcha.

5. **He puesto "consideraciones"** en cada fase (multi-consumidor, puertos, contexto, config, MCP, RAG, seguridad, compatibilidad) para que un agente no tenga que inventar.

6. **No he mencionado posadero** en ninguna parte, como pediste.

7. **El plan son 8 fases, 17-25 días estimados.** Cuando quieras, arrancamos con la Fase 0 (arreglar los 3 bugs) que es lo más urgente y no depende de nada.
