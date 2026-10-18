# 10 · Ergonomía — sacar el 100 % con menos fricción

> **Plan de trabajo.** Este documento es el punto de seguimiento para la capa
> de ergonomía: el wrapper delgado que hace que el caso común (chatear, tener
> un agente, servir) se resuelva en 2-3 líneas, sin tocar el núcleo.
>
> **Base**: `main` en `039ca7e` (2026-10-18) · 32 doctests + 1290 tests · CI verde.
>
> **Regla**: el núcleo no cambia. La capa ergonómica es azúcar sintáctico
> encima de `Candil.chat/3`, `Candil.Agent`, `Candil.Llm`, etc. Si un usuario
> necesita control, usa la API de bajo nivel directamente.
>
> **Principio**: separar potencia de ergonomía. Candil ya tiene la potencia
> (router, policy, agentes, RAG, MCP, gateway). Lo que falta es que el caso
> común sea trivial.

---

## 1 · El problema

El quick start actual requiere **6 pasos + config TOML**:

```elixir
engine = %Candil.Engine{alias: :llama_server, binary: "llama-server", host: "127.0.0.1", port: 8080}
model  = %Candil.Model{alias: :llama3, type: :local, model_dir: "/models", filename: "llama-3-8b-q4_k_m.gguf", engine: :llama_server, context_size: 8192, usage: [:chat]}
:ok = Candil.download_engine(engine)
{:ok, _} = Candil.download_model(model)
{:ok, _pid} = Candil.start_engine(engine, model)
{:ok, response} = Candil.chat(:llama3, [%{role: "user", content: "Hello!"}])
```

El objetivo: **2 líneas**, como Ollama o LangChain:

```elixir
{:ok, response} = Candil.chat("llama3", "Hello!")
```

## 2 · Lo que NO cambia

- El router (scoring, refusal, cache, policy) — ventaja competitiva.
- Los circuit breakers y agentes con memoria — diferenciadores.
- El gateway OpenAI-compatible — ya resuelve "no escribir Elixir".
- La arquitectura modular con behaviours — es correcta.
- El sistema de errores como datos.
- Todos los tests existentes siguen pasando (se añaden tests nuevos, no se modifican los existentes).

## 3 · Propuestas, ordenadas por impacto/esfuerzo

### Tier 1 — Alto impacto, bajo esfuerzo

| # | Propuesta | Esfuerzo | Estado |
|---|---|---|---|
| 1 | `Candil.chat/2` (auto-resuelve modelo → engine → arranca si no corre) | 1-2 días | ✅ hecho (PR E1) |
| 2 | `Candil.pull/1` (descarga engine + modelo en un comando, como Ollama) | 1 día | ✅ hecho (PR E1) |
| 3 | Quick start en inglés + `examples/` (3 scripts ejecutables) | 1 día | ⬜ pendiente |
| 4 | Auto-start de engines en `chat/2` | incluido en #1 | ✅ hecho (PR E1) |

### Tier 2 — Alto impacto, esfuerzo medio

| # | Propuesta | Esfuerzo | Estado |
|---|---|---|---|
| 5 | `Candil.Agent.new/1` de alto nivel (oculta Backend/Model/Engine) | 2-3 días | ⬜ pendiente |
| 6 | Streaming en agentes (`:on_token` callback en `Agent.run/3`) | 1-2 días | ⬜ pendiente |
| 7 | `Candil.serve/0` con cero config (usa el primer modelo disponible) | 1 día | ⬜ pendiente |
| 8 | Perfil/preset de modelo (implícito en `Candil.chat/2`) | incluido en #1 | ⬜ pendiente |

### Tier 3 — Medio impacto, alto esfuerzo (después)

| # | Propuesta | Esfuerzo | Estado |
|---|---|---|---|
| 9 | Configuración simplificada (opcional TOML, auto-detect) | 3-5 días | ⬜ pendiente |
| 10 | `Model.vram_mb` cableado en hydrate/schema/template | 0.5 día | ⬜ pendiente |
| 11 | Agentes multi-modelo | depende de 8b Nivel 3 | ⬜ pendiente |

## 4 · Safeguards (para no perder el rumbo)

1. **El núcleo no cambia.** `Candil.chat/2` llama a `Candil.Llm.chat/3` internamente.
2. **Los behaviours siguen siendo el contrato.** La capa ergonómica usa los mismos.
3. **Los tests del núcleo no cambian.** Se añaden tests nuevos.
4. **La documentación separa "fácil" de "potente".**
5. **El CLI sigue funcionando.** La capa ergonómica es independiente.

## 5 · Plan de implementación

### Fase E1 — `Candil.chat/2` + `Candil.pull/1` + auto-start

**Diseño:**

```elixir
# Candil.chat/2
@spec chat(String.t() | atom(), String.t() | [map()], keyword()) :: {:ok, term()} | {:error, term()}
def chat(model, message, opts \\ []) do
  model_atom = to_model_atom(model)
  messages = normalize_message(message)

  case ensure_engine_running(model_atom) do
    :ok ->
      Candil.Llm.chat(model_atom, messages, opts)
    {:error, reason} ->
      {:error, reason}
  end
end

# Candil.pull/1
@spec pull(String.t() | atom()) :: :ok | {:error, term()}
def pull(model) do
  # 1. Download engine if not present
  # 2. Download model if not present
  # 3. Register in Store if not registered
end
```

**Auto-start:** si el modelo está en el Store pero el engine no está corriendo, arrancarlo con `Candil.Llm.start_engine/2`. Timeout configurable (`:start_timeout`, default 30s).

**Ficheros a crear/modificar:**
- `lib/candil.ex` — añadir `chat/2`, `chat/3` (con opts), `pull/1`.
- `lib/candil/llm.ex` — añadir `ensure_engine_running/1`, `pull/1`.
- Tests nuevos en `test/candil/ergonomics_test.exs` (o similar).
- `examples/` — 3 scripts.

### Fase E2 — `Candil.Agent.new/1` de alto nivel

**Diseño:**

```elixir
defmodule Candil.Agent do
  def new(opts) do
    # Resolve model → backend → create SimpleReflex
    model = Keyword.get(opts, :model, "default")
    backend = Keyword.get(opts, :backend, Candil.Backend.LlamaCpp)
    goal = Keyword.get(opts, :goal)
    tools = Keyword.get(opts, :tools, [])
    max_steps = Keyword.get(opts, :max_steps, 8)
    timeout = Keyword.get(opts, :timeout, 60_000)

    # Register tools
    Enum.each(tools, &Candil.Tool.define/1)

    # Create agent
    {:ok, pid} = Candil.Agents.Supervisor.start_agent(Candil.Agents.SimpleReflex,
      name: opts[:name],
      goal: goal,
      backend: backend,
      model: model,
      max_steps: max_steps,
      timeout: timeout
    )

    %__MODULE__{pid: pid, name: opts[:name]}
  end

  def run(%__MODULE__{pid: pid}, input, opts \\ []) do
    Candil.Agents.call(pid, input, opts)
  end
end
```

**Ficheros:** `lib/candil/agent.ex` (ya existe, añadir `new/1` y `run/2`), tests.

### Fase E3 — Quick start en inglés + examples/

- README con quick start de 3 líneas.
- `examples/chat.exs`, `examples/agent.exs`, `examples/rag.exs`.
- `@moduledoc` de `Candil` actualizado.

### Fase E4 — Streaming en agentes

- `Agent.run/3` acepta `:on_token` callback.
- `SimpleReflex.evaluate/3` acepta `:on_token`.
- Integrar `Candil.Stream` en el loop.

### Fase E5 — `Candil.serve/0` con cero config

- `Candil.serve/0` → usa el primer modelo disponible, arranca engine si no corre.
- `Candil.serve(opts)` ya existe.

## 6 · Progreso

| Fase | Descripción | Estado |
|---|---|---|
| E1 | `Candil.chat/2` + `Candil.pull/1` + auto-start | ✅ hecho (PR E1) |
| E2 | `Candil.Agent.new/1` de alto nivel | ⬜ pendiente |
| E3 | Quick start en inglés + examples/ | ⬜ pendiente |
| E4 | Streaming en agentes | ⬜ pendiente |
| E5 | `Candil.serve/0` con cero config | ✅ hecho (PR E1) |

## 7 · Lo que NO cambia

- El núcleo (`Candil.Llm`, `Candil.Agent`, `Candil.Agents.*`, `Candil.Router.*`, etc.) no se modifica.
- Los tests existentes siguen pasando.
- El CLI sigue funcionando.
- Los behaviours siguen siendo el contrato.

## 8 · Notas para retomar

- `Candil.Llm.start_engine/2` toma `(engine_alias, model_alias)` — necesita que el engine y el modelo estén en el Store.
- `Candil.Llm.chat/3` toma `(model_alias, messages, opts)` — necesita el engine corriendo.
- `Candil.Agents.Supervisor.start_agent/2` toma `(module, opts)` — necesita `:backend`, `:goal`, etc.
- Auto-start: verificar `Candil.Llm.engine_healthy?/1` antes de chatear; si no, `start_engine/2`.
- Auto-pull: `Candil.Llm.download_engine/1` + `download_model/2` + `Store.register_*`.

## 9 · Convenciones de esta tanda

- Un PR consolidado por tanda.
- Gates completos antes de mergear.
- Diseño presentado antes de escribir.
- Documentar lo que se quede a medias.
- Actualizar este documento con el progreso.
EOF
echo "written"