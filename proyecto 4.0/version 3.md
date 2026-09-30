# Candil 4.0 — Diseño, decisiones, plan y ejecución

> **Documento maestro definitivo.** Autocontenido en contexto y decisiones; complementario con los dos previos en cuanto a plan de ejecución. Cada tarea es atómica y verificable.
>
> **Fecha**: 2026-09-30 · **Estado**: decisiones cerradas · **Decide**: Lorenzo · **Ejecuta**: por asignar
>
> **Fuentes**: dos documentos previos (`# Candil 4.0 — Diseño, migración…` y `# Candil 4.0 — Diseño, decisiones…`) + snapshots reales del código de Candil 3.0.0, ElPaso, Alaja, Ropero, Arrea, Apero, Trebejo, Botica y lasaca.
>
> **Destino**: `~/cacafuti/lasaca/PENDIENTE/principal/candil-4.md`

---

## Índice

**Parte I — Contexto**

1. [Resumen ejecutivo](#1-resumen-ejecutivo)
2. [Glosario](#2-glosario)
3. [El ecosistema](#3-el-ecosistema)
4. [Estado real de Candil 3.0.0](#4-estado-real-de-candil-300)
5. [Decisiones cerradas](#5-decisiones-cerradas)

**Parte II — Arquitectura** 6. [Visión general](#6-visión-general) 7. [Estructura de directorios](#7-estructura-de-directorios) 8. [Las seis capas](#8-las-seis-capas) 9. [Configuración TOML](#9-configuración-toml) 10. [Multi-consumidor](#10-multi-consumidor) 11. [Puertos y EnginePool](#11-puertos-y-enginepool) 12. [Módulos nuevos: especificaciones](#12-módulos-nuevos-especificaciones)

**Parte III — Plan de ejecución** 13. [Fase 0 — Saneamiento](#13-fase-0--saneamiento) 14. [Fase 1 — Config TOML](#14-fase-1--config-toml) 15. [Fase 2 — CLI con Alaja](#15-fase-2--cli-con-alaja) 16. [Fase 3 — Router + Gateway](#16-fase-3--router--gateway) 17. [Fase 4 — Context compartido](#17-fase-4--context-compartido) 18. [Fase 5 — MCP](#18-fase-5--mcp) 19. [Fase 6 — RAG](#19-fase-6--rag) 20. [Fase 7 — Migrar ropero](#20-fase-7--migrar-ropero) 21. [Fase 8 — Cablear Posadero](#21-fase-8--cablear-posadero) 22. [Fase 9 — Migrar arriero](#22-fase-9--migrar-arriero) 23. [Fase 10 — Borrar](#23-fase-10--borrar)

**Apéndices**

- [A. Mapeo ElPaso → Candil](#apéndice-a-mapeo-elpaso--candil)
- [B. Mapeo Ropero → TOML](#apéndice-b-mapeo-ropero--toml)
- [C. Contradicciones resueltas](#apéndice-c-contradicciones-resueltas)
- [D. Reglas duras](#apéndice-d-reglas-duras)
- [E. Preguntas abiertas](#apéndice-e-preguntas-abiertas)

---

# Parte I — Contexto

## 1. Resumen ejecutivo

Candil 3.0.0 es **una base sólida con 9 bugs y una capa de producto sin construir**. Tiene 5.923 LOC, 41 módulos, 30 archivos de test, y una arquitectura limpia. Lo que falta no es reescribirla — es **terminarla**.

**La misión de Candil 4.0** es convertirse en la **librería IA del ecosistema `cacafuti`**, absorbiendo:

- **Ropero** (bash, ~15 scripts `.sh`) → se convierte en config TOML + `Candil.Config.Migrate`.
- **ElPaso** (Elixir, 12.389 LOC) → se convierte en `Candil.Router` + `Candil.Gateway` (solo la parte de routing y gateway; se descarta su capa Ecto/Postgres obligatoria y su CLI con Mix tasks).

**El lema**: _Candil es el señor de los LLM_. Todo lo que huela a inferencia, embeddings, modelos, routing, MCP, RAG vive aquí. Los demás proyectos (`posadero`, `opencode`, `arriero` antes de morir) **consumen** Candil, no lo reimplementan.

**Esfuerzo total estimado**: 25-35 días de trabajo concentrado, repartibles en 8-10 semanas.

**Lo que NO se toca**: Alaja (dep), Apero/Arrea/Trebejo/Botica (deps), el vault, las skills de opencode, la web de Posadero.

---

## 2. Glosario

| Término          | Significado                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------- |
| **Engine**       | Un proceso OS (`llama-server`, vLLM, etc.) que sirve un modelo por HTTP. En Candil: `%Candil.Engine{}`. |
| **Model**        | Un modelo (`.gguf` local o nombre remoto tipo `gpt-4o`). En Candil: `%Candil.Model{}`.                  |
| **Provider**     | Un endpoint remoto (OpenAI, Anthropic, Ollama). En Candil: `%Candil.Provider{}`.                        |
| **Backend**      | La abstracción de "cómo hablo con un modelo". `LlamaCpp` para local, `OpenAICompat` para remoto.        |
| **Consumer**     | Quién llama a Candil: `posadero`, `opencode`, `cli`, `default`. Aísla contexto, cuota y rate limit.     |
| **Slot**         | Un puerto TCP gestionado por Candil (ej: 9999 GPU, 9998 CPU, 9990 embedding).                           |
| **Session**      | Una conversación con contexto propio, identificada por `(consumer, session_id)`.                        |
| **Router**       | El módulo que decide qué modelo responde a un prompt. Portado de ElPaso.                                |
| **Gateway**      | El endpoint HTTP OpenAI-compatible. `POST /c/:cid/v1/chat/completions`.                                 |
| **MCP**          | Model Context Protocol (JSON-RPC 2.0). Candil expone tools y consume servers externos.                  |
| **RAG**          | Retrieval-Augmented Generation: chunking, index, retrieval, rerank.                                     |
| **Prefix cache** | Cache de system prompts largos para reutilizar KV cache en llama-server.                                |

---

## 3. El ecosistema

### 3.1 Las librerías y su rol

| Librería     | Rol                                                                     | LOC        | Versión | Estado                                     |
| ------------ | ----------------------------------------------------------------------- | ---------- | ------- | ------------------------------------------ |
| **candil**   | LLM: engines, modelos, inferencia, router, gateway, MCP, RAG            | 5.923      | 3.0.0   | Base sólida, 9 bugs, capa producto ausente |
| **alaja**    | CLI framework (DSL declarativo) + rendering kit ANSI                    | 24.506     | 3.1.2   | Hex, maduro                                |
| **arrea**    | Orquestación: circuit breakers, workers, supervisión, `LongRunning`     | (no vista) | 3.0.0   | Usada por Candil (Engine.Server)           |
| **apero**    | Utilidades puras: File, Crypto, Env, Conf, Cache, Retry, HTTP, OS, Proc | (no vista) | 4.0.0   | Usada por Candil                           |
| **trebejo**  | Wrappers shell/OS: Docker, Git, SSH, K8s, Compress, `Trebejo.OS.arch/0` | (no vista) | 2.0.0   | **Opt-in** para Candil                     |
| **pote**     | Themes (colores, fonts, spacing, JSON)                                  | (no vista) | 3.0.0   | Dep transitiva vía Alaja                   |
| **botica**   | Doctor: health checks + fix + feature flags                             | (no vista) | 2.1.1   | **Opt-in** para `candil doctor`            |
| **posadero** | Daemon Elixir/OTP: procesa vault, RAG, planner                          | (no vista) | -       | **Consumidor** de Candil                   |
| **arriero**  | CLI Go thin sobre posadero                                              | (no vista) | -       | A migrar; morirá                           |
| **ropero**   | Bash: lanzador de modelos locales                                       | ~15 `.sh`  | -       | **A absorber** por Candil                  |
| **elpaso**   | Gateway OpenAI-compatible + router                                      | 12.389     | 0.1.0   | **A absorber** parcialmente                |
| **gunter**   | Deploy opencode + MCPs                                                  | (no vista) | -       | A borrar                                   |
| **lasaca**   | Meta-repo: `repos.yaml` + `lasaca.sh`                                   | -          | -       | Manifiesto                                 |

### 3.2 Filosofía

```mermaid
graph TB
    subgraph "Infraestructura"
        AP[apero<br/>utilidades puras]
        TR[trebejo<br/>wrappers shell]
        AR[arrea<br/>orquestación OTP]
        BO[botica<br/>doctor + flags]
    end

    subgraph "IA"
        CA[candil<br/>LLM · router · gateway · MCP · RAG]
    end

    subgraph "Presentación"
        PO[pote<br/>themes]
        AL[alaja<br/>CLI + ANSI]
    end

    subgraph "Consumidores"
        PD[posadero]
        OC[opencode]
        CLI[CLI de candil]
    end

    CA --> AP
    CA --> AR
    CA -. opt .-> TR
    CA -. opt .-> BO

    AL --> PO

    PD --> CA
    PD --> BO
    OC -. HTTP .-> CA
    CLI --> CA
    CLI --> AL
```

**Regla dura**: cada librería tiene su dominio. **candil no reimplementa lo que ya está en apero/trebejo/arrea**, y **alaja no sabe nada de LLMs**.

### 3.3 Candil en el meta-repo `lasaca`

Actualmente `candil` y `alaja` viven en `~/cacafuti/` (no bajo `~/cacafuti/lasaca/`). El documento asume esa topología:

```
~/cacafuti/
├── candil/                 ← proyecto
├── alaja/                  ← dependencia (path dep)
├── apero/
├── arrea/
├── trebejo/
├── botica/
└── lasaca/
    ├── repos.yaml
    ├── lasaca.sh
    ├── posadero/           ← consumidor
    ├── arriero/            ← a migrar
    ├── ropero/             ← a absorber
    └── ...
```

Si en el futuro se quiere integrar `candil` como repo del meta-repo, se añade una entrada a `repos.yaml` con `order: 25`, `install: ./candil --install`.

---

## 4. Estado real de Candil 3.0.0

### 4.1 Lo que funciona

```mermaid
graph LR
    subgraph "Engine lifecycle"
        E[Candil.Engine]
        ES[Engine.Server<br/>GenServer+Arrea.LongRunning]
        EL[Engine.Launcher<br/>behaviour para motores externos]
        HP[Engine.HealthPoller<br/>/health cada 5s]
        EP[EnginePool<br/>LRU actual]
    end

    subgraph "Backend"
        B[Candil.Backend<br/>behaviour]
        BLC[Backend.LlamaCpp<br/>⚠️ stub]
        BOC[Backend.OpenAICompat<br/>⚠️ stub en stream/embed]
    end

    subgraph "Inferencia"
        INF[Candil.Inference]
        CH[Inference.Chat<br/>openai/anthropic/ollama]
        EM[Inference.Embeddings]
        ST[Candil.Stream<br/>SSE parser]
        RB[RequestBuilder]
    end

    subgraph "Dominio"
        M[Candil.Model]
        P[Candil.Provider]
        C[Candil.Config<br/>ETS]
    end

    E --> ES
    ES --> HP
    E --> EL
    E --> EP

    INF --> CH
    INF --> EM
    CH --> RB
    CH --> ST
    INF --> B
    B --> BLC
    B --> BOC

    CH --> C
    EM --> C
    C --> M
    C --> P
```

**Módulos verificados en el snapshot** (41 totales):

| Módulo                               | LOC | Rol                                         |
| ------------------------------------ | --- | ------------------------------------------- |
| `Candil`                             | ~40 | Facade que delega en `Candil.Llm`           |
| `Candil.Llm`                         | 156 | Facade real (chat/embed/stream/download)    |
| `Candil.Engine`                      | 230 | Struct + `start/stop/healthy?/base_url`     |
| `Candil.Engine.Server`               | 136 | GenServer + `Arrea.LongRunning`             |
| `Candil.Engine.Launcher`             | 75  | Behaviour para motores externos             |
| `Candil.Engine.HealthPoller`         | 71  | Probe `/health`                             |
| `Candil.Engine.Server.External`      | 70  | GenServer para motores externos             |
| `Candil.EnginePool`                  | 74  | LRU pool                                    |
| `Candil.Backend`                     | 172 | Behaviour + registry vía `:persistent_term` |
| `Candil.Backend.LlamaCpp`            | 39  | **Stub**                                    |
| `Candil.Backend.OpenAICompat`        | 245 | Chat OK, stream/embed stub                  |
| `Candil.Inference`                   | 136 | Facade local/remoto                         |
| `Candil.Inference.Chat`              | 215 | **La implementación real**                  |
| `Candil.Inference.Embeddings`        | 71  | Embeddings local/remoto                     |
| `Candil.Stream`                      | 346 | SSE parser completo                         |
| `Candil.RequestBuilder`              | 174 | Bodies OpenAI/Anthropic/Ollama              |
| `Candil.HTTP`                        | 92  | Circuit breaker + retry                     |
| `Candil.HTTP.Client`                 | 109 | Adaptador `Apero.Http`                      |
| `Candil.HTTP.Retry`                  | -   | Wrapper de `Apero.Retry`                    |
| `Candil.Conversation`                | 178 | Historial + context window                  |
| `Candil.Conversation.Context`        | 73  | Trimming                                    |
| `Candil.Conversation.TokenEstimator` | 108 | Heurística                                  |
| `Candil.Tool`                        | 161 | Registry GenServer                          |
| `Candil.Tools`                       | 205 | Schemas + parser tool calls                 |
| `Candil.Agent`                       | 224 | Loop ReAct (⚠️ usa backend roto)            |
| `Candil.Structured`                  | 170 | JSON con schema (⚠️ usa backend roto)       |
| `Candil.Model`                       | 191 | Struct + validación                         |
| `Candil.Provider`                    | 171 | Struct + `auth_headers/1` + URLs            |
| `Candil.Config`                      | 271 | ETS registry                                |
| `Candil.ConfigManager`               | 129 | Validación ad-hoc                           |
| `Candil.Detector`                    | 96  | OS/arch/GPU                                 |
| `Candil.Detector.GPU`                | 71  | NVIDIA/AMD/Intel/Metal                      |
| `Candil.Detector.Models`             | 71  | Asset pattern                               |
| `Candil.Detector.Release`            | 57  | GitHub releases API                         |
| `Candil.Installer`                   | 186 | Descarga binarios + SHA256                  |
| `Candil.Cost`                        | 141 | Pricing table                               |
| `Candil.Health`                      | 124 | Probes                                      |
| `Candil.Telemetry`                   | 128 | Eventos                                     |
| `Candil.Cancellation`                | 109 | Registry de refs                            |
| `Candil.RateLimiter`                 | 67  | ETS sliding window                          |
| `Candil.Error`                       | 260 | Errores unificados                          |
| `Candil.Application`                 | ~30 | Supervisor tree                             |

### 4.2 Los 9 bugs verificados

#### Bug 1 — `Backend.LlamaCpp.chat/3` es un stub

```elixir
# lib/candil/backend/llama_cpp.ex (actual)
@impl true
def chat(_model, _messages, _opts) do
  {:error, %Candil.Error{reason: :backend_unavailable}}
end
```

**Impacto**: `Candil.Agent.run/3` y `Candil.Structured.complete/4` llaman a `backend.chat/3`. Con este stub, **el agente y el structured nunca funcionan**.

**El código real ya existe** en `Candil.Inference.Chat.do_chat_local/3`. La solución es delegar.

#### Bug 2 — `Backend.LlamaCpp.chat_stream/3` es un stub

```elixir
def chat_stream(_model, _messages, _opts) do
  {:error, %Candil.Error{reason: :backend_unavailable}}
end
```

**Impacto**: mismo que el bug 1 pero para streaming.

**El código real está** en `Candil.Stream.chat/4`.

#### Bug 3 — `Backend.OpenAICompat.chat_stream/3` devuelve un stream vacío

```elixir
defp build_chunk_stream(_body) do
  Stream.repeatedly(fn ->
    Process.sleep(50)
    %{content: "", finish_reason: nil, done: true}
  end)
  |> Stream.take(1)
end
```

**Impacto**: un stream vacío es **peor que no soportar streaming**, porque el llamador cree que funciona.

**La solución**: usar `Candil.Stream` (que ya tiene el SSE parser).

#### Bug 4 — `Backend.OpenAICompat.embed/3` no es batch

```elixir
def embed(model, texts, opts) do
  results = Enum.map(texts, fn text ->
    # ... una request por texto
  end)
  # ...
end
```

**Impacto**: la doc dice `embed/3` con lista, pero internamente hace **N round-trips**. Para 100 textos son 100 requests.

**Nota**: el código de `Candil.Inference.Embeddings.do_embed_remote/4` ya lo hace bien (`input: texts`). Solo hay que hacer que `OpenAICompat.embed/3` delegue.

#### Bug 5 — `Config.register_provider/1` rechaza strings planos para `api_key`

```elixir
defp validate_api_key(nil), do: :ok
defp validate_api_key({:system, var}) when is_binary(var), do: :ok
defp validate_api_key(_),
  do: {:error, "api_key must be {:system, \"ENV_VAR\"} tuple or nil, got plain string"}
```

**Impacto**: el README muestra strings planos (`System.get_env("OPENAI_API_KEY")`), pero el código los rechaza.

**Solución**: aceptar ambos. Un string plano se guarda como `{:literal, string}` internamente.

#### Bug 6 — `Detector.safe_arch/0` cae a `:unknown` sin avisar

```elixir
defp safe_arch do
  if Code.ensure_loaded?(Trebejo.OS) and function_exported?(Trebejo.OS, :arch, 0) do
    apply(Trebejo.OS, :arch, [])
  else
    :unknown
  end
end
```

**Impacto**: si `trebejo` no está instalado, `:unknown` y la descarga del binario falla sin decir por qué. Además, `trebejo` **no está en `mix.exs`**.

**Solución**: `trebejo` como dep opcional (`optional: true, runtime: false`), y si no está, **fallar con mensaje claro** en `download_engine/1`.

#### Bug 7 — `Engine.Server.build_args/2` hardcodea el puerto

`build_args/2` construye siempre `--port #{engine.port}`. `Engine.port` es del struct (8080 por defecto). **No hay estrategia de asignación**.

**Solución**: dos modos.

- **Modo estructurado** (default): `Engine.port` fijo.
- **Modo pool** (nuevo): si `Engine.port` es `:auto`, Candil asigna puerto libre del rango `[base_port, base_port + 99]`.

#### Bug 8 — `EnginePool` es LRU con bug de promoción

```elixir
def handle_call(:get, _from, state) do
  {least, rest} = List.pop_at(state, -1)
  new_state = [least | rest]
  {:reply, least, new_state}
end
```

Es un LRU de **N**, pero el nombre "pool" sugiere N concurrentes. **Nadie llama `evict/0`**. Solo hay un engine a la vez por puerto.

**Solución**: `EnginePool` deja de ser LRU y pasa a ser **registro de engines vivos** con `{alias => {pid, engine, started_at}}`. El LRU se mantiene solo para el caso `N+1 > capacidad`.

#### Bug 9 — Tests rotos y credo sucio

Baseline verificado:

```
279 tests, 22 failures
Credo: 4 refactoring + 26 readability + 7 design
Dialyzer: passed (0 errores)
```

**Fallos concretos**:

1. `config_test.exs:9` hace `:ets.delete_all_objects(:apero_llm_engines, :undefined)` — la tabla se llama `:candil_llm_engines` desde hace tiempo. **Bug del test, no del código**.
2. `engine_test.exs:39-42` espera `~/.apero/llm/bin` pero el código devuelve `~/.candil/llm/bin`. **El código tiene razón; el test está stale**.

Otros 20 fallos no se ven en el tail pero deberían ser de la misma naturaleza: nombres de tabla o paths desactualizados.

### 4.3 Lo que no existe

- Configuración en archivo (TOML). Hoy solo `config.exs` de Elixir + ETS.
- CLI.
- MCP (ni cliente ni servidor).
- RAG (solo embeddings sueltos).
- Router (decide qué modelo responde).
- Gateway (endpoint OpenAI-compatible).
- Contexto compartido en ETS entre sesiones y modelos.
- Multi-modelo real (`EnginePool` es LRU de 1 efectivo).

---

## 5. Decisiones cerradas

| #       | Decisión                                                                      | Razón                                                                                                                                                              |
| ------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **C1**  | Alaja como **path dep** (`{:alaja, path: "../alaja"}`)                        | Hex no está al día con las últimas features del DSL. Se actualiza con `git pull` en Alaja sin tocar Candil.                                                        |
| **C2**  | **ETS por defecto**, Postgres opcional                                        | Menos complejidad operativa. El 90% de casos no necesita Postgres.                                                                                                 |
| **C3**  | **CLI + Gateway + MCP**; sin web propia                                       | La web es de Posadero. Candil es librería + gateway.                                                                                                               |
| **C4**  | El **Gateway OpenAI-compatible vive en Candil**                               | Candil es "el señor de los LLM". Posadero y opencode lo consumen.                                                                                                  |
| **C5**  | `arrea`, `apero` como deps; `trebejo`, `botica` como deps **opcionales**      | Ya disponibles; se usan donde aportan sin forzar la instalación.                                                                                                   |
| **C6**  | Repo Ecto **opcional**                                                        | Solo si se activa Postgres en el TOML.                                                                                                                             |
| **C7**  | **Un solo `mix.exs`** con todo dentro                                         | Simplicidad. Sin submódulos.                                                                                                                                       |
| **C8**  | **Consumidores etiquetados** (`consumer: :posadero \| :opencode \| :default`) | Posadero y opencode pueden usar Candil a la vez sin mezclar contextos. Modelo rico: `[consumer.X]` con `model_default`, `max_concurrent`, `rate_limit_per_minute`. |
| **C9**  | **Puertos múltiples** con `Engine.port = :auto \| integer`                    | Generaliza el modelo de ropero (dos slots + pineados) a N slots. Puertos: engines 9998/9999 + auto desde 10000; gateway 7777; MCP HTTP 7778.                       |
| **C10** | **Fuente de la config**: TOML + ETS cache + retrocompat `config.exs`          | El TOML es la fuente de verdad para el usuario; `config.exs` sigue funcionando para tests y setups programáticos.                                                  |
| **C11** | **Router**: solo portar la estrategia de ElPaso, no su DB                     | ElPaso acopla el router a `PersonalityManager` + Ecto. Candil usará `%Model{}` directo.                                                                            |
| **C12** | **Formato del documento**: híbrido                                            | Autocontenido en contexto/arquitectura; complementario en plan de ejecución.                                                                                       |

### 5.1 Contradicciones resueltas

Ver [Apéndice C](#apéndice-c-contradicciones-resueltas) para la tabla completa.

---

# Parte II — Arquitectura

## 6. Visión general

```mermaid
graph TB
    subgraph Consumidores
        PD[posadero<br/>daemon Elixir]
        OC[opencode<br/>CLI + TUI]
        CLI[candil CLI]
        EXT[clientes HTTP externos<br/>curl, openai-python]
    end

    subgraph "Candil"
        GW[Gateway HTTP<br/>OpenAI-compatible<br/>:7777]
        MCP[MCP<br/>stdio + HTTP :7778]
        ROUTER[Router<br/>decide modelo]
        CTX[Context<br/>ETS por consumer]
        INF[Inference<br/>chat/embed/stream]
        TOOLS[Tools + Agents<br/>ReAct + structured]
        RAG[RAG<br/>chunk + index + search]
        CFG[Config<br/>TOML + ETS]
        EP[EnginePool<br/>registro N vivos]
    end

    subgraph "Engines locales"
        LS1[llama-server :9999 GPU]
        LS2[llama-server :9998 CPU]
        LS3[llama-server :9990 embed]
        LSN[llama-server :10000+ auto]
    end

    subgraph "Providers remotos"
        OAI[OpenAI]
        ANT[Anthropic]
        OLL[Ollama]
    end

    PD -->|Elixir dep| ROUTER
    PD -->|Elixir dep| CTX
    OC -->|HTTP| GW
    CLI --> ROUTER
    EXT -->|HTTP| GW

    GW --> ROUTER
    MCP --> ROUTER
    ROUTER --> CTX
    ROUTER --> INF
    INF --> TOOLS
    INF --> RAG
    INF --> EP
    RAG --> INF

    EP --> LS1
    EP --> LS2
    EP --> LS3
    EP --> LSN

    INF --> OAI
    INF --> ANT
    INF --> OLL

    CFG -.hidrata.-> ROUTER
    CFG -.hidrata.-> EP
```

## 7. Estructura de directorios

```
lib/candil/
  application.ex                         # supervisor tree (ampliado)
  candil.ex                              # facade pública (retrocompat)
  llm.ex                                 # facade interna (ya existe)

  # ═══ CAPA 1: BASE ═══════════════════════════════════════════════
  engine.ex                              # struct del engine
  engine/
    server.ex                            # GenServer wrapping llama-server
    server/external.ex                   # GenServer para motores externos
    launcher.ex                          # behaviour para motores externos
    health_poller.ex                     # /health polling
  engine_pool.ex                         # registro de N vivos (arreglado)

  installer.ex                           # descarga binarios + modelos
  detector.ex                            # OS/arch/GPU
  detector/
    gpu.ex
    models.ex
    release.ex

  http.ex                                # cliente HTTP
  http/
    client.ex
    retry.ex

  # ═══ CAPA 2: MODELO ═════════════════════════════════════════════
  model.ex                               # struct + validación
  provider.ex                            # struct + validación
  config.ex                              # registro ETS (cache de config/file)
  config_manager.ex                      # validación ad-hoc

  config/                                # ⭐ FASE 1
    file.ex                              # load/save/validate TOML
    schema.ex                            # NimbleOptions
    migrate.ex                           # ropero.d/*.sh → TOML

  # ═══ CAPA 3: INFERENCIA ═════════════════════════════════════════
  backend.ex                             # behaviour
  backend/
    llama_cpp.ex                         # ⚠️ ARREGLAR chat/3, chat_stream/3
    openai_compat.ex                     # ⚠️ ARREGLAR chat_stream/3, embed/3

  inference.ex
  inference/
    chat.ex                              # implementación real
    embeddings.ex

  stream.ex                              # SSE
  request_builder.ex                     # bodies por API
  structured.ex                          # JSON output (⚠️ usaba backend roto)

  # ═══ CAPA 4: INTELIGENCIA ═══════════════════════════════════════
  router/                                # ⭐ FASE 3
    router.ex
    decision_engine.ex
    cache.ex
    embedding_matcher.ex
    llm_classifier.ex
    scorer.ex
    task_categories.ex
    model_state.ex
    analyzer.ex
    auto_tuner.ex
    consumer.ex

  context/                               # ⭐ FASE 4
    store.ex
    session.ex
    session_supervisor.ex
    builder.ex
    summarizer.ex
    prefix_manager.ex
    backend/
      ets.ex
      postgres.ex
    schemas/                             # Ecto schemas (opcional)

  conversation.ex                        # (ya existe, se mantiene)
  conversation/
    context.ex
    token_estimator.ex

  agent.ex                               # (ya existe, se arregla)
  tool.ex                                # (ya existe)
  tools.ex                               # (ya existe)

  # ═══ CAPA 5: CONSUMO ════════════════════════════════════════════
  gateway/                               # ⭐ FASE 3
    endpoint.ex                          # Plug + Bandit
    router.ex                            # Plug.Router
    handlers/
      chat_completions.ex
      messages.ex
      embeddings.ex
      models.ex
      health.ex
      metrics.ex
    auth.ex
    consumer_registry.ex
    request_id.ex
    error_handler.ex

  mcp/                                   # ⭐ FASE 5
    protocol.ex
    message.ex
    error.ex
    client.ex
    client/
      stdio.ex
      http.ex
    server.ex
    server/
      tools.ex
      resources.ex
    transport/
      stdio.ex
      http.ex

  cli.ex                                 # ⭐ FASE 2
  cli/
    commands/
      models.ex
      run.ex
      stop.ex
      status.ex
      config.ex
      router.ex
      gateway.ex
      mcp.ex
      rag.ex
      doctor.ex

  # ═══ CAPA 6: CONOCIMIENTO ═══════════════════════════════════════
  rag/                                   # ⭐ FASE 6
    chunker.ex
    chunk.ex
    document.ex
    index.ex
    index/
      memory.ex
      postgres.ex
    retrieval.ex
    rerank.ex
    embedder.ex

  # ═══ RUNTIME (se mantiene) ══════════════════════════════════════
  telemetry.ex
  cancellation.ex
  rate_limiter.ex
  cost.ex
  health.ex
  error.ex
```

## 8. Las seis capas

```mermaid
graph TD
    subgraph L6["CAPA 6 · CONOCIMIENTO"]
        RAG[RAG]
    end

    subgraph L5["CAPA 5 · CONSUMO"]
        GW[Gateway]
        MCP[MCP]
        CLI[CLI]
    end

    subgraph L4["CAPA 4 · INTELIGENCIA"]
        ROUTER[Router]
        CTX[Context]
        AGENT[Agent + Tools]
    end

    subgraph L3["CAPA 3 · INFERENCIA"]
        INF[Inference]
        BE[Backend]
        STREAM[Stream]
    end

    subgraph L2["CAPA 2 · MODELO"]
        MOD[Model]
        PROV[Provider]
        CFG[Config]
    end

    subgraph L1["CAPA 1 · BASE"]
        ENG[Engine]
        DET[Detector]
        INST[Installer]
        HTTP[HTTP]
    end

    RAG --> INF
    GW --> ROUTER
    MCP --> AGENT
    CLI --> ROUTER
    ROUTER --> CTX
    CTX --> INF
    AGENT --> INF
    INF --> BE
    BE --> ENG
    STREAM --> HTTP
    CFG -.hidrata.-> ENG
    CFG -.hidrata.-> MOD
    CFG -.hidrata.-> PROV
```

### La regla de una sola dirección

Las capas superiores pueden llamar a las inferiores. **Nunca al revés.**

- `rag` **no** sabe que existe un gateway.
- `router` **no** sabe que existe MCP.
- `inference` **no** sabe que existe RAG.

Cada módulo hace una cosa. La comunicación entre ellos es por funciones puras o por GenServer + mensajes (nunca por estado global compartido fuera de `Config`, `Context` y `EnginePool`).

---

## 9. Configuración TOML

### 9.1 Ubicación y resolución

**Ruta por defecto**: `~/.config/candil/candil.toml`.

**Override por env var**: `CANDIL_CONFIG=/path/to/file.toml`.

**Override por CLI**: `candil --config /path/to/file.toml <command>`.

### 9.2 Formato completo

```toml
# ~/.config/candil/candil.toml

# ─── Información global ────────────────────────────────────────
[general]
default_consumer = "default"
data_dir = "~/.candil"
log_level = "info"
log_file = "~/.candil/logs/candil.log"

# ─── Persistencia (opcional) ───────────────────────────────────
[persistence]
# ETS por defecto. Solo si se declara `backend = "postgres"` se levanta.
backend = "ets"                       # "ets" | "postgres"
# [persistence.postgres]
# url = "postgres://user:pass@localhost/candil"
# pool_size = 5

# ─── Engines (uno por binario) ─────────────────────────────────
[engine.llama_server]
binary_dir = "~/.candil/llm/bin"
use_precompiled = true
precompiled_version = "latest"        # o "b4561"
host = "127.0.0.1"
base_port = 10000                     # auto-puertos desde aquí

[engine.external_vllm]
launcher = "Candil.Engine.Launcher.Noop"
base_url = "http://192.168.1.10:8000"

# ─── Modelos locales ───────────────────────────────────────────
[model.coder]
type = "local"
engine = "llama_server"
context_size = 131072
port = 9999
usage = ["chat", "code"]

[model.coder.source]
kind = "huggingface_gguf"
repo = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
file = "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
dest = "~/.candil/models/qwencoder"
# sha256 = "abc123..."                 # opcional

[model.coder.args]
"--n-gpu-layers" = "-1"
"--n-cpu-moe" = "30"
"--cache-type-k" = "q8_0"
"--cache-type-v" = "q8_0"
"--jinja" = true
"--reasoning-format" = "deepseek"
"--temp" = "0.7"
"--top-p" = "0.8"
"--n-predict" = "8192"

[model.verifier]
type = "local"
engine = "llama_server"
context_size = 131072
port = 9998
usage = ["chat", "reasoning"]

[model.verifier.source]
kind = "huggingface_gguf"
repo = "bartowski/openai_gpt-oss-20b-GGUF-MXFP4-Experimental"
file = "openai_gpt-oss-20b-MXFP4.gguf"
dest = "~/.candil/models/gpt-oss"

[model.verifier.args]
"--n-gpu-layers" = "99"
"--chat-template-kwargs" = '{"reasoning_effort":"high"}'
"--jinja" = true

[model.embed]
type = "local"
engine = "llama_server"
context_size = 8192
port = 9990
usage = ["embeddings"]

[model.embed.source]
kind = "huggingface_gguf"
repo = "jinaai/jina-code-embeddings-1.5b-GGUF"
file = "jina-code-embeddings-1.5b-Q8_0.gguf"
dest = "~/.candil/models/embed"

[model.embed.args]
"--embedding" = true
"--pooling" = "last"
"--embd-normalize" = "2"
"--parallel" = "4"

# ─── Modelos remotos ──────────────────────────────────────────
[model.gpt4o]
type = "remote"
name = "gpt-4o"
provider = "openai"
context_size = 128000
usage = ["chat", "completion"]

[model.claude_sonnet]
type = "remote"
name = "claude-3-5-sonnet-latest"
provider = "anthropic"
context_size = 200000
usage = ["chat", "reasoning"]

# ─── Providers remotos ─────────────────────────────────────────
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

# ─── Router ─────────────────────────────────────────────────────
[router]
enabled = true
default_strategy = "auto"             # auto | first_match | cheapest | fastest
confidence_threshold = 0.7
enable_cache = true
cache_ttl_seconds = 300

# Reglas: si task contiene estas palabras, va a este modelo.
[router.rules.code]
match = ["code", "function", "refactor", "bug", "compile"]
model = "coder"

[router.rules.reasoning]
match = ["reason", "explain", "why", "analyze"]
model = "verifier"

[router.rules.fast]
match = ["quick", "short", "summarize"]
model = "gpt4o"

# ─── Context ────────────────────────────────────────────────────
[context]
enabled = true
max_sessions = 1000                   # LRU de sesiones
session_ttl_seconds = 86400           # 24h
summarize_after_messages = 50
summarize_after_tokens = 8000
summarizer_model = "verifier"          # alias de un modelo barato

# ─── Gateway ────────────────────────────────────────────────────
[gateway]
enabled = false
host = "127.0.0.1"
port = 7777
auth = "api_key"                       # api_key | jwt | none
api_keys = ["candil-xxx", "candil-yyy"]

# ─── MCP ────────────────────────────────────────────────────────
[mcp.server]
transport = "stdio"                    # stdio | http
# [mcp.server.http]
# host = "127.0.0.1"
# port = 7778
# auth = { env = "CANDIL_MCP_KEY" }

# [mcp.client.filesystem]
# transport = "stdio"
# command = "npx"
# args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]

# ─── RAG ────────────────────────────────────────────────────────
[rag]
backend = "memory"                     # memory | pgvector
embedding_model = "embed"
chunk_size = 512
chunk_overlap = 50
top_k = 10

# ─── Consumers ──────────────────────────────────────────────────
[consumer.default]
model_default = "coder"
max_concurrent = 4
rate_limit_per_minute = 100

[consumer.posadero]
model_default = "verifier"
max_concurrent = 2
rate_limit_per_minute = 60

[consumer.opencode]
model_default = "coder"
max_concurrent = 8
rate_limit_per_minute = 300

[consumer.cli]
model_default = "coder"

# ─── Telemetry ──────────────────────────────────────────────────
[telemetry]
enabled = true
prometheus = false
```

### 9.3 El bloque `[model.<alias>.source]` — 5 kinds

**1. GGUF de Hugging Face** (el caso de ropero):

```toml
[model.coder.source]
kind = "huggingface_gguf"
repo = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
file = "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
dest = "~/.candil/models/qwencoder"
sha256 = "abc123..."                   # opcional
```

**2. safetensors de Hugging Face** (clone normal del repo):

```toml
[model.llama3_8b.source]
kind = "huggingface_safetensors"
repo = "meta-llama/Meta-Llama-3-8B-Instruct"
dest = "~/.candil/models/llama3-8b"
```

**3. Archivo único por URL**:

```toml
[model.custom.source]
kind = "url"
url = "https://example.com/model.gguf"
file = "model.gguf"
dest = "~/.candil/models/custom"
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

### 9.4 Flujo de carga

```mermaid
sequenceDiagram
    participant App as Candil.Application
    participant CFG as Candil.Config (GenServer)
    participant FILE as Candil.Config.File
    participant SCH as Candil.Config.Schema
    participant ETS as ETS tables

    App->>CFG: start_link()
    CFG->>ETS: :ets.new(:candil_llm_engines)
    CFG->>ETS: :ets.new(:candil_llm_models)
    CFG->>ETS: :ets.new(:candil_llm_providers)

    Note over CFG: 1. Carga retrocompat config.exs
    CFG->>CFG: load_from_app_config()

    Note over CFG: 2. Carga TOML (sobreescribe)
    CFG->>FILE: load()
    FILE->>FILE: File.read("~/.config/candil/candil.toml")
    FILE->>SCH: validate(toml_map)
    SCH-->>FILE: {:ok, validated}
    FILE-->>CFG: {:ok, config}
    CFG->>ETS: hydrate_from_toml(config)

    CFG-->>App: {:ok, %{}}
```

**Prioridad** (de menor a mayor):

1. Defaults en el struct.
2. `config.exs` de Elixir (retrocompat).
3. TOML.
4. Registro programático en runtime (`Config.register_model/1`).

### 9.5 Escritura atómica

```elixir
def save(config, file \\ nil) do
  file = file || path()
  File.mkdir_p!(Path.dirname(file))
  content = Toml.encode(config)
  tmp = file <> ".tmp"
  File.write!(tmp, content)
  File.rename!(tmp, file)   # rename atómico en POSIX
  :ok
end
```

### 9.6 Migración desde ropero

**Comando**:

```bash
mix candil.migrate --from-ropero ~/cacafuti/lasaca/ropero/ropero.d/ --output ~/.config/candil/candil.toml
```

**Algoritmo**:

```mermaid
flowchart TD
    A[ropero.d/*.sh] --> B[Excluir _*.sh, 00-*, 01-*, NN-*-*.sh]
    B --> C[Para cada .sh de modelo]
    C --> D[Parsear MODEL_ENGINE]
    D --> E{engine == llama-server?}
    E -->|sí| F[Parsear MODEL_GGUF, MODEL_CTX, MODEL_ALIAS, MODEL_PORT]
    E -->|no| G[Parsear MODEL_PATH, MODEL_CTX, MODEL_ENGINE]
    F --> H[Extraer get_model_args_X con grep/sed]
    G --> H
    H --> I[Convertir args bash → args TOML map]
    I --> J[Detectar source.kind: si MODEL_GGUF → huggingface_gguf o already_present]
    J --> K[Generar bloque model.X]
    K --> L[Ensamblar TOML]
    L --> M[Candil.Config.Schema.validate]
    M -->|ok| N[Escribir TOML]
    M -->|error| O[Reportar y abortar]
```

**Detalles del parseo** (sin eval de bash, **por seguridad**):

```elixir
defp parse_script(path) do
  content = File.read!(path)
  alias_name = Path.basename(path, ".sh") |> String.replace("-", "_")

  engine = extract_var(content, "MODEL_ENGINE") || "llama-server"
  gguf = extract_var(content, "MODEL_GGUF")
  ctx = extract_int(content, "MODEL_CTX")
  alias_val = extract_var(content, "MODEL_ALIAS")
  port = extract_int(content, "MODEL_PORT")

  args = extract_args(content, "get_model_args_#{alias_name}")

  %{
    alias: alias_val || alias_name,
    engine: engine,
    gguf: gguf,
    ctx: ctx,
    port: port,
    args: args
  }
end
```

**Regex de extracción**:

```elixir
~r/^\s*MODEL_GGUF\s*=\s*"([^"]+)"\s*$/m
~r/^\s*MODEL_ALIAS\s*=\s*"\$\{MODEL_ALIAS:-([^}]+)\}"\s*$/m
~r/^\s*MODEL_CTX\s*=\s*"?\$?\{?ROPERO_[A-Z_]+:-?([0-9]+)\}?"?\s*$/m
~r/^\s*MODEL_PORT\s*=\s*([0-9]+)\s*$/m
```

**Conversión de args**:

Los `.sh` usan:

```bash
local -a args=(
    --n-gpu-layers 99
    --cache-type-k q8_0
    --jinja
    --chat-template-kwargs '{"enable_thinking": false}'
)
printf '%s\n' "${args[@]}"
```

Se convierte a:

```toml
[model.X.args]
"--n-gpu-layers" = "99"
"--cache-type-k" = "q8_0"
"--jinja" = true
"--chat-template-kwargs" = '{"enable_thinking": false}'
```

Reglas:

- `--flag` seguido de valor → `"--flag" = "valor"`.
- `--flag` solo (booleano) → `"--flag" = true`.
- Valores con comillas JSON (`'{"enable_thinking": false}'`) → se preserva como string TOML.
- Valores env var (`"$N_CPU_MOE"`) → se resuelve al default del script o se comenta.

---

## 10. Multi-consumidor

### 10.1 Modelo

Cada petición lleva un `consumer` (atom). El consumer se propaga por:

```mermaid
graph LR
    CALL[chat(:coder, msgs, consumer: :posadero)]
    CALL --> ROUTER[Router]
    CALL --> CTX[Context]
    CALL --> COST[Cost]
    CALL --> RL[RateLimiter]
    CALL --> MET[Metrics]

    CTX --> KEY["key = {consumer, session_id}"]
```

**Efectos**:

- **Context.Store** aísla por consumer. Dos sesiones separadas.
- **EnginePool** comparte engines (un modelo cargado sirve a los dos consumers).
- **Cost** agrega por consumer.
- **RateLimiter** limita por consumer.
- **Metrics** etiqueta por consumer.

**Consumer por defecto**: `:default`, configurable en `[general] default_consumer`.

### 10.2 Por consumer en el TOML

```toml
[consumer.posadero]
model_default = "verifier"
max_concurrent = 2
rate_limit_per_minute = 60
```

Aplicado por el `Candil.Router.Consumer` y el `Candil.Gateway.Auth`.

### 10.3 Endpoint por consumer en el gateway

```
POST /c/:consumer/v1/chat/completions
```

Si no se especifica consumer (`POST /v1/chat/completions`), se usa el `default_consumer`.

---

## 11. Puertos y EnginePool

### 11.1 Convención de puertos

| Rango       | Uso                                                              |
| ----------- | ---------------------------------------------------------------- |
| 7777        | Gateway HTTP                                                     |
| 7778        | MCP HTTP (opt-in)                                                |
| 9990-9997   | Modelos pineados (ropero actual usa 9990 embed, 9991 qwenvision) |
| 9998        | CPU slot (default)                                               |
| 9999        | GPU slot (default)                                               |
| 10000-10099 | Auto-puertos del pool                                            |

**Resolución en `Engine.start/2`**:

```mermaid
flowchart TD
    START[Engine.start(engine, model)] --> CHECK{engine.port == :auto?}
    CHECK -->|sí| FREE[EnginePool.find_free_port(base_port, base_port+99)]
    CHECK -->|no| FIXED[Usar engine.port]
    FREE --> PORT[puerto asignado]
    FIXED --> PORT
    PORT --> SERVER[Server.start_link]
    SERVER --> REG[Registrar en Candil.Registry bajo model.alias]
    REG --> POOL[EnginePool.put alias, pid, engine]
```

### 11.2 EnginePool — registro de vivos

**Nuevo API**:

```elixir
defmodule Candil.EnginePool do
  use GenServer

  # state: %{alias => %{pid: pid, engine: Engine.t, started_at: DateTime.t}}
  #        + max_concurrent: pos_integer()

  @spec put(atom(), pid(), Engine.t()) :: :ok
  @spec delete(atom()) :: :ok
  @spec get(atom()) :: {:ok, pid(), Engine.t()} | :error
  @spec list() :: [{atom(), pid(), Engine.t()}]
  @spec count() :: non_neg_integer()
  @spec find_free_port(pos_integer(), pos_integer()) :: pos_integer() | {:error, :no_free_port}
end
```

**Eviction**: si `count() > max_concurrent` al insertar, se desaloja el `started_at` más antiguo (LRU por tiempo de arranque). El LRU se aplica **solo cuando excede la capacidad**.

### 11.3 Configuración

```toml
[engine_pool]
max_concurrent = 4
```

---

## 12. Módulos nuevos: especificaciones

Esta sección define la API pública de cada módulo nuevo. Las implementaciones detalladas van en las fases.

### 12.1 `Candil.Config.File`

```elixir
defmodule Candil.Config.File do
  @default_path "~/.config/candil/candil.toml"

  @spec path() :: String.t()
  def path do
    System.get_env("CANDIL_CONFIG") || Path.expand(@default_path)
  end

  @spec load(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def load(file \\ nil)

  @spec save(map(), String.t() | nil) :: :ok | {:error, term()}
  def save(config, file \\ nil)

  @spec exists?(String.t() | nil) :: boolean()
  def exists?(file \\ nil)
end
```

### 12.2 `Candil.Config.Schema`

```elixir
defmodule Candil.Config.Schema do
  @spec validate(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(raw)

  @spec engine_schema() :: keyword()
  @spec model_schema() :: keyword()
  @spec provider_schema() :: keyword()
  @spec consumer_schema() :: keyword()
  @spec gateway_schema() :: keyword()
  @spec mcp_schema() :: keyword()
  @spec rag_schema() :: keyword()
end
```

### 12.3 `Candil.Config.Migrate`

```elixir
defmodule Candil.Config.Migrate do
  @spec from_ropero(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def from_ropero(ropero_dir, output_file \\ nil)

  @spec parse_ropero_dir(String.t()) :: [map()]
  def parse_ropero_dir(dir)

  @spec build_toml([map()]) :: String.t()
  def build_toml(parsed_scripts)
end
```

### 12.4 `Candil.Router`

```elixir
defmodule Candil.Router do
  @type decision :: %{
          model_alias: atom(),
          strategy: :cache | :rule | :embedding | :llm | :default,
          score: float(),
          reason: String.t(),
          timestamp: DateTime.t()
        }

  @spec decide([map()], keyword()) :: {:ok, decision()} | {:error, term()}
  def decide(messages, opts \\ [])

  @spec pin(atom(), atom()) :: :ok
  def pin(consumer, model_alias)

  @spec unpin(atom()) :: :ok
  def unpin(consumer)

  @spec stats(atom()) :: map()
  def stats(consumer)
end
```

### 12.5 `Candil.Gateway.Endpoint`

```elixir
defmodule Candil.Gateway.Endpoint do
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts)

  @spec stop() :: :ok
  def stop()
end
```

Rutas expuestas:

| Método | Ruta                               | Handler                         |
| ------ | ---------------------------------- | ------------------------------- |
| POST   | `/c/:consumer/v1/chat/completions` | `Handlers.ChatCompletions`      |
| POST   | `/c/:consumer/v1/messages`         | `Handlers.Messages`             |
| POST   | `/c/:consumer/v1/embeddings`       | `Handlers.Embeddings`           |
| GET    | `/c/:consumer/v1/models`           | `Handlers.Models`               |
| GET    | `/health`                          | `Handlers.Health`               |
| GET    | `/metrics`                         | `Handlers.Metrics`              |
| POST   | `/v1/chat/completions`             | igual, con `consumer = default` |

### 12.6 `Candil.Context.Store`

```elixir
defmodule Candil.Context.Store do
  use GenServer

  # ETS: :candil_context_sessions
  # key: {consumer, session_id}

  @spec create(atom(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def create(consumer, session_id)

  @spec get(atom(), String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get(consumer, session_id)

  @spec append_message(atom(), String.t(), map()) :: :ok
  def append_message(consumer, session_id, message)

  @spec update(atom(), String.t(), map()) :: :ok
  def update(consumer, session_id, attrs)

  @spec delete(atom(), String.t()) :: :ok
  def delete(consumer, session_id)

  @spec list(atom()) :: [Session.t()]
  def list(consumer)

  @spec count(atom()) :: non_neg_integer()
  def count(consumer)

  @spec gc() :: non_neg_integer()
  def gc()
end
```

### 12.7 `Candil.MCP.Server`

```elixir
defmodule Candil.MCP.Server do
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts)
  # opts:
  #   transport: :stdio | :http
  #   port: pos_integer()          # solo si transport: :http
  #   tools: [module()] | :registered  # :registered usa Candil.Tool.list()
end
```

### 12.8 `Candil.MCP.Client`

```elixir
defmodule Candil.MCP.Client do
  @spec connect(keyword()) :: {:ok, client()} | {:error, term()}
  def connect(opts)
  # opts:
  #   transport: :stdio | :http
  #   command: String.t() + args: [String.t()]     # stdio
  #   url: String.t()                              # http

  @spec list_tools(client()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(client)

  @spec call_tool(client(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(client, name, args)

  @spec disconnect(client()) :: :ok
  def disconnect(client)
end
```

### 12.9 `Candil.RAG`

```elixir
defmodule Candil.RAG do
  @spec create_index(String.t(), keyword()) :: :ok | {:error, term()}
  def create_index(name, opts \\ [])

  @spec index(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def index(name, path_or_text, opts \\ [])

  @spec search(String.t(), String.t(), keyword()) :: {:ok, [Chunk.t()]} | {:error, term()}
  def search(name, query, opts \\ [])

  @spec drop_index(String.t()) :: :ok
  def drop_index(name)

  @spec list_indexes() :: [String.t()]
  def list_indexes()
end
```

### 12.10 `Candil.CLI`

```elixir
defmodule Candil.CLI do
  use Alaja.CLI.Definition, otp_app: :candil, halt_on_error: true

  # Comandos:
  #   models list | pull | info | rm
  #   run <alias> [--background] [--cpu] [--port N]
  #   stop <alias>|all
  #   status [--json] [--watch [ms]]
  #   config show | edit | validate | migrate
  #   router stats | test | tune
  #   gateway start | stop | status
  #   mcp serve | call
  #   rag index | query | list | drop
  #   doctor
  #   version
end
```

---

# Parte III — Plan de ejecución

Cada fase se compone de **tareas atómicas** con:

- **Archivos a tocar**.
- **Cambios concretos**.
- **Tests a añadir/actualizar**.
- **Criterio de done** (comando exacto que debe pasar).

---

## 13. Fase 0 — Saneamiento

**Objetivo**: que Candil 3.0.1 funcione sin bugs conocidos. Sin añadir features.

**Días estimados**: 1-2.

### 13.1 — Baseline

```bash
cd ~/cacafuti/candil
mix deps.get
mix compile --warnings-as-errors 2>&1 | tee docs/baseline/compile.txt
mix test 2>&1 | tee docs/baseline/test.txt
mix credo --strict 2>&1 | tee docs/baseline/credo.txt
mix dialyzer 2>&1 | tee docs/baseline/dialyzer.txt
```

**Resultado esperado** (según snapshot):

- `mix compile`: OK (sin warnings).
- `mix test`: **279 tests, 22 failures**.
- `mix credo --strict`: 4 refactoring + 26 readability + 7 design.
- `mix dialyzer`: passed.

**Guardar el output** en `docs/baseline/` para comparar después.

### 13.2 — Arreglar tests rotos (7 fallos documentados + 15 por descubrir)

**Archivos a tocar**: `test/candil/**/*.exs`.

**Bug identificado 1** — `test/candil/config_test.exs:9`:

```elixir
# Actual:
:ets.delete_all_objects(:apero_llm_engines, :undefined)

# Correcto:
:ets.delete_all_objects(:candil_llm_engines)
```

**Bug identificado 2** — `test/candil/engine_test.exs:39-42`:

```elixir
# Actual:
expected = Path.join([System.user_home!(), ".apero", "llm", "bin"])
assert Engine.binary_dir(engine) == expected

# Correcto:
expected = Path.join([System.user_home!(), ".candil", "llm", "bin"])
assert Engine.binary_dir(engine) == expected
```

**Bug 3-22** — desconocidos. Ejecutar `mix test --trace` y arreglar uno a uno.

**Regla**: **no cambiar el código de producción** para pasar tests, salvo que el test documente explícitamente un comportamiento que el código viola.

### 13.3 — Arreglar `Backend.LlamaCpp.chat/3` y `chat_stream/3`

**Archivo**: `lib/candil/backend/llama_cpp.ex`.

**Código nuevo**:

```elixir
defmodule Candil.Backend.LlamaCpp do
  @behaviour Candil.Backend

  alias Candil.{Config, Inference.Chat, Stream, Embeddings, Error}

  @impl true
  def chat(model, messages, opts) do
    model_alias = resolve_alias(model)

    case Config.get_model(model_alias) do
      {:ok, _m} -> Chat.do_chat_local(model_alias, messages, opts)
      {:error, _} -> {:error, Error.model_not_found(model_alias)}
    end
  end

  @impl true
  def chat_stream(model, messages, opts) do
    model_alias = resolve_alias(model)
    callback = Keyword.get(opts, :callback, fn _chunk -> :ok end)

    Stream.chat(model_alias, messages, callback, opts)
    # Stream.chat/4 es síncrono (bloquea hasta done). Para cumplir el
    # contrato del behaviour ({:ok, Enumerable.t}), envolvemos en un
    # Stream.resource que corre la petición en un Task.
    |> case do
      :ok -> {:ok, run_stream_async(model_alias, messages, callback, opts)}
      {:error, _} = err -> err
    end
  end

  @impl true
  def embed(model, texts, opts) when is_list(texts) do
    case Embeddings.do_embed_local(resolve_alias(model), texts) do
      {:ok, vectors} -> {:ok, vectors}
      {:error, _} = err -> err
    end
  end

  @impl true
  def models do
    Config.list_models()
  end

  # ── Helpers ───────────────────────────────────────────────────

  defp resolve_alias(%Candil.Model{alias: a}), do: a
  defp resolve_alias(a) when is_atom(a), do: a
  defp resolve_alias(a) when is_binary(a), do: String.to_existing_atom(a)

  defp run_stream_async(model_alias, messages, callback, opts) do
    Stream.resource(
      fn ->
        task = Task.async(fn ->
          Stream.chat(model_alias, messages, callback, opts)
        end)
        %{task: task, sent: false}
      end,
      fn %{task: task, sent: false} = state ->
        result = Task.await(task, 120_000)
        {[{result}], %{state | sent: true}}
      end,
      fn %{task: task, sent: false} ->
        Task.shutdown(task, :brutal_kill)
      end
    )
  end
end
```

**Tests**: actualizar `test/candil/backend/llama_cpp_test.exs` para verificar que `chat/3` delega y que `chat_stream/3` devuelve un `Enumerable.t()`.

### 13.4 — Arreglar `Backend.OpenAICompat.chat_stream/3`

**Archivo**: `lib/candil/backend/openai_compat.ex`.

**Código nuevo** (reemplaza el `build_chunk_stream/1` stub):

```elixir
@impl true
def chat_stream(model, messages, opts) when is_list(messages) do
  with {:ok, base_url, token} <- config_for(provider_of(model), opts) do
    url = "#{base_url}/v1/chat/completions"
    body = build_body(model, messages, Keyword.put(opts, :stream, true))
    headers = auth_headers(token)
    request_id = Keyword.get(opts, :request_id, "stream-#{System.unique_integer()}")

    Telemetry.emit_start(request_id, :stream, %{model: model_id(model)})
    started = System.monotonic_time()

    case HTTP.post_streaming(
           url, body, headers,
           [timeout_ms: opts[:timeout_ms] || 120_000, retry: false],
           into: receive_inbox(self())
         ) do
      {:ok, _} ->
        Telemetry.emit_stop(request_id, :stream, System.monotonic_time() - started, [])
        {:ok, sse_enumerable()}

      {:error, reason} ->
        Telemetry.emit_error(request_id, :stream, System.monotonic_time() - started, :http, %{})
        {:error, reason}
    end
  end
end

defp receive_inbox(consumer_pid) do
  fn
    {:data, data}, _acc ->
      send(consumer_pid, {:sse_data, data})
      ""

    :done, _acc ->
      send(consumer_pid, {:sse_done, self()})
      ""

    {:error, reason}, _acc ->
      send(consumer_pid, {:sse_error, reason, self()})
      ""
  end
end

defp sse_enumerable do
  Stream.repeatedly(fn ->
    receive do
      {:sse_data, data} -> {:data, data}
      {:sse_done, _} -> :done
      {:sse_error, reason, _} -> {:error, reason}
    after
      120_000 -> :done
    end
  end)
  |> Stream.transform(nil, fn
    {:data, data}, acc -> {[parse_openai_chunk(data)], acc}
    :done, acc -> {:halt, acc}
    {:error, reason}, acc -> {[{:error, reason}], acc}
  end)
end
```

**Nota**: si el parser SSE ya está en `Candil.Stream`, se puede reusar.

### 13.5 — Arreglar `Backend.OpenAICompat.embed/3`

**Archivo**: `lib/candil/backend/openai_compat.ex`.

**Reemplazar el `Enum.map`** por una sola request:

```elixir
@impl true
def embed(model, texts, opts) when is_list(texts) do
  with {:ok, base_url, token} <- config_for(provider_of(model), opts) do
    url = "#{base_url}/v1/embeddings"
    body = %{model: model_id(model), input: texts, encoding_format: "float"}
    headers = auth_headers(token)

    case HTTP.post_json(url, body, headers,
           timeout_ms: opts[:timeout_ms] || 60_000,
           retry: Keyword.get(opts, :retry, true)
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, Enum.map(data, & &1["embedding"])}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.http_error(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

**Excepción**: Ollama usa `/api/embeddings` con `prompt` (un texto por request). El `Candil.Inference.Embeddings.do_embed_remote/4` ya lo maneja. Para `OpenAICompat.embed/3` con provider Ollama, mantener el fallback (aunque no es común).

**Test**:

```elixir
test "batch embed makes a single request" do
  expect(HTTPAdapterMock, :request, fn %Request{body: body} ->
    assert body["input"] == ["a", "b", "c"]
    {:ok, %Response{status: 200, body: %{
      "data" => [
        %{"embedding" => [0.1, 0.2]},
        %{"embedding" => [0.3, 0.4]},
        %{"embedding" => [0.5, 0.6]}
      ]
    }}}
  end)

  assert {:ok, [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]} =
    OpenAICompat.embed(model(), ["a", "b", "c"], [])
end
```

### 13.6 — Arreglar `Config.register_provider/1` (aceptar strings)

**Archivo**: `lib/candil/config.ex`.

**Cambio**:

```elixir
defp validate_api_key(nil), do: :ok
defp validate_api_key({:system, var}) when is_binary(var), do: :ok
defp validate_api_key(s) when is_binary(s), do: :ok
defp validate_api_key(_), do: {:error, "api_key must be string, {:system, VAR}, or nil"}
```

**`get_provider/1`**:

```elixir
defp resolve_provider(%Provider{api_key: {:system, var}} = p),
  do: %{p | api_key: System.get_env(var)}
defp resolve_provider(p), do: p
```

**Test**:

```elixir
test "accepts a plain string api_key" do
  provider = %Provider{alias: :openai, type: :openai,
                        base_url: "https://api.openai.com",
                        api_key: "sk-test"}
  assert :ok = Config.register_provider(provider)
  assert {:ok, %Provider{api_key: "sk-test"}} = Config.get_provider(:openai)
end
```

### 13.7 — Arreglar `Detector` (trebejo opcional)

**Archivo**: `lib/candil/detector.ex` + `mix.exs`.

**`mix.exs`**:

```elixir
{:trebejo, github: "Lorenzo-SF/trebejo", optional: true, runtime: false}
```

**`detector.ex`**:

```elixir
defp safe_arch do
  if Code.ensure_loaded?(Trebejo.OS) and function_exported?(Trebejo.OS, :arch, 0) do
    {:ok, apply(Trebejo.OS, :arch, [])}
  else
    {:error, :trebejo_not_available}
  end
end

@spec detect() :: detection() | {:error, term()}
def detect do
  os = Apero.OS.type()

  with {:ok, arch} <- safe_arch() do
    {gpu, cuda_version} = GPU.detect_gpu(os)

    %{
      os: os,
      arch: arch,
      gpu: gpu,
      cuda_version: cuda_version,
      asset_pattern: Models.build_asset_pattern(os, arch, gpu, cuda_version)
    }
  end
end
```

**`installer.ex`** — si `detect()` devuelve `{:error, :trebejo_not_available}`, fallar con mensaje claro:

```elixir
def download_engine(%Engine{} = engine) do
  case Detector.detect() do
    {:error, :trebejo_not_available} ->
      {:error, "No puedo detectar arquitectura: 'trebejo' no está instalado. " <>
               "Añade {:trebejo, github: \"Lorenzo-SF/trebejo\"} a tus deps, " <>
               "o declara el binario manualmente en engine.binary_dir."}
    {:error, reason} ->
      {:error, "Detección falló: #{inspect(reason)}"}
    detection ->
      # ... proceder
  end
end
```

### 13.8 — Reescribir `EnginePool` como registro de vivos

**Archivo**: `lib/candil/engine_pool.ex`.

**Código nuevo**:

```elixir
defmodule Candil.EnginePool do
  use GenServer
  require Logger

  @max_concurrent_default 4

  # ── Client API ────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(atom(), pid(), Candil.Engine.t()) :: :ok
  def put(alias_name, pid, engine) do
    GenServer.cast(__MODULE__, {:put, alias_name, pid, engine})
  end

  @spec delete(atom()) :: :ok
  def delete(alias_name) do
    GenServer.cast(__MODULE__, {:delete, alias_name})
  end

  @spec get(atom()) :: {:ok, pid(), Candil.Engine.t()} | :error
  def get(alias_name) do
    GenServer.call(__MODULE__, {:get, alias_name})
  end

  @spec list() :: [{atom(), pid(), Candil.Engine.t()}]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @spec find_free_port(pos_integer(), pos_integer()) :: {:ok, pos_integer()} | {:error, :no_free_port}
  def find_free_port(range_start, range_end) do
    used =
      __MODULE__
      |> GenServer.call(:list)
      |> Enum.map(fn {_alias, _pid, %{port: port}} -> port end)

    free =
      (range_start..range_end)
      |> Enum.find(fn port -> port not in used and not port_listening?(port) end)

    case free do
      nil -> {:error, :no_free_port}
      port -> {:ok, port}
    end
  end

  # ── Server Callbacks ──────────────────────────────────────────

  @impl true
  def init(opts) do
    max = Keyword.get(opts, :max_concurrent, @max_concurrent_default)
    {:ok, %{engines: %{}, max_concurrent: max}}
  end

  @impl true
  def handle_cast({:put, alias_name, pid, engine}, state) do
    engines = Map.put(state.engines, alias_name, %{
      pid: pid, engine: engine, started_at: DateTime.utc_now()
    })

    engines = maybe_evict_lru(engines, state.max_concurrent)
    {:noreply, %{state | engines: engines}}
  end

  def handle_cast({:delete, alias_name}, state) do
    {:noreply, %{state | engines: Map.delete(state.engines, alias_name)}}
  end

  @impl true
  def handle_call({:get, alias_name}, _from, state) do
    case Map.get(state.engines, alias_name) do
      nil -> {:reply, :error, state}
      %{pid: pid, engine: engine} -> {:reply, {:ok, pid, engine}, state}
    end
  end

  def handle_call(:list, _from, state) do
    list = Enum.map(state.engines, fn {k, %{pid: p, engine: e}} -> {k, p, e} end)
    {:reply, list, state}
  end

  def handle_call(:count, _from, state) do
    {:reply, map_size(state.engines), state}
  end

  # ── Internals ─────────────────────────────────────────────────

  defp maybe_evict_lru(engines, max) when map_size(engines) <= max, do: engines

  defp maybe_evict_lru(engines, max) do
    {oldest_alias, _} =
      engines
      |> Enum.min_by(fn {_k, %{started_at: t}} -> DateTime.to_unix(t) end)

    Logger.info("[EnginePool] Evicting LRU: #{oldest_alias}")
    Map.delete(engines, oldest_alias)
  end

  defp port_listening?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 100) do
      {:ok, socket} -> :gen_tcp.close(socket); true
      {:error, _} -> false
    end
  end
end
```

**Tests**:

```elixir
test "put/get/list/delete" do
  pid = self()
  engine = %Candil.Engine{alias: :test, port: 9999}
  :ok = EnginePool.put(:test, pid, engine)
  assert {:ok, ^pid, ^engine} = EnginePool.get(:test)
  assert [{:test, ^pid, ^engine}] = EnginePool.list()
  assert 1 = EnginePool.count()
  :ok = EnginePool.delete(:test)
  assert :error = EnginePool.get(:test)
end
```

### 13.9 — Tag `candil-3.0.1`

```bash
git add .
git commit -m "fix(candil): 6 bugs pre-4.0 (backend stubs, config, detector, pool, tests)"
git tag candil-3.0.1
git push origin main --tags
```

**Criterio de done**:

```bash
mix compile --warnings-as-errors   # OK
mix test                            # 279 tests, 0 failures
mix credo --strict                  # 0 issues
mix dialyzer                        # 0 errores
git tag -l | grep candil-3.0.1      # aparece
```

---

## 14. Fase 1 — Config TOML

**Objetivo**: Candil lee `~/.config/candil/candil.toml`. `mix candil.migrate` convierte los `.sh` de ropero.

**Días estimados**: 2-3.

### 14.1 — Dependencias

**Archivo**: `mix.exs`.

```elixir
defp deps do
  [
    {:apero, github: "Lorenzo-SF/apero"},
    {:arrea, github: "Lorenzo-SF/arrea"},
    {:jason, "~> 1.4"},
    {:toml, "~> 0.7"},
    {:nimble_options, "~> 1.1"},
    {:trebejo, github: "Lorenzo-SF/trebejo", optional: true, runtime: false},
    # ... resto
  ]
end
```

### 14.2 — `Candil.Config.Schema`

**Archivo nuevo**: `lib/candil/config/schema.ex`.

```elixir
defmodule Candil.Config.Schema do
  @moduledoc false

  @engine_schema [
    binary_dir: [type: :string, default: "~/.candil/llm/bin"],
    use_precompiled: [type: :boolean, default: true],
    precompiled_version: [type: {:or, [:atom, :string]}, default: "latest"],
    host: [type: :string, default: "127.0.0.1"],
    base_port: [type: :integer, default: 10000],
    start_args: [type: {:list, :string}, default: []],
    launcher: [type: :atom]
  ]

  @model_schema [
    type: [type: {:in, [:local, :remote]}, required: true],
    engine: [type: :atom],
    provider: [type: :atom],
    name: [type: :string],
    context_size: [type: :pos_integer, default: 4096],
    port: [type: {:or, [:integer, :atom]}, default: :auto],
    usage: [type: {:list, {:in, [:chat, :completion, :embeddings, :reasoning, :vision, :code, :translation, :summarisation]}}, default: [:chat, :completion]],
    source: [type: :map],
    args: [type: :map, default: %{}]
  ]

  @provider_schema [
    type: [type: {:in, [:openai, :anthropic, :ollama, :openai_compatible, :azure_openai]}, required: true],
    base_url: [type: :string, required: true],
    api_key: [type: {:or, [:string, :map, nil]}],
    org_id: [type: :string],
    api_version: [type: :string],
    timeout_ms: [type: :pos_integer, default: 60_000],
    headers: [type: {:list, :any}, default: []]
  ]

  @consumer_schema [
    model_default: [type: :atom],
    max_concurrent: [type: :pos_integer, default: 4],
    rate_limit_per_minute: [type: :pos_integer, default: 60]
  ]

  @gateway_schema [
    enabled: [type: :boolean, default: false],
    host: [type: :string, default: "127.0.0.1"],
    port: [type: :pos_integer, default: 7777],
    auth: [type: {:in, [:api_key, :jwt, :none]}, default: "api_key"],
    api_keys: [type: {:list, :string}, default: []]
  ]

  @mcp_schema [
    enabled: [type: :boolean, default: false],
    transport: [type: {:in, [:stdio, :http]}, default: "stdio"],
    port: [type: :pos_integer, default: 7778]
  ]

  @rag_schema [
    backend: [type: {:in, [:memory, :pgvector]}, default: "memory"],
    embedding_model: [type: :atom, default: :embed],
    chunk_size: [type: :pos_integer, default: 512],
    chunk_overlap: [type: :pos_integer, default: 50],
    top_k: [type: :pos_integer, default: 10]
  ]

  @spec validate(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(raw) when is_map(raw) do
    errors =
      []
      |> validate_section(raw, "general", general_schema())
      |> validate_section(raw, "persistence", persistence_schema())
      |> validate_nested(raw, "engine", @engine_schema)
      |> validate_nested(raw, "model", @model_schema)
      |> validate_nested(raw, "provider", @provider_schema)
      |> validate_nested(raw, "consumer", @consumer_schema)
      |> validate_section(raw, "gateway", @gateway_schema)
      |> validate_section(raw, "mcp", @mcp_schema)
      |> validate_section(raw, "rag", @rag_schema)

    if errors == [], do: {:ok, raw}, else: {:error, Enum.reverse(errors)}
  end

  # ... helpers privados: validate_section/4, validate_nested/3, etc.

  defp general_schema do
    [
      default_consumer: [type: :atom, default: :default],
      data_dir: [type: :string, default: "~/.candil"],
      log_level: [type: {:in, [:debug, :info, :warn, :error]}, default: :info],
      log_file: [type: :string]
    ]
  end

  defp persistence_schema do
    [
      backend: [type: {:in, [:ets, :postgres]}, default: "ets"]
    ]
  end
end
```

### 14.3 — `Candil.Config.File`

**Archivo nuevo**: `lib/candil/config/file.ex`.

```elixir
defmodule Candil.Config.File do
  @moduledoc """
  Reads and writes `~/.config/candil/candil.toml`.

  El archivo TOML es la fuente de verdad para el usuario. `Candil.Config`
  (ETS) actúa como cache en memoria, hidratado al arrancar.
  """

  alias Candil.Config.Schema

  @default_path "~/.config/candil/candil.toml"

  @spec path() :: String.t()
  def path do
    System.get_env("CANDIL_CONFIG") || Path.expand(@default_path)
  end

  @spec exists?(String.t() | nil) :: boolean()
  def exists?(file \\ nil) do
    File.exists?(file || path())
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

      {:error, :enoent} ->
        {:ok, empty()}

      {:error, reason} ->
        {:error, {:read, reason}}
    end
  end

  @spec save(map(), String.t() | nil) :: :ok | {:error, term()}
  def save(config, file \\ nil) do
    file = file || path()
    File.mkdir_p!(Path.dirname(file))

    content =
      case Toml.encode(config) do
        binary when is_binary(binary) -> binary
        {:error, reason} -> throw({:toml_encode, reason})
      end

    tmp = file <> ".tmp"

    case File.write(tmp, content) do
      :ok ->
        case File.rename(tmp, file) do
          :ok -> :ok
          {:error, reason} -> {:error, {:rename, reason}}
        end

      {:error, reason} ->
        {:error, {:write, reason}}
    end
  end

  defp empty do
    %{
      "general" => %{"default_consumer" => "default"},
      "engine" => %{},
      "model" => %{},
      "provider" => %{},
      "consumer" => %{},
      "gateway" => %{},
      "mcp" => %{},
      "rag" => %{}
    }
  end
end
```

### 14.4 — Modificar `Candil.Config` (hidratar desde TOML)

**Archivo**: `lib/candil/config.ex`.

**Modificación en `init/1`**:

```elixir
@impl GenServer
def init(_opts) do
  :ets.new(@table_engines, [:named_table, :public, read_concurrency: true])
  :ets.new(@table_models, [:named_table, :public, read_concurrency: true])
  :ets.new(@table_providers, [:named_table, :public, read_concurrency: true])

  # 1. Primero: config.exs (retrocompat) — tests y setups programáticos
  load_from_app_config()

  # 2. Segundo: TOML — sobreescribe
  case Candil.Config.File.load() do
    {:ok, config} -> hydrate_from_toml(config)
    {:error, reason} ->
      require Logger
      Logger.warning("[Candil.Config] Error cargando TOML: #{inspect(reason)}")
  end

  {:ok, %{}}
end

defp hydrate_from_toml(config) do
  # Engines
  config
  |> Map.get("engine", %{})
  |> Enum.each(fn {alias_name, attrs} ->
    engine = %Engine{
      alias: String.to_existing_atom(alias_name),
      binary_dir: attrs["binary_dir"],
      use_precompiled: attrs["use_precompiled"] != false,
      precompiled_version: attrs["precompiled_version"] || :latest,
      host: attrs["host"] || "127.0.0.1",
      port: attrs["port"] || 8080,
      start_args: attrs["start_args"] || [],
      launcher: parse_launcher(attrs["launcher"])
    }
    register_engine(engine)
  end)

  # Models
  config
  |> Map.get("model", %{})
  |> Enum.each(fn {alias_name, attrs} ->
    model = build_model_from_toml(alias_name, attrs)
    register_model(model)
  end)

  # Providers
  config
  |> Map.get("provider", %{})
  |> Enum.each(fn {alias_name, attrs} ->
    provider = build_provider_from_toml(alias_name, attrs)
    register_provider(provider)
  end)
end

defp build_model_from_toml(alias_name, attrs) do
  base = %Model{
    alias: String.to_existing_atom(alias_name),
    type: String.to_atom(attrs["type"]),
    context_size: attrs["context_size"] || 4096,
    usage: Enum.map(attrs["usage"] || ["chat"], &String.to_atom/1),
    model_args: args_map_to_list(attrs["args"] || %{})
  }

  case attrs["type"] do
    "local" ->
      source = attrs["source"] || %{}
      %{base |
        engine: safe_atom(attrs["engine"]),
        model_dir: source["dest"],
        filename: source["file"] || source["path"] |> Path.basename(),
        download_url: build_download_url(source),
        provider: nil
      }

    "remote" ->
      %{base |
        name: attrs["name"],
        provider: safe_atom(attrs["provider"]),
        engine: nil
      }
  end
end

defp build_provider_from_toml(alias_name, attrs) do
  %Provider{
    alias: String.to_existing_atom(alias_name),
    type: String.to_atom(attrs["type"]),
    base_url: attrs["base_url"],
    api_key: parse_api_key(attrs["api_key"]),
    org_id: attrs["org_id"],
    api_version: attrs["api_version"],
    timeout_ms: attrs["timeout_ms"] || 60_000,
    headers: attrs["headers"] || []
  }
end

defp parse_api_key(%{"env" => var}), do: {:system, var}
defp parse_api_key(s) when is_binary(s), do: s
defp parse_api_key(nil), do: nil

defp parse_launcher(nil), do: nil
defp parse_launcher(s) when is_binary(s), do: String.to_existing_atom("Elixir." <> s)

defp safe_atom(nil), do: nil
defp safe_atom(s) when is_binary(s), do: String.to_existing_atom(s)
defp safe_atom(a) when is_atom(a), do: a

defp args_map_to_list(map) when map == %{}, do: []
defp args_map_to_list(map) do
  Enum.flat_map(map, fn
    {k, true} -> [k]
    {k, false} -> []
    {k, v} -> [k, to_string(v)]
  end)
end

defp build_download_url(%{"kind" => "huggingface_gguf", "repo" => repo, "file" => file}) do
  "https://huggingface.co/#{repo}/resolve/main/#{file}"
end
defp build_download_url(_), do: nil
```

### 14.5 — `Candil.Config.Migrate`

**Archivo nuevo**: `lib/candil/config/migrate.ex`.

```elixir
defmodule Candil.Config.Migrate do
  @moduledoc """
  Reads `ropero.d/*.sh` files and generates a `candil.toml`.

  NO evalúa bash. Extrae variables con regex y parsea
  `get_model_args_<name>()` con un parser simple.
  """

  alias Candil.Config.{File, Schema}

  @excluded_prefixes ["_", "00-", "01-", "20-", "21-"]

  @spec from_ropero(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def from_ropero(ropero_dir, output_file \\ nil) do
    with {:ok, models} <- parse_ropero_dir(ropero_dir),
         toml_string <- build_toml(models),
         {:ok, decoded} <- Toml.decode(toml_string),
         {:ok, _} <- Schema.validate(decoded) do
      if output_file do
        File.write!(output_file, toml_string)
        {:ok, output_file}
      else
        {:ok, toml_string}
      end
    end
  end

  @spec parse_ropero_dir(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_ropero_dir(dir) do
    scripts =
      Path.wildcard(Path.join(dir, "*.sh"))
      |> Enum.reject(&excluded?/1)

    if scripts == [] do
      {:error, :no_scripts_found}
    else
      models = Enum.map(scripts, &parse_script/1) |> Enum.reject(&is_nil/1)
      {:ok, models}
    end
  end

  defp excluded?(path) do
    base = Path.basename(path)
    Enum.any?(@excluded_prefixes, &String.starts_with?(base, &1))
  end

  defp parse_script(path) do
    content = File.read!(path)
    file_alias = Path.basename(path, ".sh") |> String.replace("-", "_")

    case extract_var(content, "MODEL_ENGINE") do
      "llama-server" -> parse_llama_server(content, file_alias)
      nil -> parse_llama_server(content, file_alias)  # default
      _other -> parse_external_engine(content, file_alias)
    end
  end

  defp parse_llama_server(content, file_alias) do
    gguf = extract_var(content, "MODEL_GGUF")
    ctx = extract_int_var(content, "MODEL_CTX") || 4096
    alias_val = extract_alias(content) || file_alias
    port = extract_int_var(content, "MODEL_PORT")
    args = extract_args(content, "get_model_args_#{file_alias}")

    %{
      alias: alias_val,
      type: :local,
      engine: "llama_server",
      gguf: gguf,
      context_size: ctx,
      port: port,
      usage: infer_usage(args),
      args: args
    }
  end

  defp parse_external_engine(content, file_alias) do
    engine = extract_var(content, "MODEL_ENGINE")
    path = extract_var(content, "MODEL_PATH")
    ctx = extract_int_var(content, "MODEL_CTX") || 4096
    alias_val = extract_alias(content) || file_alias

    %{
      alias: alias_val,
      type: :local,
      engine: engine,
      path: path,
      context_size: ctx,
      port: nil,
      usage: [:chat],
      args: %{}
    }
  end

  # ── Extractores ───────────────────────────────────────────────

  defp extract_var(content, name) do
    regex = ~r/^\s*#{name}\s*=\s*"([^"]*)"\s*$/m
    case Regex.run(regex, content) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp extract_int_var(content, name) do
    regex = ~r/^\s*#{name}\s*=\s*"?\$?\{?[A-Z_:]*:-?([0-9]+)\}?"?\s*$/m
    case Regex.run(regex, content) do
      [_, value] -> String.to_integer(value)
      nil -> nil
    end
  end

  defp extract_alias(content) do
    regex = ~r/^\s*MODEL_ALIAS\s*=\s*"\$\{MODEL_ALIAS:-([^}]+)\}"\s*$/m
    case Regex.run(regex, content) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp extract_args(content, func_name) do
    # Busca `get_model_args_X() { ... printf '%s\n' "${args[@]}" }`
    regex = ~r/#{func_name}\(\)\s*\{([^}]+)\}/ms

    case Regex.run(regex, content) do
      [_, body] ->
        # Encontrar el array `local -a args=( ... )`
        array_regex = ~r/local\s+-a\s+args\s*=\s*\(([^)]+)\)/ms
        case Regex.run(array_regex, body) do
          [_, args_block] -> parse_args_block(args_block)
          nil -> %{}
        end
      nil -> %{}
    end
  end

  defp parse_args_block(block) do
    tokens = tokenize_args(block)
    pair_tokens(tokens, %{})
  end

  defp tokenize_args(block) do
    # Regex que captura:
    #   --flag 'value con espacios'   → ["--flag", "value con espacios"]
    #   --flag "value"                → ["--flag", "value"]
    #   --flag value                  → ["--flag", "value"]
    #   --flag                        → ["--flag"]
    regex = ~r/(--[a-z0-9-]+)(?:\s+('[^']*'|"[^"]*"|\S+))?/i

    Regex.scan(regex, block)
    |> Enum.map(fn
      [_, flag] -> {flag, true}
      [_, flag, value] -> {flag, strip_quotes(value)}
    end)
  end

  defp pair_tokens(tokens, acc) do
    Enum.reduce(tokens, acc, fn {flag, value}, acc ->
      Map.put(acc, flag, value)
    end)
  end

  defp strip_quotes(s) do
    s
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp infer_usage(args) do
    cond do
      Map.get(args, "--embedding") -> [:embeddings]
      Map.get(args, "--mmproj") -> [:chat, :vision]
      true -> [:chat, :completion]
    end
  end

  # ── Build TOML ────────────────────────────────────────────────

  @spec build_toml([map()]) :: String.t()
  def build_toml(models) do
    header() <> Enum.map_join(models, "\n", &model_block/1)
  end

  defp header do
    """
    # Generado por `mix candil.migrate --from-ropero`
    # Revisar y ajustar a mano antes de usar en producción.

    [general]
    default_consumer = "default"
    data_dir = "~/.candil"

    [engine.llama_server]
    binary_dir = "~/.candil/llm/bin"
    use_precompiled = true

    """
  end

  defp model_block(%{type: :local, engine: "llama_server"} = m) do
    """
    [model.#{m.alias}]
    type = "local"
    engine = "llama_server"
    context_size = #{m.context_size}
    #{port_line(m.port)}usage = #{usage_toml(m.usage)}

    [model.#{m.alias}.source]
    kind = "already_present"
    path = "~/.candil/models/#{m.gguf}"

    #{args_block(m.alias, m.args)}

    """
  end

  defp model_block(%{type: :local, engine: engine} = m) do
    """
    [model.#{m.alias}]
    type = "local"
    engine = "#{engine}"
    context_size = #{m.context_size}
    usage = ["chat"]

    [model.#{m.alias}.source]
    kind = "already_present"
    path = "#{m.path}"

    """
  end

  defp port_line(nil), do: ""
  defp port_line(port), do: "port = #{port}\n"

  defp usage_toml(usages) do
    "[" <> Enum.map_join(usages, ", ", &"\"#{&1}\"") <> "]"
  end

  defp args_block(_alias_name, args) when map_size(args) == 0, do: ""

  defp args_block(alias_name, args) do
    lines =
      Enum.map_join(args, "\n", fn
        {flag, true} -> "\"#{flag}\" = true"
        {flag, value} -> "\"#{flag}\" = \"#{escape_toml(value)}\""
      end)

    "[model.#{alias_name}.args]\n#{lines}\n"
  end

  defp escape_toml(s), do: String.replace(s, "\"", "\\\"")
end
```

### 14.6 — Mix task

**Archivo nuevo**: `lib/mix/tasks/candil.migrate.ex`.

```elixir
defmodule Mix.Tasks.Candil.Migrate do
  use Mix.Task

  @shortdoc "Migrate ropero.d/*.sh to candil.toml"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [from_ropero: :string, output: :string, dry_run: :boolean]
      )

    ropero_dir = Keyword.fetch!(opts, :from_ropero)
    output = Keyword.get(opts, :output)
    dry_run = Keyword.get(opts, :dry_run, false)

    Mix.shell().info("Migrando de #{ropero_dir}...")

    case Candil.Config.Migrate.from_ropero(ropero_dir, unless(dry_run, do: output)) do
      {:ok, path_or_toml} ->
        if dry_run do
          Mix.shell().info("=== TOML generado (dry run) ===\n#{path_or_toml}")
        else
          Mix.shell().info("✓ TOML escrito en #{path_or_toml}")
        end

      {:error, reason} ->
        Mix.shell().error("✗ Error: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
```

### 14.7 — Tests

**Archivos nuevos**:

- `test/candil/config/file_test.exs`
- `test/candil/config/schema_test.exs`
- `test/candil/config/migrate_test.exs`
- `test/support/fixtures/ropero_sample/*.sh` (3-4 scripts de ejemplo)

**Tests clave**:

```elixir
describe "Config.File" do
  test "load returns {:ok, config} for a valid TOML"
  test "load returns {:ok, empty} when file doesn't exist"
  test "save writes atomically (no partial files)"
  test "path respects CANDIL_CONFIG env var"
end

describe "Config.Schema" do
  test "validate accepts a minimal valid config"
  test "validate rejects unknown engine types"
  test "validate requires model.type"
end

describe "Config.Migrate" do
  test "from_ropero parses a llama-server script"
  test "from_ropero parses an airllm script"
  test "from_ropero generates a valid TOML loadable by Config.File"
  test "extract_args handles boolean flags (--jinja)"
  test "extract_args handles flags with values (--temp 0.7)"
  test "extract_args handles JSON-string values"
end
```

### 14.8 — Criterio de done

```bash
mix test test/candil/config/        # 0 failures
mix candil.migrate --from-ropero ~/cacafuti/lasaca/ropero/ropero.d/ --dry-run | head -50
# Debe imprimir un TOML válido con los modelos de ropero
```

---

## 15. Fase 2 — CLI con Alaja

**Objetivo**: `candil models list`, `candil run coder`, `candil status`, etc.

**Días estimados**: 2.

### 15.1 — Dependencias

**Archivo**: `mix.exs`.

```elixir
{:alaja, path: "../alaja"},
{:pote, "~> 3.0"},
# opcional:
{:botica, github: "Lorenzo-SF/botica", optional: true}
```

### 15.2 — `Candil.CLI`

**Archivo nuevo**: `lib/candil/cli.ex`.

```elixir
defmodule Candil.CLI do
  use Alaja.CLI.Definition, otp_app: :candil, halt_on_error: true

  # ── models ────────────────────────────────────────────────────
  subcommand "models", "Manage models" do
    command "list", "List registered models" do
      flag :json, :boolean, default: false
      run {Candil.CLI.Commands.Models, :list}
    end

    command "pull", "Download a model" do
      argument :alias, :string, required: true
      run {Candil.CLI.Commands.Models, :pull}
    end

    command "info", "Show model details" do
      argument :alias, :string, required: true
      run {Candil.CLI.Commands.Models, :info}
    end

    command "remove", "Remove a model from config" do
      argument :alias, :string, required: true
      flag :yes, :boolean, default: false, short: "y"
      run {Candil.CLI.Commands.Models, :remove}
    end
  end

  # ── run ───────────────────────────────────────────────────────
  command "run", "Start a model" do
    argument :alias, :string, required: true
    flag :port, :integer
    flag :background, :boolean, default: false
    flag :cpu, :boolean, default: false
    run {Candil.CLI.Commands.Run, :start}
  end

  # ── stop ──────────────────────────────────────────────────────
  command "stop", "Stop a model or all engines" do
    argument :target, :string, required: true  # alias o "all"
    run {Candil.CLI.Commands.Stop, :stop}
  end

  # ── status ────────────────────────────────────────────────────
  command "status", "Show engines status" do
    flag :json, :boolean, default: false
    flag :watch, :integer
    run {Candil.CLI.Commands.Status, :show}
  end

  # ── config ────────────────────────────────────────────────────
  subcommand "config", "Manage configuration" do
    command "show", "Show current config" do
      flag :effective, :boolean, default: false  # ETS en vez de TOML
      run {Candil.CLI.Commands.Config, :show}
    end

    command "edit", "Open config in $EDITOR" do
      run {Candil.CLI.Commands.Config, :edit}
    end

    command "validate", "Validate config" do
      run {Candil.CLI.Commands.Config, :validate}
    end

    command "migrate", "Migrate from ropero.d" do
      flag :from_ropero, :string, required: true
      flag :output, :string
      run {Candil.CLI.Commands.Config, :migrate}
    end
  end

  # ── router ────────────────────────────────────────────────────
  subcommand "router", "Manage router" do
    command "stats", "Show routing stats" do
      flag :consumer, :string
      run {Candil.CLI.Commands.Router, :stats}
    end

    command "test", "Test routing decision for a prompt" do
      argument :prompt, :string, required: true
      run {Candil.CLI.Commands.Router, :test}
    end
  end

  # ── gateway ───────────────────────────────────────────────────
  subcommand "gateway", "Manage HTTP gateway" do
    command "start", "Start the gateway" do
      flag :port, :integer
      run {Candil.CLI.Commands.Gateway, :start}
    end

    command "stop", "Stop the gateway" do
      run {Candil.CLI.Commands.Gateway, :stop}
    end

    command "status", "Show gateway status" do
      run {Candil.CLI.Commands.Gateway, :status}
    end
  end

  # ── mcp ───────────────────────────────────────────────────────
  subcommand "mcp", "MCP server and client" do
    command "serve", "Start MCP server" do
      flag :transport, :string, default: "stdio", values: ~w(stdio http)
      flag :port, :integer, default: 7778
      run {Candil.CLI.Commands.MCP, :serve}
    end

    command "call", "Call a tool on an MCP server" do
      argument :server, :string, required: true
      argument :tool, :string, required: true
      argument :args_json, :string, required: true
      run {Candil.CLI.Commands.MCP, :call}
    end
  end

  # ── rag ───────────────────────────────────────────────────────
  subcommand "rag", "RAG operations" do
    command "index", "Index a directory or file" do
      argument :name, :string, required: true
      argument :path, :string, required: true
      run {Candil.CLI.Commands.RAG, :index}
    end

    command "query", "Query an index" do
      argument :name, :string, required: true
      argument :text, :string, required: true
      flag :top_k, :integer, default: 5
      run {Candil.CLI.Commands.RAG, :query}
    end

    command "list", "List indexes" do
      run {Candil.CLI.Commands.RAG, :list}
    end

    command "drop", "Drop an index" do
      argument :name, :string, required: true
      run {Candil.CLI.Commands.RAG, :drop}
    end
  end

  # ── doctor ────────────────────────────────────────────────────
  command "doctor", "Run environment diagnostics" do
    flag :fix, :boolean, default: false
    run {Candil.CLI.Commands.Doctor, :run}
  end

  # ── version ───────────────────────────────────────────────────
  command "version", "Show version" do
    run fn _opts ->
      vsn = Application.spec(:candil, :vsn)
      Alaja.Printer.print_info("Candil #{vsn}")
    end
  end
end
```

### 15.3 — `Candil.CLI.Commands.Models`

**Archivo nuevo**: `lib/candil/cli/commands/models.ex`.

```elixir
defmodule Candil.CLI.Commands.Models do
  alias Candil.Config
  alias Alaja.Components.Table
  alias Alaja.Printer

  def list(opts) do
    models = Config.list_models()

    cond do
      models == [] ->
        Printer.print_info("No hay modelos registrados.")
        Printer.print_info("Añade algunos en ~/.config/candil/candil.toml")
        Printer.print_info("O migra desde ropero: candil config migrate --from-ropero <dir>")

      opts.json ->
        IO.puts(Jason.encode!(Enum.map(models, &model_to_map/1), pretty: true))

      true ->
        Table.print(
          headers: ["Alias", "Type", "Engine/Provider", "Context", "Usage"],
          rows: Enum.map(models, fn m ->
            [
              to_string(m.alias),
              to_string(m.type),
              to_string(m.engine || m.provider || "-"),
              to_string(m.context_size),
              Enum.join(m.usage, ",")
            ]
          end),
          table_border: :rounded,
          border_color: {0, 180, 216},
          headers_color: :cyan,
          headers_effects: [:bold]
        )
    end

    :ok
  end

  def pull(opts) do
    case Config.get_model(String.to_existing_atom(opts.alias)) do
      {:ok, %{type: :remote} = m} ->
        Printer.print_info("#{m.alias} es remoto; no hay nada que descargar.")
        :ok

      {:ok, model} ->
        do_pull(model)

      {:error, :not_found} ->
        Printer.print_error("Modelo '#{opts.alias}' no encontrado.")
        {:error, :not_found}
    end
  end

  defp do_pull(model) do
    Printer.print_info("Descargando #{model.alias}...")

    case Candil.Llm.download_model(model) do
      {:ok, path} ->
        Printer.print_success("✓ Descargado en #{path}")
        :ok

      {:error, reason} ->
        Printer.print_error("✗ Falló: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def info(opts) do
    case Config.get_model(String.to_existing_atom(opts.alias)) do
      {:ok, model} ->
        IO.inspect(model, label: "Modelo #{opts.alias}", pretty: true)
        :ok

      {:error, :not_found} ->
        Printer.print_error("Modelo '#{opts.alias}' no encontrado.")
        {:error, :not_found}
    end
  end

  def remove(opts) do
    alias_atom = String.to_existing_atom(opts.alias)

    confirmed =
      if opts.yes do
        true
      else
        case Alaja.Printer.Interactive.yesno(
               "¿Eliminar el modelo '#{opts.alias}' del TOML?",
               default: :no
             ) do
          :yes -> true
          :no -> false
        end
      end

    if confirmed do
      case Candil.Config.File.load() do
        {:ok, config} ->
          new_config = update_in(config, ["model"], &Map.delete(&1, opts.alias))

          case Candil.Config.File.save(new_config) do
            :ok ->
              Config.deregister_model(alias_atom)
              Printer.print_success("✓ Modelo eliminado.")
              :ok

            {:error, reason} ->
              Printer.print_error("✗ No se pudo guardar: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Printer.print_error("✗ No se pudo leer el TOML: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Printer.print_info("Cancelado.")
      :ok
    end
  end

  defp model_to_map(m) do
    %{
      alias: m.alias,
      type: m.type,
      engine: m.engine,
      provider: m.provider,
      context_size: m.context_size,
      usage: m.usage
    }
  end
end
```

### 15.4 — Resto de comandos

Implementación análoga para `Run`, `Stop`, `Status`, `Config`, `Router`, `Gateway`, `MCP`, `RAG`, `Doctor`.

**Esqueleto de `Status`** (usa `Alaja.Components.Table`):

```elixir
defmodule Candil.CLI.Commands.Status do
  alias Alaja.Components.Table
  alias Alaja.Printer

  def show(opts) do
    rows =
      Candil.EnginePool.list()
      |> Enum.map(fn {alias_name, pid, engine} ->
        uptime_s = DateTime.diff(DateTime.utc_now(), engine_started_at(alias_name)) |> to_string()
        [
          to_string(alias_name),
          to_string(engine.port),
          "ON",
          to_string(pid),
          uptime_s <> "s",
          "llama-server"
        ]
      end)

    if rows == [] do
      Printer.print_info("Ningún engine activo.")
    else
      Table.print(
        headers: ["Alias", "Port", "State", "PID", "Uptime", "Engine"],
        rows: rows,
        table_border: :rounded,
        border_color: {0, 180, 216}
      )
    end

    :ok
  end

  defp engine_started_at(_alias), do: DateTime.utc_now()
end
```

### 15.5 — Punto de entrada

**Archivo**: `candil` (script ejecutable, no `.ex`).

**Contenido**:

```bash
#!/usr/bin/env bash
exec elixir -e 'Candil.CLI.main(System.argv())' -- "$@"
```

O mejor, un `mix escript.build` (pero requiere `escript: [main_module: Candil.CLI]` en `mix.exs`).

**Recomendación**: usar escript.

```elixir
# mix.exs
def project do
  [
    # ...
    escript: [main_module: Candil.CLI]
  ]
end
```

Y luego:

```bash
mix escript.build
./candil models list
```

### 15.6 — Tests

**Archivos nuevos**:

- `test/candil/cli_test.exs`
- `test/candil/cli/commands/models_test.exs`
- `test/candil/cli/commands/status_test.exs`

**Test con `ExUnit.CaptureIO`**:

```elixir
test "models list prints table" do
  Config.register_model(%Model{alias: :test, type: :local, engine: :llama_server,
                                model_dir: "/tmp", filename: "x.gguf"})

  output = capture_io(fn ->
    Candil.CLI.Commands.Models.list(%{json: false})
  end)

  assert output =~ "Alias"
  assert output =~ "test"
end
```

### 15.7 — Criterio de done

```bash
mix escript.build
./candil models list
./candil run coder --background
./candil status
./candil stop coder
```

Todos los comandos funcionan sin crashear.

---

## 16. Fase 3 — Router + Gateway

**Objetivo**: endpoint OpenAI-compatible que decide y arranca modelos.

**Días estimados**: 3-4.

### 16.1 — Dependencias

**Archivo**: `mix.exs`.

```elixir
{:plug, "~> 1.19"},
{:bandit, "~> 1.6"},
```

**Nota**: `plug` + `bandit` reemplazan a Cowboy (que usaba ElPaso). Bandit es el estándar 2026.

### 16.2 — `Candil.Router`

**Archivos nuevos**:

- `lib/candil/router/router.ex`
- `lib/candil/router/decision_engine.ex`
- `lib/candil/router/cache.ex`
- `lib/candil/router/embedding_matcher.ex`
- `lib/candil/router/llm_classifier.ex`
- `lib/candil/router/scorer.ex`
- `lib/candil/router/task_categories.ex`
- `lib/candil/router/model_state.ex`
- `lib/candil/router/analyzer.ex`
- `lib/candil/router/auto_tuner.ex`
- `lib/candil/router/consumer.ex`

**Estructura del `DecisionEngine`** (portada de ElPaso, sin DB):

```elixir
defmodule Candil.Router.DecisionEngine do
  alias Candil.Router.{Cache, Scorer, EmbeddingMatcher, LLMClassifier}
  alias Candil.Config

  @keyword_threshold 0.70
  @embedding_threshold 0.55

  @spec decide([map()], keyword()) ::
          {:ok, Candil.Router.decision(), map()} | {:error, term()}
  def decide(messages, opts \\ []) do
    content = extract_content(messages)
    consumer = Keyword.get(opts, :consumer, :default)

    models = Config.list_models()
    applicable = filter_by_consumer(models, consumer)

    if applicable == [] do
      {:error, :no_models_for_consumer}
    else
      # Capa 0: cache
      case Cache.get(content) do
        {:hit, model_alias} ->
          model = Enum.find(applicable, &(&1.alias == model_alias))
          if model, do: {:ok, decision(model, :cache, 0.95, "cached"), %{layer: :cache}}, else: do_decide(applicable, content, opts)

        :miss ->
          do_decide(applicable, content, opts)
      end
    end
  end

  defp do_decide(models, content, opts) do
    # Capa 1: rules (TOML)
    rules_result = Scorer.score(models, content, opts)

    if rules_result.confidence >= @keyword_threshold do
      Cache.put(content, rules_result.model.alias)
      {:ok, decision(rules_result.model, :rule, rules_result.confidence, rules_result.reason),
       %{layer: :rule, confidence: rules_result.confidence}}
    else
      # Capa 2: embedding
      case EmbeddingMatcher.match(models, content) do
        {:ok, %{confidence: conf} = result} when conf >= @embedding_threshold ->
          Cache.put(content, result.model.alias)
          {:ok, decision(result.model, :embedding, conf, "embedding similarity"),
           %{layer: :embedding, confidence: conf}}

        _ ->
          # Capa 3: LLM classifier (opt-in, caro)
          if Keyword.get(opts, :enable_llm_classifier, false) do
            case LLMClassifier.classify(models, content) do
              {:ok, %{model: model, confidence: conf}} when not is_nil(model) ->
                Cache.put(content, model.alias)
                {:ok, decision(model, :llm, conf, "llm classification"), %{layer: :llm}}

              _ ->
                fallback(models, content)
            end
          else
            fallback(models, content)
          end
      end
    end
  end

  defp fallback(models, content) do
    # Capa 4: default
    default =
      Enum.find(models, &(&1.alias == :default)) ||
        Enum.find(models, &(:chat in &1.usage)) ||
        hd(models)

    {:ok, decision(default, :default, 0.5, "default model"), %{layer: :default}}
  end

  defp decision(model, strategy, score, reason) do
    %{
      model_alias: model.alias,
      strategy: strategy,
      score: score,
      reason: reason,
      timestamp: DateTime.utc_now()
    }
  end

  defp extract_content(messages) do
    messages
    |> Enum.map_join("\n", fn
      %{content: c} when is_binary(c) -> c
      %{"content" => c} when is_binary(c) -> c
      _ -> ""
    end)
  end

  defp filter_by_consumer(models, _consumer), do: models
end
```

**`Candil.Router.Scorer`** (rules del TOML):

```elixir
defmodule Candil.Router.Scorer do
  @spec score([Model.t()], String.t(), keyword()) :: %{
    model: Model.t(),
    confidence: float(),
    reason: String.t(),
    all_scores: [{atom(), float()}]
  }
  def score(models, content, _opts) do
    config = Application.get_env(:candil, :router_rules, [])
    content_lower = String.downcase(content)

    matches =
      Enum.flat_map(config, fn {rule_name, %{match: words, model: model_alias}} ->
        hits = Enum.count(words, &String.contains?(content_lower, String.downcase(&1)))
        if hits > 0, do: [{rule_name, model_alias, hits / length(words)}], else: []
      end)

    case Enum.max_by(matches, fn {_, _, score} -> score end, fn -> nil end) do
      nil ->
        %{model: hd(models), confidence: 0.0, reason: "no rule matched", all_scores: []}

      {rule_name, model_alias, score} ->
        model = Enum.find(models, &(&1.alias == model_alias)) || hd(models)
        %{model: model, confidence: score, reason: "rule:#{rule_name}", all_scores: matches}
    end
  end
end
```

**Config de reglas** (hidratada desde TOML en `Config.init/1`):

```elixir
# En Config.init/1, tras hidratar modelos:
if rules = get_in(config, ["router", "rules"]) do
  Application.put_env(:candil, :router_rules,
    Enum.map(rules, fn {name, %{"match" => words, "model" => model}} ->
      {String.to_atom(name), %{match: words, model: String.to_existing_atom(model)}}
    end))
end
```

**`Candil.Router.Cache`**:

```elixir
defmodule Candil.Router.Cache do
  use GenServer

  # ETS: :candil_router_cache
  # key: hash(content)
  # value: {model_alias, expires_at}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get(content), do: GenServer.call(__MODULE__, {:get, content})
  def put(content, alias_name), do: GenServer.cast(__MODULE__, {:put, content, alias_name})
  def size, do: GenServer.call(__MODULE__, :size)
end
```

**`Candil.Router.Consumer`** — fusión con el TOML:

```elixir
defmodule Candil.Router.Consumer do
  @spec info(atom()) :: map() | nil
  def info(consumer) do
    Application.get_env(:candil, :consumers, %{})[consumer]
  end

  @spec model_default(atom()) :: atom() | nil
  def model_default(consumer) do
    case info(consumer) do
      %{model_default: m} -> m
      _ -> nil
    end
  end

  @spec max_concurrent(atom()) :: pos_integer()
  def max_concurrent(consumer) do
    case info(consumer) do
      %{max_concurrent: n} -> n
      _ -> 4
    end
  end

  @spec rate_limit(atom()) :: pos_integer() | nil
  def rate_limit(consumer) do
    case info(consumer) do
      %{rate_limit_per_minute: n} -> n
      _ -> nil
    end
  end
end
```

### 16.3 — `Candil.Gateway`

**Archivos nuevos**:

- `lib/candil/gateway/endpoint.ex`
- `lib/candil/gateway/router.ex`
- `lib/candil/gateway/handlers/chat_completions.ex`
- `lib/candil/gateway/handlers/messages.ex`
- `lib/candil/gateway/handlers/embeddings.ex`
- `lib/candil/gateway/handlers/models.ex`
- `lib/candil/gateway/handlers/health.ex`
- `lib/candil/gateway/handlers/metrics.ex`
- `lib/candil/gateway/auth.ex`
- `lib/candil/gateway/consumer_registry.ex`
- `lib/candil/gateway/request_id.ex`
- `lib/candil/gateway/error_handler.ex`

**`Endpoint`** — arranca Bandit:

```elixir
defmodule Candil.Gateway.Endpoint do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 7777)
    host = Keyword.get(opts, :host, "127.0.0.1")

    children = [
      {Bandit,
       plug: Candil.Gateway.Router,
       scheme: :http,
       port: port,
       ip: parse_ip(host),
       startup_log: true}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp parse_ip("127.0.0.1"), do: {127, 0, 0, 1}
  defp parse_ip("0.0.0.0"), do: {0, 0, 0, 0}
  defp parse_ip(s), do: s |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

  def stop do
    Supervisor.stop(__MODULE__)
  end
end
```

**`Router`** — Plug.Router:

```elixir
defmodule Candil.Gateway.Router do
  use Plug.Router

  plug Candil.Gateway.RequestId
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug Candil.Gateway.Auth
  plug :dispatch

  # Endpoints con consumer explícito
  post "/c/:consumer/v1/chat/completions" do
    Candil.Gateway.Handlers.ChatCompletions.handle(conn, consumer)
  end

  post "/c/:consumer/v1/messages" do
    Candil.Gateway.Handlers.Messages.handle(conn, consumer)
  end

  post "/c/:consumer/v1/embeddings" do
    Candil.Gateway.Handlers.Embeddings.handle(conn, consumer)
  end

  get "/c/:consumer/v1/models" do
    Candil.Gateway.Handlers.Models.handle(conn, consumer)
  end

  # Sin consumer explícito → default
  post "/v1/chat/completions" do
    default = Candil.ConsumerRegistry.default()
    Candil.Gateway.Handlers.ChatCompletions.handle(conn, default)
  end

  post "/v1/messages" do
    default = Candil.ConsumerRegistry.default()
    Candil.Gateway.Handlers.Messages.handle(conn, default)
  end

  post "/v1/embeddings" do
    default = Candil.ConsumerRegistry.default()
    Candil.Gateway.Handlers.Embeddings.handle(conn, default)
  end

  get "/v1/models" do
    Candil.Gateway.Handlers.Models.handle(conn, :default)
  end

  # Health y metrics
  get "/health" do
    Candil.Gateway.Handlers.Health.handle(conn)
  end

  get "/metrics" do
    Candil.Gateway.Handlers.Metrics.handle(conn)
  end

  match _ do
    Candil.Gateway.ErrorHandler.not_found(conn)
  end
end
```

**`Handlers.ChatCompletions`**:

```elixir
defmodule Candil.Gateway.Handlers.ChatCompletions do
  import Plug.Conn

  alias Candil.{Router, Inference, Config}
  alias Candil.Gateway.{ErrorHandler, RequestId}

  def handle(conn, consumer) do
    consumer_atom = String.to_existing_atom(consumer)

    params = conn.body_params
    messages = normalize_messages(params["messages"] || [])
    requested_model = params["model"] || "auto"
    stream? = params["stream"] == true

    # 1. Decidir modelo
    model_alias =
      case requested_model do
        "auto" -> decide_model(messages, consumer_atom)
        name -> String.to_existing_atom(name)
      end

    # 2. Arrancar engine si es local y no está vivo
    with :ok <- ensure_engine(model_alias),
         # 3. Inferir
         {:ok, response} <- run_inference(model_alias, messages, params, consumer_atom, stream?) do
      if stream? do
        stream_response(conn, response)
      else
        json_response(conn, response, model_alias)
      end
    else
      {:error, reason} -> ErrorHandler.handle(conn, reason)
    end
  end

  defp decide_model(messages, consumer) do
    case Router.decide(messages, consumer: consumer) do
      {:ok, %{model_alias: alias_name}} -> alias_name
      {:error, _} -> Router.Consumer.model_default(consumer) || :default
    end
  end

  defp ensure_engine(model_alias) do
    case Config.get_model(model_alias) do
      {:ok, %{type: :local, engine: engine_alias} = model} ->
        case Candil.Engine.base_url(model_alias) do
          nil ->
            {:ok, engine} = Config.get_engine(engine_alias)
            case Candil.Engine.start(engine, model) do
              {:ok, _pid} -> :ok
              error -> error
            end

          _url -> :ok
        end

      {:ok, %{type: :remote}} -> :ok
      {:error, _} = err -> err
    end
  end

  defp run_inference(model_alias, messages, params, consumer, false) do
    opts = [
      consumer: consumer,
      temperature: params["temperature"],
      max_tokens: params["max_tokens"]
    ] |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case Config.get_model(model_alias) do
      {:ok, %{type: :local}} -> Inference.chat_local(model_alias, messages, opts)
      {:ok, %{type: :remote} = model} ->
        {:ok, provider} = Config.get_provider(model.provider)
        Inference.chat_remote(model, provider, messages, opts)
    end
  end

  defp run_inference(model_alias, messages, params, consumer, true) do
    # Stream mode devuelve {:ok, enumerable}
    opts = [consumer: consumer, stream: true]
    case Config.get_model(model_alias) do
      {:ok, %{type: :local}} ->
        {:ok, Candil.Stream.stream_local(model_alias, messages, opts)}
      {:ok, %{type: :remote} = model} ->
        {:ok, provider} = Config.get_provider(model.provider)
        {:ok, Candil.Stream.stream_remote(model, provider, messages, opts)}
    end
  end

  defp json_response(conn, response, model_alias) do
    body = %{
      id: "chatcmpl-" <> RequestId.generate(),
      object: "chat.completion",
      created: System.os_time(:second),
      model: to_string(model_alias),
      choices: [%{
        index: 0,
        message: %{role: "assistant", content: response.content},
        finish_reason: response.finish_reason || "stop"
      }],
      usage: response.usage || %{}
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp stream_response(conn, enumerable) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    Enum.reduce_while(enumerable, conn, fn chunk, conn ->
      data = Jason.encode!(%{
        choices: [%{delta: %{content: chunk.content}, finish_reason: chunk.finish_reason}]
      })

      case chunk(conn, "data: #{data}\n\n") do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
    |> chunk("data: [DONE]\n\n")
    |> then(fn conn -> conn end)
  end

  defp normalize_messages(messages) do
    Enum.map(messages, fn
      %{"role" => role, "content" => content} ->
        %{role: role, content: content}
      _ ->
        %{role: "user", content: ""}
    end)
  end
end
```

**`Auth`**:

```elixir
defmodule Candil.Gateway.Auth do
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:candil, :gateway_auth, "none") do
      "none" -> conn
      "api_key" -> verify_api_key(conn)
      "jwt" -> verify_jwt(conn)
    end
  end

  defp verify_api_key(conn) do
    valid_keys = Application.get_env(:candil, :gateway_api_keys, [])

    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] ->
        if key in valid_keys, do: conn, else: unauthorized(conn)

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{message: "unauthorized", type: "auth_error"}}))
    |> halt()
  end

  defp verify_jwt(conn), do: conn  # TODO
end
```

### 16.4 — Tests

- `test/candil/router/decision_engine_test.exs` — con prompts de ejemplo, verificar routing.
- `test/candil/router/scorer_test.exs` — con reglas TOML, verificar matches.
- `test/candil/gateway/router_test.exs` — con `Plug.Test`, verificar endpoints.
- `test/candil/gateway/handlers/chat_completions_test.exs` — mock del engine.

**Ejemplo de test del gateway**:

```elixir
test "POST /v1/chat/completions with model=auto returns a response" do
  # Mock del backend
  Mox.stub(Candil.HTTPAdapterMock, :request, fn _req ->
    {:ok, %Apero.Http.Response{
      status: 200,
      body: %{"choices" => [%{"message" => %{"content" => "Hola"}}]}
    }}
  end)

  conn =
    :post
    |> Plug.Test.conn("/v1/chat/completions", Jason.encode!(%{
      model: "auto",
      messages: [%{role: "user", content: "hi"}]
    }))
    |> put_req_header("content-type", "application/json")
    |> Candil.Gateway.Router.call([])

  assert conn.status == 200
  body = Jason.decode!(conn.resp_body)
  assert body["choices"] |> hd() |> get_in(["message", "content"]) == "Hola"
end
```

### 16.5 — Criterio de done

```bash
candil gateway start --port 7777
curl -X POST http://127.0.0.1:7777/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"hola"}]}'
# Debe devolver un JSON con la respuesta del modelo
```

---

## 17. Fase 4 — Context compartido

**Objetivo**: sesiones persistentes en ETS, aisladas por consumer, con resumen automático.

**Días estimados**: 2-3.

### 17.1 — Módulos

**Archivos nuevos**:

- `lib/candil/context/store.ex`
- `lib/candil/context/session.ex`
- `lib/candil/context/session_supervisor.ex`
- `lib/candil/context/builder.ex`
- `lib/candil/context/summarizer.ex`
- `lib/candil/context/prefix_manager.ex`
- `lib/candil/context/backend/ets.ex`
- `lib/candil/context/backend/postgres.ex` (opcional)

### 17.2 — `Candil.Context.Session`

```elixir
defmodule Candil.Context.Session do
  @enforce_keys [:id, :consumer]
  defstruct [
    :id,
    :consumer,
    :created_at,
    :updated_at,
    :last_used_at,
    messages: [],
    summary: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          consumer: atom(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          last_used_at: DateTime.t(),
          messages: [map()],
          summary: String.t() | nil,
          metadata: map()
        }

  def new(consumer, id) do
    now = DateTime.utc_now()
    %__MODULE__{
      id: id,
      consumer: consumer,
      created_at: now,
      updated_at: now,
      last_used_at: now
    }
  end

  def add_message(%__MODULE__{} = s, role, content) do
    msg = %{role: role, content: content, ts: DateTime.utc_now()}
    %{s | messages: s.messages ++ [msg], updated_at: DateTime.utc_now()}
  end
end
```

### 17.3 — `Candil.Context.Store`

```elixir
defmodule Candil.Context.Store do
  use GenServer

  @table :candil_context_sessions
  @default_max_sessions 1000
  @default_ttl_seconds 86_400   # 24h

  # ── API ───────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(consumer, session_id), do: GenServer.call(__MODULE__, {:create, consumer, session_id})
  def get(consumer, session_id), do: GenServer.call(__MODULE__, {:get, consumer, session_id})
  def update(consumer, session_id, fun) when is_function(fun, 1),
    do: GenServer.call(__MODULE__, {:update, consumer, session_id, fun})
  def append_message(consumer, session_id, message),
    do: GenServer.call(__MODULE__, {:append, consumer, session_id, message})
  def delete(consumer, session_id), do: GenServer.call(__MODULE__, {:delete, consumer, session_id})
  def list(consumer), do: GenServer.call(__MODULE__, {:list, consumer})
  def count(consumer), do: GenServer.call(__MODULE__, {:count, consumer})
  def gc, do: GenServer.call(__MODULE__, :gc)

  # ── Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    max = Keyword.get(opts, :max_sessions, @default_max_sessions)
    ttl = Keyword.get(opts, :session_ttl_seconds, @default_ttl_seconds)

    schedule_gc(ttl)

    {:ok, %{max: max, ttl: ttl}}
  end

  @impl true
  def handle_call({:create, consumer, session_id}, _from, state) do
    session = Candil.Context.Session.new(consumer, session_id)
    :ets.insert(@table, {{consumer, session_id}, session})

    maybe_evict_lru(consumer, state.max)
    {:reply, {:ok, session}, state}
  end

  def handle_call({:get, consumer, session_id}, _from, state) do
    case :ets.lookup(@table, {consumer, session_id}) do
      [{_, session}] ->
        session = %{session | last_used_at: DateTime.utc_now()}
        :ets.insert(@table, {{consumer, session_id}, session})
        {:reply, {:ok, session}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update, consumer, session_id, fun}, _from, state) do
    case :ets.lookup(@table, {consumer, session_id}) do
      [{_, session}] ->
        updated = fun.(session) |> Map.put(:updated_at, DateTime.utc_now())
        :ets.insert(@table, {{consumer, session_id}, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:append, consumer, session_id, message}, _from, state) do
    case :ets.lookup(@table, {consumer, session_id}) do
      [{_, session}] ->
        updated = Candil.Context.Session.add_message(session, message.role, message.content)
        :ets.insert(@table, {{consumer, session_id}, updated})
        {:reply, :ok, state}

      [] ->
        session = Candil.Context.Session.new(consumer, session_id)
        updated = Candil.Context.Session.add_message(session, message.role, message.content)
        :ets.insert(@table, {{consumer, session_id}, updated})
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete, consumer, session_id}, _from, state) do
    :ets.delete(@table, {consumer, session_id})
    {:reply, :ok, state}
  end

  def handle_call({:list, consumer}, _from, state) do
    sessions =
      :ets.select(@table, [{{{consumer, :_}, :"$1"}, [], [:"$1"]}])

    {:reply, sessions, state}
  end

  def handle_call({:count, consumer}, _from, state) do
    n = :ets.select_count(@table, [{{{consumer, :_}, :_}, [], [true]}])
    {:reply, n, state}
  end

  def handle_call(:gc, _from, %{ttl: ttl} = state) do
    cutoff = DateTime.utc_now() |> DateTime.add(-ttl, :second)

    deleted = :ets.foldl(fn
      {{c, id}, session}, acc ->
        if DateTime.compare(session.last_used_at, cutoff) == :lt do
          :ets.delete(@table, {c, id})
          acc + 1
        else
          acc
        end
    end, 0, @table)

    {:reply, deleted, state}
  end

  # ── Internals ─────────────────────────────────────────────────

  defp maybe_evict_lru(consumer, max) do
    count = :ets.select_count(@table, [{{{consumer, :_}, :_}, [], [true]}])

    if count > max do
      # Encontrar el más viejo (por last_used_at)
      oldest =
        :ets.select(@table, [{{{consumer, :_}, :"$1"}, [], [:"$1"]}])
        |> Enum.min_by(&DateTime.to_unix(&1.last_used_at), fn -> nil end)

      if oldest do
        :ets.delete(@table, {consumer, oldest.id})
      end
    end
  end

  defp schedule_gc(ttl) do
    # GC cada 1/10 del TTL, mínimo 1h
    interval = max(div(ttl * 1000, 10), 3_600_000)
    Process.send_after(self(), :gc, interval)
  end

  @impl true
  def handle_info(:gc, state) do
    gc()
    schedule_gc(state.ttl)
    {:noreply, state}
  end
end
```

### 17.4 — `Candil.Context.Builder`

```elixir
defmodule Candil.Context.Builder do
  alias Candil.Context.Session

  @max_history_messages 10

  @spec build(Session.t(), String.t(), pos_integer(), String.t() | nil) :: [map()]
  def build(session, user_message, max_tokens, system_prompt \\ nil) do
    system = build_system(system_prompt, session.summary)
    system_tokens = estimate_tokens(system)
    user_tokens = estimate_tokens(user_message)
    history_budget = max_tokens - system_tokens - user_tokens - 200

    history = build_history(session.messages, history_budget)

    [%{role: "system", content: system} | history] ++ [%{role: "user", content: user_message}]
  end

  defp build_system(nil, nil), do: "You are a helpful assistant."
  defp build_system(nil, summary), do: "Context summary:\n\n#{summary}"
  defp build_system(prompt, nil), do: prompt
  defp build_system(prompt, summary), do: "#{prompt}\n\nContext summary:\n\n#{summary}"

  defp build_history(messages, budget) when budget <= 0, do: []

  defp build_history(messages, budget) do
    messages
    |> Enum.reverse()
    |> Enum.take(@max_history_messages)
    |> Enum.reduce({[], budget}, fn msg, {acc, remaining} ->
      tokens = estimate_tokens(msg.content)
      if tokens <= remaining do
        {[msg | acc], remaining - tokens}
      else
        {acc, 0}
      end
    end)
    |> elem(0)
  end

  defp estimate_tokens(text), do: text |> String.split(~r/\s+/g, trim: true) |> length()
end
```

### 17.5 — `Candil.Context.Summarizer`

```elixir
defmodule Candil.Context.Summarizer do
  alias Candil.{Inference, Config}

  @spec maybe_summarize(Session.t(), keyword()) :: Session.t()
  def maybe_summarize(session, opts) do
    summarize_after_msgs = Keyword.get(opts, :after_messages, 50)
    summarize_after_tokens = Keyword.get(opts, :after_tokens, 8000)
    model = Keyword.get(opts, :model)

    if length(session.messages) >= summarize_after_msgs or
         estimate_tokens(session.messages) >= summarize_after_tokens do
      do_summarize(session, model)
    else
      session
    end
  end

  defp do_summarize(%Session{messages: []} = s, _), do: s

  defp do_summarize(session, model) do
    to_summarize = session.messages
    text = Enum.map_join(to_summarize, "\n", &"#{&1.role}: #{&1.content}")

    prompt = """
    Resume el siguiente fragmento de conversación en un párrafo corto,
    preservando las decisiones clave, hechos y contexto necesario para continuar.

    Conversación:
    #{text}

    Resumen:
    """

    case Inference.chat_local(model, [%{role: "user", content: prompt}]) do
      {:ok, %{content: summary}} ->
        %{session | summary: merge_summary(session.summary, summary), messages: []}

      {:error, _} ->
        session
    end
  end

  defp merge_summary(nil, new), do: new
  defp merge_summary(old, new), do: "#{old}\n\n#{new}"

  defp estimate_tokens(messages) do
    messages |> Enum.map(& &1.content) |> Enum.join(" ") |> String.length() |> div(4)
  end
end
```

### 17.6 — `Candil.Context.PrefixManager`

```elixir
defmodule Candil.Context.PrefixManager do
  use GenServer

  @table :candil_prefix_cache
  @default_ttl_ms 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def put(key, prompt, ttl \\ @default_ttl_ms) do
    expires = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table, {key, prompt, expires})
    :ok
  end

  def get(key) do
    now = System.monotonic_time(:millisecond)
    case :ets.lookup(@table, key) do
      [{_, prompt, expires}] when expires > now -> {:ok, prompt}
      [{_, _, _}] -> :ets.delete(@table, key); :miss
      [] -> :miss
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
```

### 17.7 — Integrar context en inference

**En `Candil.Inference`** — nueva función:

```elixir
@spec chat_with_context(atom(), String.t(), [map()], keyword()) :: {:ok, response()} | {:error, term()}
def chat_with_context(model_alias, session_id, messages, opts) do
  consumer = Keyword.get(opts, :consumer, :default)

  session =
    case Candil.Context.Store.get(consumer, session_id) do
      {:ok, s} -> s
      {:error, :not_found} ->
        {:ok, s} = Candil.Context.Store.create(consumer, session_id)
        s
    end

  user_message = messages |> List.last() |> Map.get(:content, "")
  max_tokens = Keyword.get(opts, :max_tokens, 4096)

  built_messages = Candil.Context.Builder.build(session, user_message, max_tokens)

  case chat_local(model_alias, built_messages, opts) do
    {:ok, response} ->
      Candil.Context.Store.append_message(consumer, session_id, %{role: "user", content: user_message})
      Candil.Context.Store.append_message(consumer, session_id, %{role: "assistant", content: response.content})
      {:ok, response}

    err -> err
  end
end
```

### 17.8 — Criterio de done

```bash
# Test de aislamiento por consumer
iex> Candil.Context.Store.create(:posadero, "s1")
iex> Candil.Context.Store.create(:opencode, "s1")
iex> {:ok, _} = Candil.Context.Store.get(:posadero, "s1")
iex> {:ok, _} = Candil.Context.Store.get(:opencode, "s1")
iex> {:error, :not_found} = Candil.Context.Store.get(:cli, "s1")
```

---

## 18. Fase 5 — MCP

**Objetivo**: Candil expone y consume MCP (JSON-RPC 2.0).

**Días estimados**: 3-4.

### 18.1 — Módulos

- `lib/candil/mcp/protocol.ex`
- `lib/candil/mcp/message.ex`
- `lib/candil/mcp/error.ex`
- `lib/candil/mcp/transport/stdio.ex`
- `lib/candil/mcp/transport/http.ex`
- `lib/candil/mcp/server.ex`
- `lib/candil/mcp/server/tools.ex`
- `lib/candil/mcp/server/resources.ex`
- `lib/candil/mcp/client.ex`
- `lib/candil/mcp/client/stdio.ex`
- `lib/candil/mcp/client/http.ex`

### 18.2 — `Candil.MCP.Protocol`

```elixir
defmodule Candil.MCP.Protocol do
  @version "2024-11-05"

  def encode(%{method: m, params: p, id: id}) do
    Jason.encode!(%{jsonrpc: "2.0", method: m, params: p, id: id})
  end

  def encode(%{result: r, id: id}) do
    Jason.encode!(%{jsonrpc: "2.0", result: r, id: id})
  end

  def encode(%{error: e, id: id}) do
    Jason.encode!(%{jsonrpc: "2.0", error: e, id: id})
  end

  def decode(binary) do
    case Jason.decode(binary) do
      {:ok, %{"jsonrpc" => "2.0"} = msg} -> {:ok, msg}
      {:ok, _} -> {:error, :invalid_jsonrpc}
      {:error, reason} -> {:error, reason}
    end
  end

  def version, do: @version
end
```

### 18.3 — `Candil.MCP.Server`

```elixir
defmodule Candil.MCP.Server do
  use GenServer

  def start_link(opts) do
    transport = Keyword.get(opts, :transport, :stdio)
    case transport do
      :stdio -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      :http -> start_http(opts)
    end
  end

  defp start_http(opts) do
    port = Keyword.get(opts, :port, 7778)
    children = [
      {Bandit, plug: Candil.MCP.Transport.Http, scheme: :http, port: port}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.HTTP)
  end

  # ── Callbacks (stdio) ─────────────────────────────────────────

  @impl true
  def init(opts) do
    tools = Keyword.get(opts, :tools, :registered)
    {:ok, %{tools: tools}}
  end

  @impl true
  def handle_info({:input, line}, state) do
    with {:ok, msg} <- Candil.MCP.Protocol.decode(line),
         response <- handle_message(msg, state) do
      IO.puts(Candil.MCP.Protocol.encode(response))
    end
    {:noreply, state}
  end

  defp handle_message(%{"method" => "initialize", "id" => id}, _state) do
    %{id: id, result: %{
      protocolVersion: Candil.MCP.Protocol.version(),
      capabilities: %{tools: %{}, resources: %{}},
      serverInfo: %{name: "candil", version: Application.spec(:candil, :vsn) |> to_string()}
    }}
  end

  defp handle_message(%{"method" => "tools/list", "id" => id}, state) do
    tools = list_tools(state)
    %{id: id, result: %{tools: Enum.map(tools, &tool_to_mcp/1)}}
  end

  defp handle_message(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name, "arguments" => args}}, _state) do
    case Candil.Tool.call(name, args) do
      {:ok, result} ->
        %{id: id, result: %{content: [%{type: "text", text: inspect(result)}]}}
      {:error, reason} ->
        %{id: id, error: %{code: -32603, message: inspect(reason)}}
    end
  end

  defp handle_message(%{"id" => id}, _state) do
    %{id: id, error: %{code: -32601, message: "method not found"}}
  end

  defp list_tools(:registered), do: Candil.Tool.list()
  defp list_tools(list) when is_list(list), do: list
  defp list_tools(mods) when is_list(mods), do: Enum.map(mods, & &1.__tool__())

  defp tool_to_mcp(%Candil.Tool{name: name, description: desc, schema: schema}) do
    %{name: name, description: desc, inputSchema: schema}
  end
end
```

### 18.4 — `Candil.MCP.Client`

```elixir
defmodule Candil.MCP.Client do
  def connect(opts) do
    transport = Keyword.get(opts, :transport, :http)

    case transport do
      :http -> {:ok, %{type: :http, url: opts[:url], id_counter: :atomics.new(1, [])}}
      :stdio -> connect_stdio(opts)
    end
  end

  defp connect_stdio(opts) do
    cmd = opts[:command]
    args = opts[:args] || []

    port = Port.open({:spawn_executable, cmd}, [
      :binary, :exit_status, args: args, :stderr_to_stdout
    ])

    {:ok, %{type: :stdio, port: port, id_counter: :atomics.new(1, [])}}
  end

  def list_tools(client) do
    call(client, "tools/list", %{})
  end

  def call_tool(client, name, args) do
    call(client, "tools/call", %{name: name, arguments: args})
  end

  defp call(%{type: :http, url: url, id_counter: counter} = _client, method, params) do
    id = :atomics.add_get(counter, 1, 1)
    body = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params, id: id})

    case Apero.Http.post(url, body, [{"content-type", "application/json"}]) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)["result"]}
      error -> error
    end
  end

  defp call(%{type: :stdio, port: port, id_counter: counter}, method, params) do
    id = :atomics.add_get(counter, 1, 1)
    body = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params, id: id})
    Port.command(port, body <> "\n")

    receive do
      {^port, {:data, response}} ->
        {:ok, Jason.decode!(response)["result"]}
    after
      30_000 -> {:error, :timeout}
    end
  end

  def disconnect(%{type: :stdio, port: port}) do
    Port.close(port)
    :ok
  end
  def disconnect(_), do: :ok
end
```

### 18.5 — Criterio de done

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | candil mcp serve --transport stdio
# Debe imprimir un JSON con las tools registradas
```

---

## 19. Fase 6 — RAG

**Objetivo**: indexar y consultar documentos.

**Días estimados**: 3-4.

### 19.1 — Módulos

- `lib/candil/rag/chunker.ex`
- `lib/candil/rag/chunk.ex`
- `lib/candil/rag/document.ex`
- `lib/candil/rag/index.ex`
- `lib/candil/rag/index/memory.ex`
- `lib/candil/rag/index/postgres.ex` (opcional)
- `lib/candil/rag/retrieval.ex`
- `lib/candil/rag/rerank.ex`
- `lib/candil/rag/embedder.ex`

### 19.2 — `Candil.RAG.Chunker`

```elixir
defmodule Candil.RAG.Chunker do
  @spec chunk(String.t(), keyword()) :: [String.t()]
  def chunk(text, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :sentence)
    size = Keyword.get(opts, :size, 512)
    overlap = Keyword.get(opts, :overlap, 50)

    case strategy do
      :sentence -> chunk_sentence(text, size, overlap)
      :paragraph -> chunk_paragraph(text, size, overlap)
      :fixed -> chunk_fixed(text, size, overlap)
    end
  end

  defp chunk_sentence(text, size, overlap) do
    sentences = String.split(text, ~r/(?<=[.!?])\s+/)

    sentences
    |> Enum.chunk_every(div(size, 20), max(1, div(overlap, 20)), :discard)
    |> Enum.map(&Enum.join(&1, " "))
  end

  defp chunk_paragraph(text, size, _overlap) do
    text
    |> String.split(~r/\n\s*\n/)
    |> Enum.flat_map(fn para ->
      if String.length(para) <= size, do: [para], else: chunk_fixed(para, size, 0)
    end)
  end

  defp chunk_fixed(text, size, overlap) do
    step = max(1, size - overlap)

    text
    |> String.codepoints()
    |> Enum.chunk_every(step, step, :discard)
    |> Enum.map(&Enum.join/1)
  end
end
```

### 19.3 — `Candil.RAG.Index.Memory`

```elixir
defmodule Candil.RAG.Index.Memory do
  use GenServer

  # state: %{indexes: %{name => [%Chunk{}]}}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(name), do: GenServer.call(__MODULE__, {:create, name})
  def add(name, chunks), do: GenServer.call(__MODULE__, {:add, name, chunks})
  def search(name, query_embedding, top_k), do: GenServer.call(__MODULE__, {:search, name, query_embedding, top_k})
  def drop(name), do: GenServer.call(__MODULE__, {:drop, name})
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(_), do: {:ok, %{indexes: %{}}}

  @impl true
  def handle_call({:create, name}, _from, state) do
    {:reply, :ok, put_in(state.indexes[name], [])}
  end

  def handle_call({:add, name, chunks}, _from, state) do
    current = Map.get(state.indexes, name, [])
    {:reply, :ok, put_in(state.indexes[name], current ++ chunks)}
  end

  def handle_call({:search, name, query_emb, top_k}, _from, state) do
    chunks = Map.get(state.indexes, name, [])

    results =
      chunks
      |> Enum.map(fn chunk ->
        score = cosine_similarity(chunk.embedding, query_emb)
        {chunk, score}
      end)
      |> Enum.sort_by(fn {_, score} -> -score end)
      |> Enum.take(top_k)
      |> Enum.map(fn {chunk, score} -> %{chunk | score: score} end)

    {:reply, {:ok, results}, state}
  end

  def handle_call({:drop, name}, _from, state) do
    {:reply, :ok, %{state | indexes: Map.delete(state.indexes, name)}}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state.indexes), state}
  end

  defp cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0, fn {x, y}, acc -> acc + x * y end)
    na = :math.sqrt(Enum.reduce(a, 0, fn x, acc -> acc + x * x end))
    nb = :math.sqrt(Enum.reduce(b, 0, fn x, acc -> acc + x * x end))
    if na == 0 or nb == 0, do: 0.0, else: dot / (na * nb)
  end
end
```

### 19.4 — Criterio de done

```bash
candil rag index mydocs ./docs
candil rag query mydocs "how to configure X"
# Debe devolver los chunks más relevantes
```

---

## 20. Fase 7 — Migrar ropero

**Objetivo**: ropero desaparece; los modelos están en Candil.

**Días estimados**: 1-2.

### 20.1 — Correr migración

```bash
cd ~/cacafuti/candil
mix candil.migrate --from-ropero ~/cacafuti/lasaca/ropero/ropero.d/ \
  --output ~/.config/candil/candil.toml
```

### 20.2 — Revisar el TOML a mano

**Verificaciones**:

- [ ] Cada modelo tiene `type`, `engine`, `context_size`, `usage`.
- [ ] Los aliases públicos (`coder`, `verifier`, `designer`, `analyst`, `coder_lite`) aparecen como `[model.X]`.
- [ ] Los puertos pineados (`embed: 9990`, `qwenvision: 9991`) están en `port = X`.
- [ ] Los args complejos (con comillas JSON, tipos numéricos) se preservan.
- [ ] Los modelos external (`airgptoss`) se marcan con el engine correcto.

**Ajustes manuales probables**:

- Añadir `[model.X.source]` con `kind = "huggingface_gguf"` y `repo`/`file` correctos (el migrate solo puede inferir `already_present`).
- Comentar args que no apliquen.
- Ajustar `usage` si el migrate no lo infiere bien.

### 20.3 — Verificar arranque

```bash
candil models list
candil run coder --background
candil status
candil stop coder
candil run verifier --background
candil status
```

Cada modelo arranca, responde, y se para.

### 20.4 — Borrar ropero

```bash
cd ~/cacafuti/lasaca
# Editar repos.yaml: quitar la entrada de ropero
./lasaca.sh --status  # verificar
git add repos.yaml
git commit -m "chore(ropero): remove, absorbed by candil 4.0"
git rm -r ropero/
git commit -m "chore(ropero): delete directory"
```

### 20.5 — Criterio de done

```bash
candil models list | grep -c "coder\|verifier\|analyst\|designer\|embed"
# Debe salir >= 5
ls ~/cacafuti/lasaca/ropero 2>&1 | grep -q "No such" && echo "ropero borrado"
```

---

## 21. Fase 8 — Cablear Posadero

**Objetivo**: Posadero usa Candil en vez de su cliente HTTP suelto.

**Días estimados**: 3-4.

### 21.1 — Dep

**Archivo**: `~/cacafuti/lasaca/posadero/mix.exs`.

```elixir
{:candil, path: "../../candil"},
```

### 21.2 — Reemplazar cliente HTTP

Buscar en `posadero/lib/` los usos de `HTTPoison` o `localhost:9999`:

```bash
cd ~/cacafuti/lasaca/posadero
grep -rln "localhost:9999\|HTTPoison\|:9998\|llama.cpp\|llama-server" lib/
```

Reemplazar por llamadas a Candil:

```elixir
# Antes:
HTTPoison.post("http://localhost:9999/v1/chat/completions", body, headers)

# Después:
Candil.chat(:coder, messages, consumer: :posadero)
```

### 21.3 — Reemplazar embeddings

```elixir
# Antes:
HTTP.post("http://localhost:9990/v1/embeddings", ...)

# Después:
Candil.embed(:embed, texts, consumer: :posadero)
```

### 21.4 — Exponer tools del vault vía MCP

```elixir
Candil.MCP.Server.start_link(
  transport: :stdio,
  tools: Posadero.Tools.all()
)
```

### 21.5 — Criterio de done

```bash
cd ~/cacafuti/lasaca/posadero
mix deps.get
mix compile --warnings-as-errors
mix test  # 0 failures
grep -r "HTTPoison\|localhost:9999" lib/ | wc -l  # 0
```

---

## 22. Fase 9 — Migrar arriero

**Objetivo**: portar los comandos de arriero a un CLI Elixir con Alaja.

**Días estimados**: 5-7.

### 22.1 — Comandos a portar

Según los documentos previos, arriero tiene:

- `status` (ya cubierto por `candil status`)
- `ask`
- `do`
- `version`
- `wiki adr` / `wiki new` / `wiki summary` / `wiki recent`

**Recomendación**: los comandos específicos del vault (`wiki *`) **no son de Candil**; van a un CLI de Posadero o a un nuevo CLI `posadero`. Los comandos genéricos de operación de modelos ya están en Candil.

### 22.2 — Plan

1. Crear `posadero/lib/posadero/cli.ex` con Alaja.
2. Portar los comandos que falten.
3. Cablear las 29 tools del vault vía Candil.MCP.
4. Deprecar arriero (repo Go).

### 22.3 — Criterio de done

```bash
posadero --help
posadero wiki recent
posadero ask "..."
# Funcionan
```

---

## 23. Fase 10 — Borrar

**Días estimados**: 1.

- `gunter` fuera (ya no hace falta, opencode se configura aparte).
- `arriero` fuera (migrado en Fase 9).
- `ropero` fuera (absorbido en Fase 7).
- `elpaso` fuera (portado en Fase 3).
- Actualizar `repos.yaml`, `README.md`, `ARCHITECTURE.md`.

### Criterio de done

```bash
ls ~/cacafuti/lasaca/ | grep -E "ropero|arriero|gunter"  # nada
grep -c "ropero\|arriero" ~/cacafuti/lasaca/repos.yaml  # 0
```

---

# Apéndices

## Apéndice A — Mapeo ElPaso → Candil

| Módulo ElPaso                            | Módulo Candil                        | Acción                                                |
| ---------------------------------------- | ------------------------------------ | ----------------------------------------------------- |
| `Domain.Router`                          | `Candil.Router`                      | Portar (adaptar a `%Model{}` en vez de `Personality`) |
| `Domain.DecisionEngine`                  | `Candil.Router.DecisionEngine`       | Portar (4 capas: keyword → embedding → LLM → default) |
| `Domain.DecisionEngine.DecisionCache`    | `Candil.Router.Cache`                | Portar (ETS)                                          |
| `Domain.DecisionEngine.EmbeddingMatcher` | `Candil.Router.EmbeddingMatcher`     | Portar                                                |
| `Domain.DecisionEngine.LLMClassifier`    | `Candil.Router.LLMClassifier`        | Portar                                                |
| `Domain.DecisionEngine.Scorer`           | `Candil.Router.Scorer`               | Portar (adaptar a reglas TOML)                        |
| `Domain.Router.TaskCategories`           | `Candil.Router.TaskCategories`       | Portar                                                |
| `Domain.Router.ModelState`               | `Candil.Router.ModelState`           | Portar                                                |
| `Domain.RouterAnalyzer`                  | `Candil.Router.Analyzer`             | Portar (sin Ecto)                                     |
| `Domain.AutoTuner`                       | `Candil.Router.AutoTuner`            | Portar (opt-in)                                       |
| `Domain.Router.Cluster`                  | —                                    | **Descartar** (no multi-nodo)                         |
| `Context.Storage`                        | `Candil.Context.Backend.Postgres`    | Portar como **opcional**                              |
| `Context.SessionContext`                 | `Candil.Context.Session` + `Store`   | Portar con backend ETS                                |
| `Context.Schemas.*`                      | `Candil.Context.Schemas.*`           | Portar como **opcional**                              |
| `Context.ContextBuilder`                 | `Candil.Context.Builder`             | Portar                                                |
| `Context.ContextSummarizer`              | `Candil.Context.Summarizer`          | Portar (usa `Inference.chat_local`)                   |
| `Context.PrefixManager`                  | `Candil.Context.PrefixManager`       | Portar (ETS con TTL)                                  |
| `Context.TokenCounter`                   | `Candil.Conversation.TokenEstimator` | **Ya existe** — no portar                             |
| `Context.SessionSupervisor`              | `Candil.Context.SessionSupervisor`   | Portar (DynamicSupervisor)                            |
| `HTTP.Server`                            | `Candil.Gateway.Endpoint`            | Reescribir con **Bandit**                             |
| `HTTP.AnthropicProxy`                    | `Candil.Gateway.Handlers.Messages`   | Portar                                                |
| `HTTP.MessageNormalizer`                 | `Candil.Gateway.MessageNormalizer`   | Portar                                                |
| `HTTP.Dashboard`                         | —                                    | **Descartar** (sin web)                               |
| `Security.Auth`                          | `Candil.Gateway.Auth`                | Portar (solo API key)                                 |
| `Security.JWT`                           | `Candil.Gateway.Auth`                | Portar (opcional)                                     |
| `Security.RateLimiter`                   | `Candil.RateLimiter`                 | **Ya existe** — ampliar con per-consumer              |
| `Security.Secrets`                       | —                                    | **Descartar**                                         |
| `CostManager`                            | `Candil.Cost`                        | Ampliar (per-consumer)                                |
| `Domain.EngineManager`                   | `Candil.Engine`                      | **Ya existe** — no portar                             |
| `Domain.LlamaServerManager`              | `Candil.Engine.Server`               | **Ya existe** — no portar                             |
| `Domain.ModelManager`                    | `Candil.EnginePool` + `Config`       | **Ya existe**                                         |
| `Domain.PersonalityManager`              | —                                    | **Descartar** (fuera de scope)                        |
| `Downloader.ModelDownloader`             | `Candil.Installer`                   | Ampliar con `source.kind`                             |
| `Cluster.NodeRegistry`                   | —                                    | **Descartar**                                         |
| `Bootstrap`                              | —                                    | **Descartar**                                         |
| `Ecosystem`                              | —                                    | **Descartar**                                         |
| `Repo`                                   | `Candil.Context.Backend.Postgres`    | Portar como opcional                                  |
| CLI + 17 Mix tasks                       | `Candil.CLI`                         | Reescribir con Alaja                                  |
| `Doctor`                                 | `Candil.CLI.Commands.Doctor`         | Portar; usa Botica si está                            |

## Apéndice B — Mapeo Ropero → TOML

| Elemento Ropero            | Elemento Candil                                   | Ejemplo                                   |
| -------------------------- | ------------------------------------------------- | ----------------------------------------- |
| `ropero.d/<modelo>.sh`     | `[model.<alias>]`                                 | `ropero.d/qwencoder.sh` → `[model.coder]` |
| `MODEL_ALIAS="coder"`      | `alias = "coder"`                                 | Directo                                   |
| `MODEL_GGUF="X.gguf"`      | `source.file = "X.gguf"`                          | Directo                                   |
| `MODEL_CTX=131072`         | `context_size = 131072`                           | Directo                                   |
| `MODEL_PORT=9990`          | `port = 9990`                                     | Directo                                   |
| `MODEL_NGL=30`             | `args."--n-cpu-moe" = "30"`                       | Convertir                                 |
| `MODEL_CACHE_K/V=q8_0`     | `args."--cache-type-k/v" = "q8_0"`                | Convertir                                 |
| `get_model_args_X()`       | `[model.X.args]`                                  | Parsear                                   |
| `--n-gpu-layers -1`        | `"--n-gpu-layers" = "-1"`                         | Convertir                                 |
| `--jinja`                  | `"--jinja" = true`                                | Boolean                                   |
| Entry point `ropero`       | `candil` CLI                                      | Reescribir                                |
| `_common.sh`               | —                                                 | Descartar                                 |
| `00-utils.sh`, `01-env.sh` | —                                                 | Descartar                                 |
| `20-compile-llama.sh`      | —                                                 | `Candil.Installer`                        |
| `21-download-models.sh`    | `candil models pull`                              | Reescribir                                |
| `MODEL_ENGINE="airllm"`    | `engine = "airllm"`                               | Directo                                   |
| `MODEL_PATH="X"`           | `source.path = "X"`                               | Directo                                   |
| Alias público              | `[model.<public_alias>]` + `[model.<file_alias>]` | Duplicar bloque                           |

## Apéndice C — Contradicciones resueltas

| Punto                  | Doc 1                                       | Doc 2                                                                         | **Decisión final**                                   | Motivo                                                 |
| ---------------------- | ------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------ |
| **Alaja**              | `{:alaja, github: ...}`                     | `{:alaja, path: "../alaja"}`                                                  | **path dep**                                         | Iteración rápida; Hex no está al día con el DSL actual |
| **Puerto Gateway**     | 9999 → corregido a 10000                    | 7777                                                                          | **7777**                                             | Rango limpio, lejos de engines                         |
| **Puerto MCP**         | 9997                                        | 7778                                                                          | **7778**                                             | Contiguo al gateway                                    |
| **Puerto engines**     | 9998/9999 (ropero) + auto                   | 9998/9999 + auto                                                              | **9990-9999 fijos + auto 10000+**                    | Generaliza ropero (9990 embed, 9991 qwenvision)        |
| **Consumer config**    | `[candil] consumer = "default"`             | `[consumer.X]` con `model_default`, `max_concurrent`, `rate_limit_per_minute` | **`[consumer.X]` rico + `consumer:` keyword en API** | Cubre más casos                                        |
| **`source` de modelo** | Campos planos (`model_dir`, `download_url`) | Bloque `[model.X.source]` con 5 kinds                                         | **Bloque con 5 kinds**                               | Cubre ropero y más                                     |
| **Persistencia**       | No hay sección                              | `[persistence]` con `backend = "ets" \| "postgres"`                           | **Sí, `[persistence]`**                              | Permite ETS puro por defecto                           |
| **EnginePool**         | Registro de N vivos                         | N concurrentes + LRU cuando excede                                            | **Registro de N + LRU solo al exceder capacidad**    | Ambos tienen razón                                     |
| **Consumidores**       | `consumer:` keyword                         | `consumer_id` de 1ª clase, endpoints `/c/:cid/...`                            | **Ambos: keyword + endpoints**                       | Coexisten                                              |
| **Auth Gateway**       | `api_keys = [...]` en TOML                  | `{ env = "CANDIL_GATEWAY_KEY" }`                                              | **`api_keys = [...]` en TOML + `{ env = ... }`**     | Composición                                            |
| **Fases**              | 10 fases (~25-35d)                          | 8 fases (~17-25d)                                                             | **10 fases**                                         | Incluye migración y borrado reales                     |
| **Ecto**               | Opcional                                    | `optional: true` en deps                                                      | **Opcional con deps opcionales**                     | Mismo resultado                                        |
| **Capas**              | 6 capas                                     | No las enumera                                                                | **6 capas**                                          | Ayudan a razonar la dirección única                    |
| **Posadero**           | Fase 8 completa                             | Excluido                                                                      | **Incluido como Fase 8**                             | Es parte del ciclo                                     |
| **`trebejo`**          | `optional: true, runtime: false`            | Opt-in                                                                        | **`optional: true, runtime: false`**                 | Estándar                                               |

## Apéndice D — Reglas duras

1. **Un solo `mix.exs`**. Sin submódulos.
2. **`consumer` como parámetro** en todo lo que tenga estado por sesión.
3. **Config en TOML**. `config.exs` sigue funcionando para retrocompat.
4. **ETS por defecto**, Postgres opcional.
5. **Ningún GenServer gigante**. Cada uno tiene una responsabilidad clara.
6. **Ningún `Process.sleep`** en producción, salvo health polling.
7. **Ningún `String.to_atom/1`** con input del usuario. Los aliases vienen del TOML (confiable) o de la API (validar contra existentes).
8. **Cero deps para JSON-RPC**. Se escribe con stdlib (Jason para JSON).
9. **Candil no depende de Posadero**. Posadero depende de Candil. Nunca al revés.
10. **Candil no depende de Alaja** salvo para el CLI. El resto no la usa.
11. **Toda API pública tiene `@spec`**. Dialyzer limpio.
12. **Toda config tiene default razonable**. Si el TOML no está, el CLI arranca.

## Apéndice E — Preguntas abiertas

No bloquean las fases 0-2. Se deciden antes de las fases 3+.

| #       | Pregunta                                        | Bloquea | Recomendación                                     |
| ------- | ----------------------------------------------- | ------- | ------------------------------------------------- |
| **C13** | ¿Qué modelo de embeddings por defecto?          | Fase 3  | `embed` (jina-code 1.5b), según ropero            |
| **C14** | ¿Cómo se declaran los prompts de clasificación? | Fase 3  | En el TOML, bajo `[router.classifier]`            |
| **C15** | ¿Cómo se declara la afinidad consumer→modelo?   | Fase 3  | `[consumer.X] model_default`                      |
| **C16** | ¿El `AutoTuner` corre por defecto?              | Fase 3  | No, opt-in con `[router] auto_tune = true`        |
| **C17** | ¿Eviction de sessions: LRU o TTL?               | Fase 4  | **TTL** (24h) + **LRU** al exceder `max_sessions` |
| **C18** | ¿El Summarizer usa qué modelo?                  | Fase 4  | Configurable en `[context] summarizer_model`      |
| **C19** | ¿MCP server por defecto HTTP o stdio?           | Fase 5  | **stdio** (default), HTTP opt-in                  |
| **C20** | ¿El shim stdio arranca Candil?                  | Fase 5  | No; falla con mensaje claro si Candil no corre    |
| **C21** | ¿RAG rerank opt-in o por defecto?               | Fase 6  | **opt-in**                                        |

---

## Cuadro resumen de fases

| Fase      | Qué                                  | Días      | Salida              |
| --------- | ------------------------------------ | --------- | ------------------- |
| 0         | Saneamiento (9 bugs + tests + credo) | 1-2       | Candil 3.0.1        |
| 1         | Config TOML + migrate                | 2-3       | Candil 4.0-alpha1   |
| 2         | CLI con Alaja                        | 2         | Candil 4.0-alpha2   |
| 3         | Router + Gateway                     | 3-4       | Candil 4.0-beta     |
| 4         | Context compartido                   | 2-3       | Candil 4.0-beta2    |
| 5         | MCP                                  | 3-4       | Candil 4.0-rc1      |
| 6         | RAG                                  | 3-4       | Candil 4.0-rc2      |
| 7         | Migrar ropero                        | 1-2       | ropero borrado      |
| 8         | Cablear Posadero                     | 3-4       | posadero usa candil |
| 9         | Migrar arriero                       | 5-7       | arriero borrado     |
| 10        | Borrar (gunter, elpaso)              | 1         | elpaso borrado      |
| **Total** |                                      | **26-36** |                     |

---

## Comandos de arranque — Fase 0

```bash
cd ~/cacafuti/candil

# 1. Baseline
mix deps.get
mkdir -p docs/baseline
mix compile --warnings-as-errors 2>&1 | tee docs/baseline/compile.txt
mix test 2>&1 | tee docs/baseline/test.txt
mix credo --strict 2>&1 | tee docs/baseline/credo.txt
mix dialyzer 2>&1 | tee docs/baseline/dialyzer.txt

# 2. Arreglar tests rotos (ver §13.2)
$EDITOR test/candil/config_test.exs
$EDITOR test/candil/engine_test.exs

# 3. Arreglar Backend.LlamaCpp
$EDITOR lib/candil/backend/llama_cpp.ex
$EDITOR test/candil/backend/llama_cpp_test.exs

# 4. Arreglar Backend.OpenAICompat
$EDITOR lib/candil/backend/openai_compat.ex
$EDITOR test/candil/backend/openai_compat_test.exs

# 5. Config.register_provider
$EDITOR lib/candil/config.ex

# 6. Detector
$EDITOR mix.exs
$EDITOR lib/candil/detector.ex
$EDITOR lib/candil/installer.ex

# 7. EnginePool
$EDITOR lib/candil/engine_pool.ex
$EDITOR test/candil/engine_pool_test.exs

# 8. Verificar
mix test
mix credo --strict
mix dialyzer

# 9. Tag
git add -A
git commit -m "fix(candil): 6 bugs pre-4.0 (backend stubs, config, detector, pool, tests)"
git tag candil-3.0.1
git push origin main --tags
```

---

**Fin del documento.**

_Cualquier cambio de alcance debe reflejarse aquí antes de tocar código._
