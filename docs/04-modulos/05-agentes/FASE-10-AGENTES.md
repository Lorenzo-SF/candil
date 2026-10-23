# FASE 10 · Los agentes — spec

> **Estado**: **borrador escrito por el consejero** (2026-10-23) ✓, a la espera
> de la aprobación del dueño ✓. **No es una fase empezada**: es el plano ✓.
>
> **Dónde encaja**: la fase **10** de [`docs/02-orden/`](../../02-orden/README.md) ✓,
> dentro del módulo **05 · Agentes** ✓. No crea un módulo nuevo ✓.
>
> **Qué resuelve**: el otro bloque grande que no tenía criterio de aceptación ✓.
> Cierra **F5.6** (la admisión) ✓, **F5.7** (`StepRouter`) ✓, **F5.8**
> (`GoalBased`) ✓, **F5.9** (`UtilityBased`) ✓, **P-9** (la identidad derivada
> de D-25 ✓) y el **contrato de `Agent.new/1`** ✓, que hoy miente porque se
> traga el fallo de `ensure_engine_running/2` ✓.
>
> **Prerrequisitos**: F5.0–F5.5 cerradas ✓; **P-12** y **P-10** cerrados ✓
> (P-10 por D-29 ✓). **P-6 no es prerrequisito de F5.6**: P-6 es el reintento
> en varias GPUs ✓; F5.6 funciona con una ✓. P-6 solo entra cuando la fase 10
> se use en una máquina con más de un device ✓.

---

## 1 · Lo que cambia, en una tabla

| Pieza | Hoy | Lo que este spec fija |
|---|---|---|
| `Agent.new/1` | Devuelve un struct y **ignora** el fallo de `ensure_engine_running/2` ✓; además hace `{:ok, pid} = ...` y revienta si el supervisor falla ✓ | `{:ok, agent}` \| `{:error, reason}` ✓, sin proceso huérfano ✓ |
| **F5.6** · admisión | El agente con modelo pineado funciona; el que pide otro modelo puede acabar en un 500 o en un OOM ✓ | Una puerta que contesta con **errores tipados** ✓ y no duplica el ledger ✓ |
| **F5.7** · `StepRouter` | El modelo se elige **una vez** por sesión ✓ | Se elige **una vez por paso** ✓, con la misma traza del router ✓ |
| **F5.8** · `GoalBased` | No existe ✓ | Descomposición en sub-objetivos ✓ y sub-agentes con admisión ✓ |
| **F5.9** · `UtilityBased` | No existe; `Scorer` puntúa modelos ✓ | Candidatos por paso y `Scorer` aplicado a **caminos** ✓ |
| **P-9** | Un agente **sin nombre** se salta el presupuesto de crashes y el circuito ✓ | Identidad derivada (D-25) ✓: cae en la misma puerta que los nombrados ✓ |

---

## 2 · El contrato de `Agent.new/1`

### 2.1 · Lo que hace hoy, y por qué miente

`lib/candil/agent.ex:145` declara:

```elixir
@spec new(keyword()) :: %__MODULE__{}
def new(opts \\ []) do
  ...
  if alias_ != nil do
    Candil.ensure_engine_running(alias_, opts)   # ← el resultado se ignora
  end

  {:ok, pid} = Candil.Agents.Supervisor.start_agent(...)
  %__MODULE__{pid: pid, name: name}
end
```

Dos mentiras en cinco líneas:

1. **El motor puede no arrancar** —modelo desconocido, sin engine, sin VRAM,
   `:memory_unknown`— y `new/1` devuelve un agente vivo que fallará en el
   primer paso ✓.
2. **El supervisor puede no arrancar el proceso** —nombre duplicado, opciones
   inválidas— y el `{:ok, pid} = ...` convierte el error en un
   `MatchError` ✓.

### 2.2 · El contrato propuesto

```elixir
@spec new(keyword()) :: {:ok, t()} | {:error, term()}
```

El orden es el que ya está, pero **cada paso devuelve el error**:

1. Resolver el alias del modelo. Si no está en el catálogo:
   `{:error, :model_not_found}` ✓.
2. `Candil.ensure_engine_running(alias, opts)`:
   - `:ok` → seguir.
   - `{:error, reason}` → devolver `reason` **sin traducirlo** ✓.
3. `Candil.Agents.Supervisor.start_agent(...)`:
   - `{:ok, pid}` → `{:ok, %__MODULE__{pid: pid, name: name}}` ✓.
   - `{:error, reason}` → `{:error, reason}` ✓.

**Si el motor arrancó y el agente no**, el motor **no se para** ✓: puede ser
compartido con otro agente o con una petición del gateway ✓. La consecuencia
—un motor encendido sin agente— se documenta; no se esconde ✓.

**Compatibilidad**: no hay llamadores en `lib/` ni en `test/` que usen
`Agent.new/1`; el único ejemplo está en el `@doc` ✓. Cambiar el contrato no
rompe código de producción ✓, solo el ejemplo, que se actualiza ✓.

### 2.3 · Los tests del contrato

- `new/1` con un modelo que no existe devuelve `{:error, :model_not_found}` y
  **no** arranca ningún proceso ✓.
- `new/1` con un modelo sin engine devuelve `{:error, :no_engine}` ✓.
- `new/1` con un modelo que no cabe devuelve `{:error, :no_room}` ✓ (con
  `FakeGPU` o un stub del scheduler) ✓.
- `new/1` con un nombre ya vivo devuelve `{:error, {:already_started, pid}}` ✓.
- `new/1` feliz devuelve `{:ok, %Agent{pid: pid}}` y el proceso está en el
  supervisor ✓.

---

## 3 · F5.6 · La admisión

### 3.1 · La regla

**La cuenta ya existe.** `Candil.Engine.Resource` registra `Arrea.Resource`
por device, reserva antes de arrancar y libera al morir el motor ✓ (D-27 ✓,
P-12 ✓). Lo que falta no es otro ledger ✓: es una **puerta para el agente** que
use esa cuenta y conteste con errores que el bucle pueda entender ✓.

> Un agente y un motor piden cosas distintas a la misma VRAM. El motor pide
> *cargar* y la respuesta es sí o no. El agente pide *usar* y la respuesta
> tiene que ser un número o un error tipado, porque si no cabe ahora quizá
> cabe en tres pasos.

### 3.2 · La API

```elixir
defmodule Candil.Agents.Admission do
  @spec check(atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def check(model_alias, opts \\ [])

  @spec ensure(atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def ensure(model_alias, opts \\ [])
end
```

- `check/2` **no arranca nada**: solo dice si el modelo se puede usar ahora.
  Es lo que consulta `StepRouter` para descartar candidatos ✓.
- `ensure/2` **arranca si hace falta** y es lo que usa el paso del agente ✓.
  Reutiliza `Candil.ensure_engine_running/2`; no crea un camino nuevo ✓.
- `opts`: `:consumer` (para el pin), `:start_wait_ms` (se pasa al arranque) ✓.

### 3.3 · Los errores tipados

| Error | Cuándo | Quién lo produce |
|---|---|---|
| `:model_not_found` | El alias no está en el catálogo | `Candil.Store.get_model/1` |
| `:no_engine` | El modelo no declara engine y no es remoto | `ensure_engine_running/2` |
| `:engine_not_found` | El engine del modelo no está en el catálogo | `ensure_engine_running/2` |
| `:model_not_up` | El modelo existe pero no está arriba y `check/2` no arranca | `Candil.Llm.engine_healthy?/1` |
| `:no_gpu` | El modelo pide GPU y la máquina no tiene | `Engine.start_placed/2` |
| `:gpu_layers_fixed` | El modelo fija las capas y el fit no puede ajustarlas | `Engine.start_placed/2` |
| `:memory_unknown` | No se puede medir el device | `Engine.start_placed/2` |
| `:no_room` | No cabe y no hay víctima expulsable | `Engine.start_placed/2` |

**Un modelo remoto no pasa por la admisión de VRAM** ✓: su provider ya existe
y no ocupa esta GPU ✓. `check/2` devuelve `:ok` si el provider está en el
catálogo; `{:error, {:unknown_provider, name}}` si no ✓.

### 3.4 · Los tests

- `check/2` de un modelo inexistente: `:model_not_found` ✓.
- `check/2` de un modelo local sin engine: `:no_engine` ✓.
- `check/2` de un modelo remoto con provider: `:ok` ✓; sin provider:
  `{:unknown_provider, name}` ✓.
- `ensure/2` con un modelo que no cabe: `:no_room` ✓ y **no** arranca ✓.
- `ensure/2` con un modelo ya sano: `:ok` y **no** vuelve a arrancar ✓.
- El test de que la cuenta es la del ledger: el error de `start_placed/2`
  llega **sin traducir** ✓.

---

## 4 · F5.7 · `StepRouter`

### 4.1 · La pieza

Hoy `agent.ex:113` elige el modelo en `resolve_model/2` y no lo toca en toda la
vida del bucle ✓. La pieza es mover esa decisión **dentro** del paso ✓:
`Candil.Router.route/2` ya existe ✓, con sus capas, su caché y su traza ✓. Lo
único que cambia es la **frecuencia** ✓.

### 4.2 · La API

```elixir
defmodule Candil.Agents.StepRouter do
  @spec route(Candil.Agent.agent_state(), term(), keyword()) ::
          {:ok, Candil.Agents.Route.t()} | {:error, term()}
  def route(state, input, opts \\ [])
end
```

`%Candil.Agents.Route{}`:

| Campo | Qué es |
|---|---|
| `model` | El alias elegido |
| `backend` | El módulo de backend que sirve ese modelo (`LlamaCpp`, `OpenAICompat`) |
| `target` | El engine o provider resuelto |
| `decision` | El `%Candil.Router.Decision{}` completo, para la traza |

- Si hay **pin** (`Candil.Router.pinned(consumer)`), el pin gana ✓ y no se
  consulta al router ✓.
- Si el agente lleva `:model` fijo, ese modelo gana ✓ y `StepRouter` no se
  usa ✓. El `:auto` es lo que enciende el routing por paso ✓.
- La traza del paso guarda `model`, `strategy`, `layers_ran` y `alternatives`
  ✓. Sin eso, un agente que cambia de modelo no se puede depurar ✓.
- Después de elegir, `Admission.ensure/2` ✓. Si falla, el paso devuelve
  `{:error, reason, trace}` ✓; **no hay fallback silencioso** ✓. Un fallback
  se configura explícitamente (`:fallback_model`) y se registra en la traza ✓.

### 4.3 · El backend por modelo

`Candil.Agent` guarda **un** backend ✓; un router por paso puede elegir un
modelo local y otro remoto ✓, y no hablan el mismo protocolo ✓. `StepRouter`
resuelve el backend con `Candil.Router.resolve/1` ✓:

| Tipo de modelo | Backend |
|---|---|
| `:local` | `Candil.Backend.LlamaCpp` |
| `:remote` | `Candil.Backend.OpenAICompat` |
| `:external` | `Candil.Backend.OpenAICompat` |

El `:backend` explícito del agente **sigue ganando** ✓ (es lo que usan los
tests con `StubBackend` ✓). El cambio es que `step/3` usa el backend de la
**ruta del paso**, no el del estado global ✓.

### 4.4 · Los tests

- Dos pasos con `StubBackend` distinto por modelo: el paso 1 va al modelo A y
  el paso 2 al B ✓; la traza lo dice ✓.
- Un pin existente gana al router ✓.
- Un modelo fijo (`:model`) no consulta al router ✓.
- `:no_room` en el paso 2 devuelve `{:error, :no_room, trace}` ✓ y no cae al
  modelo del paso 1 en silencio ✓.
- El test de que el backend remoto se resuelve sin tocar `LlamaCpp` ✓.

---

## 5 · F5.8 · `GoalBased`

### 5.1 · La regla

El tipo 3 no inventa un bucle nuevo ✓: descompone un objetivo en
**sub-objetivos** ✓, cada uno con su agente ✓, y reparte el trabajo ✓. La
descomposición la propone el modelo ✓, pero **Candil la valida** ✓: una lista
de sub-objetivos, un máximo (`:max_subgoals`, 4 por defecto) ✓, y un JSON
parseable ✓.

### 5.2 · La API

```elixir
defmodule Candil.Agents.GoalBased do
  @spec plan(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def plan(goal, opts \\ [])

  @spec run(String.t(), keyword()) :: Candil.Agent.result()
  def run(goal, opts \\ [])
end
```

- `plan/2` llama al modelo planificador (el `:planner` del TOML o el modelo
  del agente) y espera:
  `{"subgoals": ["...", "..."]}` ✓.
- Si el JSON no vale o hay más de `:max_subgoals`, `{:error, :invalid_plan}`
  ✓; no se recorta en silencio ✓.
- `run/2` arranca un agente por sub-objetivo con
  `Candil.Agents.Supervisor` ✓, los ejecuta con `Candil.Agents.call/3` ✓ y
  recoge los resultados ✓. Un sub-agente que falla **no tumba a los demás** ✓:
  el resultado lleva `{:error, reason}` en su posición ✓.
- El reparto usa `Arrea.Leader` **solo como fan-out** ✓; los sub-agentes son
  procesos de Candil ✓, no workers de Arrea ✓. Si `Arrea.Leader` no puede
  ejecutar procesos, se usa `Task.async_stream` ✓ y se documenta ✓.

### 5.3 · Los tests

- `plan/2` con un stub que devuelve dos sub-objetivos: `{:ok, [a, b]}` ✓.
- `plan/2` con JSON inválido: `{:error, :invalid_plan}` ✓.
- `plan/2` con cinco sub-objetivos y `max_subgoals: 4`: error ✓.
- `run/2` con dos sub-agentes: los dos corren ✓; uno falla y el otro no ✓; el
  resultado conserva las dos posiciones ✓.
- El sub-agente hereda la admisión ✓: si su modelo no cabe, devuelve
  `:no_room` y no arranca ✓.

---

## 6 · F5.9 · `UtilityBased`

### 6.1 · La regla

El tipo 4 no puntúa **modelos** ✓: puntúa **caminos** ✓. Un camino es una
secuencia de pasos, cada uno con su modelo y su prompt ✓. El `Scorer` que ya
existe (`Candil.Router.Scorer`) se aplica a cada paso ✓ y el camino se queda
con la suma (o la media) de sus puntuaciones ✓, no con la del primer modelo ✓.

### 6.2 · La API

```elixir
defmodule Candil.Agents.UtilityBased do
  defmodule Path do
    defstruct steps: [], score: 0.0, cost_mb: 0, trace: []
  end

  @spec candidates(Candil.Agent.agent_state(), term(), keyword()) :: [Path.t()]
  def candidates(state, input, opts \\ [])

  @spec choose([Path.t()], keyword()) :: {:ok, Path.t()} | {:error, :no_path}
  def choose(paths, opts \\ [])

  @spec run(String.t(), keyword()) :: Candil.Agent.result()
  def run(input, opts \\ [])
end
```

- `candidates/3` genera hasta `:max_paths` (3 por defecto) ✓, cada uno con
  una secuencia de modelos candidatos ✓.
- `choose/2` descarta los caminos con algún paso `:no_room` o
  `:memory_unknown` ✓ y elige el de mayor `score` ✓; a igualdad, el de menor
  `cost_mb` ✓.
- `run/2` ejecuta el camino elegido paso a paso ✓, con `StepRouter` y
  `Admission.ensure/2` ✓.
- La traza lleva el score de cada camino y por qué se descartó ✓.

### 6.3 · Los tests

- Dos caminos con modelos distintos y un stub de `Scorer`: gana el de mayor
  suma ✓, no el del primer paso ✓.
- Un camino con `:no_room` se descarta ✓.
- A igualdad de score, gana el de menor `cost_mb` ✓.
- `run/2` ejecuta exactamente los pasos del camino elegido ✓.

---

## 7 · P-9 · La identidad derivada (D-25)

### 7.1 · La regla

D-25 ya decidió la tercera opción ✓: **darle identidad derivada** al agente sin
nombre ✓, para que caiga en la misma puerta que los nombrados ✓. No se acepta
«los agentes anónimos son los que cuelgan» ✓.

### 7.2 · La API

```elixir
defmodule Candil.Agents.Identity do
  @spec derive(module(), keyword()) :: term()
  def derive(agent_module, opts)
end
```

Orden de derivación:

1. `:name` si está ✓.
2. `:goal` si está → `{:goal, hash(goal)}` ✓.
3. `{agent_module, hash(opciones_normalizadas)}` ✓.

- `hash/1` usa `:crypto.hash(:sha256, :erlang.term_to_binary(term))` ✓ y
  devuelve un binario hexadecimal ✓; no `phash2`, que no está pensado para
  persistir ✓.
- Las opciones se normalizan: se quitan `:name`, `:pid`, funciones y
  referencias ✓; si no, dos agentes iguales tendrían identidades distintas ✓.
- `Crashes.count/2` y `Breakers.load/1` reciben **siempre** una identidad ✓;
  no queda la rama `true ->` que se salta las dos puertas ✓.

### 7.3 · Los tests

- Dos agentes sin nombre con las mismas opciones tienen la misma identidad ✓.
- Con opciones distintas, identidad distinta ✓.
- Un agente sin nombre que revienta cinco veces recibe
  `:crash_budget_exceeded` ✓.
- Un agente sin nombre que se cuelga cinco veces abre su circuito ✓.
- El test de que no queda ninguna rama que se salte la identidad ✓.

---

## 8 · Las fases

| Fase | Qué | Prerrequisito |
|---|---|---|
| **F5.6.0** | El contrato de `Agent.new/1`: `{:ok, agent}` \| `{:error, reason}` | ninguno |
| **F5.6** | `Admission.check/2` y `ensure/2`, errores tipados | #136 mergeado ✓ |
| **F5.7** | `StepRouter`, `Route`, backend por modelo y traza | F5.6 y F5.2 |
| **F5.8** | `GoalBased`: plan, validación, sub-agentes, parciales | F5.7 |
| **F5.9** | `UtilityBased`: caminos, `Scorer` de caminos, ejecución | F5.7 |
| **F5.9b** | P-9: `Identity.derive/2` y las dos puertas | F5.6 (puede ir en paralelo) |

P-9 **no espera** a F5.7 ✓: la identidad se puede arreglar en cuanto F5.6 esté
cerrada ✓, y es la deuda que hoy hace que un agente anónimo se salte el
circuito ✓.

---

## 9 · Los criterios de aceptación

- `Agent.new/1` devuelve `{:ok, agent}` o `{:error, reason}` ✓; con un modelo
  inexistente o sin VRAM **no arranca ningún proceso** ✓; el ejemplo del
  `@doc` está actualizado ✓.
- `Admission.check/2` y `ensure/2` devuelven los errores tipados de §3.3 ✓;
  `:no_room` no se convierte en un 500 ni en un OOM ✓.
- Un agente con `:auto` cambia de modelo entre pasos ✓; la traza dice qué
  modelo y qué capa lo eligió ✓; un pin gana ✓; un `:model` fijo no consulta
  al router ✓.
- `GoalBased.run/2` descompone en sub-objetivos validados ✓, ejecuta cada uno
  con su agente ✓ y devuelve resultados parciales si uno falla ✓.
- `UtilityBased.run/2` elige el camino de mayor score ✓, descarta los que no
  caben ✓ y ejecuta sus pasos ✓.
- Un agente sin nombre tiene identidad derivada ✓ y cae en `Crashes` y
  `Breakers` ✓; no queda ninguna rama que se salte las dos puertas ✓.
- `grep` no encuentra `Candil.CLI` en `lib/candil/agents/**` ni en
  `lib/candil/agent.ex` ✓.
- Las puertas: tests con semillas 0 y 1 ✓, `mix credo` ✓, `mix dialyzer` ✓,
  `mix docs` ✓.

---

## 10 · Lo que este spec **no** decide

- **El tipo 5, de aprendizaje** ✓: sigue fuera, y no es una fase todavía ✓.
- **El split de P-6** ✓: `--split-mode layer` y `--tensor-split` son otro PR
  ✓, con dos GPUs reales ✓.
- **Un modelo real para la puerta de máquina de los tipos 3 y 4** ✓: la
  aceptación se hace con `StubBackend` ✓, como el resto de la fase 10 ✓.
- **La política de fallback** ✓: se configura (`:fallback_model`) y se
  registra ✓; no hay un fallback silencioso por defecto ✓.
- **El número de sub-objetivos y de caminos** ✓: `:max_subgoals` (4) y
  `:max_paths` (3) son los valores de fábrica de este spec ✓; se pueden
  cambiar en el TOML o en la llamada ✓.

---

## 11 · Las decisiones del dueño que siguen abiertas

1. **`Agent.new/1`**: ¿`{:ok, agent}` / `{:error, reason}` o excepción? Este
   spec recomienda el tuple ✓; una excepción para un fallo de configuración
   también es defendible, pero el resto de la fachada (`Candil.chat/3`,
   `Candil.pull/1`) usa tuples ✓.
2. **P-9**: ¿identidad derivada (D-25) o aceptar explícitamente que un agente
   anónimo no tenga protección? Este spec implementa D-25 ✓.
3. **F5.6**: ¿el agente puede **arrancar** un modelo que no está arriba, o
   solo usar los que ya están? Este spec usa `ensure/2` (arranca si cabe) ✓ y
   `check/2` (no arranca) ✓; el paso usa `ensure/2` ✓.
4. **F5.8/F5.9**: ¿entran en la definición de «terminado» con
   `StubBackend`, o el dueño exige una puerta con modelo real? La definición
   actual dice que sí entran ✓; la evidencia real es la puerta de máquina de
   la fase 10 ✓, que hoy no existe ✓.
