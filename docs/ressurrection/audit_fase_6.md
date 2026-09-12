# candil — ressurrection_fase_6: análisis meticuloso

> **Fecha**: 2026-09-12
> **Rama**: `ressurrection_fase_6`
> **Tamaño**: 45 módulos, ~5,872 LOC

---

## 1. Dominio

candil es el **LLM SDK** del ecosistema. Backend OpenAI-compat (cubre OpenAI,
Anthropic, Ollama, Azure), local engines (llama.cpp), streaming, tool calls.

**Migración zaguan → candil**: zaguan tiene `Zaguan.LLMClient` propio (555 LOC) +
`Zaguan.Embeddings` (228 LOC). Ambos serían reemplazables por candil.

---

## 2. Análisis

### P0-1 — `Candil.Stream.do_stream` task linked al caller

**Archivo**: `lib/candil/stream.ex:151-165`
**Tipo**: reliability
**Impacto**: el Task se crea con `Task.start_link/1` que LINKEA al caller. Si el caller
muere, el streaming se mata. En la mayoría de casos esto es OK pero impide streams
supervisados.
**Fix**: usar `Task.start/1` (no linked) + cleanup explícito en el resource teardown.

### P0-2 — `Candil.Backend.OpenAICompat` retry por defecto activo

**Archivo**: `lib/candil/backend/openai_compat.ex:38`
**Tipo**: design choice
**Impacto**: `retry: true` por defecto. Si el caller quiere control, debe pasar `retry: false`.
**Decisión**: OK — retry por defecto es razonable.

---

## 3. Fix aplicado

P0-1: `Task.start` en lugar de `Task.start_link`. No link, cleanup explícito.
