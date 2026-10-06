# Plan de trabajo en Arrea — justificado, con tareas definidas

> **Por qué este documento**: Arrea es del proyecto, así que mejorar lo que haga
> falta está permitido. El listón es que cada cambio esté **justificado con
> evidencia**, **planificado**, y con **las tareas definidas**. Eso es lo que hay
> aquí: tres cambios y una lista de cosas que **no** hay que tocar.
>
> **Fecha**: 2026-10-06 · Arrea 44 módulos / 314 tests · Todo lo de abajo está medido
> **Dónde se ejecuta**: en el repo de Arrea, con su PR. Nada de esto se hace
> desde Candil ni en un commit directo.

---

## 1 · D1 — `send_message/2` devuelve `:ok` cuando el mensaje se ha perdido

### La evidencia

```elixir
@spec send_message(atom(), term()) :: :ok
def send_message(worker_id, message) do
  GenServer.cast(via_tuple(worker_id), {:message, message})
end
```

`GenServer.cast/2` devuelve `:ok` **siempre**. Y `via_tuple/1` es
`{:via, Registry, {Arrea.Registry, id}}`, que si el worker no existe no resuelve
nada: el cast es un no-op silencioso.

**Ejecutado**, no leído:

```
EXISTE       -> :ok
INEXISTENTE  -> :ok        # un worker que nunca existió
INEXISTENTE2 -> :ok
```

### Por qué es un defecto y no una limitación

Un sistema de mensajes que **dice que entregó lo que no entregó** es peor que no
tener mensajes. El que llama cree que el otro agente lo sabe, y no hay forma de
saber que no.

Y hay un segundo motivo, que es el que lo ata al `@spec`: **el `@spec` dice
`:ok`**, así que dialyzer confirma la mentira. No es un contrato optimista, es un
contrato equivocado escrito en el sitio donde dialyzer lo leerá.

Esto es exactamente la clase de fallo contra la que lleva la fase 6: *«un fallo
que un script no puede ver»*. Y aquí es peor que un exit code, porque **nadie se
equivoca al verlo**.

### Qué hay que hacer

| | |
|---|---|
| **Dónde** | `lib/arrea/worker.ex`, `send_message/2` |
| **Qué** | Comprobar la existencia antes del cast. `Registry.lookup/2` primero; si está vacío, devolver `{:error, :worker_not_found}` |
| **El `@spec`** | `:ok \| {:error, :worker_not_found}` |
| **Qué NO se toca** | que siga siendo un `cast`. **Sigue sin acuse de recibo.** Un cast que se entrega no es un cast que se ha procesado. El `call/3` de F2 es lo que resuelve eso, y son dos tareas separadas a propósito |
| **Tests** | +3: existente devuelve `:ok`; inexistente devuelve el error; **y un test de contrato que falle si el `@spec` vuelve a decir `:ok`** |
| **Tamaño** | pequeño |
| **Riesgo de ruptura** | bajo: quien hoy hace `case send_message(...) do :ok -> ... end` sigue funcionando, porque `:ok` no cambia |

### Lo que este arreglo NO arregla

Sigue sin haber **acuse de recibo**. `send_message` seguirá diciendo `:ok` cuando el
worker existe pero está muerto de verdad entre el `lookup` y el `cast`. Eso es
inherente a `cast` y por eso existe F2.

---

## 2 · F2 — `Arrea.Agent.call/3`, la llamada dirigida

### La justificación

Hoy la única forma de obtener una respuesta de otro worker es
`Leader.subscribe/0` + `receive`, que es un **bus de difusión**: cualquiera puede
oírlo, y no se sabe quién lo oyó ni si lo oyó nadie. No es una llamada dirigida.

Un framework de agentes necesita *preguntar y esperar*. Y la respuesta a «¿está
vivo?» no puede ser un `:ok` incondicional, o sea que **depende directamente de
D1**.

### Qué hay que hacer

| | |
|---|---|
| **Dónde** | `lib/arrea/agent.ex` (nuevo) |
| **Qué** | `call(agent_id, request, timeout)` sobre `GenServer.call` por el mismo `via_tuple`, con timeout explícito y `{:error, :worker_not_found}` si no está |
| **El `@spec`** | `{:ok, term()} \| {:error, :worker_not_found \| :timeout}` |
| **Tests** | +6: contesta; no contesta y da `timeout`; el receptor muere a mitad; `not_found`; y **uno que compruebe que no se puede usar con un `Pool.Worker`** (ver §5) |
| **Tamaño** | pequeño |
| **Depende de** | D1 (misma comprobación, mismo sitio) |

### Lo que NO hace

**No convierte `send_message/2` en `call/3`.** Son dos operaciones distintas y el
código que manda un aviso no debería bloquear esperando un acuse que nadie pidió.

---

## 3 · F1 — `Arrea.Agent`, el behaviour de proceso que falta

### La justificación

`Arrea.Pool.Worker` es hoy el **único** behaviour de proceso de Arrea, y expone
**un** callback:

```elixir
@callback start_link(term()) :: GenServer.on_start()
```

Un proceso necesita más que arrancar: identidad, qué hacer cuando le llega algo,
qué hacer cuando falla, y si está sano. Hoy nada de eso es un callback.

**El precedente está en el hermano.** Alaja es un framework de TUI y tiene
`Alaja.App` con `init` / `update` / `view` / `subscriptions`. Arrea es un
framework de ejecución y tiene `Worker`, que es un ejecutor de colas, y **no
tiene su equivalente de proceso largo**. El paralelismo es exacto.

Y el hueco no es teórico: un agente no es un `Arrea.Worker`, porque la cola de un
ReAct **no se conoce de antemano** — el paso 5 depende de lo que conteste el
modelo en el 4. Es el motivo por el que `Candil.Agent` no cabe dentro.

### Qué hay que hacer

```elixir
defmodule Arrea.Agent do
  @callback identity() :: term()
  @callback handle(request :: term(), state :: term()) ::
              {:reply, term(), state} | {:noreply, state} | {:stop, state}
  @callback on_error(error :: term(), state :: term()) :: :continue | :stop
  @callback health(state :: term()) :: :ok | {:error, term()}
end
```

| | |
|---|---|
| **Dónde** | `lib/arrea/agent.ex` |
| **Qué más** | `use Arrea.Agent` genera `start_link/1`, `call/2`, `cast/2`, `stop/1`, y el registro |
| **Tests** | +8: implements obligatory, ciclo completo, `on_error: :stop` mata, `health` se llama, el proceso se da de baja al morir |
| **Tamaño** | medio |
| **Riesgo de ruptura** | **ninguno**: es un módulo nuevo. No toca `Worker`, ni `Pool`, ni `Leader`, ni `Monitor` |

### La frontera

`Arrea.Agent` es un **proceso actor de vida larga**. `Arrea.Worker` sigue siendo un
**ejecutor de lotes**. Son dos formas y no se mezclan; confundirlas es el error.

---

## 4 · F3 — `Arrea.Resource`, contabilidad ponderada

### La justificación

`Arrea.Bulkhead` **cuenta** slots: "caben 4". Cualquier recurso cuyo coste no sea
uno — GB de VRAM, conexiones, caracteres de un presupuesto, megas — no se puede
expresar. Y no es un caso de Candil: es de cualquiera.

Es la generalización de `Bulkhead`, no su sustituto.

### Qué hay que hacer

| | |
|---|---|
| **Dónde** | `lib/arrea/resource.ex` (nuevo) |
| **Qué** | Un recurso **con coste**: `try_reserve(cost)`, `release/1`, y un **orden de expulsión** cuando no cabe |
| **El `@spec`** | `try_reserve` devuelve `:ok` o `{:error, {:not_enough, needed, free}}` — **el número, no un `:busy` genérico** |
| **Tests** | +9: cabe; no cabe y dice cuánto falta; libera; expulsión por antigüedad; expulsión por prioridad; **y uno con un presupuesto de 0** |
| **Tamaño** | medio |
| **Riesgo de ruptura** | **ninguno**: módulo nuevo |

### Lo que NO se toca

**`Arrea.Bulkhead` se queda como está**, con sus 9 tests. Contar y pesar no son el
mismo tipo de módulo, y meterle pesos a un API limpio lo ensucia. Los dos
conviven: `Bulkhead` para concurrencia, `Resource` para coste.

---

## 5 · Lo que NO se toca, y por qué

Porque son cambios que parecerían razonables y no lo son.

| | Por qué no |
|---|---|
| **`Arrea.Supervisor` `:rest_for_one`** | Lo señalé como riesgo, y el veredicto honesto es que **es correcto**. Una librería que se usa sola quiere que el Monitor se reinicie junto con el Leader, porque el estado del Monitor sin Leader no significa nada. Lo que hay que hacer es **documentarlo**, no cambiarlo. Si Candil necesita otra cosa, lo pone en su árbol — no le cambia el árbol a la librería |
| **`Arrea.Monitor` que se reinicia** | **Es un caché, y un caché debe reiniciarse.** El que necesita sobrevivir es un registro de verdad, y ese ya existe: `instances.json`, por D2. Arrea no necesita un registro persistente; Candil tampoco, si usa el suyo |
| **`Arrea.Registry` plano, sin metadatos** | Se puede imaginar un registro con atributos, y **no hace falta**. El que necesita metadatos —qué modelo, cuánta VRAM, quién lo usa— es el catálogo de Candil, que vive en el toml. Meter atributos en el Registry de Arrea para que un solo consumidor los use es diseño por un cliente |
| **Convertir `Worker` en actor** | No. Son dos formas, y `Worker` está bien para lo que hace. El error sería forzar los agentes dentro |

---

## 6 · El orden

```
D1 ──┬──> F2        el cast miente, y la llamada dirigida no puede mentir igual
     │
     └──> F1        el behaviour, que usa F2
              └──> F3   el coste, que es de otro eje

F1 y F3 no dependen entre sí, y ninguno depende de que Candil exista.
```

**D1 primero y solo.** Es un defecto medido, cabe en una tarde, y **cambia un
`@spec` público** — que es la clase de cosa que hay que hacer antes de que haya
código que dependa del contrato viejo.

## 7 · Los criterios

Cada tarea se cierra con su criterio, y el criterio **no** es «compila»:

| | Criterio |
|---|---|
| **D1** | `send_message(:inexistente, msg)` devuelve `{:error, :worker_not_found}` en un test, **y el test falla si alguien vuelve a poner `:ok` en el `@spec`** |
| **F2** | Un agente A pregunta a B y recibe la respuesta; si B no contesta, A recibe `timeout` y **no se queda colgado** |
| **F1** | Un módulo de dos líneas con `use Arrea.Agent` corre un ciclo de vida entero sin tocar Arrea |
| **F3** | Con un presupuesto de 16 y un recurso que pide 12.4, `try_reserve` dice `{:error, {:not_enough, 12.4, 3.6}}` |

## 8 · Lo que esto NO desbloquea

- **La 8b sigue siendo de Candil.** `Arrea.Resource` le da la primitiva; el
  planificador, la cola, la línea de cajas y la política de expulsión por
  antigüedad **son de Candil**, porque saben qué es un modelo.
- **No hay descubrimiento.** Los dos procesos nacen de `start_child` con un id
  conocido. «Todos los agentes vivos ahora mismo» sigue sin existir, en Arrea y en
  Candil.
- **`Candil.Agent` no se toca hasta que F1 esté dentro**, y eso es fase 12.
