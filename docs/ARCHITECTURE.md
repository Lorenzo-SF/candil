# Candil — Architectural Reference

> LLM inference and model management for Elixir — v2.1.0

---

## 1. What is Candil

Candil is the **LLM inference engine** of the Lorenzo-SF ecosystem. It
provides a unified API for running local models (via `llama.cpp` / `llama-server`)
and remote models (OpenAI, Anthropic, Ollama, OpenAI-compatible, Azure OpenAI).
It handles engine lifecycle, model downloads (GGUF), chat completion,
streaming (SSE), embeddings, provider configuration, conversation management,
cost estimation, health checks, and circuit-broken HTTP transport.

---

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    Candil (Facade)                            │
│  lib/candil.ex — chat/2-5, embed/2-4, stream/3-5            │
├──────────────────────────────────────────────────────────────┤
│                       │                                       │
│               ┌───────▼───────┐                               │
│               │  Candil.Llm   │  (internal orchestrator)     │
│               │               │                               │
│               │ dispatch to   │                               │
│               │ local/remote  │                               │
│               └───────┬───────┘                               │
│                       │                                       │
│        ┌──────────────┴──────────────┐                       │
│        │                             │                        │
│  ┌─────▼──────┐               ┌─────▼──────┐                 │
│  │   Local    │               │   Remote   │                 │
│  │ inference  │               │ inference  │                 │
│  │            │               │            │                 │
│  │ llama.cpp  │               │ OpenAI     │                 │
│  │ via Engine │               │ Anthropic  │                 │
│  │ ── Server  │               │ Ollama     │                 │
│  │    (OS pr) │               │ Azure      │                 │
│  └─────┬──────┘               └─────┬──────┘                 │
│        │                            │                        │
│  ┌─────▼────────────────────────────▼──────┐                 │
│  │           Inference Engine              │                 │
│  │  Candil.Inference — chat_local/remote   │                 │
│  │  Candil.RequestBuilder — build bodies   │                 │
│  │  Candil.Stream — SSE parsing            │                 │
│  │  Candil.HTTP — circuit + retry + rate   │                 │
│  └──────────────────────────────────────────┘                 │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │              Engine Lifecycle                         │    │
│  │                                                      │    │
│  │  Engine.Server — GenServer over llama-server OS proc │    │
│  │  Engine.Server.External — externally-managed engines │    │
│  │  Engine.HealthPoller — periodic /health probe        │    │
│  │  EnginePool — LRU pool of running engines            │    │
│  │  Engine.Launcher — behaviour for custom launchers    │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │              Configuration                            │    │
│  │                                                      │    │
│  │  Config — ETS-based registry (engines/models/provid) │    │
│  │  ConfigManager — map-based config validation         │    │
│  │  Provider — struct with auth, URLs, type             │    │
│  │  Model — struct (local GGUF or remote name)          │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │              Download & Detection                     │    │
│  │                                                      │    │
│  │  Installer — download llama.cpp + GGUF (resume)      │    │
│  │  Detector — GPU detection (nvidia/amd/intel/apple)   │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. Subsystems

### 3.1 Public API (Candil + Candil.Llm)
- `chat/2-5` — text completion (local or remote)
- `embed/2-4` — embeddings (local or remote)
- `stream/3-5` — streaming chat with SSE callback
- `download_engine/1` — download llama.cpp binary
- `download_model/1` — download GGUF model file
- `start_engine/2` — start llama-server with model
- `stop_engine/1` — stop running engine
- `engine_healthy?/1` — health probe

### 3.2 Engine Lifecycle
- **Engine.Server** (GenServer): Manages `llama-server` OS process via
  `Arrea.LongRunning`. Builds CLI args, polls `/health`, registers in
  `Candil.Registry`. Auto port cleanup.
- **Engine.Server.External** (GenServer): For externally-managed engines
  (Docker, systemd, k8s via `Candil.Engine.Launcher`). Holds `base_url`,
  polls health, sends shutdown on terminate.
- **Engine.HealthPoller**: Shared health-polling logic. Probes `<base_url>/health`
  every 5s. Used by both Server implementations.
- **EnginePool** (GenServer): LRU pool of running engines. Ordered by recency.
  `get/0`, `put/1`, `evict/0`. Used for automatic engine selection.
- **Engine struct**: alias, binary_dir, host, port, context_size, etc.

### 3.3 Inference
- **Inference**: `chat_local/3`, `chat_remote/4`, `embed_local/3`, `embed_remote/4`.
  Builds provider-specific request bodies, parses responses (OpenAI, Anthropic,
  Ollama format). Validates context window. Emits telemetry.
- **RequestBuilder**: Normalizes messages, handles system prompts, streaming flag,
  tool definitions, stop sequences for each provider type.
- **Stream**: SSE parsing for all providers. Parses OpenAI, Anthropic, Ollama chunk
  formats. Calls user callback per token: `%{content:, finish_reason:, done:}`.

### 3.4 HTTP Transport (Candil.HTTP)
- Circuit breaker (`Arrea.CircuitBreaker`)
- Retry with exponential backoff (`Apero.Retry`)
- Sliding-window rate limiter
- `post_json/4`, `post_streaming/5`, `get/3`

### 3.5 Configuration
- **Config** (GenServer): ETS-based registry for engines, models, providers.
  Loads from application env on init. Resolves `{:system, "ENV_VAR"}` api_key
  tuples at lookup time.
- **ConfigManager**: Raw map-based config validation/normalization. Validates
  provider configs, provides defaults.
- **Provider struct**: Types: `:openai`, `:anthropic`, `:ollama`,
  `:openai_compatible`, `:azure_openai`. Generates `auth_headers/1`,
  `chat_url/1`, `embeddings_url/1`.
- **Model struct**: Local (GGUF + engine) or remote (model name + provider).
  Fields: alias, type, model_dir, filename, context_size, usage.

### 3.6 Installer & Detector
- **Installer**: Downloads llama.cpp binaries and GGUF models. Streams to disk
  (no full memory load), supports resume via HTTP Range, SHA-256 verification.
- **Detector**: System capability detection for llama.cpp binary selection.
  Detects OS (Apero.OS), arch (Trebejo.OS), GPU (nvidia-smi, rocminfo,
  vulkaninfo, sycl-ls, Metal). Builds asset pattern for GitHub release matching.

### 3.7 Conversation & Cost
- **Conversation**: Maintains message list, auto-trims to fit context window.
  Token estimation via `ceil(byte_size/4)`. Supports local and remote models.
- **Cost**: Built-in pricing table for OpenAI and Anthropic models.
  `estimate(model, input_tokens, output_tokens)` → `{:ok, float}` or `:unknown`.

### 3.8 Health
- `Candil.Health`: Provider health checks. Probes `<url>/v1/models` endpoint,
  returns reachability, latency, model count. `ping/3` sends a minimal embedding
  request to verify a model is loaded.

---

## 4. Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| **Apero** | path: ../apero | HTTP transport (`Apero.Http`), retry (`Apero.Retry`), OS detection (`Apero.OS`) |
| **Arrea** | path: ../arrea | Circuit breaker (`Arrea.CircuitBreaker`), long-running OS process (`Arrea.LongRunning`), Registry, Monitor, WorkerSupervisor |
| **Trebejo** | path: ../trebejo | OS architecture detection (`Trebejo.OS.arch/0`) |
| Jason | ~> 1.4 | JSON encoding/decoding for API requests |

Candil depends on **Apero** (HTTP), **Arrea** (resilience, process mgmt),
and **Trebejo** (OS detection).

---

## 5. Consumed by

| Project | What it uses |
|---------|--------------|
| **Delfos** | `Candil.Provider` struct, `Candil.chat` for LLM summarization/explanation, `Candil.embed` for embeddings, `Candil.Health.probe` for health checks, `Candil.HTTP` for API calls |

Candil is a leaf library: it does the LLM work for Delfos.

---

## 6. Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **local/remote split in Llm** | Single API (`chat/2-5`) handles both. Caller doesn't care where the model runs. |
| **Engine as OS process via Arrea.LongRunning** | Proper supervision, telemetry, crash isolation, and port cleanup. Not a bare `System.cmd`. |
| **Provider struct with URL generation** | Each provider knows its own API format. `chat_url/1`, `embeddings_url/1` encapsulate the variation. |
| **ETS config registry** | Hot-reloadable config without application restart. `{:system, "VAR"}` tuples defer resolution to lookup time. |
| **SSE streaming standardized** | All provider chunk formats normalized to `%{content:, finish_reason:, done:}` callback. Consumer writes one handler. |
| **Download with resume** | HTTP Range headers for interrupted downloads. Critical for multi-GB GGUF files. |
| **GPU detection** | Auto-selects the right llama.cpp binary (CUDA, ROCm, Vulkan, SYCL, Metal, CPU). No manual config. |
| **Circuit breaker on HTTP** | Prevents cascading failures when LLM endpoints are down. |

---

## 7. Supervision Tree

```
Candil.Application
  ├── Candil.Registry (Elixir.Registry)
  ├── Candil.Config (GenServer, ETS)
  ├── Candil.EnginePool (GenServer, LRU)
  └── Candil.EngineSupervisor (DynamicSupervisor)
        └── Candil.Engine.Server (GenServer, one per running engine)
```

---

## 8. Current State (v2.1.0 — Jul 2026)

- 24 source modules across 8 subsystems
- 19 test files
- Supports: llama.cpp (local), OpenAI, Anthropic, Ollama, OpenAI-compatible, Azure
- GPU detection: NVIDIA (nvidia-smi), AMD (rocminfo), Intel (sycl-ls), Apple (Metal), CPU fallback
- Streaming, embeddings, conversation management, cost estimation all operational
- Used by Delfos for all LLM operations
