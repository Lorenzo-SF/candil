# 05-agentes · Taxonomía de Agentes Autónomos

> **Estado**: escrito leyendo el código de `docs-v2`. **Nada de este documento se ha
> ejecutado**: el contenedor donde se escribió no tiene `mix` en el `PATH` y
> `_build` es un enlace simbólico a un directorio que no existe. Todo lo que aquí
> se afirma sale de leer ficheros, y cada afirmación lleva su `fichero:línea`.
> Lo que hay que ejecutar está marcado como **PENDIENTE DE MEDIR**, con el comando
> exacto y con lo que se espera ver.
>
> **Ficheros leídos**: `lib/candil/agent.ex`, `lib/candil/tool.ex`,
> `lib/candil/tools.ex`, `lib/candil/structured.ex`, `lib/candil/backend.ex`,
> `lib/candil/application.ex`, `lib/candil/store.ex`, `lib/candil/instances.ex`,
> `lib/candil/conversation.ex`, `test/candil/agent_test.exs`,
> `test/candil/tool_test.exs`, `test/candil/tools_test.exs`, `mix.exs`, y en
> `deps/arrea/lib/arrea/`: `worker.ex`, `worker_state.ex`, `worker/error_policy.ex`,
> `worker/result_handler.ex`, `worker/scheduler.ex`, `worker/registry.ex`,
> `pool.ex`, `pool/worker.ex`, `registry.ex`, `bulkhead.ex`, `supervisor.ex`,
> `monitor.ex`, `leader.ex`, `circuit_breaker/circuit_breaker.ex`.
>
> **Regla de este documento**: lo que existe se cita con su fichero. Lo que no
> existe se marca **[PROPUESTO]** y no se escribe nunca como si ya estuviera.

---

> ## ⚠️ Este módulo se escribió sobre un bucle que NO funcionaba
>
> La [fase 0.2 lo ejecutó por primera vez contra un backend
> real](../../01-inventario/HALLAZGOS-FASE-0.md), y encontró que **el bucle
> ReAct no cerraba jamás**: la observación se metía con `role: "user"`, así que
> el modelo recibía su propio resultado como si el usuario lo hubiera dicho,
> volvía a pedir la herramienta, y otra vez hasta agotar los pasos.
>
> **Arreglado en `1e60ab6`** y verificado con un backend de verdad.
>
> ### Qué se sostiene y qué hay que releer
>
> | | |
> |---|---|
> | ✅ **Se sostiene** | La taxonomía de los cinco tipos, la frontera con Arrea, y el análisis de qué falta en `Arrea`. Nada de eso depende de que el bucle funcione |
> | ⚠️ **Releer con reservas** | **§5.3** (escribir un agente paso a paso) y **§4** (los tests primero). Las hipótesis sobre cómo escalar a multi-agente se hicieron **sin poder ejecutar ni un solo paso** |
>
> §5.3 lleva ahora, al principio, **las cuatro reglas del contrato** que no
> estaban en ninguna versión anterior de este documento: el backend es
> obligatorio, la llamada va en el texto, el resultado vuelve con `role: "tool"`
> y las herramientas se registran con `Candil.Tool.define/1`. Sin esas cuatro el
> bucle no cierra, y sin ellas el paso a paso no funciona.

---

## 1 · Qué es

**Un agente no es una tarea: es un proceso que no sabe todavía qué va a hacer.**

Y ese es exactamente el punto donde el chasis que Candil ya tiene se queda corto,
por un motivo que no es de IA sino de concurrencia: `Arrea.Worker` ejecuta una
**cola** que se le pasa **antes** de empezar, y un agente no tiene esa cola, porque
el segundo paso de un ReAct depende de lo que conteste el modelo en el primero.

Por qué ahora, y no en tres fases: porque `lib/candil/agent.ex` ya existe, ya tiene
un bucle ReAct, y **no lo ha ejecutado nunca nadie contra un modelo de verdad**.
Medido:

```bash
grep -rn "use Candil.Agent" --include=*.ex --include=*.exs . | grep -v ^./deps
```

Devuelve **una sola línea**, y es el ejemplo de su propio `@moduledoc`
(`lib/candil/agent.ex:27`). No hay ningún `defmodule` en el repo que lo use, no hay
ningún `doctest` en `test/candil/agent_test.exs`, y los tres tests que hay
(`test/candil/agent_test.exs`, líneas 71, 78 y 110) llaman todos a `run/3` con un
**mapa de configuración**, nunca a la API documentada.

> Es decir: la puerta pública de este módulo —`use Candil.Agent`— tiene **cero**
> cobertura. Todo lo que funciona, funciona por un camino que el diseño del usuario
> no menciona.

---

## 2 · Por qué así

### 2.1 · El dato que reencuadra el encargo: la dependencia va al revés

El encargo dice «Candil es dependencia dura de Arrea». **No es así**, y conviene
decirlo antes de decidir nada, porque cambia el coste de la decisión principal.

`mix.exs:59`:

```elixir
{:arrea, github: "Lorenzo-SF/arrea", branch: "main", override: true},
```

Y `deps/arrea/mix.exs` **no menciona `candil` en ninguna línea**. La flecha es:

```
Candil  ──depende──▶  Arrea 3.x  ──depende──▶  Apero, Alaja, Trebejo, …
```

Qué significa en la práctica, y es lo que hay que tener claro antes de la F5.1:
**escribir `Arrea.Agent` en Arrea no es un commit en este repo.** Es una PR en
`Lorenzo-SF/arrea`, sobre `main`, desde otro repositorio, con su CI y su door de
revisión. Candil la consume con `override: true` **desde la rama `main` de
GitHub**, no desde una etiqueta con versión: un `mix deps.get` se lleva lo que haya
ahí ese día.

> Por qué importa: una fase que ponga el behaviour en Arrea **no es una fase
> cerrable en Candil**. Es una fase con dos mitades y dos repositorios, y la mitad
> de Arrea puede mergearse mientras la de Candil sigue en rojo.

### 2.2 · El reparto real: seis de doce, y media docena es código muerto

`docs/00-arrea/README.md` §2 dice «Seis de doce». Se sigue confirmando: contando los
`Arrea.*` que aparecen en `lib/` de Candil:

| Módulo de Arrea | ¿Lo usa Candil? | Dónde |
|---|---|---|
| `Arrea.Parallel` | ✅ | `lib/candil/concurrency.ex` |
| `Arrea.RateLimiter` | ✅ | `lib/candil/http/rate_limit.ex` |
| `Arrea.LongRunning` | ✅ | `lib/candil/engine*` — **es el motor** |
| `Arrea.CircuitBreaker` | ✅ | `lib/candil/http/retry.ex` |
| `Arrea.Telemetry` | ✅ | `lib/candil/telemetry.ex` |
| `Arrea.Registry` | ✅ | el motor se registra aquí |
| `Arrea.Worker` · `Leader` · `Monitor` · `Pool` · `Bulkhead` · `Subscribers` | ❌ **cero** | la mitad colectiva |

Los seis que no usa son, uno a uno, los que un agente necesitaría. Eso no es
casualidad: se integró la mitad de **una instancia** —un proceso, una llamada— y se
dejó entera la mitad **colectiva**.

> ⚠️ **Un número de `docs/00-arrea/README.md` §1 ha cambiado.** Allí dice «44
> módulos, 314 tests». Hoy, medido:
>
> ```bash
> find deps/arrea/lib   -name '*.ex'          | wc -l   # 45
> find deps/arrea/test  -name '*_test.exs'    | wc -l   # 33 ficheros de test
> ```
>
> Arrea se sigue desde `main` y se mueve, así que el número de módulos era
> correcto cuando se escribió y ya no lo es. **No se corrige aquí**: corregir un
> número sin volver a medirlo es exactamente lo que `docs/03-convenciones/README.md`
> §5 prohíbe. Queda medido y dicho.

Ahora el dato que no está en ningún documento y que hay que meter aquí, porque
cambia la lista de la fase:

```bash
grep -rn "ResultHandler" deps/arrea/lib
# deps/arrea/lib/arrea/worker/result_handler.ex:1:defmodule Arrea.Worker.ResultHandler do

grep -rn "Scheduler" deps/arrea/lib
# deps/arrea/lib/arrea/worker/result_handler.ex:14:  alias Arrea.Worker.Scheduler
# deps/arrea/lib/arrea/worker/scheduler.ex:1:defmodule Arrea.Worker.Scheduler do
```

| Módulo | Quién lo llama | Estado |
|---|---|---|
| `Arrea.Worker.ErrorPolicy` | `Arrea.Worker` (`worker.ex:42`, `worker.ex:428`) | **vivo** |
| `Arrea.Worker.ResultHandler` | nadie | **código muerto** |
| `Arrea.Worker.Scheduler` | solo `ResultHandler` | **código muerto** |

`ResultHandler` y `Scheduler` son un par huérfano con las mismas firmas que
`ErrorPolicy` (`handle_error_with_policy/3`, `build_default_policy/0`,
`handle_custom_action/3`). El `Arrea.Worker` real usa `ErrorPolicy` y se escribe sus
propios `handle_task_success/3` y `handle_task_error/3` en privado (`worker.ex:256` y
`worker.ex:302`).

> **Consecuencia para esta fase**: de las trece piezas que el encargo enumera, dos
> no son un punto de partida, son un sitio donde pisar. No se puede «reutilizar
> `Arrea.Worker.ResultHandler`» porque no lo reutiliza nadie y no se sabe si
> funciona.

### 2.3 · El dato que cambia el punto de partida: `Candil.Agent` no es un GenServer

El diseño dice «cada agente es un actor autónomo viviente dentro de la BEAM», y
cada agente es un `GenServer` con estado de herramientas, memoria y objetivos. Lo
que hay en `lib/candil/agent.ex` es otra cosa, y conviene decirlo sin suavizar:

| Lo que dice el diseño | Lo que hay en `agent.ex` |
|---|---|
| un `GenServer` vivo, con nombre | `loop/7`, una **función privada recursiva** (`agent.ex:113`) |
| estado: herramientas, memoria, objetivos | el estado es el **argumento de la recursión**; no hay struct |
| se le manda un mensaje: `send(agente_b, {:evaluar_tarea, datos})` | no hay `handle_call/3`, `handle_cast/2` ni `handle_info/2` en el fichero |
| un Supervisor lo reinicia a su último estado estable | no hay Supervisor, ni `snapshot`, ni nada que reiniciar |
| se le habla con `send/2` | la única puerta es `Candil.Agent.run/3`, que **bloquea** |

Es decir: hoy `Candil.Agent` es una **función pura con forma de agente**, no un
proceso con forma de agente. La diferencia no es de estilo; es la diferencia entre
poder tener dos agentes hablando y no poder.

Tres fallos concretos que salen de leer el fichero, y que la F5.0 tiene que arreglar
antes de tocar nada más:

**a) El contrato declarado y el contrato real no son el mismo.**

```elixir
# lib/candil/agent.ex:41
@type result :: {:ok, String.t(), trace()} | {:error, term()}
```

pero `finalize/1` devuelve una tupla de **tres** elementos en error
(`agent.ex:219-220`), y el test lo confirma:

```elixir
# test/candil/agent_test.exs:128
assert {:error, :max_steps_exhausted, trace} =
         Candil.Agent.run(config, "go", backend: StubBackend, model: "test")
```

El `@spec` dice dos y el código hace tres. Nadie se dio cuenta porque
`@type result()` se escribe a mano y no lo comprueba nadie.

**b) Sin `:backend` no devuelve un error: revienta.**

```elixir
# lib/candil/agent.ex:87-93
defp resolve_backend(opts) do
  case opts[:backend] do
    nil -> nil          # ← nil
    mod -> mod
  end
end
```

y dos líneas más abajo, en cada vuelta del bucle:

```elixir
# lib/candil/agent.ex:121
case backend.chat(model, messages, tools: prompt_schemas) do
```

`nil.chat/3` es un `UndefinedFunctionError`. Los tres tests pasan el backend **a
mano** (`agent_test.exs:75`, `:103`, `:129`), que es justo por lo que nadie lo ha
visto: **la ruta documentada —`MyAgent.run("hola")` sin opciones— es la que peta.**

**c) Un modelo que no existe se convierte en la cadena `"default"`.**

```elixir
# lib/candil/agent.ex:95-98
defp resolve_model(opts, config) do
  Keyword.get(opts, :model) || config[:model] || "default"
end
```

No hay catálogo, ni comprobación, ni `String.to_existing_atom/1`. Un alias
inventado no falla: **se convierte en otro alias**. Es exactamente el bucle de
`docs/00-arrea/README.md` §5 —«un nombre que no existe tiene que ser un fallo
ruidoso, no un `nil`»— y `docs/03-convenciones/README.md` §4 lo dice con nombre:
*«un alias se llama `coder`. Si el código dice `:verifier` donde la config dice
`coder`, el router simplemente no encuentra nada»*. El agente hoy hace
exactamente eso, en la línea 97, con una cadena.

### 2.4 · La forma: por qué un agente no cabe en `Arrea.Worker`

Este es el argumento central y se demuestra leyendo tres sitios de
`deps/arrea/lib/arrea/worker.ex`:

```elixir
# worker.ex:144 — la cola se fija AL ARRANCAR
tasks = Keyword.get(opts, :tasks, [])

# worker.ex:174 — y arranca de inmediato
Process.send_after(self(), :execute_task, 0)

# worker.ex:368 — y solo se puede SACAR por la cabeza
defp execute_next_task(%WorkerState{tasks: [task | rest]} = state) do
```

La cola **baja**, nunca sube. Y el único `handle_cast` del worker
(`worker.ex:182`) recibe `{:message, message}` y hace dos cosas
(`worker.ex:400-421`): emitir un evento, o **reenviar** el mensaje a *otro* worker
con `{:send_to_worker, target, payload}`. En **ningún** caso añade una tarea a la
cola.

> **La forma, en una frase**: `Arrea.Worker` responde a «¿qué hago con esta lista?».
> Un agente necesita responder a «dame un paso más», y esa pregunta no tiene
> respuesta hasta que el modelo ha contestado el paso anterior.

Por eso un agente **no** es un `Arrea.Worker` con una tarea más larga. Y por eso
tampoco sirve «meter el ReAct dentro de una tarea de la cola»: el bucle sería una
función de aridad 0 opaca, sin estado inspeccionable, sin `handle_call`, y sin
posibilidad de que otro proceso le hable.

### 2.5 · Y lo que Arrea **no** tiene

Todo verificado en `deps/arrea/lib/arrea/`:

| Falta | Dónde se comprueba | Por qué le importa a un agente |
|---|---|---|
| **RPC dirigido** | `worker.ex:112-118` — `send_message/2` es `GenServer.cast/2`: `:ok` significa «se encoló», nunca «lo procesó» | dos agentes necesitan **pregunta y respuesta**, no un aviso |
| **Descubrimiento** | `registry.ex` tiene `all/0`, `count/0`, `lookup/1` | «quién hay vivo» no existe; hay «los pids registrados» |
| **Registro con metadatos** | `registry.ex:13-21` — `Registry.select` devuelve `%{atom() => pid()}` | no hay dónde guardar `goal`, `kind` o `max_steps` de un agente |
| **Heartbeats** | `grep -riE "heartbeat" deps/arrea/lib` → **0 resultados** | no hay forma de saber que un agente vive sin perguntarle |
| **Breaker por agente** | `CircuitBreaker.call/3` existe (`circuit_breaker.ex:142`) pero se instancia por **nombre de recurso**, y el nombre es del modelo | un agente que se cuelga no abre nada: el breaker lo abriría el modelo, y ese puede estar sano |
| **Reinicio a estado estable** | `worker.ex:35` → `use GenServer, restart: :temporary`; `pool/worker.ex:34` → también `:temporary` | **Arrea no reinicia sus workers**, y aunque lo hiciera no hay estado guardado |

> Sobre la última fila, porque es la que toca el diseño de frente: el enunciado
> «si un agente entra en bucle de razonamiento o falla, su Supervisor lo reinicia a
> su último estado estable» describe **dos cosas que Arrea no da**. Una: los workers
> son `:temporary`. Dos: no hay `snapshot`/`restore` en ninguna parte. Eso se
> construye, no se hereda.

### 2.6 · Lo que se descartó, y por qué

| Alternativa | Por qué se descarta |
|---|---|
| **Meter el agente en `Arrea.Worker`** | La cola es de Plain Known Length en la práctica (`worker.ex:144`), y no crece. Es la razón de §2.4. |
| **Un `Task` por cada `run/3`** | Un `Task` no tiene nombre, ni `whereis`, ni supervisor propio, ni se puede reiniciar «a su último estado». Además el diseño dice explícitamente que **no** hay bucles infinitos para mantener vivos a los agentes. |
| **`Arrea.Pool` de agentes** | `Pool.checkout/2` es un lease con `checkin` y *overflow* (`pool.ex:102-136`): sirve para un conjunto homogeneous que se toma prestado. Un agente no se toma prestado, se habla con él. Y `Pool.Worker` expone **un** callback (`pool/worker.ex:25`), insuficiente para un agente. |
| **Dejar el behaviour en Candil** | Descartado por decisión, y el precedente está confirmado: Alaja tiene su DSL y **los dos** repos lo consumen — `lib/candil/cli.ex:43` y `deps/arrea/lib/arrea/cli/definition.ex:27`, los dos con `use Alaja.CLI.Definition`. Un behaviour en la biblioteca de abajo, y el framework de arriba como una implementación más. |
| **Extender `Arrea.Bulkhead` para la VRAM** | Descartado por tipo, no por esfuerzo. `Bulkhead.start_link/3` toma `max_concurrent::pos_integer()` (`bulkhead.ex:64`) y `run/2` acquisition es un `:acquire` binario (`bulkhead.ex:183`). **Contar slots y pesar gigas no son la misma cuenta**: un modelo de 7 GB y uno de 2 GB ocupan el mismo «1». De ahí `Arrea.Resource` **[PROPUESTO]**, módulo nuevo, y `Bulkhead` intacto. |

### 2.7 · La pieza elegante: cada paso del ReAct **es** una decisión de routing

Esta es la conexión que cierra el módulo contra el resto del producto, y no
necesita un solo componente nuevo.

Hoy, en `agent.ex:113`, una vuelta del bucle hace exactamente tres cosas:
comprobar la cancelación, preguntar al modelo, y si la respuesta trae tool calls,
ejecutarlas y volver. El modelo está **fijado** en `resolve_model/2` antes de
empezar y no se toca nunca durante la vida del bucle.

La pieza es esa línea, movida:

> El agente no elige el modelo una vez por sesión. **Lo elige una vez por paso.**

Y por qué esto es una pieza y no una idea:

1. **No es un subsistema nuevo.** El router ya existe (`lib/candil/router.ex`) y
   ya tiene sus capas (`Candil.Router.Scorer`, `Candil.Router.DecisionEngine`). Lo
   único que cambia es la **frecuencia**: de una vez por petición a una vez por
   paso. El mismo `decide/3`, el mismo `pin/2`, la misma traza.
2. **Cierra con la línea de cajas, que es donde duele.** Cada paso del bucle ocupa
   el motor del modelo que lo Conteste. Si el paso 3 se decide en un modelo que no
   estaba arriba, ese modelo **hay que cargarlo** —y cargarlo son segundos y
   gigabytes— o hay que **negarse**. Sin contabilidad de VRAM en GB **nadie puede
   decir que no**: el `Bulkhead` cuenta slots y los dos modelos cuentan 1.
3. **Por eso los agentes multi-modelo no pueden empezar antes que 8b.** Un agente
   con el modelo pineado funciona hoy, con `resolve_model/2` y sin más. Uno que
   pregunta al router en cada paso puede pedir algo que no está arriba, y el
   primer fallo que vería un usuario sería un OOM en la GPU, no un error de Candil.

---

## 3 · Qué toca

Lista cerrada. Todo lo demás está fuera de esta fase.

### 3.1 · En Arrea — otro repositorio

**PR **PROPUESTO**, no existe****

| Fichero | Qué |
|---|---|
| `deps/arrea/lib/arrea/agent.ex` | **[PROPUESTO]** el behaviour `Arrea.Agent`, §5.2 |
| `deps/arrea/lib/arrea/agent/supervisor.ex` | **[PROPUESTO]** `DynamicSupervisor` de agentes, `:one_for_one` |
| `deps/arrea/lib/arrea/resource.ex` | **[PROPUESTO]** contabilidad **ponderada en GB**, §5.2 |
| `deps/arrea/test/arrea/agent_test.exs` | **[PROPUESTO]** tests del behaviour |

### 3.2 · En Candil — este repositorio

| Fichero | Qué | Estado |
|---|---|---|
| `lib/candil/agent.ex` | pasa a **implementar** `Arrea.Agent`; se arregla el `@type result/0` y `resolve_backend/1` | existe, hay que tocarlo |
| `lib/candil/agents/simple_reflex.ex` | **[PROPUESTO]** el agente del tipo 1, como `GenServer` | no existe |
| `lib/candil/agents/supervisor.ex` | **[PROPUESTO]** enganche con `Arrea.Agent.Supervisor` | no existe |
| `lib/candil/agents/step_router.ex` | **[PROPUESTO]** la decisión de routing **por paso** (§2.7) | no existe |
| `lib/candil/agent_test.exs` | los tres tests que hay, **más** los de la F5.0 | existe |
| `test/candil/agent/simple_reflex_test.exs` | **[PROPUESTO]** | no existe |
| `test/candil/agent/contract_test.exs` | **[PROPUESTO]** el test de contrato del §4 | no existe |

### 3.3 · Lo que NO toca esta fase

`lib/candil/tools.ex`, `lib/candil/tool.ex` y `lib/candil/structured.ex` **se leen
y se usan tal cual**. No se cambian. `parse_tool_calls/1` y `schemas_to_prompt/1`
ya hacen el trabajo pesado del parseo y son la razón por la que el agente puede ser
pequeño. `lib/candil/application.ex` solo se toca en la F5.3, y solo para añadir
**un** hijo.

---

## 4 · Los tests primero

Cuatro tests **escritos, no ejecutados**. Los ficheros
(`test/candil/agent/contract_test.exs` y compañía) **no existen todavía**: esto es
el guion de la fase, no su estado.

> Una versión anterior de este documento decía «los cuatro son rojos hoy», y no
> era cierto: un test escrito en un markdown no está rojo, **no está**. El
> primero que existe de verdad es
> [`real_test.exs`](../../../test/candil/agent/real_test.exs), y lo escribió la
> fase 0.2 porque no había otra manera de saber si el bucle cerraba.

Y los que había de verdad, la fase 0.2 los encontró **verdes y falsos**: el
bucle estaba roto y los tests no lo veían.

Patrón de los cuatro: **de contrato** (los tres primeros) y **de orden** (el
cuarto, porque `Candil.Tool` es estado global y hay que limpiarlo).

> Orden real de la F5.0: escribe el test, **ejecuta**, lee el rojo, luego el
> código. Un test escrito después del código es una descripción de lo que hizo el
> código, no un test.

### Test 1 — el contrato de `run/3` dice dos elementos y hace tres

```elixir
# test/candil/agent/contract_test.exs
defmodule Candil.Agent.ContractTest do
  use ExUnit.Case, async: false

  # Patrón: DE CONTRATO. Lee la declaración que lee un humano, y falla si vuelve a
  # mentir. Es el mismo truco que ya usa Arrea con `send_message/2`, documentado en
  # docs/00-arrea/README.md §6: el @spec decía `:ok` y dialyzer confirmaba la
  # mentira.
  test "el tipo result/0 declara la forma de error que finalize/1 devuelve de verdad" do
    fuente = File.read!("lib/candil/agent.ex")

    assert fuente =~ "@type result :: {:ok, String.t(), trace()} | {:error, term(), trace()}"
  end
end
```

**Hoy**: rojo. `agent.ex:41` dice `{:error, term()}`.
**Se ve el fallo**: el mensaje nombra la cadena que no aparece y la línea entera.

### Test 2 — sin `:backend` no se revienta

```elixir
# test/candil/agent/contract_test.exs (mismo fichero)

  test "run/3 sin :backend devuelve un error en vez de llamar a nil.chat/3" do
    config = %{goal: "g", max_steps: 1, tool_schemas: []}

    assert {:error, :no_backend} = Candil.Agent.run(config, "hola")
  end
```

**Hoy**: rojo, y no con un fallo sino con un **`UndefinedFunctionError`**. Eso es
justo lo que hay que ver: el test no falla, **el proceso muere**. Si el test parece
«raro», el bug está donde toca.

### Test 3 — un alias inventado no se convierte en `"default"`

```elixir
  test "un alias que no está en el catálogo es un error ruidoso" do
    config = %{goal: "g", max_steps: 1, tool_schemas: []}

    assert {:error, :model_not_up, "inventado"} =
             Candil.Agent.run(config, "hola",
               backend: Candil.AgentTest.StubBackend,
               model: "inventado"
             )
  end
```

**Hoy**: rojo. `resolve_model/2` (`agent.ex:97`) devuelve `"inventado"` tal cual y
no lo comprueba contra nada; el test falla porque **no** hay `{:error, ...}`. Este
es el test que cierra la familia del «pin que no existía» del que habla
`docs/03-convenciones/README.md` §1.

### Test 4 — el `use` documentado, ejecutado por fin

```elixir
  defmodule WeatherAgent do
    use Candil.Agent,
      name: "weather",
      goal: "Responder preguntas meteorológicas",
      tools: [],
      max_steps: 2
  end

  test "el macro __using__ declara lo que promete" do
    assert %{name: "weather", goal: "Responder preguntas meteorológicas", max_steps: 2} =
             WeatherAgent.__agent_config__()
  end
```

**Hoy**: **verde**, y esa es la parte incómoda. El macro funciona. Lo que no
existe es el resto: nadie ha comprobado que `run/2` se genere, ni que `__agent_config__`
se llame sin backend (y por §2.3-b, si se llama sin backend, **reventará**). Este
test entra en la fase precisamente para que el Test 2 tenga a quién morder.

### Y el primero de todos, el de la F5.3

```elixir
# test/candil/agent/simple_reflex_test.exs
defmodule Candil.Agents.SimpleReflexTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised({Candil.AgentTest.StubBackend, responses: []})
    Candil.Tool.reset()
    :ok
  end

  test "responde a un estímulo y no guarda memoria entre llamadas" do
    {:ok, pid} = Candil.Agents.SimpleReflex.start_link(name: "router", goal: "clasificar")

    assert {:ok, "FINAL_ANSWER: one", _} = Candil.Agents.SimpleReflex.evaluate(pid, "uno")
    assert {:ok, "FINAL_ANSWER: two", _} = Candil.Agents.SimpleReflex.evaluate(pid, "dos")

    # Sin memoria: el segundo estímulo no puede ver el primero.
    assert {:ok, %{steps: 0}, _} = Candil.Agents.SimpleReflex.status(pid)
  end
end
```

Es **de orden**, porque `StubBackend` es un proceso con nombre global
(`test/candil/agent_test.exs:15`) y sin `Tool.reset()` la herramienta del test
anterior se cuela en este. Es exactamente el fallo de semilla del que avisa
`docs/03-convenciones/README.md` §5.

---

## 5 · Cómo se hace

### 5.1 · La taxonomía: los cinco tipos

Para cada tipo: qué necesita de Arrea, qué aporta Candil, y qué falta.

---

#### Tipo 1 · Reflejo Simple — estímulo → respuesta, sin memoria

Clasificadores, routers de prioridad. Un paso, una decisión, se acabó.

**Qué necesita de Arrea**

| Pieza | Existe | Nota |
|---|---|---|
| `Arrea.Registry` | ✅ | `registry.ex:36` — el nombre del agente |
| `Arrea.CircuitBreaker` | ✅ | por nombre de **modelo**, no de agente |
| `Arrea.Telemetry` | ✅ | ya reflejo en `[:candil, …]` |
| `Arrea.Agent` (behaviour) | ❌ **[PROPUESTO]** | §5.2 |
| `Arrea.Agent.call/3` (RPC con respuesta) | ❌ **[PROPUESTO]** | `send_message/2` es un `cast` |

**Qué aporta Candil**

`Candil.Tool` (registro, `tool.ex:43` es un `GenServer` en el árbol de
`Candil.Supervisor`), `Candil.Tools.parse_tool_calls/1` (`tools.ex:81`),
`Candil.Backend` (el behaviour de 4 callbacks, `backend.ex:63-75`) y
`Candil.Telemetry`.

**Qué hay que crear**

| | |
|---|---|
| el behaviour | `Arrea.Agent` |
| el proceso | `Candil.Agents.SimpleReflex` |
| el supervisor | hijo en `Candil.Supervisor` (`application.ex:44`) |
| el RPC | `Arrea.Agent.call/3` |

> **El primero, y el único que hoy no depende de 8b.** Con un modelo pineado y un
> `max_steps: 1` no hay nada que decidir por routing, nada que pesar y nada que
> persistir. Es el que hay que hacer primero.

---

#### Tipo 2 · Reflejo Basado en Modelos — estado interno mutable

El estado vive **en** su `GenServer`: qué ha visto, en qué va, qué ha pagado.

| | |
|---|---|
| **Existe** | `Arrea.Monitor` (estadísticas, pero **en memoria**: `monitor.ex:60` `get_state/0`), `Arrea.Bulkhead`, `Candil.Context` (historial en ETS, `application.ex:52`) |
| **Falta** | `snapshot/1` y `restore/1` en el behaviour — **el «último estado estable» no existe** |
| **Aporta Candil** | `Candil.Conversation` (hoy) → `Candil.Context` (§7, el bloqueo de 4.1.0) |
| **Candil aporta** | el bucle ReAct pasa de recursión a reductor sobre estado — `agent.ex:113` deja de ser `loop/7` y pasa a ser `step/3` |

---

#### Tipo 3 · Basado en Objetivos — meta a largo plazo, descomposición

| | |
|---|---|
| **Existe** | `Arrea.Leader` (`leader.ex:92` `execute/2`) — **es lo más cerca que hay**: reparte un lote en paralelo, avisa a suscriptores (`leader.ex:56`), y manda `{:worker_done, …}` / `{:worker_error, …}` al padre (`worker.ex:277`, `:330`) |
| **Falta** | un almacén de objetivos que sobreviva al reinicio. `Candil.Store` es **ETS** (`store.ex:88`) y muere con la VM |
| **Falta** | sub-agentes: hoy `Leader` reparte tareas, no agentes que toman decisiones |
| **Candil aporta** | el prompt de descomposición, y `Candil.Tools` para que un objetivo se convierta en tool calls |

---

#### Tipo 4 · Basado en Utilidad — evalúa varios caminos y elige el mejor

Se puntúa por coste, latencia y ficheros modificados.

| | |
|---|---|
| **Existe** | `Arrea.Parallel` — y Candil **ya lo envuelve** en `Candil.Concurrency.map/2`, con elwhy escrito en su `@moduledoc`: tiempo por tarea, resultados etiquetados, orden de entrada |
| **Existe** | `Candil.Router.Scorer` (`scorer.ex`) — **ya hay una función de puntuación en el repo**, con `score/4` y `explain/2` |
| **Falta** | generar los candidatos **por paso**: el scorer existe, el «qué alternativas hay en este punto del ReAct» no |
| **Falta** | admisión por VRAM: §2.7 |

> El tipo 4 es, de lejos, el más construido: el 80 % de las piezas ya están
> escritas, pero **en el sitio equivocado**. `Scorer` puntúa modelos; aquí hay que
> puntuar caminos.

---

#### Tipo 5 · De Aprendizaje — guarda feedback y ajusta system prompts

| Necesita | Existe |
|---|---|
| Feedback del usuario, por agente | ❌ **nada**. No hay ni un tipo, ni una función, ni un fichero que lo represente |
| Persistencia | ⚠️ **parcial**: `Candil.Store` es ETS y muere con la VM. Lo único durable es `Candil.Instances.path/0` → `instances.json` (`instances.ex:138`), escrito con `Apero.Atomic.File.write(…, fsync: true)` (`instances.ex:171`) |
| Reconstruir un `system_prompt` y persistirlo | ❌ nada |

**Y por eso este no se implementa.** Dos razones, y la segunda es la importante:

1. `instances.json` es una lista de **instancias corriendo** —`model`, `port`,
   `engine`, `pid`, `owner`, `started_at`, `healthy`— (`instances.ex:13`). Meter
   ahí lo que un usuario le enseñó a un agente rompe la regla 2 de
   `docs/README.md`: *«una verdad, un sitio»*.
2. Falta la **decisión de diseño**, no el código. ¿Dónde vive un prompt aprendido?
   ¿Se versiona? ¿Se puede borrar? ¿Qué pasa con dos agentes que aprenden cosas
   distintas del mismo modelo? **Ninguna de esas cuatro tiene respuesta**, y las
   cuatro son anteriores a escribir una línea.

Lo que sí es verdad a su favor, y es la razón por la que no se descarta: **el
mecanismo de escritura durable ya está probado en producción** en este repo.
`instances.json` se escribe a fichero temporal y se renombra, con `fsync`. Copiar
ese patrón para un almacén de prompts no es inventar nada. Lo que falta es la
tienda y su esquema, y el esquema es una decisión de producto.

---

**Resumen: qué está hecho y qué hay que crear**

| Tipo | Arrea que hace falta | Candil que hace falta | ¿Depende de 8b? |
|---|---|---|---|
| 1 · Reflejo Simple | `Arrea.Agent`, supervisor, `call/3` | `SimpleReflex` como `GenServer` | **no** |
| 2 · Basado en Modelos | `snapshot/1`, `restore/1` | migrar `Conversation` → `Context` | no |
| 3 · Basados en Objetivos | `Leader` (ya está) | almacén de objetivos, descomposición | **sí** (el sub-agente puede pedir otro modelo) |
| 4 · Basados en Utilidad | `Parallel` (ya está), admisión VRAM | candidatos por paso, `Scorer` de caminos | **sí** |
| 5 · De Aprendizaje | — | almacén durable + **decisión de diseño** | bloqueado, y no por 8b |

### 5.2 · El behaviour `Arrea.Agent`

**[PROPUESTO] — no existe. Esto es el contrato que se propone, no una API que se pueda llamar hoy.**

```elixir
# deps/arrea/lib/arrea/agent.ex   ← PROPUESTO, otro repositorio
defmodule Arrea.Agent do
  @moduledoc """
  Behaviour for a long-lived process whose next unit of work is not known yet.

  A worker is given a queue at start-up. An agent is given a goal and decides
  one step at a time, because what the second step is depends on what the model
  answered to the first.
  """

  @type agent_state :: term()
  @type input :: term()

  @doc "Builds the initial state. A process that cannot start must say why."
  @callback init_agent(keyword()) ::
              {:ok, agent_state} | {:stop, term()}

  @doc """
  One unit of work. Pure: same state + same input, same result.

  This is the callback that replaces the queue. It is a function, not a message,
  so an agent can be reasoned about — and tested — without starting a process.
  """
  @callback step(agent_state, input, keyword()) ::
              {:ok, agent_state, term()} | {:error, term(), agent_state}

  @doc """
  Static metadata: name, goal, kind. Arity 0 on purpose: a supervisor holding the
  name of a dead agent has no state to give it.
  """
  @callback describe() :: map()

  @doc "The last state worth restarting from."
  @callback snapshot(agent_state) :: map()

  @doc "Go back to a snapshot. Only reachable when snapshot/1 is implemented."
  @callback restore(map()) :: {:ok, agent_state} | {:error, term()}

  @optional_callbacks snapshot: 1, restore: 1, describe: 0
end
```

**Y por qué estos cinco, y no otros.** Esto es lo que más se va a discutir, así que
va razonado:

| Decisión | Por qué |
|---|---|
| **`step/3` es una función, no un mensaje** | Es lo que hace que un agente se pueda probar sin BEAM. `Candil.Agent.loop/7` ya es una función pura con forma de ReAct; el contrato la saca de `privado` a `público` sin cambiarle la forma. **Es el movimiento más barato de todos los de esta fase.** |
| **No `run/2`** | `run/3` bloquea. Un `GenServer` que bloquea es un `Task` con nombre, y un `Task` no se reinicia ni se registra. Un agente que ejecuta un paso y devuelve es un proceso que hace N pasos sin morir en ninguno. |
| **No `handle_call/3` ni `handle_info/2`** | Son internos de GenServer. Un behaviour que los declara ata el framework al proceso. El precedente está en la casa: `Arrea.Pool.Worker` declara **un** callback, `start_link/1` (`pool/worker.ex:25`), y deja que `use GenServer` sea dueño del resto. |
| **`describe/0` sin argumentos** | Un supervisor que reinicia a un agente **no tiene su estado**: tiene su nombre. Por eso es de aridad 0 y devuelve lo estático. |
| **`snapshot/1` y `restore/1` opcionales** | Un tipo 1 no tiene estado estable que restaurar: no tiene memoria. Declararlos obligatorios obligaría a los cinco tipos a fingir un estado que no tienen. Opcional también significa que Arrea puede reinudar el proceso sin estado — degraded, pero no muerto. |
| **`init_agent/1` y no `init/1`** | Para que el `GenServer` que genera el `__using__` pueda tener su `init/1` sin colisión. `init_agent/1` devuelve `{:ok, state}` y el `__using__` lo envuelve en `{:ok, state}` del `GenServer`. |
| **`Arrea.Resource` aparte, y `Bulkhead` intacto** | `Bulkhead.start_link/3` cuenta `pos_integer()` slots (`bulkhead.ex:64`). Pesar es otra cuenta. No es una ampliación de `Bulkhead`; es un módulo que se parece a `Bulkhead` y no es `Bulkhead`. Lo que pesaría: |

```elixir
# deps/arrea/lib/arrea/resource.ex   ← PROPUESTO
defmodule Arrea.Resource do
  @type weight :: non_neg_integer()      # GB

  # :ok si cabe; {:error, :no_room} con las cuentas si no
  @callback admit(atom(), weight()) :: :ok | {:error, :no_room}
  @callback release(atom()) :: :ok
  @callback committed(atom()) :: {:ok, weight(), weight()}   # {lo que hay, el techo}
end
```

> `Arrea.Resource` **no se implementa en esta fase**. Se escribe su contrato aquí
> porque es lo que desbloquea el tipo 3, el 4 y la F5.7, y para que quede escrito
> **antes** de que haya código que lo dé por hecho.

### 5.3 · Escribir un agente desde cero, paso a paso

Para alguien que nunca ha encendido un ordenador. Si ya sabes Elixir, esto te
sobra; si no, esto es lo que hay que hacer.

#### Antes de nada: el contrato real, y son cuatro cosas

Esto no estaba en ninguna versión anterior de este documento, y costó horas
descubrirlo ejecutando. Un agente de Candil **no** se escribe solo: hay cuatro
cosas que hay que saber o el bucle no cierra.

| # | Regla | Qué pasa si no la sabes |
|---|---|---|
| 1 | **El backend es obligatorio**: `Agent.run(input, backend: MiBackend)` | `resolve_backend/1` devuelve `nil` y el bucle hace `nil.chat(...)` → `UndefinedFunctionError` |
| 2 | **La llamada a herramienta va en el TEXTO**: `<tool_call>{"name":"…","args":{…}}</tool_call>` | Un LLM real la pone en `content`, no en un campo. `Candil.Tools.parse_tool_calls/1` la saca de ahí |
| 3 | **El resultado vuelve con `role: "tool"`** | Es lo que espera un LLM de verdad. Con `role: "user"` el modelo recibe su propio resultado como si el usuario lo hubiera dicho, y **vuelve a pedir la herramienta para siempre** |
| 4 | **Las herramientas se registran con `Candil.Tool.define/1`** | `use Candil.Agent, tools: [MiTool]` **no registra nada**: espera `%Tool{}` ya construidos y revienta |

> Las cuatro están comprobadas en
> [`test/candil/agent/real_test.exs`](../../../test/candil/agent/real_test.exs),
> que es el test que se escribió para encontrarlas. Y el tag `<tool_call>`
> **se construye con `<<60>>` y `<<62>>`**, porque escrito a mano se cuela un
> carácter invisible entre el `<` y el nombre, el parser no ve la llamada, y el
> agente se queda en `max_steps_exhausted` sin decir por qué.

**Paso 1 · Abrir el repo y ver que está.**

```bash
cd /workspace/repos/candil
git branch --show-current
```
Esta documentación está en `main` desde el 2026-10-08. Si no imprime `main`,
no sigas: estás en otra rama y vas a perder el trabajo.

```bash
mix --version
```
Debe imprimir `Elixir 1.19.5-otp-28` con OTP 28. Si dice `mix: command not
found`, no es un problema del código: no hay Elixir instalado. Para todo este
documento eso está **sin medir** (§ cabecera).

**Paso 2 · Ver el estado real antes de tocar nada.**

```bash
mix test test/candil/agent_test.exs
```
Se espera ver `8 tests, 0 failures` (`agent_test.exs` + `real_test.exs`). **Si ves muchos fallos y no sabes por qué,
mira §5 de `docs/03-convenciones/README.md`**: un `MIX_BUILD_PATH` sucio produce
`Mox.Server` sin arrancar y un montón de rojos que no son tuyos.

**Paso 3 · Escribir el test ROJO primero.**

Crear el fichero `test/candil/agent/simple_reflex_test.exs` con el test del §4.
Ahora existe un directorio que no existía (`test/candil/agent/`).

```bash
mix test test/candil/agent/simple_reflex_test.exs
```
Se espera ver un error de **compilación**: `Candil.Agents.SimpleReflex` no existe.
**Ese es el rojo correcto.** Un test que se pone rojo porque el módulo no existe
está haciendo su trabajo.

**Paso 4 · Escribir el fichero más pequeño que pueda.**

Crear `lib/candil/agents/simple_reflex.ex`:

```elixir
defmodule Candil.Agents.SimpleReflex do
  @moduledoc """
  Tipo 1 de la taxonomía: estímulo -> respuesta, sin memoria.

  Cada `step/3` son exactamente las tres líneas que ya tiene `loop/7` en
  lib/candil/agent.ex, sin recursión y sin estado acumulado.
  """
  use GenServer

  @impl true
  def init(opts), do: {:ok, %{name: opts[:name], goal: opts[:goal], steps: 0}}

  @impl true
  def handle_call({:evaluate, input}, _from, state) do
    {:reply, Candil.Agent.run(state.name, input, backend: opts_backend()), state}
  end
end
```

(Ojo: ese `opts_backend()` **no existe**. Es a propósito — el módulo no compila
todavía, y el siguiente paso es escribirlo bien. Un ejemplo de aquí se copia
**entendiendo**; el fichero bueno es el de la F5.3.)

**Paso 5 · Compilar, con los warnings como errores.**

```bash
mix compile --force --warnings-as-errors
```
Se espera ver `0 warnings`. Si ves uno, no lo silencies: en este repo los
warnings son errores por puerta, y el último rojo real de la fase 7 fue un
warning.

**Paso 6 · Ver el test en verde, y luego verlo fallar.**

```bash
mix test test/candil/agent/simple_reflex_test.exs
```
Verde. **Y ahora, lo importante**: rompe el código a propósito —saca el `steps: 0`
del estado, o cambia `FINAL_ANSWER` por otra cosa— y vuelve a correr. **Si sigue
en verde, el test no es un test, es decoración** (`docs/03-convenciones/README.md`
§3). Vuelve a arreglarlo.

**Paso 7 · Las siete puertas, en su orden.**

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix escript.build
```

El orden importa: el `test` va **en medio** a propósito. Si el dialyzer falla antes
de correr los tests, se ha perdido la información de qué rompe de verdad.

**Y la octava, que no es una puerta:**

> Ninguna fase se cierra con el resultado de un comando. Se cierra con lo que pasó
> en la máquina del dueño.

---

## 6 · Las puertas

Las siete de `docs/03-convenciones/README.md` §5, y para esta fase dos más:

| Puerta | Qué falla si no pasa |
|---|---|
| `mix format --check-formatted` | El CI falla. Es la más barata. |
| `mix compile --force --warnings-as-errors` | Un warning sobre un `@deprecated` en 4.1.0 (§7) rompe la fase entera |
| `mix credo --strict` | Complejidad. `loop/7` ya pasó por aquí una vez (`CHANGELOG.md:321`) |
| **`mix test`** | Debe subir el número **y** los nuevos tests deben ser rojos antes del código |
| `mix dialyzer` | El `@type result/0` mentiroso (§2.3-a) es justo lo que dialyzer no ve porque el tipo se escribe a mano. **Esta fase añade el test de contrato que sí lo ve.** |
| `mix escript.build` | **Cuidado: sobrescribe el binario `candil` que está versionado.** Si pasa, `git checkout -- candil` |
| Verificación por semilla | `for s in 1 42 99991; do mix test --seed $s; done` |
| **Puerta propia de esta fase** | **El agente se cuelga si el backend se cuelga.** Ninguna de las siete lo detecta porque todas terminan cuando el proceso termina. Hace falta un test con **timeout** queCompruebe que el proceso responde — §8.3 |
| **Puerta de máquina** | Un agente **real**, con un modelo de verdad, contestando. Un `StubBackend` verde es una hipótesis (`docs/README.md` §3) |

---

## 7 · Cómo se sabe que funciona

Cada test dice las dos cosas: cómo se ve pasar, y **cómo se ve fallar**.

| Qué | Pasa cuando… | **Y falla cuando…** |
|---|---|---|
| `run/3` sin `:backend` | devuelve `{:error, :no_backend}` | **hoy revienta con `UndefinedFunctionError`** (§2.3-b). Romperlo es quitar la rama `:no_backend` |
| `result/0` | el fichero contiene `{:error, term(), trace()}` | si alguien lo deja en `{:error, term()}`, el test lo dice con la cadena entera (§4, test 1) |
| Alias inexistente | `{:error, :model_not_up, "inventado"}` | **hoy devuelve `"default"` o deja pasar el alias**. Es el bug de la familia «pin que no existía» |
| `max_steps` | `{:error, :max_steps_exhausted, trace}` con `≤ max_steps` acciones | con `max_steps: 5` y una respuesta final en el paso 6: 0 fallos, y eso está bien |
| Un agente no cuelga | el proceso responde en < N ms con un backend parado | con el backend bloqueado: **`mix test` se queda colgado hasta el timeout global**. Por eso esta fila necesita su propio `@tag timeout:` |
| Reinicio a estado estable | tras tumbar el agente, vuelve con el estado del último `snapshot` | si vuelve **vacío**, el test pasa si no mira el estado. Hay que mirar el estado |

**Y el orden de las siete puertas, y las tres semillas**, están en §5.3 paso 7.

> Un aviso que hay que repetir aquí porque es el que más caro sale: **el
> `StubBackend` de `test/candil/agent_test.exs:6` es la única cosa que ha ejecutado
> este módulo alguna vez, y no es un modelo.** Las siete puertas pueden estar en
> verde y el agente no haber hablado nunca con un modelo de verdad. Eso no lo
> arregla ningún test unitario.

---

## 8 · Cuando sale mal

### 8.1 · Bucle infinito de razonamiento

**Qué pasa hoy.** `max_steps` (por defecto 8, `agent.ex:43`). Cuando llega a 0:

```elixir
# lib/candil/agent.ex:110-111
defp loop(_conv, _cfg, _backend, _model, 0, _ref, trace),
  do: trace ++ [%{kind: :final, content: :max_steps_exhausted}]
```

y `finalize/1` lo convierte en `{:error, :max_steps_exhausted, trace}`.

**Con qué error**: `:max_steps_exhausted`. Sin crash, sin excepción.

**Qué hace el sistema**: nada. `run/3` **devuelve** el error al que llamó, y el
proceso que llamó sigue ahí, exactamente igual.

**Las cuatro cosas que hoy no cubre** — y que hay que decidir antes de dar el tipo
por hecho:

1. **`max_steps` cuenta pasos, no coste.** Un paso puede costar 30 s y 4 000 tokens.
   El bucle se para igual. Falta un presupuesto en tokens o en segundos.
2. **No detecta repetición.** Un modelo que llama a la misma herramienta con los
   mismos argumentos ocho veces agota `max_steps` y sale con
   `:max_steps_exhausted`… que **es el mismo error que un bucle sano que se pasó
   de largo**. Quien llama no puede distinguir «se quedó pensando» de «acabó mal».
3. **`trace ++ [...]` es O(n²).** Con 8 pasos no se nota; con 200, sí, y en el
   camino caliente.
4. **`max_steps: 0` no llama al modelo nunca** y devuelve `:max_steps_exhausted`
   con la traza vacía. Es defendible, pero es una sorpresa: 0 no es «cero pasos»,
   es «cero resultado y mismo error que un bucle».

**En el diseño nuevo**: `max_steps` vive en el estado, no en un argumento. El
proceso **no muere**: responde `{:error, :max_steps_exhausted, trace}` y sigue
esperando el siguiente estímulo. Eso ya es mejor que `Arrea.Worker`, que en error
hace `{:stop, {:error, reason}, final_state}` (`worker.ex:337`) y se acaba.

### 8.2 · El agente pide un modelo que no está arriba

**Qué pasa hoy**: **nada, y esa es la parte grave.** `resolve_model/2`
(`agent.ex:97`) no consulta nada. Un alias inventado viaja tal cual hasta el backend.

**Con qué error**: ninguno. Sale un `4xx` del servidor, o un `FunctionClauseError`
dentro del launcher, o —lo peor— un OOM en la GPU, según por dónde se escape.

**Qué hace el sistema**: nada que ayude. No hay admisión, no hay VRAM, no hay un
punto donde decir «ese modelo no está arriba».

**Por qué 8b lo arregla y por qué antes no**: la línea de cajas es la que sabe qué
modelos están **above** y cuántos GB tienen **libres**. Un agente que pide un modelo
que no está arriba necesita exactamente dos respuestas, y las dos son de la línea
de cajas:

| Lo que pide | Lo que debería contestar | Antes de 8b |
|---|---|---|
| un modelo que no existe en el catálogo | `{:error, :model_not_found, alias}` | `String.to_existing_atom` o nada |
| un modelo que existe pero no está cargado | `{:error, :model_not_up, alias}` | un 500 del servidor |
| un modelo que no **cabe** en la VRAM libre | `{:error, :no_room, needed, free}` | un OOM del SO, y el proceso de todos los demás |

> Las tres filas de la derecha son **fallos ruidosos que hoy son silenciosos**. Y
> la tercera es la que mata: un OOM en la GPU no se le atribuye a Candil, se le
> atribuye al usuario.

### 8.3 · El agente se cuelga

**Qué pasa hoy**: `run/3` es una llamada bloqueante en el proceso del que llamó. Si
`backend.chat/3` se cuelga, **se cuelga el llamante**. No hay `Task`, no hay
timeout, no hay nada.

Peor: **la cancelación no ayuda**. `Cancellation.cancelled?/1` se comprueba
**entre** pasos (`agent.ex:114`), no dentro. Un paso que se ha colgado no se
cancela:

```elixir
# lib/candil/agent.ex:113-121
defp loop(conv, cfg, backend, model, steps_left, cancel_ref, trace) do
  if cancel_ref && Cancellation.cancelled?(cancel_ref) do
    ...
  else
    case backend.chat(model, messages, tools: prompt_schemas) do   # ← aquí se cuelga
```

**Con qué error**: **ninguno**. Esto es lo grave: un cuelgue no es un error, es una
ausencia de error. Un proceso en la BEAM que no contesta no falla — **se queda**.

**Qué hace el sistema**: nada. Un GenServer que ignora su mailbox no encola nada,
no responde, y su supervisor ve un proceso vivo.

**En el diseño nuevo**, tres defences, y las tres tienen que existir:

| Defensa | Dónde | Por qué |
|---|---|---|
| `GenServer.call` con `timeout` en cada paso | `handle_call({:evaluate, …})` | el llamante recibe `{:error, :timeout}` y el agente sigue vivo |
| `:brutal_kill` no: `shutdown: 5_000` | el child spec del agente | al reiniciar, se le da tiempo a terminar limpio |
| `Arrea.CircuitBreaker` **por agente** | §2.5 — hoy solo hay por **modelo** | un agente que se cuelga 5 veces seguidas abre su **propio** breaker, no el del modelo, que puede estar sano para los demás |

Y un test con `@tag timeout:` propio, porque las siete puertas **no lo detectan**:
todas terminan cuando el proceso termina, y un proceso colgado hace que termine el
`mix test` por timeout global, que se lee como «el runner se murió», no como «el
agente se colgó».

---

## Anexo I · Desglose en fases (Módulo 5)

Cada fase lleva su **prerrequisito explícito**. Esto alimenta
[`02-orden/`](../../02-orden/README.md), que es donde vive el orden de verdad.

```
F5.0 ──▶ F5.1 ──▶ F5.2 ──▶ F5.3 ──▶ F5.4 ──┬──▶ F5.5
                                 │        │
                                 └──▶ F5.8 ──▶ F5.9
                                          ▲
   8b (línea de cajas) ──▶ F5.6 ──▶ F5.7 ─┘
```

| # | Fase | Prerrequisito | Por qué en este sitio |
|---|---|---|---|
| **F5.0** | Arreglar el contrato de `Candil.Agent` | — | **No espera a nadie.** Los 4 tests del §4, el `@type result/0`, `resolve_backend/1` y `resolve_model/2` contra el catálogo. Sin tocar Arrea. Es lo más barato y desbloquea todo lo demás |
| **F5.1** | `Arrea.Agent` en Arrea | F5.0 | El behaviour (§5.2) y su supervisor. **Es un PR en `Lorenzo-SF/arrea`**, no un commit de este repo |
| **F5.2** | `Candil.Agent` implementa el behaviour | F5.1 **mergeada** | `loop/7` → `step/3`. **Migrar `Conversation` → `Context`**, que es lo que desbloquea el `@deprecated` de 4.1.0 (abajo) |
| **F5.3** | Tipo 1: Reflejo Simple | F5.2 | El primer `GenServer` de verdad, con `evaluate/2`, un hijo en `Candil.Supervisor` y **el test del cuelgue** (§8.3). **No depende de 8b**: con el modelo pineado no hay nada que pesar |
| **F5.4** | Tipo 2: Reflejo Basado en Modelos | F5.3 | `snapshot/1` y `restore/1`, y el **reinicio de verdad**, que Arrea no da porque sus workers son `:temporary` |
| **F5.5** | RPC entre agentes | F5.3 | `Arrea.Agent.call/3`: pregunta **y** respuesta, contra un `send_message/2` que es un `cast` (`worker.ex:112`) |
| **F5.6** | `Arrea.Resource` | **8b** | **BLOQUEADA por 8b.** Contabilidad **ponderada en GB**. `Arrea.Bulkhead` intacto: contar slots y pesar gigas no son la misma cuenta |
| **F5.7** | El router por paso | F5.6 **y** F5.2 | **BLOQUEADA.** La pieza del §2.7: `StepRouter` decide en cada paso del ReAct. Sin F5.6 puede pedir un modelo que no está arriba |
| **F5.8** | Tipo 3: Basados en Objetivos | F5.7 | Descomposición, y `Arrea.Leader` como reparto de sub-agentes. El sub-agente puede pedir otro modelo, así que hereda el bloqueo |
| **F5.9** | Tipo 4: Basados en Utilidad | F5.7 | Candidatos por paso y `Scorer` aplicado a **caminos**, no a modelos. También bloqueada |
| **F5.10** | Tipo 5: De Aprendizaje | — | **BLOQUEADA por diseño, no por 8b** (§5.1). No es una fase todavía: falta la decisión de producto |

### ⚠️ Un solapamiento con el módulo 01, que hay que resolver en `02-orden/`

El [módulo 01](../01-routing-y-ciclo-vida/README.md) ya tiene dos fases que tocan
esto, y **no son las mismas** que F5.6:

| Módulo | Fase | Qué |
|---|---|---|
| 01 | **F2** | «Un número de VRAM (`Detector.VRAM`)» — **medir** cuántos GB hay |
| 01 | **F7** | «Admisión knapsack (`Lifecycle.LoadSet`)» — **admitir** o rechazar, **en Candil** |
| 05 | **F5.6** | `Arrea.Resource` — admitir o rechazar, **en Arrea** |

Medir y admitir no se solapan: F2 es el dato, F5.6 es la cuenta. **Lo que sí se
solapa es F7 y F5.6**, que serían la misma decisión en dos sitios y en dos
repositorios.

Esto **no se resuelve aquí**, porque la decisión es de `02-orden/` y la regla dura de
este módulo dice que `Arrea.Resource` es un módulo **nuevo** en Arrea y que
`Bulkhead` no se toca. Lo que se deja escrito es el criterio, para que quien ordene
no tenga que adivinarlo:

> **Un agente y un motor piden cosas distintas a la misma scarce resource.** Un motor
> pide *cargar* un modelo y se le responde sí o no. Un agente pide *usar* un modelo
> durante un paso y la respuesta tiene que ser un número, porque si no cabe ahora
> quizá cabe en tres pasos. Si van en el mismo módulo, ese módulo tiene que saber
> distinguir «cargar» de «usar», y hoy nada lo distingue.

La forma barata de no duplicar: **`Detector.VRAM` (Candil, F2 del módulo 01) es la
única que lee la GPU; `Arrea.Resource` (F5.6) es la única que lleva la cuenta.** Si
`02-orden/` decide lo contrario, este módulo cambia y hay que decirlo aquí.

### Las tres reglas de este orden

**1 · F5.0 va primero y no depende de nadie.** Es la única que se puede empezar hoy,
en este repo, sin PR y sin 8b. Arregla tres mentiras concretas (§2.3) y es la que
desbloquea todas las demás.

**2 · F5.1 es una fase con dos repositorios, y hay que decirlo al empezar.**
`Arrea.Agent` vive en `Lorenzo-SF/arrea` sobre `main`, y Candil la consume con
`override: true` **desde esa rama**, no desde una etiqueta. Mientras la PR no esté
mergeada, `mix deps.get` en Candil puede traerse algo sin el behaviour. **F5.2 no
puede empezar hasta que la PR esté mergeada y publicada**, y ese tiempo no lo
controlamos.

**3 · F5.6 y F5.7 son las **únicas** bloqueadas por 8b, y es a propósito.**

> Un agente con el modelo pineado **funciona sin 8b**: `resolve_model/2` lo resuelve
> y ya. Uno que pregunta al router en cada paso **puede pedir algo que no está
> arriba**, y sin contabilidad de VRAM **nadie le dice que no** — el que lo dice es
> el OOM del sistema operativo, que no es un error de Candil y no se le atribuye a
> nadie.

Por eso F5.3, F5.4 y F5.5 van **antes** de 8b, y por eso el tipo 1 es el primero:
es el único que no puede pedir un modelo que no existe.

### El bloqueo de 4.1.0, que hay que conocer antes de F5.2

`lib/candil/conversation.ex:21-28` dice, textual:

> *«`@deprecated` … `Candil.Agent` sigue llamando a cuatro de estas funciones, así
> que marcarlas volvería `mix compile --warnings-as-errors` rojo sobre el código
> del propio repo. Se probó `@compile {:no_warn_deprecated, Candil.Conversation}` y
> **no funciona cuando los dos módulos están en el mismo lote de compilación
> paralela** — medido, no supuesto. El atributo va cuando `Agent` migra a
> `Candil.Context`, en 4.1.0.»*

Medido sobre el fichero: `agent.ex` llama a **tres** funciones distintas —
`Conversation.new/1` (`agent.ex:78`), `Conversation.add_message/3` (`:81`, `:172`)
y `Conversation.messages/1` (`:118`). El comentario dice cuatro; la diferencia no
importa y **no se ha investigado**, así que queda dicho y no se corrige aquí.

> Esto convierte la migración a `Candil.Context` en parte de F5.2 y no en una
> mejora: **es lo que desbloquea el `@deprecated` de 4.1.0**, y ese atributo, a su
> vez, es lo que permitirá que `mix compile --warnings-as-errors` vuelva a ser una
> puerta de verdad sobre `Conversation`.

---

## Anexo II · Lo que esta fase NO va a conseguir

Que quede escrito antes, y no como sorpresa en la revisión.

| Lo que no se consigue | Por qué |
|---|---|
| **El tipo 5, de aprendizaje** | §5.1. No hay almacén de feedback, no hay esquema de prompt, y `instances.json` no es su sitio. Falta una **decisión de producto** antes que una línea de código |
| **Los tipos 3 y 4** | Dependen de 8b y de la F5.7. El 80 % de sus piezas existen pero en el sitio equivocado: `Leader` reparte tareas donde habría que repartir agentes, y `Scorer` puntúa modelos donde habría que puntuar caminos |
| **Un agente que se reinicie «a su último estado estable»** | Hay que **construirlo**: `snapshot/1` y `restore/1` no existen, y Arrea no reinicia workers (`worker.ex:35`, `pool/worker.ex:34`, ambos `:temporary`) |
| **`Arrea.Resource` funcionando** | En esta fase solo se **escribe el contrato** (§5.2). La contabilidad en GB es la línea de cajas |
| **Un agente validado contra un modelo de verdad** | Las siete puertas pasan con un `StubBackend`. Eso es una hipótesis, y la hipótesis más cara de este repo |
| **`Arrea.Agent` merged en Arrea** | Es una PR en `Lorenzo-SF/arrea` (`main`). Mientras no esté, `Candil.Agent` compila contra una dependencia que no tiene el behaviour, y **el work de Arrea vive en un repo que no es este** |

---

## Las tres preguntas de esta fase

*(`docs/03-convenciones/README.md` §7. Si alguna tiene respuesta vaga, la fase no
está lista.)*

**1 · ¿Cómo sé que está roto?**
Los cuatro tests del §4 —**que están escritos en este documento y no existen
como ficheros**—. Y antes de ellos, uno que ya existe y sí encontró cosas:
[`real_test.exs`](../../../test/candil/agent/real_test.exs), que ejecuta
`use Candil.Agent` contra un backend de verdad.

> La respuesta honesta a «¿cómo sé que está roto?» hoy es: **escribiendo el
> test**, porque los que había no lopillaban. Y el primero que se escribió de
> verdad encontró tres bugs en el mismo día.

**2 · ¿Cómo sé que está bien?**
Un `SimpleReflex` que responde a un estímulo desde un proceso vivo, con el
supervisor reiniciándolo y devolviéndolo con su estado, y **un test con timeout
que comprueba que no se cuelga**. Y en la máquina del dueño: un agente con un
modelo de verdad contestando. Sin esa última, esto es una hipótesis.

**3 · ¿Qué he descartado, y por qué?**
Meter el agente en `Arrea.Worker` (la cola no crece, `worker.ex:144`), usar `Task`
(no tiene nombre ni supervisor), usar `Arrea.Pool` (es un lease, no un proceso con
el que se conversa), y extender `Arrea.Bulkhead` a la VRAM (cuenta slots; pesar
gigas es otra cuenta — §2.6).