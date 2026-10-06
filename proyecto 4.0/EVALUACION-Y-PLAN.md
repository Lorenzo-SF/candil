# Candil 4.0 — Evaluación del estado real y planificación

> **Qué es esto.** Una auditoría hecha sobre el código y los 41 documentos de
> `proyecto 4.0/`, no una lectura del plan. Cada afirmación lleva su medición.
>
> **Fecha**: 2026-10-06 · **Rama**: `fase-7-router` (que será `main`)
> **Medido**: 87 módulos, 65 ficheros de test, **800 tests + 27 doctests, 0 fallos**

---

## 1. El hallazgo central

**Tu diagnóstico es correcto, y es más preciso de lo que parece: la visión de
framework está ~60% escrita en Candil y 0% planificada.**

Eso no es "hemos hecho las cosas al revés". Es peor y más útil: **las piezas ya
existen, están huérfanas, y nadie las ha conectado ni las ha probado.** Nadie las
mencionó porque no están en ningún plan.

| | |
|---|---|
| Módulos | 87 |
| Behaviours (extension points) | **2** |
| Registros donde un tercero mete código | **1** |
| Menciones de "framework / librería / extender" en 41 documentos | **1**, y es una frase suelta |

**La frase**, en `original/candil-4.0-final.md`:

> "Candil 4.0 es la absorción de `ropero` y de la parte útil de `elpaso`, para
> convertir Candil 3.0.0 en **la librería de IA del ecosistema**."

Está en el resumen ejecutivo del plan. Y no vuelve a aparecer. Las 11 fases que
vienen después son todas "Candil **tiene** X".

---

## 2. Los cuatro estados que diste, verificados

### 2.1 · Comprobado

| | |
|---|---|
| Encender/apagar local en CPU y GPU | ✅ Sí. `gpu_layers` es campo de modelo y `--cpu` lo pone a 0 |
| Motor de decisiones | ✅ Sí. `Candil.Router`, 800 tests en verde |

### 2.2 · Hecho pero **no comprobado** — y aquí hay un matiz

**Proveedor externo.** Verificado:

- `[provider.X]` en el toml **sí** define proveedores arbitrarios. No es una lista
  fija: es `section(config, "provider", &provider/2)`.
- `Candil.Inference.chat_remote/4` existe.
- **Y tiene 2 usos en todo el suite de tests.** Eso no es una prueba de
  extremo a extremo; es que la función está referenciada dos veces.

**Tu intuición es correcta, y es la misma del siempre:** *está hecho y no está
comprobado son la misma frase que "no está hecho", pero cuesta el doble
descubrirlo después.*

### 2.3 · Tiene pero **no probado**

| | |
|---|---|
| Infra de RAG | Tipos **congelados** (`RAG.Chunk` con `@type t`), **5 módulos por crear**: `Chunker`, `Embedder`, `Index`, `Retrieval`, `Rerank` |
| Instalación de engines | `Candil.Installer` existe y tiene tests, pero **solo llama.cpp**. De tu lista: llama.cpp ✅, y ollama / airllm / vllm / mlx_lm / tensorrt_lm / FLM **no existen** |

Sobre los seis motores que faltan: **no son seis tareas iguales.** `ollama` y
`vllm` son un `Launcher` cada uno (comportamiento de 1 callback que ya existe).
`mlx_lm` es macOS y `tensorrt_lm` es Linux+NVIDIA: son el mismo trabajo con una
guarda de plataforma encima. `FLM` es AMD con APU y `airllm` no son motores de
inferencia sino que *envuelven* otros: son otra categoría.

### 2.4 · Pendiente

- Infra para crear MCPs propios
- Infra para crear y gestionar agentes, y automatizar tareas

Las dos son **la misma tarea**, y es la que ya está medio hecha. Sección 3.

---

## 3. La visión de framework ya está en el código

Esto es lo que no sabíamos los dos.

### 3.1 · `Candil.Agent` tiene el patrón exacto de Alaja

```elixir
defmodule MyApp.WeatherAgent do
  use Candil.Agent,
    name: "weather",
    goal: "Answer weather questions",
    tools: [Candil.MyTools.get_weather],
    max_steps: 6
end
```

Eso es un `use` con DSL y opciones. **Es literalmente el modelo de Alaja, ya
escrito.** Y tiene **cero usos** fuera de sus propios tests.

### 3.2 · `Candil.MCP` ya promete lo que pides

Del propio `@moduledoc` de `Candil.MCP`:

> "Tools come from the registry, not from a list. `serve/1` takes `:registered`
> and exposes whatever `Candil.Tool` has. A consumer that defines its own tools
> therefore gets them served without Candil knowing anything about them — which
> is how a vault of 29 tools gets exposed by a client that knows nothing about
> vaults."

**Ese párrafo es tu visión, escrita por mí hace meses, y es correcta.** Un cliente
que registra 29 herramientas y Candil no sabe nada de vaults es exactamente
"Candil como framework".

### 3.3 · El único punto de extensión real

`Candil.Tool` es **el** lugar donde un tercero mete código:

- registro con `define/2` y `call/2`
- macro `__tool__` para declarar una herramienta
- validación de argumentos contra un **JSON schema**

Y lo consumen `Candil.MCP` y `Candil.Agent`. **`Candil.RAG` no lo consume.**

### 3.4 · Los dos behaviours, y lo que falta para llegar a los cinco

| Behaviour | Callbacks | Implementadores |
|---|---|---|
| `Candil.Backend` | 4 | 2 (`llama_cpp`, `openai_compat`) |
| `Candil.Engine.Launcher` | 1 | 1 (`http`) |

Para que alguien pueda construir su RAG o su proveedor, faltan behaviours para:
**chunking strategy**, **embedder**, **provider**, **router classifier** y
**scheduler policy**. Ninguno existe.

---

## 4. El hallazgo serio: hay dos runtimes de agente y nadie ha elegido

**Arrea tiene la maquinaria entera.** 44+ módulos:
`Worker`, `Worker.Scheduler`, `Worker.Registry`, `Worker.ErrorPolicy`,
`Worker.ResultHandler`, `Leader`, `Monitor`, `Registry`, `Supervisor`, `Pool`,
`CircuitBreaker`, `Bulkhead`, `RateLimiter`, `LongRunning`, `Telemetry` (7
módulos), `Subscribers`, `Config`, `Validation` (3), `Logging`.

Arrea es una dependencia **dura** de Candil. Y Candil usa 13 de sus módulos:

```
Arrea.CircuitBreaker   Arrea.LongRunning   Arrea.Parallel    Arrea.RateLimiter
Arrea.Registry         Arrea.Supervisor    Arrea.Telemetry   Arrea.WorkerSupervisor
```

**Ninguno es para agentes.** Y mientras tanto, `Candil.Agent` tiene **su propio
bucle ReAct**, escrito desde cero, que no usa ni `Arrea.Worker` ni
`Arrea.Leader` ni el circuit breaker ni el monitor.

Consecuencias concretas, todas reales:

1. **No hay telemetría de agentes.** `Arrea.Telemetry` mide lo que le digas, y el
   agente de Candil no le dice nada.
2. **No hay circuit breaker en el bucle del agente.** Si el modelo devuelve
   basura tres veces, el ReAct de Candil sigue. Arrea lo tiene y no lo usa.
3. **No hay límite de concurrencia.** `Arrea.Bulkhead` existe; el agente de
   Candil no lo consulta.
4. **Hay dos formas de hacer un agente**, y no sabemos cuál es la buena.

**Lo que Arrea NO tiene**, y hay que decirlo porque no es gratis: `coordinator`,
`mailbox`, `rpc` y `health` **no existen** (0 módulos cada uno). Arrea es un pool
de tareas con coordinación de lote; **no es un sistema de agentes distribuidos.**

---

## 5. El problema de concepto, dicho con precisión

No es "hay que añadir más cosas". Es que hay dos productos distintos:

| | Producto A | Producto B |
|---|---|---|
| Qué es | Candil **tiene** un MCP | Candil **deja construir** un MCP |
| Extensible | no | sí |
| Cómo se usa | `candil mcp serve` y ya | defines tus tools, el servidor las sirve |

Lo mismo para RAG, para agentes y para el router. **El plan v4.1 está entero en
la columna A.** Y tu visión, entera, en la B.

La diferencia técnica que lo separa **no es escribir más código**: es que en la
columna B, casi todo lo que hay que escribir son **behaviours y registros**, no
módulos con `def`. Es otro tipo de trabajo y otro tipo de criterio de aceptación
— el criterio de la B es *«un tercero define esto y funciona sin tocar Candil»*.

Y esa frase, **literalmente, no aparece en ningún documento de planificación.**

---

## 6. Planificación

Esfuerzo en sesiones de trabajo, no en días de calendario. El plan v4.1 estima
57-67 días de contenido; esto se mide igual.

### Grupo 0 · Cerrar la 7 — 0,5 sesión

| | |
|---|---|
| 0.1 | Decidir si el `consumer` del contexto y el del router son el mismo o dos |

Ya está en `VISION.md`. Es pequeño, pero es una decisión de arquitectura y sale
antes de que la 8 dependa de ella.

### Grupo 1 · Probar lo que existe sin probar — 2 sesiones

**Esto va primero y va rápido.** No es escribir features: es hacer que lo que ya
está **sea cierto** o dejar de decirlo.

| | | |
|---|---|---|
| 1.1 | **Proveedor externo de punta a punta** | Un `[provider.X]` del toml, un `chat_remote/4`, un modelo de verdad, una aserción sobre el RESULTADO y no sobre "no revienta" | 0,5 |
| 1.2 | **RAG de los tipos congelados a algo que responda** | Indexar un fichero real, recuperar, y comprobar que el chunk sale. Hoy hay tipos y 5 stubs | 0,5 |
| 1.3 | **Engines: los que existen, encendidos** | El refusal de VRAM, con `mix run` y un modelo pequeño. No es un test unitario: es una medición | 0,5 |
| 1.4 | **`Candil.Agent`, un agente real de punta a punta** | `use Candil.Agent` con una herramienta de verdad, un modelo mockeado, y **aserciones sobre el resultado** | 0,5 |

> **1.4 importa más de lo que parece.** Es el único módulo de Candil que ya es un
> framework, y no se ha ejecutado nunca fuera de sus propios tests. Es exactamente
> el patrón de fallo de esta semana: *verde porque nadie lo llamó*.

### Grupo 2 · Las piezas de framework que faltan — 4-6 sesiones

**Aquí es donde se arregla el problema de concepto, y no es un añadido: es el
trabajo que convierte la columna A en la columna B.**

| | | |
|---|---|---|
| 2.1 | **`Candil.RAG.Embedder` como behaviour** | El primero. RAG es el más autocontenido y el que más te va a doler si lo dejas para el final | 1 |
| 2.2 | **`Candil.RAG.Chunker` como behaviour** | sentence / paragraph / fixed, los tres del README | 0,5 |
| 2.3 | **`Candil.Provider` como behaviour** | Ahora es un módulo con 5 proveedores dentro. Debe ser un registro: tú defines uno, Candil lo sirve | 1 |
| 2.4 | **`Candil.Router.Classifier` como behaviour** | Hoy las reglas están en código, no en datos. Sin esto, "modificar el routing desde el toml" es media verdad | 1 |
| 2.5 | **El test de la columna B** | **Un test que defina una tool, un embedder, un provider y un chunker EN UN FICHERO DE TEST, sin tocar Candil.** Si ese test pasa, el framework existe. Si falla, no existe | 1,5 |

> **2.5 es el entregable que define el proyecto.** Todo lo demás se puede
> escribir sin él y no significa nada. Con él, Candil es un framework. Sin él,
> Candil es un programa con muchos módulos.

### Grupo 3 · El pegamento de agentes — 3-4 sesiones

La decisión de §4, y su consecuencia.

| | | |
|---|---|---|
| 3.1 | **Decidir: ¿el agente de Candil usa Arrea o no?** | Si sí: `Arrea.Worker` + `Leader` + `CircuitBreaker` + `Bulkhead` + `Telemetry` por detrás del bucle ReAct, y desaparece el loop propio. Si no: se documenta que Arrea es para tareas y el agente es aparte, y se acepta la Telemetry sin integrar | 0,5 |
| 3.2 | **`Candil.Agent` como behaviour** | Hoy es un `use` con un bucle fijo. Para que alguien construya sus agentes tiene que ser sustituible | 1 |
| 3.3 | **Automatización de tareas** | `Arrea.Leader` ya hace lotes con suscriptores. Lo que falta es la versión con LLM: workers que además son prompts | 1,5 |
| 3.4 | **Dejar escrito qué NO es Arrea** | `coordinator`, `mailbox`, `rpc` y `health` no existen. Si alguien los necesita, se compran en otro sitio | 0,5 |

### Grupo 4 · Las fases grandes

| Fase | Qué | Depende de |
|---|---|---|
| **8b · Scheduler** | Cola, eviction por VRAM, prioridad. **Es la base de la que cuelgan todo lo demás** | — |
| **8a · Gateway** | `candil serve`, OpenAI-compatible, flags, api-key | 8b para el enrutado real |
| **8c · Mesa camilla** | Contexto compartido entre sesiones | 8b y 10 |
| **9 · MCP** | 5 módulos nuevos. **Reescribirlo como "sirve el registro", que es lo que el moduledoc ya promete** | 2.3, 8a |
| **10 · RAG** | 5 módulos nuevos, sobre los behaviours del grupo 2 | 2.1, 2.2 |
| **11 · Stats** | Conectar la telemetría de Arrea, que ya existe y no se conecta | — |
| **12 · Agentes** | Lo que salga de la decisión 3.1 | grupo 3 |

> **El grupo 2 va antes que la 9 y la 10, y eso invierte el orden del replan v4.1.**
> No es una ocurrencia mía: la fase 9 dice que `Candil.Tool` "existe desde 3.0" y
> lo usa de base. Si los behaviours no existen, la fase 9 construye un servidor MCP
> bonito que solo sirve lo que Candil ya sabe.

---

## 7. Las decisiones

Cinco. Las tres primeras cambian código.

**1 · ¿El agente de Candil se apoya en Arrea, o son dos sistemas?**
Hoy son dos y nadie lo ha elegido. Es la decisión más profunda de la lista,
porque Arrea es una dependencia dura y esto decide qué es Candil.

**2 · ¿Los behaviours del grupo 2 son parte de 4.0 o de 5.0?**
Si son de 4.0, la 9 y la 10 se reescriben antes de empezar. Si son de 5.0, 4.0
sale con Candil como programa y el framework llega después.

**3 · ¿La fase 8b entra ahora, o 4.0 sale sin la línea de cajas?**
Es la que hace que `candil serve` sea usable con más de un modelo.

**4 · ¿Cuántos motores, y de qué categoría?**
Los que puedo escribir como `Launcher` (ollama, vllm) son baratos. Los que envuelven
otros (airllm, FLM) son otra categoría. Y dos son exclusivos de plataforma.

**5 · ¿`Candil.Provider` es un registro, o una lista cerrada con custom?**
Si es lista cerrada, "configura tu proveedor en el toml" tiene un techo.

---

## 8. Lo que no voy a decidir yo

Lo que este documento **no** hace, a propósito:

- **No dice cuánto cuesta cada tarea.** Doy sesiones, no días, porque el calendario
  depende de paralelismo y eso es tuyo. Las cifras del plan v4.1 (57-67 días) son
  suyas y no las he re-estimado.
- **No reescribe las fases.** El grupo 4 las menciona y las reordena lo mínimo.
- **No cierra ninguna de las tres colisiones** de `VISION.md` (round-robin vs FIFO,
  memoria común vs aislamiento, eviction). Son tuyas y siguen abiertas.

Lo único que propongo como **prioridad dura**: **el grupo 1 antes que el grupo 2,
y el grupo 2 antes que la 9 y la 10.** Porqueel grupo 1 es barato y convierte
afirmaciones en hechos, y el grupo 2 es lo que convierte un programa en un
framework. La 9 y la 10 escritas sin el grupo 2 se esperan.