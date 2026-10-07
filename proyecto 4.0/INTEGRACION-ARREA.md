# Cómo integrar Arrea en Candil — tres niveles, tres Costs

> **La pregunta**: ¿cómo se mete el motor de agentes de Arrea en Candil?
>
> **Fecha**: 2026-10-06 · Lectura de `arrea/lib/arrea/{leader,leader/command_runner,worker,monitor,supervisor,pool}.ex`

---

## 0. La costura ya está abierta

Una «tarea» en Arrea, literalmente:

```elixir
@spec execute([String.t() | function()], keyword()) :: {:ok, String.t()} | ...
# "can be a shell command binary or a zero-arity function"
```

Y en `Arrea.Leader.CommandRunner`:

```elixir
def build_task_function(cmd) when is_binary(cmd), do: ...shell...
def build_task_function(fun) when is_function(fun, 0), do: fun
```

**Una inferencia es una función de aridad cero.**

```elixir
Arrea.Leader.execute([
  fn -> Candil.Inference.chat_local(:coder, msgs_a) end,
  fn -> Candil.Inference.chat_local(:analyst, msgs_b) end
])
```

Eso funciona **hoy**, sin tocar Arrea. El fan-out de Candil no necesita reescribir
nada del plano de ejecución: ya habla su idioma.

Es la misma forma del hallazgo de `Candil.Agent` con `use`, y del moduledoc de
`Candil.MCP` sirviendo un registro. **La visión estaba escrita en tres sitios y
ninguno se había probado.**

---

## 1. Nivel 0 — Lo que ya está (y está bien)

Seis módulos, hojas sin estado compartido, que Candil llama directamente:

`Arrea.Parallel` · `Arrea.CircuitBreaker` · `Arrea.RateLimiter` ·
`Arrea.LongRunning` · `Arrea.Telemetry` · `Arrea.Registry`

**No hay que mover nada.** Son utilidades, y el hecho de que Candil llame a
`Arrea.Parallel` en vez de usar `Task.async_stream` es exactamente lo que se
quería: una sola respuesta a «cómo hago fan-out en este ecosistema».

---

## 2. Nivel 1 — Un solo camino de fan-out, no dos

**Hoy Candil tiene un fan-out** (`Candil.Concurrency`, un solo caller:
`candil models list`) y **va por `Arrea.Parallel`**, que es el caso degenerado de
`Arrea.Leader`:

| | `Arrea.Parallel` | `Arrea.Leader` |
|---|---|---|
| paralelo | ✅ | ✅ |
| timeout por tarea | ✅ | ✅ |
| suscriptores | ❌ | ✅ |
| limpieza de lotes | ❌ | ✅ (cada 60 s) |
| estado acumulado | ❌ | ✅ |

**Movimiento:** `Candil.Concurrency` pasa a `Arrea.Leader.execute/2`, y el fallo
(raising) se resuelve en el `rescue` del caller igual que ahora.

**Lo que cuesta:** nada de Arrea. **Lo que da:** los suscriptores, que es lo que
`candil stats` va a necesitar, y una limpieza de lotes que no hay que escribir.

**Y un aviso:** `Leader.execute/2` es `GenServer.call` a **un solo proceso** con un
timeout. Cinco opencodes mandando prompts pasan por ahí. Funciona, pero es un
punto de serialización; hay que mirarlo con carga real antes de construir encima.

---

## 3. Nivel 2 — El que falta, y es el 8b

Ni el nivel 0 ni el 1 sirven para la línea de cajas, y hay que saber por qué.

`Leader.execute/2` ejecuta un **lote** y se olvida. La 8b necesita un **conjunto
permanente** que responde a: *¿qué prompts hay en cola ahora mismo, qué modelo
quiere cada uno, qué motores están cargados y cuánta VRAM está comprometida?*

Eso no es un lote. Es un conjunto de pie, y para eso está `Arrea.Pool`:

```elixir
Arrea.Pool.start_link(name, module, opts)   # checkout / checkin / overflow
```

**Pero aquí está la pared, y es la misma de siempre:**

`Arrea.Pool.Worker` es un behaviour con **un** callback:

```elixir
@callback start_link(term()) :: GenServer.on_start()
```

Un motor de IA no es un `start_link`. Es un proceso que **cuesta GB**, que tiene
**salud**, que **sirve** y que se puede **descargar**.

| necesita un engine | Arrea lo tiene |
|---|---|
| identidad | ✅ registry |
| salud | ✅ `LongRunning.health/1` |
|conjunto de pie / checkout | ✅ `Pool` |
| **coste en GB** | ❌ |
| **estado consultable que sobreviva a un reinicio** | ❌ (`Monitor` es en memoria) |

**Los esteroides son esas dos filas.** Y son Arrea en el primer caso (un recurso
ponderado es genérico) y de Candil en el segundo (`instances.json` ya es la
verdad, por D2).

---

## 4. Nivel 3 — Agentes

Con `Arrea.Agent` (nuevo, en Arrea) y `Candil.Agent` como implementación:

```
Arrea.Agent          behaviour: identity, handle/1, on_error/1, health/0
  └── Candil.Agent   ReAct + prompt + modelo + memoria
Arrea.Leader         coordina lotes de agentes
Arrea.Monitor        acumula estadísticas
```

### El límite duro, y hay que decidirlo antes

```elixir
@spec send_message(atom(), term()) :: :ok
def send_message(worker_id, message), do: GenServer.cast(via_tuple(worker_id), {:message, message})
```

**Es un `cast`.** Sin ack, sin respuesta, sin timeout, sin reintento. El único
otro camino es `Leader.subscribe/0`, que es un **bus de difusión**, no una llamada
dirigida.

Consecuencia concreta: **un agente no puede preguntarle a otro y esperar la
respuesta.** Solo puede avisar, y enterarse de lo que pasa por el bus.

Para el caso de Candil —«este agente llama a otro y necesita su respuesta»— eso
hay que **añadirlo en Arrea** (una función de reply con timeout y reintento, como
la que ya tiene `ErrorPolicy` para tareas) o **no se puede**.

---

## 5. Un riesgo que conviene mirar antes de construir encima

`Arrea.Supervisor` usa **`:rest_for_one`**, con este orden:

```
5 registries  →  Arrea.Monitor  →  Arrea.Leader  →  Arrea.WorkerSupervisor
```

`:rest_for_one` significa que **si uno de esos procesos cae, se reinicia todo lo
que está por encima**. Si `Arrea.Monitor` peta, caen `Leader` y `WorkerSupervisor`.
Y si un registro peta, cae todo.

Para una librería de la que Candil depende pero no controla, **ese radio de
explosión es una decisión de Arrea que Candil no puede cambiar.** No es un bug: es
un diseño razonable para una librería que se usa sola. Solo hay que saberlo antes
de que haya cinco sesiones apoyadas encima.

---

## 6. El orden

| | Qué | Repo | Tamaño |
|---|---|---|---|
| **1** | `Candil.Concurrency` → `Arrea.Leader.execute/2` | Candil | pequeño |
| **2** | `Arrea.Resource` — contabilidad ponderada, módulo **nuevo** | **Arrea** | medio |
| **3** | El 8b: cola + eviction con `instances.json` como verdad | Candil | grande |
| **4** | `Arrea.Agent` behaviour + reply con timeout | **Arrea** | medio |
| **5** | `Candil.Agent` como implementación | Candil | pequeño |

**1 antes que 3** porque es el mismo camino y hay que elegirlo una vez.
**2 antes que 3** porque el 8b sin coste en GB no puede decidir nada.
**4 y 5 pueden ir en paralelo con 3**, porque no dependen del scheduler.

---

## 7. Lo que hay que decidir

1. **¿La función de reply para agentes entra en Arrea o se resuelve en Candil?**
   Sin ella, los agentes se avisan pero no se hablan. Con `Arrea.Agent` ya siendo
   de Arrea, yo diría que en Arrea.
2. **¿El fan-out de Candil pasa por `Leader` ahora, o en la 8b?**
   Yo: **ahora**. Es pequeño, y hacerlo dos veces es justo lo que pasó con el
   drift entre `Lockfile` y `dart analyze`.
3. **¿El radio de `:rest_for_one` de Arrea se acepta, o se pide un árbol más
   tolerant?** No lo decide Candil, pero lo decide quien use Arrea para algo que
   no puede caerse.
4. **¿Quién lee `instances.json`?** Ya lo decides en `CANDIL-ES-ARREA.md` §6.3, y
   es la misma pregunta: en cuanto Arrea registre workers que consumen VRAM, los
   dos lo necesitan.
