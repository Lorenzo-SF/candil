# Cómo integrar Arrea en Candil — el plan del framework de agentes

> **La pregunta**: workers, leader, monitor y las comunicaciones entre ellos encajan
> muy bien en lo que Candil necesita para el parámetro del framework de agentes.
> **Cómo se enchufa, en orden.**
>
> **Fecha**: 2026-10-06 · Arrea 44 módulos / 314 tests · Candil 87 módulos / 800 tests

---

## 1. El obstáculo, y es de forma

`Arrea.Worker` está medido, y no es un actor:

```elixir
Arrea.Worker.start_link(id: :worker_1, tasks: [fn -> :work end], parent: self())
#                                          ^^^^^^ una lista PRE-CARGADA
```

```elixir
handle_info(:execute_task, state)   # ejecuta la PRIMERA de la cola
handle_cast({:message, msg}, state) # recibe mensajes, fire-and-forget
terminate(...)                       # cuando la cola se acaba
```

**Es un ejecutor de lotes.** Se le da la cola antes de empezar, la vacía, y muere.

**Un agente es lo contrario**: vive, recibe mensajes, decide, y no tiene cola
prevista. Un `Candil.Agent` haciendo ReAct son 8 pasos que **no se conocen de
antemano** — el paso 5 depende de lo que conteste el modelo en el 4.

Meter un agente en `Arrea.Worker` es **encajarlo en una forma que no es la suya**.
Y por eso el subagente escribió, sin que se lo pidiera:

> «No hay abstracción de agente. `Arrea.Pool.Worker` es el único behaviour de
> proceso y expone un solo callback: `start_link/1`.»

---

## 2. Lo que hay y lo que falta, pieza a pieza

| Necesita Candil | Arrea hoy | Veredicto |
|---|---|---|
| Un proceso por agente, con ciclo de vida | `Worker` (cola) · `Pool` (checkout) | ❌ **la forma no sirve** |
| Acción dirigida a otro agente, con respuesta | `send_message/2` = `GenServer.cast` | ❌ **unidireccional** |
| Tolerar que un modelo falle repetidamente | `CircuitBreaker.call/3` por nombre | ✅ **encaja exacto** — el modelo *es* un recurso con nombre |
| Admitir N agentes según VRAM | `Bulkhead` con N slots | ⚠️ **cuenta, y la VRAM se pesa** |
| Métricas | `Monitor` + `Telemetry` | ✅ pero `Monitor` **se reinicia con el árbol** |
| Procesos largos (el motor) | `LongRunning` | ✅ ya se usa |
| Coordinar un grupo | `Leader.execute/2` | ✅ pero es de lote |

**Tres de siete encajan. Las que fallan fallan por forma, no por falta de código.**

---

## 3. El plan, en tres movimientos

### Movimiento 1 · `Arrea.Agent` — el behaviour que falta

En Arrea, con PR propio. No en Candil: lo necesita Arrea igual para lo suyo.

```elixir
defmodule Arrea.Agent do
  @callback identity() :: term()
  @callback handle(request :: term(), state :: term()) ::
              {:reply, term(), state} | {:noreply, state} | {:stop, state}
  @callback on_error(error :: term(), state :: term()) :: :continue | :stop
  @callback health(state :: term()) :: :ok | {:error, term()}
end
```

Y **la pieza que de verdad falta: la llamada dirigida.**

```elixir
Arrea.Agent.call(agent_id, request, timeout)  # GenServer.call por debajo
Arrea.Agent.cast(agent_id, request)            # el cast de ahora, renombrado
```

Hoy `send_message/2` es un `cast`: si el emisor necesita respuesta, **no hay
forma**. El único camino es `Leader.subscribe/0` + `receive`, que es un bus
global, no una llamada dirigida. Dos agentes que se hablan necesitan una pregunta
y una respuesta, y eso no existe.

### Movimiento 2 · `Candil.Agent` pasa a ser implementación

```elixir
defmodule Candil.Agent do
  use Arrea.Agent                       # identidad, ciclo, health, parada

  def handle({:step, prompt}, state) do
    # 1 · PIDE al router qué modelo para este paso
    # 2 · llama a Candil.Context para el historial de ESTE agente
    # 3 · infiere, registra la observación, y pide el siguiente paso
  end
end
```

**Y aquí está la pieza elegante, que es la que cierra el círculo:**

> **Cada paso del ReAct es una decisión de routing.**

Pensar → *¿qué modelo?* → actuar → observar → *¿y ahora?* El router no decide
**una vez** por sesión: decide **una vez por paso**. Y cada decisión ocupa el
motor de ese modelo, y por tanto su VRAM.

Así que el router de la fase 7 y la 8b de la línea de cajas dejan de ser dos
sistemas que se cruzan sin hablarse: **es la misma decisión, vista desde dos
decide el modelo, la otra decide dónde cabe.

### Movimiento 3 · Admisión por VRAM, no por slots

`Arrea.Bulkhead` cuenta slots. La 5080 tiene 16 GB y:

```
coder 12.4 · analyst 6.1 · embed 1.8 · designer 9.2
```

Un bulkhead de «4 agentes» **no significa nada** cuando lo que escasea son GB.
Hace falta un módulo nuevo — `Arrea.Resource` — que sepa:

- un recurso **con un coste en GB**, no un contador
- **`try_reserve(coste)`**: si no cabe, se dice que no
- **orden de expulsión**, para la línea de cajas

Y **`Arrea.Bulkhead` se queda como está**, con sus 9 tests. Contar y pesar no son
el mismo tipo de módulo, y romper un API limpio de 9 tests para meterle pesos
sería empeorarlo.

---

## 4. El orden, y la trampa

**El orden va de abajo arriba porque cada cosa necesita la de debajo:**

```
4 · Arrea.Resource (VRAM)        ─┐
3 · Arrea.Pool de agentes         ├─ solo cuando hay algo que repartir
2 · Candil.Agent sobre Arrea.Agent
1 · Arrea.Agent + Agent.call/3   ─┘
```

**Y la trampa, que es la que importa:**

> **No se empiezan los agentes multi-modelo antes que la 8b.**

Un agente con **un** modelo pineado funciona hoy, sin 8b: un proceso, un motor,
cero decisiones. Un agente que **pregunta al router en cada paso** puede pedir un
modelo que no está arriba — y sin contabilidad de VRAM no hay nadie que le diga
que no. Eso es el OOM con retardo, pero en versión agente.

**Por eso el orden es 8b → agentes**, y no al revés, aunque los agentes suenen más
emocionantes que un planificador de memoria.

---

## 5. Lo que esto NO arregla

Porque es tentador creer que esto lo arregla todo, y no:

- **La mesa camilla** (8c) sigue sin decidirse. Los agentes de arriba usan
  `Candil.Context`, que particiona por `consumer`. Si cada agente es su propio
  `consumer`, no hay mesa; si comparten, hay que reescribir la política justa.
- **`Arrea.Monitor` se reinicia con el árbol.** Sigue siendo cierto. La verdad
  que sobrevive es `instances.json`, y eso hay que decidirlo antes de que haya
  agentes (ver decisión 3 de `CANDIL-ES-ARREA.md`).
- **No hay descubrimiento.** Los agentes nacen de un `start_child` explícito con
  un `batch_id` conocido. Eso vale para lotes y no vale para "todos los agentes
  vivos ahora mismo", que es lo que un pool de agentes necesita.
- **Los seis motores que faltan** (ollama, vllm, airllm, mlx_lm, tensorrt_lm,
  FLM) siguen sin existir. Un framework de agentes sobre un motor es un ejemplo
  muy bonito.
