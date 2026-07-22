# Candil v2.3.0 — Plan de Ejecución

> **Última actualización**: 2026-07-22
> **Auditoría original**: `AUDIT.md` (2026-07-19)
> **Auditoría complementaria**: revisión tras batch de calidad (2026-07-21)
> **Auditoría complementaria v2**: revisión + agrupación por impacto (2026-07-22)
> **Estado**: 5/5 comandos pasan. Pendientes: cobertura baja + algunos bugs específicos.

---

## 0. Estado actual (verificado 2026-07-21)

| Check | Resultado |
|-------|-----------|
| `mix format --check-formatted` | ✅ 0 cambios |
| `mix compile --warnings-as-errors` | ✅ 0 warnings |
| `mix credo --strict --format=json` | ✅ 0 issues |
| `mix test --cover` | ✅ 170 tests, 0 fail, coverage **31.9%** |
| `mix dialyzer` | ✅ 0 errors |

CHANGELOG `[Unreleased]` actualizado. Git history normalizado.

**Nota sobre coverage**: 31.9% es bajo. Cumple el mínimo (≥30% para framework) pero lejos del ideal (≥70%).

---

## 1. Resumen

| Severidad | Total | Realizadas | Pendientes |
|-----------|-------|------------|------------|
| 🔴 P0 | 1 | 1 | 0 |
| 🟠 P1 | 3 | 3 | 0 |
| 🟡 P2 | 7 | 4 | 3 |
| 🟢 P3 | 3 | 2 | 1 |
| **Refactors estructurales** | — | — | 3 |
| **Coverage gaps** | — | — | 4 |
| **Total tareas** | **14 + 7** | **10** | **11** |

**Esfuerzo restante estimado**: ~20h (incluye refactors + tests).

### Vista por impacto (ver §11 para detalle)

| Impacto | # tareas | Descripción |
|---------|----------|-------------|
| 🟢 LOCAL | 16 | Solo afecta a candil internamente (fixes security, types, tests) |
| 🟡 MEDIO | 4 | Refactors estructurales (Inference/HTTP/Conversation/Detector split) — afectan a delfos |
| 🔴 CRÍTICO | 0 | candil es leaf library, refactors mantienen API vía fachada |

**Conclusión**: candil tiene **0 tareas críticas** porque es una leaf library. Los 4 refactors estructurales (CAN-15..18) son MEDIO porque el consumer único (delfos) debe smoke-testear, pero como las fachadas mantienen API, el riesgo es bajo.

---

## 2. Tareas realizadas en este batch

### ✅ CAN-01: Restore HTTP result typing
- **Commit**: `1b68c0f` ("fix(candil): restore HTTP result typing")
- **Qué se hizo**:
  - `lib/candil/http.ex:231` `wrap_error/1` mantiene HTTP headers en el error tuple
  - Resuelve 12 errores dialyzer en cascada en `inference.ex` y `embeddings.ex`

### ✅ CAN-02: Fix health-check payload
- **Commit**: parte de `1b68c0f` o cercano
- **Qué se hizo**:
  - `lib/candil/health.ex:69` payload handling corregido
  - Resuelve 5 errores dialyzer (no_return + call)

### ✅ CAN-03: Replace `String.to_atom/1` con `to_existing_atom/1`
- **Commit**: `f9057e0` ("fix(candil): reject unknown config atoms")
- **Qué se hizo**:
  - `lib/candil/config.ex:266` ahora usa `String.to_existing_atom/1` con rescue
  - Elimina riesgo de memory exhaustion por user input

### ✅ CAN-04: Mock GitHub requests en detector tests
- **Commit**: `9dd351d` ("test(candil): isolate detector release requests")
- **Qué se hizo**:
  - `test/candil/detector_test.exs:34-48` ya no hace HTTP real a GitHub
  - Resuelve flaky test (1/3 runs fallaba)

### ✅ CAN-05: Strict credo pass
- **Commit**: `f28ab4d` ("chore(candil): satisfy strict credo")
- **Qué se hizo**:
  - 17 alias-usage issues en 8 ficheros corregidos
  - 0 issues en credo strict

### ✅ CAN-09: `ETS-based Candil.RateLimiter` module
- **Commit**: parte del batch (reviewar git log)
- **Qué se hizo**: módulo rate limiter basado en ETS creado

### ✅ CAN-10: Download timeout 30 min default
- **Cambio**: parte del batch
- **Qué se hizo**: timeout de descarga configurable, 30 min default

### ✅ CAN-11: `File.read!` → `File.read` en `verify_checksum`
- **Cambio**: parte del batch
- **Qué se hizo**: error handling mejorado

### ✅ CAN-13: `@doc` para `cost.ex`
- **Commit**: `26f629e` ("docs(candil): document cost helpers")
- **Qué se hizo**: 2 @doc añadidos en `lib/candil/cost.ex:51,65`

### ✅ Limpieza de artefactos
- **Commit**: parte del batch
- **Qué se hizo**: `erl_crash.dump` y `candil-2.0.0.tar` gitignored y removidos

### ✅ README + CHANGELOG
- **Commit**: `3e248e8`
- **Qué se hizo**: README actualizado con API usage, dependencies, OpenAI config, etc.

---

## 3. Tareas pendientes

### CAN-06: Remote model routing fix
- **Hallazgo**: P1 — `chat_local`/`embed_local` no enrutaban a remote cuando correspondía
- **Severidad**: 🟠 P1
- **Estado**: pendiente (verificar si ya está hecho)

### CAN-07: `stream_download` refactor
- **Hallazgo**: P2 — `installer.ex` tiene stream_download complejo
- **Severidad**: 🟡 P2
- **Estado**: pendiente
- **Ficheros**: `lib/candil/installer.ex`

### CAN-08: `reason()` type — add atoms + remove `term()` from union
- **Hallazgo**:
  - AUDIT P2 #7: `reason()` type union incluye `term()` → unsound (Dialyzer can't check exhaustiveness)
  - AUDIT P2: faltan atoms `:circuit_open`, `:execution_failed`
- **Severidad**: 🟡 P2
- **Estado**: pendiente
- **Ficheros**: `lib/candil/error.ex`
- **Pasos**:
  1. Reemplazar `@type reason :: ... | term()` por union específica
  2. Añadir `:circuit_open` y `:execution_failed` a la union
  3. Mantener `term()` solo en `wrap/1` (función de escape)
  4. Verificar con `mix dialyzer`
- **Verificación**: `mix dialyzer` (0 warnings)

### CAN-12: HTTP response type alias
- **Hallazgo**: P2 — `HTTP.response` type alias falta
- **Severidad**: 🟡 P2
- **Estado**: pendiente

### CAN-14: Verify `embeddings.ex` return spec
- **Hallazgo**: P2 — `@spec embed/2` declares `{:error, String.t()}` pero retorna `{:error, Exception.t()}`
- **Severidad**: 🟡 P2
- **Estado**: pendiente

---

## 4. Refactors estructurales

### CAN-15: Split `lib/candil/inference.ex` (409 líneas)
- **Hallazgo**: **409 líneas** con toda la lógica de inference (chat, embeddings, stream, parsing)
- **Severidad**: 🟠 Estructural
- **Ficheros**:
  - `lib/candil/inference.ex` (409 líneas)
  - `lib/candil/inference/` (nuevo)
- **Esfuerzo estimado**: 5-7h
- **Análisis estructural actual**:
  - Chat: `chat/2`, `chat_stream/2`, `parse_chat_response/2`, `parse_chat_chunk/2`
  - Embeddings: `embed/2`, `parse_embeddings_response/2`
  - Stream: lógica compartida
  - Errors: `handle_http_error/2`, `parse_ollama_embedding/2`
- **Plan de split**:
  - `inference.ex` (~100 líneas): fachada
  - `inference/chat.ex` (~150 líneas): chat + chat_stream + parsing
  - `inference/embeddings.ex` (~100 líneas): embed + parsing
  - `inference/streaming.ex` (~80 líneas): chunk parsing y SSE
  - `inference/errors.ex` (~50 líneas): HTTP error handling
- **Pasos detallados**:
  1. Extraer `errors.ex` (más simple)
  2. Extraer `embeddings.ex`
  3. Extraer `streaming.ex`
  4. Extraer `chat.ex`
  5. Inference como fachada
- **Verificación**: `mix test --cover` + `mix credo --strict` + `mix dialyzer`
- **Riesgos**: MEDIO. Inference es core de candil, consumido por mavis y arrea (potencialmente).

---

### CAN-16: Split `lib/candil/http.ex` (254 líneas)
- **Hallazgo**: 254 líneas con HTTP client + retry + circuit breaker integration
- **Severidad**: 🟡 Estructural
- **Ficheros**:
  - `lib/candil/http.ex` (254 líneas)
  - `lib/candil/http/` (nuevo)
- **Esfuerzo estimado**: 3-4h
- **Análisis**:
  - `post_json/4` (36 líneas)
  - `post_streaming/2` (40 líneas)
  - Retry logic
  - Circuit breaker integration
  - Header building
- **Plan de split**:
  - `http.ex` (~80 líneas): fachada
  - `http/client.ex` (~80 líneas): post_json, get
  - `http/streaming.ex` (~80 líneas): post_streaming, SSE
  - `http/retry.ex` (~50 líneas): retry logic

---

### CAN-17: Split `lib/candil/conversation.ex` (253 líneas)
- **Hallazgo**: 253 líneas con conversation history management
- **Severidad**: 🟡 Estructural
- **Esfuerzo estimado**: 3-4h
- **Plan**:
  - `conversation.ex` (~80 líneas): fachada
  - `conversation/history.ex` (~100 líneas): gestión de mensajes
  - `conversation/context.ex` (~80 líneas): windowing y truncation

---

### CAN-18: Split `lib/candil/detector.ex` (258 líneas)
- **Hallazgo**: 258 líneas con detección de GPU/modelos
- **Severidad**: 🟡 Estructural
- **Esfuerzo estimado**: 3-4h
- **Plan**:
  - `detector.ex` (~80 líneas): fachada
  - `detector/gpu.ex` (~120 líneas): nvidia-smi, rocminfo, vulkan detection
  - `detector/models.ex` (~80 líneas): model discovery, format detection

---

## 5. Coverage gaps (subir de 31.9% → 60%+)

### CAN-19: Tests para `HTTP` (post_json, retry, circuit breaker)
- **Hallazgo**: coverage muy baja en HTTP
- **Ficheros**: `test/candil/http_test.exs`
- **Esfuerzo**: 2h
- **Plan**:
  - Mocks con Bypass para HTTP responses
  - Tests de retry: success after N retries, max retries exceeded
  - Tests de circuit breaker integration

### CAN-20: Tests para `Inference` (chat, embeddings, stream)
- **Ficheros**: `test/candil/inference_test.exs`
- **Esfuerzo**: 2h

### CAN-21: Tests para `Conversation` (history, windowing)
- **Ficheros**: `test/candil/conversation_test.exs`
- **Esfuerzo**: 1h

### CAN-22: Tests para `Detector` con mocks robustos
- **Ficheros**: `test/candil/detector_test.exs` (ampliar)
- **Esfuerzo**: 1h

### CAN-23: Tests para `Model`, `Engine`, `Stream`
- **Ficheros**: `test/candil/{model,engine,stream}_test.exs`
- **Esfuerzo**: 2h

---

## 6. Dependencias externas

| Tarea | Dependencia |
|-------|-------------|
| CAN-15..18 | arrea, mavis (consumers de Inference) |
| CAN-19..23 | ninguna |

Candil **no depende de otros proyectos lorenzo-sf en runtime**.

---

## 7. Riesgos globales

1. **Coverage muy baja (31.9%)**: el mayor gap. Tests primero antes de refactors.
2. **CAN-15 Inference split**: core de candil. Muchos consumers.
3. **Mock robusto de HTTP**: tests deben cubrir timeouts, retries, circuit breaker.
4. **HTTP rate limit / circuit breaker**: funcionalidad crítica que necesita cobertura exhaustiva.

---

## 8. Comandos de verificación

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict --format=json
mix test --cover                    # objetivo: ≥60%
mix dialyzer

# Consumers (si cambia API):
(cd ../arrea && mix compile)
(cd ../mavis && mix compile)
```

---

## 9. CHANGELOG bullets para próximos lotes

Bajo `[Unreleased]`:

### Changed
- `Candil.Inference` split into Chat/Embeddings/Streaming/Errors (CAN-15)
- `Candil.HTTP` split into Client/Streaming/Retry (CAN-16)
- `Candil.Conversation` split into History/Context (CAN-17)
- `Candil.Detector` split into GPU/Models (CAN-18)

### Added
- Tests para HTTP, Inference, Conversation, Detector, etc. (CAN-19..23)

### Fixed
- Tareas CAN-XX según se completen

NO bumpear versión.

---

## 10. AUDIT v2 — Hallazgos adicionales no abordados (2026-07-22)

> Tareas del `AUDIT.md` original que **no tienen contraparte** en las secciones §3-§5 (CAN-01..CAN-23).

### CAN-24: Sanitize path traversal in `server.ex` + `installer.ex` (P0 security)
- **Hallazgo** (`AUDIT.md` §P0 #1 y #2):
  > `server.ex:107` `Path.join(model.model_dir, model.filename)` permite path traversal. Si un atacante controla `model.filename` con `"../../etc/passwd"`, llama a `llama-server` para leer archivos arbitrarios.
  > `installer.ex:94` `System.cmd("unzip", [..., dest_dir, ...])` con `dest_dir` user-controllable se vuelve command injection.
- **Severidad**: 🔴 P0 (security)
- **Ficheros**: `lib/candil/server.ex`, `lib/candil/installer.ex`, `lib/candil/engine.ex`
- **Esfuerzo**: 2h
- **Pasos**:
  1. En `Engine.binary_dir/1`, validar que el path no contiene `..` ni caracteres especiales
  2. Si inválido, retornar `{:error, :invalid_binary_dir}` o lanzar `ArgumentError`
  3. En `Server.build_args`, validar `model.filename` con regex `\A[a-zA-Z0-9._-]+\z`
  4. Tests:
     - Path traversal bloqueado: `model.filename = "../../etc/passwd"` → error
     - Binary dir con `..` bloqueado
- **Verificación**: `mix test` + `mix credo --all`
- **Impacto**: 🟢 LOCAL (defensiva, no cambia API)

### CAN-25: Tests para `HTTP` (cubierto por CAN-19) — nota
- **Nota**: AUDIT P0 #3 ("Test gap — core execution path untested") está cubierto por **CAN-19..CAN-23**.

### CAN-26: `LongRunning.start_link` can crash init on failure
- **Hallazgo** (`AUDIT.md` §P1 #4): `server.ex:59-72` `{:ok, lr_pid} = LongRunning.start_link(...)` crashes `init/1` si retorna `{:error, _}`.
- **Severidad**: 🟠 P1
- **Ficheros**: `lib/candil/server.ex`
- **Esfuerzo**: 30 min
- **Pasos**:
  1. Reemplazar `{:ok, lr_pid} = LongRunning.start_link(...)` por:
     ```elixir
     case LongRunning.start_link(...) do
       {:ok, lr_pid} -> ...
       {:error, reason} -> {:stop, reason}
     end
     ```
  2. Test que simule `LongRunning` retornando `{:error, :max_children}` y verifique que `init/1` retorna `{:stop, :max_children}` correctamente
- **Verificación**: `mix test` + `mix credo --all`
- **Impacto**: 🟢 LOCAL

### CAN-27: `post_json` return type spec correction
- **Hallazgo** (`AUDIT.md` §P2 #8): `@spec post_json(...) :: {:ok, map()}` pero el retorno es `{:ok, %{status: integer, body: any}}` — spec engañoso.
- **Severidad**: 🟡 P2
- **Ficheros**: `lib/candil/http.ex`
- **Esfuerzo**: 15 min
- **Pasos**:
  1. Definir `@type response :: %{status: integer, body: any, headers: map()}`
  2. Corregir `@spec post_json(...) :: {:ok, response()} | {:error, term()}`
  3. Verificar con `mix dialyzer`
- **Verificación**: `mix dialyzer` (0 warnings)
- **Impacto**: 🟢 LOCAL

### CAN-28: Rate limiter ETS-based (no process dictionary)
- **Hallazgo** (`AUDIT.md` §P2 #9): `http.ex:225-243` usa `Process.get/1` / `Process.put/2` — rate limiting per-process, no global. Silently wrong en GenServers con requests concurrentes.
- **Severidad**: 🟡 P2
- **Ficheros**: `lib/candil/http.ex`
- **Esfuerzo**: 3h
- **Pasos**:
  1. Crear `Candil.RateLimiter` GenServer con tabla ETS interna (¿ya existe? verificar CAN-09)
  2. Reemplazar `Process.put/get` por llamadas a `Candil.RateLimiter.check/1`
  3. Si ya existe CAN-09 (`ETS-based Candil.RateLimiter`), audit este código está usándolo o sigue con Process dict
  4. Tests con requests concurrentes
- **Verificación**: `mix test test/candil/http_test.exs`
- **Impacto**: 🟢 LOCAL (mejora correctness)
- **Dependencias**: CAN-09 (verificar)

### CAN-29: Limpiar referencia a `docs/candil_llm.md`
- **Hallazgo** (`AUDIT.md` §P3 #12): `llm.ex:5` `@moduledoc false  # original moduledoc is in docs/candil_llm.md` — verificar que existe o eliminar referencia.
- **Severidad**: 🟢 P3
- **Ficheros**: `lib/candil/llm.ex`
- **Esfuerzo**: 5 min
- **Pasos**:
  1. Verificar `docs/candil_llm.md` existe y tiene contenido útil
  2. Si existe: añadir `@moduledoc` en `llm.ex` que linke al fichero
  3. Si no existe: eliminar la referencia del comentario
- **Verificación**: `mix docs` (no warnings)
- **Impacto**: 🟢 LOCAL

### CAN-30: Nombrar telemetry handlers en tests
- **Hallazgo** (`AUDIT.md` §P3 #13): tests pasan funciones anónimas como telemetry handlers — produce performance warnings.
- **Severidad**: 🟢 P3
- **Ficheros**: varios `test/candil/*_test.exs`
- **Esfuerzo**: 30 min
- **Pasos**:
  1. Identificar tests con `:telemetry.attach(handler_id, ..., fn _, _, _, _ -> ... end)`
  2. Sustituir por módulos nombrados o `&Mod.handle_event/4` referencias
  3. Verificar que `mix test --trace` no emite warnings
- **Verificación**: `mix test --trace` (sin warnings de telemetry)
- **Impacto**: 🟢 LOCAL

---

## 11. Agrupación por impacto en el ecosistema (2026-07-22)

> **Pregunta**: si hago esta tarea, ¿tengo que tocar otros proyectos o se hace y ya?

### 🟢 LOCAL — "se hace y ya" (16 tareas)

| ID | Tarea |
|----|-------|
| CAN-06 | Remote model routing fix |
| CAN-07 | `stream_download` refactor |
| CAN-08 | `reason()` type — add atoms + remove `term()` |
| CAN-12 | HTTP response type alias |
| CAN-14 | Verify `embeddings.ex` return spec |
| CAN-19 | Tests para HTTP |
| CAN-20 | Tests para Inference |
| CAN-21 | Tests para Conversation |
| CAN-22 | Tests para Detector |
| CAN-23 | Tests para Model, Engine, Stream |
| CAN-24 | Sanitize path traversal (P0 security) |
| CAN-26 | `LongRunning.start_link` init crash fix |
| CAN-27 | `post_json` return type spec correction |
| CAN-28 | Rate limiter ETS-based |
| CAN-29 | Limpiar referencia `docs/candil_llm.md` |
| CAN-30 | Nombrar telemetry handlers en tests |

**Workflow**: branch en `candil` → tests → commit → push.

---

### 🟡 MEDIO — "verificar 1-2 consumidores" (4 tareas)

| ID | Tarea | Consumidores | Smoke test |
|----|-------|--------------|------------|
| CAN-15 | Split `inference.ex` (409 LoC) | delfos (vía `Candil.chat`, `Candil.embed`) | `cd ../delfos && mix test` |
| CAN-16 | Split `http.ex` (254 LoC) | delfos (vía HTTP) | idem CAN-15 |
| CAN-17 | Split `conversation.ex` (253 LoC) | delfos (vía Conversation) | idem CAN-15 |
| CAN-18 | Split `detector.ex` (258 LoC) | delfos (vía Detector) | idem CAN-15 |

**Workflow**: branch en `candil` → tests propios → smoke test en delfos → merge.

---

### 🔴 CRÍTICO (0 tareas)

**No hay tareas críticas en candil.** Como leaf library, candil tiene un único consumer (delfos) y los refactors estructurales mantienen API vía fachadas. Si en una futura auditoría aparece algo con blast radius ≥3 o que rompa el contrato con delfos, se reclasificará aquí.

---

### 📊 Matriz resumen

| Impacto | # tareas | Esfuerzo | Branch dedicada | Smoke tests externos |
|---------|----------|----------|-----------------|----------------------|
| 🟢 LOCAL | 16 | ~12h | No | 0 proyectos |
| 🟡 MEDIO | 4 | ~16h | No (en candil) | 1 proyecto (delfos) |
| 🔴 CRÍTICO | 0 | — | — | — |
| **Total** | **20** | **~28h** | — | — |

### 🎯 Orden de ejecución sugerido

1. **Security quick wins LOCAL** (2h): CAN-24 (path traversal)
2. **Bug fixes LOCAL** (1h): CAN-08 (reason type), CAN-26 (init crash), CAN-27 (post_json spec)
3. **Polish LOCAL** (30 min): CAN-29, CAN-30
4. **Rate limiter fix LOCAL** (3h): CAN-28
5. **Tests LOCAL** (8-9h): CAN-19, CAN-20, CAN-21, CAN-22, CAN-23
6. **More LOCAL polish** (1-2h): CAN-06, CAN-07, CAN-12, CAN-14
7. **MEDIO con smoke tests** (16h, varios sprints): CAN-15, CAN-16, CAN-17, CAN-18