# 00 · Arrea — el chasis

> **Por qué este bloque va el primero.** Candil no está al lado de Arrea: está
> **encima**. Antes de planificar nada de Candil hay que saber qué es Arrea, qué
> garantiza y qué no. Escribir sobre Arrea sin haberlo leído es el error más caro
> que se puede cometer aquí, porque todo lo que se construya encima hereda sus
> límites.
>
> **Estado**: escrito a partir del código de `Lorenzo-SF/arrea` en `82a9ada`.

---

## 1 · Qué es

Arrea es el motor de ejecución asíncrona del ecosistema, en OTP puro. No sabe
nada de LLMs. Su unidad de trabajo es **una tarea**: una función o un comando.

- **44 módulos**, **314 tests** (el recuento es del código: la suite **no
  imprimía el resumen** hasta el arreglo de `halt_on_error`, así que el número
  documentado salía de contar, no de ejecutar)
- Sin dependencias de IA. Es genérico.

## 2 · Lo que Candil usa hoy, y lo que no

Medido sobre `lib/` de Candil:

| Módulo de Arrea | ¿Lo usa Candil? | Para qué |
|---|---|---|
| `Arrea.Parallel` | ✅ | el fan-out de `Candil.Concurrency` |
| `Arrea.CircuitBreaker` | ✅ | **toda** llamada HTTP saliente, en `Candil.HTTP.Retry` |
| `Arrea.LongRunning` | ✅ | arrancar `llama-server` como proceso del SO, con health |
| `Arrea.RateLimiter` | ✅ | el limitador por proveedor |
| `Arrea.Telemetry` | ✅ | telemetría, reflejada en `[:candil, …]` y `[:arrea, :candil_*]` |
| `Arrea.Registry` | ✅ | |
| `Arrea.Worker` · `Leader` · `Monitor` · `Pool` · `Bulkhead` · `Subscribers` | ❌ **cero** | la mitad colectiva, sin usar |

**Seis de doce.** Se integró la mitad de *una instancia* —un proceso, una
llamada— y se dejó entera la mitad *colectiva*, que es justo donde Candil
necesita estar.

## 3 · Las piezas, y para qué sirven de verdad

| Pieza | Qué hace | Dónde le encaja a Candil |
|---|---|---|
| `Worker` | ejecuta una **cola** de tareas en orden y muere al acabarla | **no** — un agente no tiene cola conocida |
| `Leader` | coordina un lote en paralelo y avisa a suscriptores | el fan-out por lotes, con progreso |
| `Monitor` | acumula estadísticas de workers y tareas, **en memoria** | `candil stats` — y se reinicia con el árbol |
| `CircuitBreaker` | `:closed` / `:open` / `:half_open` por **nombre de recurso** | **encaja exacto**: un modelo *es* un recurso con nombre |
| `Bulkhead` | **cuenta** slots, rechaza sin encolar | concurrencia; no VRAM |
| `Pool` | conjunto de pie con `checkout` / `checkin` y overflow | el conjunto de motores |
| `LongRunning` | `Port` + health de un proceso del SO | **ya es el motor** |
| `RateLimiter` | cubo de tokens sobre `Apero.RateLimit` | API keys de proveedores |

## 4 · El mapa: Candil es Arrea con otro vocabulario

Esta es la razón por la que Arrea va primero. Ocho piezas coinciden una a una:

| Arrea (genérico) | Candil (IA) |
|---|---|
| una **tarea** (función o comando) | un **prompt** (modelo + mensajes) |
| un recurso **con nombre** | la **VRAM**, en GB |
| `LongRunning` | `Candil.Engine` — ya es un `LongRunning` |
| `CircuitBreaker` por recurso | un modelo que devuelve basura |
| `Bulkhead`, N slots | cuántos modelos caben en 16 GB |
| `Leader.execute/2` | un lote de peticiones al gateway |
| `Monitor.get_stats/0` | `candil stats` |
| `RateLimiter` | API keys de proveedores |

Y dos que **solo son de Candil**: el catálogo (`Store`), la decisión
(`Router`) y el presupuesto (`Context`).

> **La costura ya está abierta.** Una «tarea» en Arrea es
> `[String.t() | function()]`, y `build_task_function/1` acepta una función de
> aridad cero tal cual. Una inferencia **es** una función de aridad cero:
>
> ```elixir
> Arrea.Leader.execute([
>   fn -> Candil.Inference.chat_local(:coder, msgs) end,
>   fn -> Candil.Inference.chat_local(:analyst, msgs) end
> ])
> ```

## 5 · Lo que Arrea **no** tiene

Y hay que saberlo antes de construir encima:

| Falta | Por qué importa |
|---|---|
| **Coste en GB** | `Bulkhead` cuenta slots. La VRAM se gasta en GB y cada modelo cuesta distinto: eso es **knapsack**, no concurrencia |
| **Registro que sobreviva a un reinicio** | `Monitor` es memoria en un GenServer. El que sobrevive es `instances.json`, y es de Candil |
| **RPC dirigido** | `send_message/2` es un `cast`: **sin respuesta**. Dos agentes que se hablan necesitan pregunta *y* respuesta |
| **Abstracción de agente** | el único behaviour de proceso es `Pool.Worker`, y expone **un** callback: `start_link/1` |
| **Descubrimiento** | los workers nacen de `start_child` con un `batch_id` que ya sabes. Vale para lotes; no para «quién hay vivo» |

## 6 · Decisiones ya tomadas sobre Arrea

**El halt vive en una sola frontera.** Arrea es escript *y* librería, y el DSL
de Alaja con `halt_on_error` compila a un `System.halt/1` **incapturable** que
se lleva la VM del host. Ahora:

```elixir
Arrea.CLI.main/1        # devuelve un valor, no mata a nadie   ← tests y hosts
Arrea.CLI.Escript       # System.halt(status)                  ← main_module del escript
```

Y el código de salida se pone **halando**, no devolviendo: el wrapper de un
escript llama `halt(0)` al salir sea cual sea el valor devuelto. Por eso antes
`arrea run` podía imprimir un comando fallido y salir con 0.

**`send_message/2` no miente.** Antes devolvía `:ok` para un worker que nunca
existió, porque `GenServer.cast/2` devuelve `:ok` siempre y el `via_tuple` de un
worker ausente no resuelve. Ahora devuelve `{:error, :worker_not_found}`, y el
`@spec` lo declara. Hay un test de **contrato** que lee el `@spec` y falla si
vuelve a decir `:ok`.

## 7 · Lo que hay que recordar al usar Arrea

1. **`Leader.execute/2` es un `GenServer.call` a un solo proceso**, con timeout.
   Todo el fan-out pasa por ahí. Con cinco clientes a la vez hay que mirarlo con
   carga real antes de construirle encima.
2. **`Leader` no acepta tuplas etiquetadas.** `Parallel.run_sync/2` sí. Por eso
   `Candil.Concurrency` sigue con `Parallel`: `candil models list` necesita las
   etiquetas para pintar la tabla, y `Leader` devolvería un agregado.
3. **`Arrea.Supervisor` usa `:rest_for_one`.** Si cae `Arrea.Monitor`, caen
   también `Leader` y `WorkerSupervisor`. Es un diseño razonable para una
   librería que se usa sola, y un radio de explosión que Candil no controla.
4. **13 tests rojos**, de shell y de CLI, dos marcados `@tag :wip_cli` por el
   propio autor. Estaban antes de este trabajo; no los ha tocado nadie.

## 8 · Lo que sigue

En [`02-orden/`](../../02-orden/) está el orden de integración, con lo que hay que
hacer en Arrea y lo que hay que hacer en Candil, y qué prerrequisito va antes
de cuál.

**Pendiente de escribir**: la guía de uso práctica (los cuatro patrones con los
que se usa Arrea desde Candil, con código), y el detalle de `Bulkhead`,
`CircuitBreaker` y `LongRunning` para quien no los conoce.
