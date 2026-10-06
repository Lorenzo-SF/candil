# Candil = Arrea con esteroides, especializado en IA

> **La pregunta**: ¿debe Candil apoyarse en Arrea, o son dos sistemas?
>
> **Respuesta corta**: **sí, y la esteroides son casi todo el trabajo.** Pero no
> porque Arrea tenga lo que a Candil le falta, sino porque las dos cosas hacen
> **exactamente la misma mecánica con objetos distintos**, y reimplementar eso es
> tener dos planificadores peleándose por la misma VRAM.
>
> **Fecha**: 2026-10-06 · Arrea: 44 módulos, 314 tests · Candil: 87 módulos, 800 tests

---

## 1. El mapeo que faltaba

Cuando Candil se integrating Arrea en la fase 5, se integra **6 módulos**. Y el
resto, **cero referencias**:

| Arrea | Ocurrencias en `lib/` de Candil |
|---|---|
| `LongRunning` · `CircuitBreaker` · `RateLimiter` · `Parallel` · `Telemetry` · `Registry` | **usadas** |
| `Worker` · `Leader` · `Monitor` · `Pool` · `Bulkhead` · `Subscribers` | **0** |

Seis de doce. Se integró **la mitad de una instancia** — la que sirve para un
proceso o una llamada HTTP — y se dejó entera **la mitad colectiva**, que es justo
donde Candil necesita estar.

Ahora el mapeo completo, putting el objeto de Arrea al lado del de Candil:

| | Arrea (genérico) | Candil (IA) |
|---|---|---|
| Unidad de trabajo | una **tarea** (función o comando) | un **prompt** (modelo + mensajes) |
| Recurso escaso | un **nombre** (`:llama_bin`, `:api_groq`) | la **VRAM**, en GB |
| Proceso de vida larga | `LongRunning` (Port + health) | `Candil.Engine` — **ya es un `LongRunning`** |
| Fallo repetido | `CircuitBreaker.call/3` por recurso | un modelo que devuelve basura |
| Límite de concurrencia | `Bulkhead`, N slots | cuántos modelos caben en 16 GB |
| Lote paralelo | `Leader.execute/2` + suscriptores | embeddings a N proveedores |
| Métricas | `Monitor.get_stats/0` | `candil stats` |
| Rate limit | `RateLimiter`, token bucket | API keys de proveedores |
| Catálogo | no existe | **`Candil.Store`** |
| Elección | no existe | **`Candil.Router`** |
| Presupuesto de contexto | no existe | **`Candil.Context`** |

**Ocho filas que coinciden. Dos que no, y las dos son de Candil.**

Eso no es «Candil usa Arrea». Eso es «Candil es Arrea con el vocabulario
sustituido por el de IA». Y tiene una consecuencia directa y uncomfortable:

> **Si `Candil.Agent` tiene su propio bucle ReAct con su propia semántica de
> reintentos, de límites y de errores, hay dos planificadores en el mismo proceso
> peleándose por la misma GPU.** Uno cuenta slots y el otro cuenta GB, y no saben
> del uno del otro.

Es exactamente la clase de bug contra la que llevamos dos días peleando.

---

## 2. Qué son los «esteroides», con precisión

No es «más código». Arrea ya tiene casi todo el chasis. Los esteroides son **una
sola cosa**, y es la que Arrea no puede tener porque no sabe qué es un modelo:

### 2.1 · El recurso es ponderado, no contable

`Arrea.Bulkhead` cuenta **slots**. La VRAM se **gasta en GB**, y cada modelo
cuesta distinto:

```
coder    12.4 GB
analyst   6.1 GB
embed     1.8 GB
                        suma 20.3 GB  >  16 GB de la 5080
```

Cuatro bulkheads de un slot no dan este problema. **Un bulkhead que solo cuenta no
puede expresar «dejar salir a `analyst` porque no cabe»**. Es un problema de
**knapsack**, no de concurrencia.

**Ese es el esteroide, y es la 8b entera.** La línea de cajas, el eviction, la
cola: es contabilidad de un recurso ponderado. Arrea no lo tiene porque Arrea
trabaja con recursos intercambiables y la VRAM no lo es.

### 2.2 · El registro tiene que sobrevivir y llevar atributos

`Arrea.Registry` son cinco `Registry` con `keys: :unique` planos, sin atributos.
`Arrea.Monitor` acumula estadísticas **en memoria en un GenServer**: se reinicia
con el árbol y se pierde.

Candil necesita responder, en caliente y después de un reinicio:

```
qué modelos hay          ->  Candil.Store
qué modelos están arriba ->  instances.json (D2: "la única verdad entre procesos")
cuánta VRAM usa cada uno  ->  instances.json + nvidia-smi
quién lo está usando     ->  sessions
quién está pineado       ->  el router
```

**Esa fila no puede ser una tabla en memoria de Arrea.** Y ya está medio
resuelta en Candil: `instances.json` es la verdad entre procesos desde D2.

---

## 3. La decisión que cambia: dónde vive el behaviour de agente

El subagente lo escribió sin que yo se lo pidiera, y es el punto:

> «No hay abstracción de agente. `Arrea.Pool.Worker` es el único behaviour de
> proceso y expone un solo callback: `start_link/1`.»

**Ese behaviour no va en Candil. Va en Arrea.**

Porque un `Arrea.Agent` genérico es exactamente lo que le falta a Arrea para ser
lo que Candil necesita ser, y a la vez es útil para lo que Arrea **ya** hace:
cualquiera que quiera un worker con ciclo de vida, identidad, política de error y
parada limpia lo necesita igual. Candil no es el único que lo pide.

La forma sería:

```elixir
defmodule Arrea.Agent do
  @callback identity()          :: term()
  @callback handle(request)     :: {:reply, term()} | {:noreply, state()} | :stop
  @callback on_error(error)     :: :continue | :stop
  @callback health()            :: :ok | {:error, term()}
end
```

Y entonces:

```
Arrea.Agent            behaviour, en Arrea
  ├── Candil.Agent     ReAct + prompt + modelo        <- ya existe, hay que adaptarlo
  └── (quien quiera)    cualquier otro agente
```

**`Candil.Agent` deja de ser el framework y pasa a ser una implementación.** Que es
justo lo que pasa en Alaja: `Alaja.CLI` no es el framework, es un consumidor de
`Alaja.CLI.Definition`. Tres repos lo hacen ya — Alaja, Arrea y Candil — y ninguno
ha tenido que tocar Alaja.

**Esto es una contribución a Arrea, no un consumo.** Y hay que decirlo claro
porque cambia el reparto del trabajo: hoy el plan trata Arrea como proveedor, y
esta decisión la convierte en **hermana de dos_dirs**.

---

## 4. La frontera: qué NO se mueve

Lo que separa «Arrea con esteroides» de «Arrea otra vez»:

| | |
|---|---|
| **Arrea** | ciclo de vida del worker, política de errores, leader, monitor, circuit breaker, bulkhead, resource accounting **genérico**, registro, telemetría |
| **Candil** | el catálogo de modelos, el motor de decisiones, el presupuesto de contexto, los backends, los installers, y **el significado de «prompt»** |

La regla que lo resume: **Arrea no sabe qué es un modelo. Candil no reimplementa
supervisión.** Ya está escrita, y es la regla dura del `version 3.md`:

> «**Regla dura**: cada librería tiene su dominio. **Candil no reimplementa lo que
> ya está en apero/trebejo/arrea**, y **Alaja no sabe nada de LLMs**.»

La incidente del ReAct la rompe, y por eso hay que arreglarla.

---

## 5. Qué cambia en el plan

**El grupo 3 de `EVALUACION-Y-PLAN.md` se reescribe:**

| Antes | Ahora |
|---|---|
| 3.1 Decidir si el agente usa Arrea | **Decidido: sí.** |
| 3.2 `Candil.Agent` como behaviour | **`Arrea.Agent` behaviour en Arrea; `Candil.Agent` pasa a implementación** |
| 3.3 Automatización de tareas | Igual, pero sobre `Arrea.Leader` |
| 3.4 Documentar lo que Arrea no tiene | Igual |

**Y aparece trabajo en el repo hermano**, que el plan actual no contempla en
ninguna fase:

- `Arrea.Agent` — el behaviour
- `Arrea.Resource` — contabilidad ponderada (slots **con coste**)
- upgrading de `Bulkhead` para admitir pesos, **sin romper** `Arrea.Bulkhead.run/2`

Ese último punto es el que hay que cuidar: `Arrea.Bulkhead.run/2` tiene **9 tests**
y no se rompe. Un `Bulkhead` ponderado es un módulo **nuevo**, no una versión
nueva del viejo.

### Lo que esto NO cambia

- La 8b sigue siendo la base de todo lo demás.
- El refusal de VRAM sigue siendo la regla: **no se carga solo**.
- `Candil.Store`, `Candil.Router` y `Candil.Context` no se tocan.
- Las tres colisiones de `VISION.md` siguen abiertas y siguen siendo tuyas.

---

## 6. Lo que hay que decidir

**1 · ¿El `Arrea.Agent` se hace en Arrea, o Candil lo propone y quien lo acepta lo escribe?**
Mi opinión: en Arrea, y con PR propio. Pero eso es trabajo en un repo que no es
este, y es tu decisión de reparto.

**2 · ¿El bulkhead ponderado es un módulo nuevo, o se extiende el viejo?**
Yo: **módulo nuevo**. El viejo tiene 9 tests y una semántica limpia de «slots»,
y un bulkhead que cuenta y un bulkhead que pesa no son el mismo tipo.

**3 · ¿Quién es el dueño de `instances.json` cuando hay dos procesos?**
Ya está decidido por D2 — Candil. Pero si Arrea va a registrar workers que
consumen VRAM, **los dos necesitan leerlo**, y entonces Arrea lee de un fichero
que Candil escribe. Eso es una dependencia de dirección que conviene decidir
antes, no después.

---

## 7. La frase

> **Candil es Arrea con esteroides, especializado en IA.**
>
> Los esteroides no son más código: son **un recurso que se gasta en GB y no en
> slots**, y **un registro que sobrevive a un reinicio**.
>
> Y el `Candil.Agent` que ya existe, con su `use` y su bucle ReAct, es la prueba de
> que la visión estaba escrita y no cableada — igual que `Candil.MCP` prometiendo
> servir un registro que nadie tenía.
