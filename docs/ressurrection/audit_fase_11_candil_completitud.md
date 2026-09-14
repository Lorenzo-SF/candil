# candil — audit completitud (iter-041)

> **Fecha**: 2026-09-12
> **Tamaño**: 5,876 LOC, ~45 módulos
> **Tests**: 30 archivos
> **Meta**: candil 100% terminado

---

## Estado actual

| Área | LOC | Estado |
|------|-----|--------|
| `candil.ex` (facade) | ~150 | ✅ |
| `stream.ex` | 338 | ✅ (iter-028 fix) |
| `config.ex` | 271 | ✅ |
| `error.ex` | 260 | ✅ |
| `backend/openai_compat.ex` | 245 | ✅ |
| `engine.ex` | 230 | ✅ |
| `agent.ex` | 224 | ✅ |
| `inference/chat.ex` | 215 | ✅ |
| `tools.ex` | 205 | ✅ |
| `model.ex` | 191 | ✅ |
| `cost.ex` | 107 | ✅ |
| `embeddings.ex` | ~150 | ✅ |
| `inference.ex` | ~120 | ✅ |
| `config_manager.ex` | ~100 | ✅ |
| `cancellation.ex` | ~50 | ✅ |
| `health.ex` | ~80 | ✅ |
| `detector/` | ~150 | ✅ |
| `http/` | ~200 | ✅ |
| `engine_pool.ex` | ~80 | ✅ |
| `telemetry/` | ~150 | ✅ |

30 tests files.

## Gap identificado (iter-041)

### P2 — `Candil.Cost.format_price/1` no existe
**Archivo**: `lib/candil/cost.ex`
**Tipo**: UX
**Impacto**: no hay helper para formatear precios en formato humano
(`"$0.0075"`, `"$1.50"`, `"$1.5K"` para grandes).

### Plan iter-041

1. P2: `format_price/1` con currency formatting.
2. Tests: 4 nuevos.
3. Doc.
