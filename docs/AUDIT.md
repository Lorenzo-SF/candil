# Candil — Code Quality Audit

> **Generated**: 2026-07-18 | **Stack**: Elixir 1.19 / OTP 28  
> **Scope**: Full codebase audit — security, correctness, typespecs, coverage, OTP compliance

---

## Summary

| Metric | Value |
|--------|-------|
| **Coverage** | 30.3% |
| **Credo issues** | 1 (cyclomatic complexity 11 in installer.ex:107) |
| **Dialyzer** | not run |
| **Test count** | 163 pass, 0 fail |
| **P0 findings** | 3 |
| **P1 findings** | 3 |
| **P2 findings** | 4 |
| **P3 findings** | 4 |

---

## 🔴 P0 — Critical

### 1. Path traversal in `server.ex:107`

```elixir
model_path = Path.join(model.model_dir, model.filename)
```

`model_dir` and `filename` come from user-provided structs. If an attacker controls `model.filename` (e.g. `"../../etc/passwd"`), `build_args` passes it as `--model` to `llama-server`. While not a direct file read, it causes the binary to read arbitrary files.

**Fix**: Sanitize both fields — validate they contain no `..` components, or use `Path.expand/1` with a whitelist of allowed base directories.

---

### 2. Unsafe shell invocation in `installer.ex:94`

```elixir
System.cmd("unzip", ["-o", "-j", zip_path, "llama-server", "llama-cli", "-d", dest_dir], ...)
```

`dest_dir` comes from `Engine.binary_dir(engine)` which falls back to `~/.apero/llm/bin`. Low risk currently, but if `binary_dir` is ever user-controlled, this becomes a command injection vector.

**Fix**: Add validation in `Engine.binary_dir/1` to reject paths with `..` components.

---

### 3. Test gap — core execution path untested

| Module | Coverage | Relevant Lines | Uncovered |
|--------|----------|----------------|-----------|
| `http.ex` | **0.0%** | 83 | 83 |
| `server.ex` | **0.0%** | 26 | 26 |
| `inference.ex` | **3.3%** | 121 | 117 |
| `stream.ex` | **3.5%** | 57 | 55 |
| `error.ex` | **12.5%** | 16 | 14 |
| `installer.ex` | **32.5%** | 40 | 27 |
| **Pipeline total** | **~2%** | 343 | 322 |

The entire inference pipeline — HTTP client, engine lifecycle, streaming, error shaping, model downloading — is untested. The 163 existing tests only cover `config.ex`, `detector.ex`, `model.ex`, `provider.ex`, `request_builder.ex`, and `cost.ex`.

---

## 🟠 P1 — High

### 4. `LongRunning.start_link` can crash init on failure

**File**: `server.ex:59–72`

```elixir
{:ok, lr_pid} = LongRunning.start_link(...)
```

If `LongRunning.start_link` returns `{:error, _}`, this match crashes the `init/1`. Should use a `case`/`with` and return `{:stop, reason}`.

---

### 5. Remote model incorrectly routed through `chat_local`

**File**: `inference.ex:67–78`

```elixir
with {:ok, model} <- Config.get_model(model_alias),
     true <- :chat in model.usage || ... do
```

If `model.type == :remote`, the guard `:chat in model.usage` passes but `do_chat_local` is called, which calls `Engine.base_url(model_alias)` → returns `nil`. Error message says "engine not running" instead of "model is remote".

**Fix**: Check `model.type` before the usage guard. Route remote models to `do_chat_remote` explicitly.

---

### 6. Cyclomatic complexity in `installer.ex:107`

Credo reports complexity **11** (threshold 9) in `stream_download`:
- Closure definition + 4-clause `case`
- Nested `if checksum`
- `verify_checksum` call

**Fix**: Extract streaming closure to `stream_to_file/2`, extract post-download phase to `finalize_download/3`.

---

## 🟡 P2 — Medium

### 7. `reason()` type union includes `term()`

**File**: `error.ex:28`

```elixir
@type reason :: :model_not_found | :engine_not_running | ... | term()
```

The `| term()` makes the union unsound — Dialyzer can't check exhaustiveness. Remove `term()` or use it only in `wrap/1`.

---

### 8. `post_json` return type misleading

**File**: `http.ex:37–38`

```elixir
@spec post_json(url :: String.t(), body :: map(), opts :: keyword()) :: {:ok, map()}
```

Actual return is `{:ok, %{status: integer, body: any}}`. The spec implies the body is unwrapped.

---

### 9. Rate limiter uses process dictionary

**File**: `http.ex:225–243`

`Process.get/1` / `Process.put/2` — silently wrong if a process handles multiple concurrent requests. Rate limiting is per-process, not global.

**Fix**: Use an ETS counter (e.g. `Candil.Config` store) or a dedicated GenServer.

---

### 10. Model download has no timeout

**File**: `installer.ex:127`

```elixir
receive_timeout: :infinity
```

If the remote server never closes the connection, this hangs forever. Should have a configurable timeout (e.g. 30 min for large models).

---

## 🟢 P3 — Low

### 11. `File.read!` in checksum verification

**File**: `installer.ex:160`

`File.read!(path)` raises on partial write. Use `File.read/1` and handle the error.

### 12. `docs/candil_llm.md` reference may be stale

**File**: `llm.ex:5`

```elixir
@moduledoc false  # original moduledoc is in docs/candil_llm.md
```

Verify the file exists or remove the reference.

### 13. Anonymous telemetry handlers

**File**: Tests pass anonymous functions as telemetry handlers. Produces performance warnings.

### 14. `String.to_atom` in config.ex

Documented as safe (comes from app config, not user input). Worth noting for audit.

---

## 📊 Coverage Detail

| Module | Coverage | Gap Description |
|--------|----------|-----------------|
| `config.ex` | ~95% | Well tested |
| `provider.ex` | ~90% | Good |
| `model.ex` | ~85% | Good |
| `detector.ex` | ~80% | Adequate |
| `request_builder.ex` | ~75% | Adequate |
| `cost.ex` | ~100% | Excellent |
| `error.ex` | 12.5% | Error wrapping untested |
| `inference.ex` | 3.3% | Chat pipeline untested |
| `stream.ex` | 3.5% | Streaming untested |
| `installer.ex` | 32.5% | Download untested |
| `llm.ex` | 31.5% | Facade partially tested |
| `http.ex` | 0.0% | HTTP client untested |
| `server.ex` | 0.0% | Engine server untested |
| **Overall** | **30.3%** | |

---

## 🔧 Top 5 Fixes (Priority Order)

1. **Sanitize `model_dir`/`filename`** in server.ex and installer.ex — security P0
2. **Write tests for HTTP client** (`http.ex`) — 83 uncovered lines, foundation of all inference
3. **Write tests for inference pipeline** (`inference.ex` + `stream.ex`) — 172 uncovered lines
4. **Refactor `stream_download`** — reduce cyclomatic complexity 11 → <8
5. **Fix remote model routing** — misleading error message when remote model hits `chat_local`

---

## 📝 Architecture Notes

- **Good**: ETS registry for config, circuit breaker in HTTP client, unified error type, telemetry instrumentation
- **Good**: Provider abstraction supports both local (llama-server) and remote (OpenAI-compatible) models
- **Weak**: No integration tests for real engine lifecycle, no contract tests for provider implementations
- **Weak**: Process-dictionary rate limiting is unsafe for multi-request GenServers

---

## Cómo usar esta auditoría

### Interpretación

- **P0 (🔴)**: Debe corregirse antes de cualquier release. Riesgo de crash, seguridad, o pérdida de datos.
- **P1 (🟠)**: Debe corregirse en el próximo ciclo. Degradación significativa de calidad o seguridad.
- **P2 (🟡)**: Debe corregirse cuando se toque el módulo afectado. Deuda técnica.
- **P3 (🟢)**: Conveniencia o estilo. Bajo impacto.

### Flujo de trabajo autónomo

Este documento, junto con `ARCHITECTURE.md` (diseño del proyecto) e `INDEX.md` (navegación de docs), contiene toda la información necesaria para abordar las correcciones de forma autónoma:

1. **Lee ARCHITECTURE.md** primero — entiende el diseño, subsistemas y decisiones clave.
2. **Lee INDEX.md** — localiza los archivos y módulos relevantes.
3. **Vuelve a esta auditoría** — prioriza por severidad (P0 → P1 → P2 → P3).
4. **Para cada hallazgo**: el fichero y línea están indicados. El código fuente relevante está en `lib/`.
5. **Ejecuta `mix test --cover`** antes y después para medir el impacto.
6. **Ejecuta `mix credo --all`** para garantizar que no introduces nuevas violaciones.
7. **Si el hallazgo implica cambiar una interfaz pública**, verifica los proyectos consumidores (listados en ARCHITECTURE.md §consumed-by).

### Dependencias entre proyectos

Candil depende de **apero** (HTTP, retry, crypto), **arrea** (circuit breaker, long-running), y **trebejo** (OS/arch detection). Se recomienda leer las auditorías en este orden:
1. `../apero/docs/AUDIT.md` — fundación
2. `../arrea/docs/AUDIT.md` — orquestación
3. `../trebejo/docs/AUDIT.md` — comandos shell
4. Este documento — inferencia LLM

Candil es consumido por **delfos** para todas las operaciones de LLM. Si modificas una interfaz pública de candil (inferencia, modelos, engine lifecycle), verifica que delfos sigue compilando y pasando sus tests (especialmente los de LLM).

### Checklist por severidad

**Al corregir un P0**:
- [ ] Aísla la causa raíz (línea exacta)
- [ ] Escribe un test que reproduzca el fallo **antes** de corregir
- [ ] Aplica la corrección
- [ ] Verifica que el test pasa
- [ ] Ejecuta `mix test --cover` — la cobertura no debe disminuir
- [ ] Ejecuta `mix credo --all` — cero nuevas violaciones
- [ ] Si cambia una interfaz pública, verifica proyectos consumidores

**Al corregir un P1**:
- [ ] Identifica todos los lugares donde se aplica el patrón (grep por el código similar)
- [ ] Testea el cambio (unitario + integración si aplica)
- [ ] Verifica `mix test --cover` no baja
- [ ] Si afecta a consumidores, ejecuta sus tests también

**Al corregir P2/P3**:
- [ ] Corrige cuando toques el módulo por otra razón (boy-scout rule)
- [ ] No merecen un esfuerzo dedicado si no hay un bug reportado
