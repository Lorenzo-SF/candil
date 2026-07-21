# Candil — Document Index

> v2.1.0 — LLM inference and model management for Elixir

| Document | Description |
|----------|-------------|
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | Complete design reference: subsystems (Public API, Engine Lifecycle, Inference, HTTP Transport, Configuration, Installer/Detector, Conversation/Cost, Health), dependencies, supervision tree |
| [`AUDIT.md`](./AUDIT.md) | Code quality audit: path traversal in server/installer, 0% coverage on HTTP + engine server, 30.3% overall, complexity 11, top 5 fixes |
| [`README.md`](../README.md) | English README — installation, usage, API overview |
| [`docs/README.es.md`](./README.es.md) | Spanish README |
| [`docs/candil_llm.md`](./candil_llm.md) | LLM usage guide — engine lifecycle, local vs remote models, code examples |
| [`CHANGELOG.md`](../CHANGELOG.md) | Version history and release notes |
| [`LICENSE.md`](../LICENSE.md) | MIT License |
| [`plan_candil.md`](./plan_candil.md) | Historical implementation plan (engine pool, LRU) |

### Ecosystem context

Candil is the **LLM inference layer** of the Lorenzo-SF ecosystem.
It depends on Apero (HTTP, retry), Arrea (circuit breaker, long-running),
and Trebejo (OS arch). It is consumed by Delfos for all LLM operations.
See the [dependency graph](../docs/ARCHITECTURE.md#5-consumed-by).
