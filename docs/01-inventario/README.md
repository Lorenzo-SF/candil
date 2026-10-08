# 01 · Inventario — qué hay

> **Regla de este bloque**: todo número sale de ejecutarlo. Si algo no se ha
> medido, dice «sin medir» y punto.
>
> **Medido el**: 2026-10-07 · rama `docs-v2` · `main` en `e168ccd`
> **Gates**: 27 doctests, 800 tests, 0 failures

---

## 1 · Los números

```
88 módulos en lib/
65 ficheros de test
27 doctests + 800 tests, 0 failures
```

| Área | Módulos | Qué hay |
|---|---|---|
| `cli` | 15 | Alaja: definición, dispatch, help, 12 comandos |
| `engine` | 9 | arranque, log, launcher, health poller, servidor externo |
| `context` | 6 | sesiones, builder, summarizer, token estimator, prefix manager |
| `router` | 6 | decisión, scorer, consumer, cache |
| `config` | 5 | fichero, schema, hydrate, template |
| `backend` | 3 | behaviour + llama_cpp + openai_compat |
| `inference` | 3 | chat, embeddings, chat_local/chat_remote |
| `doctor` | 4 | checks, fix_table, integración Botica |
| `mcp` | 2 | protocolo escrito, **transports sin hacer** |
| `store` `tools` `rag` | 1 c/u | |

## 2 · Los cuatro puntos donde se puede ampliar Candil sin tocarlo

**Esto es lo importante del inventario.** Si solo hay cuatro, la visión de
framework es más pequeña de lo que parecía — y también más cerca.

| | Qué es | Callbacks / superficie | Quién lo implementa |
|---|---|---|---|
| `Candil.Backend` | **behaviour** | 4: `chat`, `chat_stream`, `embed`, `models` | `llama_cpp`, `openai_compat` |
| `Candil.Engine.Launcher` | **behaviour** | 1: `launch` | `http` |
| `Candil.Tool` | **registro** | `define/2`, `call/2`, macro `__tool__`, schema JSON | el usuario final |
| `Candil.Router.Consumer` | **registro** | `candidates/1`, pin por consumer | el TOML |

**Contra:** hay cinco comportamientos que el diseño necesita y **no existen**:
embedder, chunker, provider, clasificador del router, y política de scheduler.

> Ese es el trabajo de la fase de frameworks (`docs/02-orden/`). Sin ellos,
> «Candil deja construir un RAG» es media verdad: el que use el RAG de Candil
> usa el embedder de Candil.

## 3 · Lo que está hecho y probado

| | |
|---|---|
| **Encender y apagar motores** | local, CPU y GPU. `gpu_layers` es campo del modelo, `--cpu` lo pone a 0. **Medido en la máquina del dueño** |
| **El motor de decisiones** | pin → force → reglas → embeddings → LLM, con `reason` que dice por qué. 40 tests |
| **Contexto compartido** | particionado por `{consumer, session_id}`. Aísla de verdad: dos consumers no se pisan |
| **Política de desbordamiento** | `:strict` (error), `:compact` (recorta), `:summarize` (resume, degrada). `:strict` es default y no degrada nunca |
| **Doctor** | Botica entero, 8 checks, `--fix` con memoria y disco |
| **CLI** | Alaja entero, `catch_all` propio, `halt_on_error` desactivado |
| **`candil init`** | plantilla generada desde el schema, **que se valida a sí misma** |
| **Proveedor externo** | `[provider.X]` acepta cualquier proveedor. `chat_remote/4` existe |

## 4 · Lo que existe pero NO está probado — MEDIDO el 2026-10-08

> **Las cuatro tienen respuesta ya.** Ver
> [`HALLAZGOS-FASE-0.md`](HALLAZGOS-FASE-0.md).

| | Cómo está | **Medido** |
|---|---|---|
| **Proveedor externo** | `chat_remote/4` con 2 usos, ambos contra un mock | **Ninguno de los 800 tests salía a la red**: todo el suite intercepta HTTP con un Mox. Ahora hay un test con un servidor real |
| **`Candil.Agent`** | el `use` funciona y tiene tests | **El bucle ReAct no cerraba jamás**: la observación se metía con `role: "user"` y el modelo pedía la herramienta para siempre. Arreglado |
| **RAG** | tipos congelados y 5 stubs | **Cinco stubs y un struct.** El `@moduledoc` promete un escaneo coseno que no existe |
| **Instalar motores** | `Installer` con tests | Solo sabe llama.cpp. ollama, vllm, airllm, mlx, tensorrt y FLM no existen |

> **«Existe» y «probado» eran la misma columna y no lo son.** Las cuatro estaban
> en «hecho» en el plan, y tres de las cuatro tenían además una suposición de
> diseño detrás.

## 5 · Lo que NO existe

| | |
|---|---|
| `candil serve` | **No hay endpoint.** No existe `ask`, ni `serve`, ni chat por HTTP |
| **El router sin consumidor** | `grep -rn 'Router.route(' lib/` da **cero** llamadas fuera del CLI y sus tests. Hay un motor de decisiones entero y nadie lo consulta |
| **Cola / línea de cajas** | no hay scheduler, ni eviction, ni contabilidad de VRAM en GB |
| **Mesa camilla** | contexto compartido entre sesiones: no existe |
| **`candil stats`** | no existe. Arrea tiene `Monitor` y `Telemetry`; no están conectados a nada |
| **MCP** | solo el protocolo escrito. `Server`, `Client`, `Transport`, `Builtin` sin hacer |
| **RAG** | ver arriba |
| **Agentes sobre Arrea** | `Arrea.Agent` no existe en Arrea |

## 6 · El hueco de una línea

> **Un módulo entero que decide, y nadie lo consulta.**

No es un bug. Es que la fase 8a —un endpoint que enrute— es la que lo pone en
el camino, y esa fase no existe todavía. El router está terminado y **sin
consumidor**, que es el estado más raro en que puede estar un componente.

## 7 · Las cinco decisiones abiertas

Ninguna cerrada. Todas bloquean algo:

| # | Decisión | Bloquea |
|---|---|---|
| 1 | ¿Round-robin justo (lo que hay) o FIFO con VIP (la línea de cajas)? | **8b, entera** |
| 2 | ¿La memoria compartida comparte historial o solo patrones? | 8c |
| 3 | ¿Quién escribe la verdad de la VRAM, Candil o Arrea? | 8b y los agentes |
| 4 | ¿`Candil.Provider` es un registro o una lista cerrada? | RAG, agentes, MCP |
| 5 | ¿El camino de librería entra en las fases, o queda fuera? | el orden entero |

## 8 · Lo que se sabe que está mal

Documentado para que no se redescubra:

| | |
|---|---|
| **Sin eviction no hay cola** | `EnginePool` quitó su LRU **a propósito**: «pretendía resolver un problema de memoria que nadie tiene». Cuatro modelos de 20 GB no caben en 16 GB, y un LRU de cuatro no cambia eso |
| **`Arrea.Monitor` se reinicia** | Es un caché y un caché debe reiniciarse. La verdad que sobrevive es `instances.json` |
| **`Arrea.Supervisor` es `:rest_for_one`** | Si cae `Monitor`, caen `Leader` y `WorkerSupervisor`. Decisión de Arrea que Candil no controla |
| **La suite de Arrea no imprimía resumen** | `halt_on_error` mataba la VM a mitad. **Arreglado**; ahora dice `3 properties, 315 tests, 13 failures` |
| **`Arrea.Leader.execute/2` no acepta etiquetas** | Por eso `Candil.Concurrency` sigue con `Parallel`: `candil models list` necesita las etiquetas |
| **13 tests rojos en Arrea** | De shell y CLI, dos marcados `@tag :wip_cli` por el autor. Preexistentes |

## 9 · El ciclo que se repite

Cada fase de este proyecto ha salido con la misma forma:

1. Los tests están en verde.
2. Alguien ejecuta el binario en su máquina.
3. El binario miente dos veces: algo dice `:ok` que no fue `:ok`, o algo no encuentra un fichero que existe.

Los tres de esta semana: **la API inventada de Alaja**, **los consumers que no
se leían del toml**, y **el «pin» que era un solo candidato**.

> Por eso la primera puerta no es `mix test`. Es *alguien lo ejecuta*.
