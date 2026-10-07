# 01 · Módulo 1 — Smart Routing y ciclo de vida de los LLMs locales

> **Qué es este documento.** El plano del módulo 1 de los cinco: la parte que
> decide **qué modelo contesta** y la parte que decide **qué modelos están
> cargados**. Es el módulo del que [`docs/02-orden/`](../../02-orden/) bebe: el
> Anexo I son fases con prerrequisito, escritas para que se copien tal cual.
>
> **Estado**: escrito leyendo el código de la rama `docs-v2` a fecha de este
> documento. `mix` no está instalado en la máquina donde se escribió, así que
> **ninguna puerta de la §6 se ha ejecutado aquí**. Todo lo que dice
> «medido» viene de leer ficheros o de contar; todo lo que no, lo dice.
>
> **Cómo se lee**. Si vienes de `00-arrea/`, ya sabes que Candil va montado
> encima de Arrea. Aquí no se reimplementa nada de eso.

---

## Antes de empezar · lo que ya existe (contado, no recordado)

Todo lo de esta tabla está leído del código. Las rutas son reales.

| Fichero | Qué es | Líneas |
|---|---|---|
| `lib/candil/router.ex` | la puerta: `route/2`, `pin/2`, `resolve/1`, `settings/0`, y el struct `Candil.Router.Decision` | 249 |
| `lib/candil/router/decision_engine.ex` | la cadena de capas y su orden | 319 |
| `lib/candil/router/scorer.ex` | puntúa candidatos por capa. Reglas implementadas; `embedding` y `llm` son `:miss` | 121 |
| `lib/candil/router/cache.ex` | hash del último turno de usuario → decisión, con TTL, en ETS | 127 |
| `lib/candil/router/consumer.ex` | candidatos por consumidor y el pin, en ETS | 182 |
| `lib/candil/engine.ex` | `start/2`, `stop/1`, `healthy?/2`, `base_url/1`, `for_model/3` | 535 |
| `lib/candil/engine/server.ex` | el GenServer de **un** `llama-server`, sobre `Arrea.LongRunning` | 248 |
| `lib/candil/engine_pool.ex` | registro de lo que está vivo en **esta** VM. Clave `{alias, port}` | 246 |
| `lib/candil/instances.ex` | `instances.json`: lo que está vivo en **la máquina** | 386 |
| `lib/candil/instances/reaper.ex` | poda del fichero. **No mata nada** | 83 |
| `lib/candil/instances/probe.ex` | ¿hay alguien escuchando en este puerto? (TCP, no HTTP) | 82 |
| `lib/candil/detector/gpu.ex` | **solo** detecta backend (`:cuda`, `:rocm`, `:metal`, `:cpu`). No lee VRAM | 72 |
| `test/candil/router_test.exs` | 40 tests, 13 bloques `describe` | 493 |
| `lib/candil/router/decision_engine.ex:36-40` | el orden de capas, escrito en un `with` | — |

**Y cinco cosas que NO existen y este módulo necesita.** No están en ningún
sitio, y cada una es un prerrequisito:

| Lo que falta | Por qué importa |
|---|---|
| Ningún temporizador de ociosidad | nada apaga un modelo que nadie usa |
| Ningún contador de decisiones | no se puede saber si una capa vale algo |
| Ningún número de VRAM | `Detector.GPU` dice qué GPU hay, no cuánto queda |
| Ningún camino que niegue por modelo no cargado | el refusal está **decidido** pero no escrito |
| Ninguna puerta de entrada nueva con `to_existing_atom/1` | hay un `String.to_atom/1` vivo con un alias de la línea de órdenes (`lib/candil/cli/lifecycle.ex:550`, ver §8), y este módulo va a añadir otra |

---

## 1 · Qué es

**El problema, en una frase**: *un modelo cargado se come GB de VRAM para
siempre, y el router elige modelos sin saber ni si están en memoria ni cuánto
cuesta cada uno.*

Y por qué ahora: porque la mitad que decide ya está hecha y en verde. El motor
de decisiones tiene sus 40 tests, el refusal está decidido y el arranque del
motor funciona. Lo que falta es todo lo demás, y **cada cosa que falta depende
de una medida que todavía no se ha tomado**. Por eso este módulo empieza
midiendo, no programando.

Un aviso de vocabulario, porque el nombre engaña: aquí **«cold start» no
significa arrancar solo**. Significa dos cosas, y solo dos:

1. Un modelo que nadie usa **no se queda** ocupando VRAM.
2. Un modelo que no está cargado, cuando alguien lo necesita, **no se arranca
   solo**: se dice el comando exacto.

El punto 2 es una decisión ya tomada. No se vuelve a discutir aquí. La §2.1
explica por qué encaja con el punto 1 en vez de contradecirlo.

---

## 2 · Por qué así

### 2.1 · El refusal, no el arranque automático

**Decidido.** Si el router elige un modelo que no está cargado, no lo arranca:
contesta con el comando para arrancarlo.

Encaja con el cold start porque son la misma política vista desde dos lados.
«No arranco lo que no se me pide» y «no dejo nada encendido que no se use» son
la misma frase: **Candil no manage la VRAM del usuario por su cuenta**. Si
arrancara solo, el usuario tendría un modelo de 20 GB en la GPU que no ha
pedido, sin ninguna línea en la que se lo hayan pedido. Y si lo apagara solo
mientras alguien lo usa, sería peor: el refusal es visible, un apagado
encerrado en un temporizador es invisible.

Consecuencia práctica: el «cold start» de este módulo es **disponibilidad de
la orden**, no descarga automática. `candil route ask "…"` dice el modelo que
gana y, si no está cargado, la línea de al lado dice el comando. Punto.

### 2.2 · El temporizador de ociosidad: primero el que ya existe, luego el nuestro

Hay **dos** sitios posibles para apagar un modelo ocioso, y no son lo mismo:

| | Flag de `llama-server` | GenServer propio en Candil |
|---|---|---|
| Qué hace | el servidor duerme solo tras N segundos sin peticiones | Candil para el proceso con `Engine.stop/1` |
| Qué libera | el modelo y su KV cache (**el doc dice RAM**) | el proceso entero: modelo, KV cache, **puerto** y registro |
| Latencia de vuelta | recarga automática en la siguiente petición | la del arranque en frío, de segundos |
| Overhead en Candil | uno en `start_args` | un proceso, un ETS y una ruta de fallo nueva |

El flag se llama `--sleep-idle-seconds` y existe; viene de la documentación de
llama.cpp (**no del repo de Candil**, y **sin medir** contra el binario del
dueño). La misma fuente dice que `/health` y `/props` **no** cuentan como
petición y **no** reinician el temporizador.

> **Sin medir**: si al dormir baja la **VRAM** o solo la RAM. El texto habla
> de RAM y del KV cache. Si el contexto CUDA se queda, el modelo sigue
> ocupando tarjeta y el flag no sirve de nada para lo que aquí importa.

Por eso el orden es: **F2 mide, y el resultado decide dónde va el temporizador**.
Escribir el GenServer primero es escribir la respuesta antes de conocer la
pregunta. La §2.6 dice qué pasa si los dos hacen falta.

### 2.3 · Candil no reimplementa supervisión

Decidido, y está en `00-arrea/`. Arrea ya da:

- **`Arrea.LongRunning`** — el proceso del SO, con puerto enlazado, salud y
  telemetría. `lib/candil/engine/server.ex:68` ya lo usa.
- **`Arrea.CircuitBreaker`** — por recurso con nombre. `lib/candil/http/retry.ex:15`.
- **`Arrea.Pool`** — conjunto de pie con `checkout/2` y `checkin/2`.

Lo que **no** se reimplementa: un supervisor para engines, un pool propio, un
`Bulkhead`, un limitador. Si algo de eso hace falta, se usa el de Arrea o se
escribe y se justifica.

**Aviso, y es un hallazgo, no una opinion**: hoy el GenServer del engine local
**no está supervisado**. `Candil.EngineSupervisor` se usa en
`lib/candil/engine.ex:439`, y ese es su **único** uso en todo el repo. El
camino local (`start_via_server/2`, `lib/candil/engine.ex:428`) llama a
`Server.start_link/1`, que enlaza al **llamante**, no al DynamicSupervisor. Y
el `@moduledoc` de `lib/candil/engine/server.ex:21` dice lo contrario («*This*
GenServer runs under `Candil.EngineSupervisor`»), igual que el comentario de
`lib/candil/cli/lifecycle.ex:99`.

Esto no es una opinión sobre el diseño: es el prerrequisito de la mitad A. Un
controlador que vaya a parar un engine ocioso necesita saber **quién lo
sostiene**, y hoy la respuesta es «quien llamó a `Engine.start/2`». Ver F4.

### 2.4 · El recurso se gasta en GB: es un knapsack, no una concurrencia

Decidido. Y de aquí sale un rechazo con nombre:

| Pieza de Arrea | Por qué NO es la herramienta |
|---|---|
| `Arrea.Bulkhead` | cuenta **slots**. Cuatro modelos de 20 GB no caben en 16 GB, y un Bulkhead de 4 no cambia eso |
| `Arrea.Pool` | `:size` y `:max_overflow` son **números de workers**, no de gigabytes. Encaja para «un conjunto de pie», no para «cuánta memoria cabe» |

El Pool sí puede ser la **cola** que reparte peticiones entre los engines ya
admitidos (F11). El **admisor** de GB es otra cosa, y es de Candil.

### 2.5 · Tres estados, no dos

«Está ocioso» y «está muerto» son cosas distintas, y lo que hay que hacer con
cada una también:

| Estado | Qué es | Quién lo resuelve |
|---|---|---|
| `:idle` | cargado, vivo, nadie pregunta desde hace N | lo apagamos nosotros |
| `:dead` | registrado, y el proceso ya no está | nadie lo apaga: ya no está. Hay que **dejar de fingir** |
| `:detached` | el dueño es otro proceso de otra VM | nunca es nuestro |

El `:dead` es el caso que se cuela hoy, y se cuela porque
`Candil.Instances.Reaper` poda por **dueño**, no por engine: el dueño es el pid
del SO de la VM (`lib/candil/instances.ex:323`), y esa VM sigue viva aunque el
`llama-server` haya muerto. O sea que un engine caído **no lo poda nadie**, y
su entrada se queda en `instances.json` y en `Candil.EnginePool`, y
`EnginePool.claim_port/2` sigue contando con su puerto. `candil status` sí
lo enseña como `DOWN` (porque `Engine.healthy?/2` pregunta de verdad), y eso es
lo único que hoy lo delata.

Y en `lib/candil/` **no hay ni un `Process.monitor/1` sobre un engine**
(`grep 'Process\.monitor'` solo devuelve `lib/candil/cli/holder.ex:207` y
`lib/candil/build.ex:616`, que son de otra cosa). El apagado por ociosidad es,
de hecho, el **primer** sitio donde Candil va a enterarse de que un engine se
murió. Ver F6.

### 2.6 · El motor de decisiones sigue siendo síncrono y estático primero

Decidido. Un clasificador con modelo entra **después** de medir la cobertura
real de las capas baratas, no antes. La razón está escrita en
`lib/candil/router.ex:17-20` y es la correcta: un router que gasta una
inferencia completa para ahorrar un décimo de otra inferencia normalmente sale
perdiendo.

Y hay una razón más, que sale de leer el código: **la capa de reglas no está
conectada a la configuración**. `@rules` (`lib/candil/router/scorer.ex:18`) y
`@default_rules` (`lib/candil/router/scorer.ex:29`) están **fijas en el
código**, y `grep` no encuentra **ninguna lectura** de `[router.rules]` en
`lib/`. El comentario de `scorer.ex:24` dice que son «the fallbacks when
`[router.rules]` is absent», y `test/candil/router_test.exs:217` explica que
para tener vocabulario en español se sobrescribe `[router.rules]`. Eso no
funciona: no hay código que lo lea. Consecuencias medibles:

- El vocabulario es **inglés**, y `test/candil/router_test.exs:226` lo
  demuestra: `"código"` no casa.
- Las categorías apuntan a **tres alias fijos** (`:coder`, `:verifier`,
  `:gpt4o`). En una máquina cuyo catálogo no tenga `:gpt4o`, la categoría
  `fast` **no puede ganar nunca**.

Es decir: antes de preguntarse si hace falta un clasificador, hay que
**arreglar y medir** el que ya existe. F0 y F8.

### 2.7 · `String.to_existing_atom/1`, siempre

Un nombre que no existe tiene que ser un fallo ruidoso, no un `nil`: si el
código dice `:verifier` donde la config dice `coder`, el router no encuentra
nada y no dice por qué. Ya se hace en `lib/candil/router/consumer.ex:122`,
`lib/candil/cli/router.ex:138` y `lib/candil/config/schema.ex:291`.

**Deuda viva**: `lib/candil/cli/lifecycle.ex:550` usa `String.to_atom/1` con un
alias de la línea de comandos, con un `# credo:disable-for-next-line
Credo.Check.Warning.UnsafeToAtom` encima. No es de este módulo, pero **este
módulo va a añadir otra puerta de entrada por línea de comandos** (el refusal
tiene que decir un comando, F1) y tiene que hacerlo con `to_existing_atom/1`.
Ver §8.

### 2.8 · Las decisiones abiertas que tocan este módulo

[`01-inventario`](../../01-inventario/README.md) §7 lista cinco decisiones sin
cerrar. **Dos son de este módulo**, y ninguna se puede esquivar por arriba:

| # | La decisión | Qué bloquea aquí |
|---|---|---|
| 3 | **¿Quién escribe la verdad de la VRAM, Candil o Arrea?** | **F2 y F7 enteras.** Hoy `lib/candil/detector/gpu.ex` detecta *qué* backend hay y no lee una sola cifra de memoria, y Arrea no tiene una pieza de VRAM (`00-arrea` §5). Este documento propone que la lea Candil en `Candil.Detector.VRAM`, **pero eso es una propuesta, no una decisión tomada**: si la respuesta es Arrea, F2 se escribe en Arrea y este documento cambia |
| 1 | ¿Round-robin justo o FIFO con VIP? | **F11**, y el reparto entre clientes de `Candil.Lifecycle.Idle` si llega a haber más de uno |

Las otras tres (memoria compartida, `Candil.Provider`, camino de librería) no
tocan este módulo.

Y dos cosas de `01-inventario` que este documento asume como verdad:

- **§6**: «un módulo entero que decide, y nadie lo consulta». `Router.route/2`
  tiene **cero** llamadas fuera de `lib/candil/cli/router.ex` y sus tests. Por
  eso F0 (contadores) es la primera fase: sin un consumidor real no hay ni un
  dato de los que la §V necesita.
- **§2**: el «clasificador del router» es uno de los cinco behaviours que el
  diseño necesita y **no existen**. Por eso F8 se escribe como **behaviour**
  con un callback, no como módulo suelto: la forma extensible desde el día uno
  es la que cuesta más si se deja para después. Y el criterio es el del bloque
  04 ([`04-modulos/README.md`](../README.md)): *un tercero define
  esto y funciona sin tocar Candil*.

---

## 3 · Qué toca

Lista cerrada. **Ni un fichero más.**

### 3.1 · Se leen y no se tocan

```
lib/candil/router.ex
lib/candil/router/decision_engine.ex
lib/candil/router/scorer.ex
lib/candil/router/cache.ex
lib/candil/router/consumer.ex
lib/candil/engine.ex
lib/candil/engine/server.ex
lib/candil/engine/health_poller.ex
lib/candil/engine_pool.ex
lib/candil/instances.ex
lib/candil/instances/reaper.ex
lib/candil/instances/probe.ex
lib/candil/detector/gpu.ex
lib/candil/config/schema.ex
lib/candil/config/file.ex
lib/candil/application.ex
```

Los tres últimos se leen pero **se tocan**; están en 3.3.

### 3.2 · Se crean (nuevos)

```
lib/candil/lifecycle/idle.ex              Candil.Lifecycle.Idle      — GenServer + temporizador
lib/candil/lifecycle/load_set.ex          Candil.Lifecycle.LoadSet  — el knapsack de GB
lib/candil/detector/vram.ex               Candil.Detector.VRAM      — cuánto hay y cuánto queda
lib/candil/router/dispatch.ex             Candil.Router.Dispatch    — el refusal
lib/candil/router/metrics.ex              Candil.Router.Metrics     — contadores por capa
lib/candil/router/complexity.ex           Candil.Router.Complexity  — el behaviour clasificador
scripts/vram-check.sh                      el script de medición de la §5.4
```

`Candil.Router.Complexity` se escribe como **behaviour** con **un** callback
(`classify/1`), al lado de su implementación heurística, por lo mismo que
`Candil.Backend` y `Candil.Engine.Launcher`: son behaviours de un solo callback
porque un behaviour de uno se puede ampliar sin romper a quien lo implementa.
El criterio de que vale la pena está en
[`04-modulos/README.md`](../README.md): *un tercero define esto y
funciona sin tocar Candil*. Con un behaviour, la segunda implementación (el
clasificador con modelo, F10) no toca el router; con un módulo suelto, sí.

Y sus tests, escritos **antes** (§4):

```
test/candil/lifecycle/idle_test.exs
test/candil/lifecycle/load_set_test.exs
test/candil/detector/vram_test.exs
test/candil/router/dispatch_test.exs
test/candil/router/metrics_test.exs
test/candil/router/complexity_test.exs
```

### 3.3 · Se tocan

| Fichero | Qué se toca |
|---|---|
| `lib/candil/router.ex` | un `dispatch/2` nuevo, junto a `resolve/1`. Nada del orden de capas |
| `lib/candil/router/scorer.ex` | **leer** `[router.rules]` del TOML (§2.6). Es el arreglo previo a cualquier clasificador |
| `lib/candil/error.ex` | un `model_not_loaded/2` nuevo, y `:model_not_in_candidates` y `:no_classifier_model` **fuera** del `@type reason`, que hoy no los incluye |
| `lib/candil/application.ex` | los GenServers nuevos en `children`, **después** de `Candil.Store` |
| `lib/candil/engine.ex` | el camino local, para que el engine quede bajo `Candil.EngineSupervisor` (§2.3) |
| `lib/candil/config/schema.ex` | `"router"` y `"lifecycle"` en `@sections`, que hoy son `@sections ~w(general engine model provider consumer)` |

Sobre lo último: `[router]` **ya funciona** hoy y **aun así** no está
declarado. `Candil.Router.settings/0` la lee, y `Candil.Config.Schema` no la
rechaza porque `check_sections/1` recorre solo las secciones conocidas y una
sección desconocida no es un error. Funciona por accidente. Declararla es lo
que la convierte en una opción y la mete en
`docs/05-cli/config/candil.toml`, que se genera desde el schema.

### 3.4 · NO se toca, y por qué

| Fichero | Por qué |
|---|---|
| `lib/candil/router/decision_engine.ex` | el orden de capas es correcto y está escrito en un `with` legible (`decision_engine.ex:36-40`). El módulo B **agrega encima**, no reescribe debajo |
| `lib/candil/instances/reaper.ex` | el Reaper no mata nada y su regla es correcta (`reaper.ex:17-29`). El apagado por ociosidad va en otro proceso, con otro nombre |
| `lib/candil/engine/server.ex` | el `Arrea.LongRunning` ya está bien montado ahí. Un temporizador de Candil no se cuela dentro |
| `test/candil/router_test.exs` | **no se toca**. Los 40 tests son la base sobre la que se añade. Si alguno hay que cambiarlo, se añade otro al lado y se explica por qué |

---

## 4 · Los tests primero

Cada bloque va **literal**, en el fichero que dice su nombre, y se ve **rojo**
antes de que exista el código. Los que están marcados *ya existe* se copian
para fijar el contrato: son los que no pueden romperse.

### 4.1 · Ya existe · el contrato de prioridad (copia y no se toca)

Vive en `test/candil/router_test.exs:379-451` y `:456-493`. Se copia aquí
porque es **el** contrato del módulo y porque los 40 tests de ese fichero son
la única red que hay debajo de todo lo de este documento.

```elixir
# test/candil/router_test.exs, describe "forzar un modelo a mano"
test "gana al pin, que es del consumidor y dura mas" do
  Consumer.pin(:test_consumer, :coder)
  codigo = [%{role: "user", content: "hola"}]

  assert {:ok, decision} =
           Router.DecisionEngine.decide(codigo, [:coder, :verifier],
             consumer: :test_consumer,
             force_model: :verifier
           )

  assert decision.model_alias == :verifier
end

# describe "un solo candidato NO es un pin"
test "sin pin, un unico candidato se marca default y lo dice" do
  on_exit(fn -> Consumer.unpin(:otro_consumer) end)

  assert {:ok, decision} =
           Router.DecisionEngine.decide([%{role: "user", content: "hola"}], [:coder],
             consumer: :otro_consumer
           )

  assert decision.model_alias == :coder
  refute decision.strategy == :pinned
  assert decision.strategy == :default
  assert decision.reason =~ "no hay pin"
end
```

La prioridad completa, y es **esta**, sin excepción:

```
force_model  >  pin  >  [router.rules]  >  embeddings  >  clasificador LLM  >  default
```

El «un solo candidato no es un pin» está porque el fallo real salió en la
máquina del dueño y no en un test: `route ask` anunciaba `pinned` sin que
hubiera pin, y `route pin` decía «ninguno» justo después. Los dos tenían razón
sobre la misma cosa mal dicha.

### 4.2 · `test/candil/router/dispatch_test.exs` — el refusal

Rojo hoy: no existe `Candil.Router.Dispatch` ni `Error.model_not_loaded/2`.
Cinco tests.

```elixir
defmodule Candil.Router.DispatchTest do
  use ExUnit.Case, async: false

  alias Candil.{Engine, Error, Model, Provider, Router, Store}
  alias Candil.Router.Decision

  setup do
    :ok = Store.register_engine(%Engine{alias: :llama_cpp, binary: "llama-server"})

    :ok =
      Store.register_model(%Model{
        alias: :coder,
        type: :local,
        engine: :llama_cpp,
        usage: [:chat, :code],
        model_dir: "/models",
        filename: "coder.gguf"
      })

    :ok = Store.register_provider(%Provider{alias: :openai, type: :openai,
                                           base_url: "https://api.openai.com"})

    :ok =
      Store.register_model(%Model{
        alias: :gpt4o,
        type: :remote,
        name: "gpt-4o",
        provider: :openai
      })

    # El Store es ETS GLOBAL y compartido: lo que se registra, se borra.
    on_exit(fn ->
      Enum.each([:coder, :gpt4o], &Store.deregister_model/1)
      Store.deregister_provider(:openai)
      Store.deregister_engine(:llama_cpp)
    end)

    :ok
  end

  test "un modelo local que no esta cargado se NIEGA, y no se arranca" do
    # El caso de un lado: hay engine en el pool, no lo hay. Sin engine
    # arrancado, `Engine.healthy?/2` ya contesta false, asi que este test no
    # necesita montar nada para ser verdad.
    assert {:error, %Error{reason: :model_not_loaded}} =
             Router.Dispatch.attempt(decision(:coder))
  end

  test "el refusal DICE el comando, y lo dice entero" do
    assert {:error, error} = Router.Dispatch.attempt(decision(:coder))

    assert error.context.command == "candil run coder"
    # El alias va tambien. Un refusal que solo da el comando deja al usuario
    # sin saber si el modelo no existe, no esta descargado o no esta arrancado.
    assert error.context.alias == :coder
    # Y lo que SI hay cargado, para que vea el estado de su máquina y no
    # solo la orden.
    assert error.context.running == []
  end

  test "el refusal NO toca el pool" do
    # El camino entero del refusal, con la asercion al final. Un refusal que
    # de paso arranca el modelo es un arranque automatico con otro nombre.
    antes = Candil.EnginePool.count()

    assert {:error, %Error{reason: :model_not_loaded}} =
             Router.Dispatch.attempt(decision(:coder))

    assert Candil.EnginePool.count() == antes
    assert Candil.EnginePool.list() == []
  end

  test "un modelo remoto nunca se niega por estar sin cargar" do
    # No hay VRAM detras de un proveedor. Negarse por eso seria absurdo, y
    # es el segundo caso en el que un "esta ocioso" mal entendido tocaria un
    # modelo que no esta en la tarjeta.
    assert {:ok, %Model{alias: :gpt4o}, %Provider{}, :already_running} =
             Router.Dispatch.attempt(decision(:gpt4o))
  end

  test "el refusal NO cambia la forma de devolver una decision" do
    # `Router.route/2` sigue dando `{:ok, decision}` aunque el modelo no este
    # cargado. Decide y se niega son dos pasos, y el segundo no puede
    # arrastrar al primero: si lo arrastra, el `reason` que dice COMO se
    # decidio desaparece.
    assert {:ok, %Decision{strategy: :rule}} =
             Router.route([%{role: "user", content: "arregla el bug"}],
               candidates: [:coder],
               skip_cache: true
             )
  end

  # `alias` es una macro de Kernel. Como nombre de parametro se lee bien y
  # rompe cosas raras; `alias_name` no rompe nada.
  defp decision(alias_name) do
    %Decision{
      model_alias: alias_name,
      strategy: :rule,
      score: 0.375,
      reason: "keyword rule matched [\\"bug\\"]",
      degraded: [],
      confidence: :full,
      timestamp: DateTime.utc_now()
    }
  end
end
```

Los tres primeros son **de contrato**: si mañana alguien mete un
`Engine.start/2` dentro del refusal, el tercero se pone rojo y el segundo deja
de ser verdad. El cuarto fija que **decidir** y **despachar** son dos pasos
separados, que es la forma exacta en la que este módulo mantiene el refusal
decidido sin romper el router.

### 4.3 · `test/candil/lifecycle/idle_test.exs` — el temporizador

```elixir
defmodule Candil.Lifecycle.IdleTest do
  use ExUnit.Case, async: false

  alias Candil.Lifecycle.Idle

  setup do
    start_supervised!(Idle, idle_ms: 50)
    :ok
  end

  test "un toque deja marca de uso" do
    :ok = Idle.touch(:coder)

    assert %{last_used: %{coder: _}} = :sys.get_state(Idle)
  end

  test "caducar es apagar, y apagar quita la marca" do
    :ok = Idle.touch(:coder)
    ref = :sys.get_state(Idle).timers[:coder]

    # El mensaje de un temporizador VIEJO, ya en el buzon, con un ref que no
    # es el vigente. Sin esta comprobacion, un timer que llego tarde apaga un
    # modelo que alguien esta usando ahora mismo.
    send(Process.whereis(Idle), {:idle_expired, :coder, make_ref()})
    Process.sleep(20)
    assert :sys.get_state(Idle).timers[:coder] == ref

    send(Process.whereis(Idle), {:idle_expired, :coder, ref})
    Process.sleep(20)
    refute Map.has_key?(:sys.get_state(Idle).timers, :coder)
  end

  test "un toque REARMA el temporizador, no lo añade" do
    :ok = Idle.touch(:coder)
    primero = :sys.get_state(Idle).timers[:coder]
    :ok = Idle.touch(:coder)
    segundo = :sys.get_state(Idle).timers[:coder]

    refute primero == segundo
    # Y solo queda UN temporizador por modelo. Sin esto, N peticiones dejan N
    # temporizadores y el primero que llegue lo apaga en mitad del trabajo.
    assert map_size(:sys.get_state(Idle).timers) == 1
  end

  test "el estado sobrevive a que muera el motor" do
    :ok = Idle.touch(:coder)
    refute Idle.status(:coder) == :idle
    # El motor semurio: eso no es ociosidad, y el estado tiene que decirlo.
    assert Idle.status(:coder) == :dead
  end
end
```

Los tres primeros son **de contrato**: fallan si el temporizador no se rearma,
si no rearmar deja tempor zombis, o si un timer viejo apaga un modelo ocupado.
El cuarto es el que separa `:idle` de `:dead` (§2.5).

### 4.4 · `test/candil/lifecycle/load_set_test.exs` — el knapsack

```elixir
defmodule Candil.Lifecycle.LoadSetTest do
  use ExUnit.Case, async: true

  alias Candil.Lifecycle.LoadSet

  # 16 GB de tarjeta, 2 GB de margen. Un 7B Q4 son ~5 GB y un 27B son ~18:
  # el segundo NO cabe aunque quepa el primero, y ese es el punto.
  @dev %{total_gb: 16.0, free_gb: 16.0}

  test "acepta lo que cabe y rechaza lo que no" do
    assert {:ok, :coder} = LoadSet.admit(:coder, %{vram_gb: 5.0}, @dev)
    assert {:error, :insufficient_vram} = LoadSet.admit(:analyst, %{vram_gb: 18.0}, @dev)
  end

  test "el margen se respeta" do
    # 14 GB libres menos 2 de margen = 12. Un modelo de 13 no entra aunque
    # "encaje" en la tarjeta.
    dev = %{total_gb: 16.0, free_gb: 14.0}

    assert {:error, :insufficient_vram} = LoadSet.admit(:big, %{vram_gb: 13.0}, dev)
  end

  test "un modelo SIN coste declarado no se admite" do
    # El knapsack con un coste Unknown no es un knapsack: es una adivinanza.
    # Se admite solo si el modelo ya esta cargado.
    assert {:error, :unknown_cost} = LoadSet.admit(:nuevo, %{}, @dev)
  end

  test "el conjuntoadmite maximiza valor, no cantidad" do
    # Tres modelos de 5 GB en 16 GB: caben los tres. Cuatro de 5 en 12 GB
    # utiles: caben dos, y son los dos de mas valor, no los dos primeros.
    items = [
      {:a, %{vram_gb: 5.0, value: 1}},
      {:b, %{vram_gb: 5.0, value: 10}},
      {:c, %{vram_gb: 5.0, value: 10}}
    ]

    assert {:ok, chosen} = LoadSet.select(items, %{free_gb: 12.0, headroom_gb: 0.0})
    assert length(chosen) == 2
    assert :a not in chosen
  end
end
```

El último test es el que dice por qué esto es un knapsack: **elegir más cosas
no es el objetivo**. Es elegir las que más valen por GB. Un LRU de «N
entradas» no sabe de GB y por eso no puede hacerlo.

### 4.5 · `test/candil/router/metrics_test.exs` — qué se puede medir

```elixir
defmodule Candil.Router.MetricsTest do
  use ExUnit.Case, async: true

  alias Candil.Router.Metrics

  test "cada decision cuenta UNA vez, en la capa que gana" do
    Metrics.reset()
    Metrics.record(%{strategy: :rule, score: 0.375, degraded: [], latency_us: 42})

    assert %{decisions: 1, by_strategy: %{rule: 1}, degraded: 0} = Metrics.snapshot()
  end

  test "una decision DEGRADED cuenta aparte" do
    # Sin esto, no se puede comparar una capa contra otra: el 0.375 que gana
    # con embedder y el 0.375 que gana sin el son el MISMO numero y estan
    # midiendo cosas distintas.
    Metrics.reset()
    Metrics.record(%{strategy: :rule, score: 0.375, degraded: [:embedding], latency_us: 42})

    assert %{degraded: 1} = Metrics.snapshot()
  end

  test "el default se cuenta como default, no como acierto" do
    Metrics.reset()
    Metrics.record(%{strategy: :default, score: 0.5, degraded: [], latency_us: 12})

    assert %{by_strategy: %{default: 1}} = Metrics.snapshot()
  end
end
```

El segundo test es el que da valor a toda la fase: **sin él no hay forma de
saber si una capa nueva vale algo**.

### 4.6 · `test/candil/router/complexity_test.exs` — el clasificador barato

```elixir
defmodule Candil.Router.ComplexityTest do
  use ExUnit.Case, async: true

  alias Candil.Router.Complexity

  test "devuelve complejidad Y requisitos, nunca un modelo" do
    # Que devuelva un alias seria meter el clasificador dentro del router, y
    # el clasificador no sabe nada del catalogo de esta maquina.
    assert %Complexity{} = r = Complexity.classify(text("refactoriza este modulo de Elixir"))
    assert r.complexity in [:trivial, :normal, :hard]
    assert :code in r.requires
  end

  test "un prompt corto es trivial" do
    assert Complexity.classify(text("hola")).complexity == :trivial
  end

  test "vision se pide explicitamente, no se adivina" do
    assert :vision in Complexity.classify(text("que pone en esta imagen: revisa el grafico")).requires
    refute :vision in Complexity.classify(text("refactoriza este modulo")).requires
  end

  test "es una heuristica y se declara como tal" do
    # Un numero sin nombre es una caja negra. Este se llama `heuristic_score`
    # y por eso se puede discutir.
    assert is_number(Complexity.heuristic_score(text("por que esto es O(n log n)")))
  end

  defp text(content), do: [%{role: "user", content: content}]
end
```

### 4.7 · Los que NO se escriben todavía

| Test | Por qué no |
|---|---|
| El del clasificador con modelo | la fase F10 está **bloqueada** por un dato que no existe (Anexo V) |
| El de «la VRAM baja tras dormir» | depende de lo que mida F2 |
| El de «apagar un engine desatendido» | depende de lo que decida F4 sobre la supervisión (§2.3) |

Un test escrito antes de existir el dato es una hipótesis con sintaxis de
test. Es exactamente lo que este documento está intentando evitar.

---

## 5 · Cómo se hace

Los pasos son las fases del **Anexo I**, en orden. Cada uno dice su
prerrequisito. Los comandos son para la máquina del dueño.

> En la máquina donde se escribió esto no hay Elixir instalado, así que **ninguno
> de estos comandos se ha ejecutado**. Si algo falla, empieza por
> `mix deps.get` y comprueba que estás en la rama `docs-v2`.

### 5.1 · Antes de escribir nada (5 minutos)

```bash
cd /workspace/repos/candil
git branch --show-current
# debe imprimir: docs-v2

mix deps.get
mix compile
# debe imprimir: "Compiled N files" y 0 errores

mix test test/candil/router_test.exs
# debe imprimir: 40 tests, 0 failures
```

Si los 40 tests **no** están verdes, no se sigue. F0–F11 cuelgan de ese número.

### 5.2 · F0 · Contadores de decisión (sin nada nuevo que romper)

```bash
mix test test/candil/router/metrics_test.exs
# debe imprimir: 3 tests, 3 failures          <- se ven FALLAR

# escribir lib/candil/router/metrics.ex

mix test test/candil/router/metrics_test.exs
# debe imprimir: 3 tests, 0 failures
```

Y engancharlo: una línea en `lib/candil/router.ex`, dentro de `route/2`, justo
después del `with`. **Solo** si eso no cambia ninguna forma de retorno.

```bash
mix test test/candil/router_test.exs
# debe imprimir: 40 tests, 0 failures
```

### 5.3 · F1 · El refusal

```bash
mix test test/candil/router/dispatch_test.exs
# debe imprimir: 5 tests, 5 failures

# escribir lib/candil/router/dispatch.ex y Error.model_not_loaded/2

mix test test/candil/router/dispatch_test.exs
# debe imprimir: 5 tests, 0 failures
```

### 5.4 · F2 · El número de VRAM

Primero, **el script de medición**, antes que el módulo. Es un fichero de
`scripts/` y no un test:

```bash
cat > scripts/vram-check.sh <<'EOF'
#!/usr/bin/env bash
# Cuanto hay y cuanto queda, por dispositivo.
set -u
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "sin nvidia-smi: esta maquina no se puede medir con este script"
  exit 1
fi
nvidia-smi --query-gpu=index,name,memory.total,memory.used,memory.free \
           --format=csv,noheader,nounits
EOF
chmod +x scripts/vram-check.sh
./scripts/vram-check.sh
```

Se ejecuta **con un modelo cargado y con la tarjeta vacía**, y las dos cifras
se apuntan en `DECISIONES.md`. Sin esas dos cifras, F7 no se abre.

### 5.5 · F3–F6 · Toque, temporizador, apagado y reconciliación

En este orden, porque cada uno necesita el anterior:

```bash
mix test test/candil/lifecycle/idle_test.exs
# debe imprimir: 4 tests, 4 failures

# escribir lib/candil/lifecycle/idle.ex + engancharlo a lib/candil/application.ex

mix test test/candil/lifecycle/idle_test.exs
# debe imprimir: 4 tests, 0 failures
```

En `lib/candil/application.ex`, el GenServer va **después** de `Candil.Store`
en la lista `children`, porque el catálogo vive en tablas ETS que `Store`
crea en su `init/1`. Un hijo antes de la tabla lee una tabla que no está.

### 5.6 · F7–F9 · Medir, luego clasificador barato, luego embeddings

```bash
mix test test/candil/lifecycle/load_set_test.exs
mix test test/candil/router/complexity_test.exs
# ambos en rojo antes
```

### 5.7 · F10 · **Bloqueada**

```bash
mix test test/candil/router/classifier_test.exs
# el fichero NO existe. No se escribe.
```

Si alguien abre este paso, el primer trabajo no es código: es traer el número
de la Anexo V.

### 5.8 · F11 · El Pool (último, y opcional)

Nada de esto se toca hasta que F7 esté verde.

---

## 6 · Las puertas

### 6.1 · Las siete de siempre

En este orden, y el `test` va en medio a propósito: si el dialyzer falla antes
de correr los tests, se ha perdido la información de qué rompe de verdad.

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix escript.build
```

**Ninguna fase se cierra con el resultado de un comando.** Se cierra con lo que
pasó en la máquina del dueño (§7).

### 6.2 · Verificación por semilla

```bash
for s in 1 42 99991; do mix test --seed $s; done
```

No es superstición. La tabla de pins (`:candil_router_pins`,
`lib/candil/router/consumer.ex:19`) sobrevive entre tests del mismo VM, y los
tests de pin ya llevan `on_exit/1` por esto. **Cualquier** test nuevo que
 toque la tabla de pins lo lleva también, o no vale nada.

### 6.3 · Build limpio

```bash
rm -rf /tmp/build-candil && mkdir -p /tmp/build-candil
MIX_BUILD_PATH=/tmp/build-candil mix deps.get
MIX_BUILD_PATH=/tmp/build-candil mix compile
MIX_BUILD_PATH=/tmp/build-candil mix test
```

Un `MIX_BUILD_PATH` sucio produce `Mox.Server` sin arrancar y decenas de
fallos que no son de nadie. Si salen muchos fallos de golpe y no sabes por qué,
**el build está corrupto antes que tu código**.

### 6.4 · Las puertas propias de este módulo

| # | Puerta | Qué falla si no pasa |
|---|---|---|
| P1 | `mix test test/candil/router_test.exs` dice **40 tests, 0 failures** | todo lo demás se construye sobre un suelo que no está |
| P2 | El refusal no cambia ninguna forma de retorno de `route/2` | el contrato de la §4.1 se rompe por la puerta de atrás |
| P3 | `Router.Dispatch.attempt/1` **no llama a `Engine.start/2`** | se ha convertido el refusal en un arranque automático, que es lo decidido en contra |
| P4 | Un temporizador viejo no apaga un modelo en uso | un cliente se queda sin servidor a mitad de una respuesta |
| P5 | El apagado baja la VRAM **medida con `nvidia-smi`**, no supuesto | el módulo entero no sirve para lo que dice servir (Anexo V.1) |
| P6 | `:dead` no se confunde con `:idle` | se intenta parar un engine que ya no está, y el registro se llena de trampas |
| P7 | Ningún `String.to_atom/1` con entrada externa en el código nuevo | crear átomos desde el TOML o la línea de órdenes es denegación de servicio con un fichero en la mano |
| P8 | F10 no se abre sin el dato de la Anexo V | un clasificador con modelo entra por entusiasmo, que es como entró `--cpu` |

---

## 7 · Cómo se sabe que funciona

### 7.1 · En la suite

| Qué | Cómo se sabe que está bien | Cómo se sabe que **falla** |
|---|---|---|
| Prioridad de capas | 40/0 en `router_test.exs` | rompe `decision_engine.ex:36-40` y pon las capas al revés: los tests de pin y de forzado tienen que ponerse rojos |
| Un candidato no es un pin | `decision.strategy == :default` | cambia `{_, [only]}` por `{:ok, _}` en `pinned/4` y el test de `router_test.exs:464` se pone rojo diciendo `pinned` |
| El refusal | `{:error, %Error{reason: :model_not_loaded}}` con `context.command` | quita el `context.command` del error y el test sigue verde: por eso el `context` se mira en un test aparte |
| El refusal no arranca | `EnginePool.count/0` igual antes y después | mete un `Engine.start/2` dentro de `Dispatch.attempt/1`: el count cambia y el test cae |
| El temporizador se rearma | `map_size(timers) == 1` tras tres toques | quita el `Process.cancel_timer/1`: `timers` crece y el test cae |
| Un timer viejo no manda | tras un `{:idle_expired, alias, otro_ref}` el timer sigue ahí | quita la comparación de refs: el test cae |
| El knapsack | 4/0 en `load_set_test.exs` | baja `headroom_gb` a 0 y el test del margen se pone rojo |
| Los contadores | `%{degraded: 1}` | renombra el campo `degraded` en el struct y el `Map.new` se queda sin él: el test cae con un `KeyError` que **no dice qué faltaba** |

La última fila es la trampa de todos los contadores: un `snapshot/0` que
construye el mapa con `Map.new` **no falla** cuando le falta una clave, y quien
lo lee es un humano que no sabe qué buscar. Los contadores se testean con
`assert %{clave: _} = snapshot()`, no con `assert snapshot() == %{...}` sobre
campos sueltos.

### 7.2 · En la máquina

Aquí es donde se cierra la fase. Sin esto no está hecha.

**Cold start / idle shutdown:**

```bash
# 1. vaciar la tarjeta
./scripts/vram-check.sh
# anotar: VRAM antes

# 2. arrancar un modelo
candil run coder
# debe imprimir: "coder arrancado en :NNNN"

# 3. MIRAR que la VRAM sube. Sin esto, "arrancado" no significa nada.
./scripts/vram-check.sh
# anotar: VRAM despues. Debe ser > antes.

# 4. esperar al temporizador
sleep 900
candil status
# debe imprimir una tabla SIN la fila de coder

./scripts/vram-check.sh
# DEBE volver al valor del paso 1. Si no, el temporizador apaga el proceso y
# la VRAM se queda: eso es un fallo, no un detalle.
```

**El refusal:**

La linea del refusal **hoy no existe**: `Candil.CLI.Router.show/1`
(`lib/candil/cli/router.ex:51-67`) imprime estrategia, score, confianza,
reason, degradadas y alternativas, y ni una palabra de si el modelo está
cargado. Ponerla es parte de F1.

```bash
candil route ask "refactoriza este modulo de Elixir y arregla el bug"
# debe imprimir:
#   -> coder
#   estrategia  rule
#   score       0.375
#   confianza   degraded        (o full, segun si hay embedder)
#   reason      keyword rule matched ["bug", "elixir", "refactor"]
#   candil run coder           <- el refusal

candil status
# debe seguir mostrando lo de antes. Si coder aparece ya arrancado, P3 ha
# fallen: el refusal arranco el modelo.
```

Y el caso que de verdad importa, el que salió en la máquina del dueño:

```bash
candil route ask "lo que sea"
candil route pin
# Las dos cosas tienen que decir lo mismo. Si la primera dice `pinned` y la
# segunda dice "ninguno", el router esta mintiendo sobre COMO se decidio.
```

**El clasificador, cuando exista:**

```bash
mix run -e 'IO.inspect(Candil.Router.Complexity.classify([%{role: "user", content: "por que esto es O(n log n)"}]))'
# debe imprimir una estructura con :complexity y :requires
```

### 7.3 · Lo que **no** se verifica aquí

- Que la VRAM vuelva tras un apagado por ociosidad (**sin medir**: depende de
  F2 y de la máquina).
- Que dormir recargue a la primera petición (**sin medir**: es comportamiento
  de `llama-server`, no de Candil).
- Cuánto tarda de verdad un arranque en frío en la máquina del dueño. **No hay
  ni un número en este documento**, y es el número que más se va a necesitar.

---

## 8 · Cuando sale mal

| Síntoma | Qué está pasando de verdad | Qué hacer |
|---|---|---|
| `candil status` dice `DOWN` y `candil stop` dice que no hay instancias | el engine murió y la entrada se quedó en `EnginePool`. `Reaper` poda por **dueño**, y el dueño es la VM, que sigue viva | F6: `Process.monitor/1` sobre el pid del engine y quitar la entrada en `:DOWN`. **No** tocar `Reaper`: su regla de no matar es correcta |
| El refusal arranca el modelo | `Dispatch` está llamando a `Engine.start/2`, o hay un camino nuevo que lo hace | P3. Quitar la llamada y añadir el test de `§4.2`, que es el que se supone que impedía esto |
| Un cliente se queda sin servidor a mitad de una respuesta | llegó un `{:idle_expired, ...}` de un temporizador ya cancelado | la comparación de refs de `§4.3`. Sin ella, cancelar no basta: el mensaje ya estaba en el buzón |
| `route ask` dice `pinned` y `route pin` dice «ninguno» | un solo candidato se está marcando como pin | el fallo de `§4.1`, y ya se arregló una vez en `decision_engine.ex:140-173`. Si vuelve, es que alguien ha vuelto a tocar `pinned/4` |
| El pin no sobrevive a un reinicio | **no es un fallo.** `Consumer.pin/2` vive en ETS (`consumer.ex:36`) y los pins no sobreviven, y es deliberado (`lib/candil/router.ex:132-134`) | nada. Si se quiere persistente, es otra fase y otra decisión |
| El vocabulario de las reglas no cambia al tocar el TOML | `@rules` y `@default_rules` están fijos en `lib/candil/router/scorer.ex` y **nadie lee `[router.rules]`** | §2.6 y F8. Es un fallo de cableado, no de configuración |
| La categoría `fast` no gana nunca | `@default_rules` apunta a `:gpt4o`, y ese alias no está en el catálogo de esta máquina | lo mismo que arriba. Y el mismo dato sale de `candil models list` |
| Un clasificador devuelve un modelo que no existe | el clasificador se ha colado en el mapa de modelos. `§4.6` dice que devuelve **requisitos**, no alias | quitar el acceso a `Store` del clasificador. Un clasificador que conoce el catálogo es un router que ya no se puede medir por capas |
| Un 0.375 gana con embedder y sin él, y no se nota | la marca de degradado no se está propagando | `decision.degraded` (`lib/candil/router.ex:54`) y `confidence`. Los scores **no** se renormalizan, y no se deben renormalizar |
| `mix credo --strict` falla con `UnsafeToAtom` | alguien ha escrito `String.to_atom/1` con entrada externa | P7. El caso que ya existe y está en `lib/candil/cli/lifecycle.ex:550`, con un `credo:disable` encima; un `disable` ahí es una deuda, no un stylistic |
| `mix test` falla con muchos fallos de golpe y no se sabe por qué | el build está corrupto | la §6.3. `rm -rf` y recompilar **antes** de mirar el código |
| `candil route` sin subcomando revienta | `lib/candil/cli.ex:76` declara `run({Router, :unknown})` y **`Candil.CLI.Router.unknown/1` no existe** (el único `unknown/1` del repo está en `lib/candil/cli/escript.ex:154`). Igual con `candil models` | es del bloque 05, no de este módulo, pero es **la puerta de entrada** de este módulo: quien lo pruebe lo ve en el primer minuto. Se arregla en `05-cli`, o se documenta aquí como conocido |
| `dialyzer` se queja de `:model_not_in_candidates` | el `@type reason` de `lib/candil/error.ex:18-36` **no incluye** ni `:model_not_in_candidates` ni `:no_classifier_model`, y los dos se construyen en `error.ex:64` y `error.ex:79` | añadirlos al `@type`. **Sin medir** si dialyzer lo canta hoy: no se ha ejecutado en esta máquina |

---

## Anexo I · Desglose en fases (Ciclo-A)

> Esto es lo que alimenta [`docs/02-orden/`](../../02-orden/). Cada fase dice su
> prerrequisito. Una fase sin prerrequisito puede empezar hoy.

| # | Fase | Prerrequisito | Por qué en este sitio |
|---|---|---|---|
| **F0** | Contadores por capa (`Router.Metrics`) | — | Sin esto no se puede comparar ninguna capa con ninguna. Es lo primero y es lo más barato |
| **F1** | El refusal (`Router.Dispatch`) | el struct `Decision` (`lib/candil/router.ex:35`) y `Engine.healthy?/2` | Es una decisión ya tomada y **no depende de nada**. Puede ir en paralelo con F0 |
| **F2** | Un número de VRAM (`Detector.VRAM`) | F0 | El número es un dato, no un módulo. F7 y F4 lo necesitan y sin él los dos son suposiciones |
| **F3** | El toque de uso en cada petición | F1 | El toque tiene que colgar del camino de despacho, que es F1. Un toque puesto en otro sitio es un toque que no se llama |
| **F4** | GenServer + temporizador (`Lifecycle.Idle`) | F2 **y** F3 | El temporizador sin F3 no sabe cuándo se rearma; sin F2 no sabe si sirve de algo. Y necesita la decisión de supervisión de §2.3 |
| **F5** | Apagado y comprobación de que la VRAM vuelve | F4 | El apagado sin comprobación es una afirmación |
| **F6** | Reconciliación al arrancar: `:idle` / `:dead` / `:detached` | F4 | Comparte el estado con F4 y usa el mismo camino. Un `Process.monitor/1` que nace con el GenServer |
| **F7** | Admisión knapsack (`Lifecycle.LoadSet`) | F2 **y** F5 | Necesita el coste por modelo (F2) y necesita saber que un modelo unloaded sí libera (F5) |
| **F8** | Clasificador heurístico (`Router.Complexity`) | F0 | Antes hay que saber cuánto falla lo barato. Y hay que **arreglar `[router.rules]`** (§2.6), que es parte de esta fase |
| **F9** | Capa de embeddings de verdad | F0 **y** F8 | Solo tiene sentido si F8 ha dejado claro qué NO sabe el clasificador barato. Hoy es un `:miss` (`scorer.ex:55-60`) |
| **F10** | Clasificador con modelo | F8 + F9 + **el dato de la Anexo V** | Bloqueada. No es una fase todavía: es una hipótesis con prerrequisitos |
| **F11** | `Arrea.Pool` para el conjunto de motores | F7 + F4 | La cola reparte peticiones entre los ya admitidos. La admisión en GB es F7 y **no** es el Pool |

### El grafo, en una línea

```
F0 ──┬──► F8 ──┬──► F9 ──┬──► F10   (F10 BLOQUEADA: falta un dato)
     │         │         │
F1 ──┼──► F3 ──┴─────────┘
     │      │
     └──► F4 ◄── F2
            ├──► F5 ──┐
            ├──► F6   ├──► F7 ──► F11
            └─────────┘
```

**Lo que puede empezar hoy mismo:** F0 y F1, porque no esperan a nadie.

---

## Anexo II · Cold Start: el GenServer y el temporizador

### II.1 · El pseudocódigo

Es el patrón que ya está en `lib/candil/instances/reaper.ex:82`, con un
ref por medio. Sin tildes, como manda el repo.

```elixir
defmodule Candil.Lifecycle.Idle do
  use GenServer
  require Logger

  alias Candil.{Engine, EnginePool}

  # Sin medir. Este numero sale de la maquina del dueno, no de aqui.
  @default_idle_ms :timer.minutes(15)

  # ESTADO
  #
  #   timers    %{alias => reference()}   UN temporizador por modelo
  #   last_used %{alias => integer()}     reloj monotono, ms
  #
  # Lo que NO esta aqui, y por que: el estado real de un modelo (cargado,
  # muerto, de otro) NO lo guarda este modulo. Se pregunta a EnginePool y al
  # proceso, porque un estado guardado en dos sitios diverge. Este solo
  # guarda CUANDO se toco, que es lo unico que no se puede mirar fuera.
  #
  # Los refs de `Process.monitor/1` tampoco estan todavia: llegan en F6, con
  # el supervisor que los necesita. Anadir un `refs: %{}` aqui seria un campo
  # que nunca se lee.

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Un cast, no un call. Tocar el reloj de ociosidad no puede hacer esperar a
  # una peticion: si el controlador esta ocupado, la peticion espera por un
  # temporizador, que no vale la pena.
  @spec touch(atom()) :: :ok
  def touch(model_alias), do: GenServer.cast(__MODULE__, {:touch, model_alias})

  @spec status(atom()) :: :idle | :loaded | :dead | :unknown
  def status(model_alias), do: GenServer.call(__MODULE__, {:status, model_alias})

  @impl GenServer
  def init(opts) do
    idle_ms = Keyword.get(opts, :idle_ms, @default_idle_ms)
    # Aqui no hay ningun Process.monitor/1 todavia. El monitor va con el
    # supervisor de F6, que es quien sabe que hacer con un :DOWN.
    {:ok, %{idle_ms: idle_ms, timers: %{}, last_used: %{}}}
  end

  # ── el camino caliente: una peticion ──────────────────────────────────
  @impl GenServer
  def handle_cast({:touch, model_alias}, state) do
    ref = make_ref()

    # 1. Cancelar el VIEJO. Y esto NO basta solo: si el mensaje ya estaba en
    #    el buzon, `cancel_timer/1` lo deja estar. Por eso el mensaje lleva
    #    un ref y `handle_info` lo comprueba antes de apagar nada.
    case Map.fetch(state.timers, model_alias) do
      {:ok, old_ref} -> Process.cancel_timer(old_ref)
      :error -> :ok
    end

    # 2. Poner el NUEVO. Uno por modelo, no uno por peticion.
    new_ref = Process.send_after(self(), {:idle_expired, model_alias, ref}, state.idle_ms)

    # 3. Y apuntar el reloj de monotono, que es el unico que sirve para medir
    #    duraciones: un reloj de pared atrasa con un NTP y un dia de ociosidad
    #    se mide en horas, no en milisegundos.
    %{
      state
      | timers: Map.put(state.timers, model_alias, new_ref),
        last_used: Map.put(state.last_used, model_alias, System.monotonic_time(:millisecond))
    }
    |> noreply()
  end

  # ── el camino frio: se cumplio el temporizador ────────────────────────
  @impl GenServer
  def handle_info({:idle_expired, model_alias, ref}, state) do
    # Un timer viejo que llego tarde. Puede ser que este modelo este en uso
    # AHORA MISMO. Si se apaga aqui, un cliente se queda sin servidor a mitad
    # de una respuesta y no hay quien lo haya hecho cuentas.
    if Map.get(state.timers, model_alias) == ref do
      Logger.debug("lifecycle.idle: #{model_alias} lleva #{state.idle_ms}ms sin uso")

      state
      |> Map.update!(:timers, &Map.delete(&1, model_alias))
      |> Map.update!(:last_used, &Map.delete(&1, model_alias))
      |> release(model_alias)
      |> noreply()
    else
      noreply(state)
    end
  end

  # El :DOWN de un engine. OJO: esto es MUCHO mas pequeno que el temporizador.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Un motor que se murio no es un motor ocioso. La entrada en EnginePool
    # sigue diciendo que esta vivo, y su puerto sigue contado como ocupado
    # por EnginePool.claim_port/2.
    #
    # Aqui SOLO se avisa. Quitar la entrada es trabajo de F6 y lo hace otro
    # proceso: este apaga engines, y un modulo que ademas limpia registros
    # tiene dos razones para fallar en el mismo sitio.
    Logger.warning("lifecycle.idle: #{inspect(pid)} ha muerto: #{inspect(reason)}")
    noreply(state)
  end

  def handle_info(_msg, state), do: noreply(state)

  # ── que significa estar cargado ───────────────────────────────────────
  @impl GenServer
  def handle_call({:status, model_alias}, _from, state) do
    # :dead y :idle son COSAS DISTINTAS y se contestan distinto:
    #
    #   :idle  -> lo apagamos nosotros (el temporizador va a vencer)
    #   :dead  -> NO hay que apagarlo: ya no esta. Hay que quitar su entrada
    #             de EnginePool y de instances.json, o el puerto queda
    #             fantasma para siempre.
    #
    # Aqui solo se LEE. Quitar las entradas es trabajo de F6, y va en otro
    # proceso a proposito.
    estado =
      case EnginePool.by_model(model_alias) do
        [] ->
          :unknown

        [_ | _] ->
          if Engine.healthy?(model_alias, 500), do: freshness(state, model_alias), else: :dead
      end

    {:reply, estado, state}
  end

  defp noreply(state), do: {:noreply, state}

  # "Fresco" es "alguien lo ha tocado hace menos de idle_ms". La pregunta es
  # de reloj, no de EnginePool: un engine cargado y sin nadie preguntando es
  # exactamente el caso que hay que distinguir de uno que esta sirviendo.
  defp freshness(state, model_alias) do
    case Map.fetch(state.last_used, model_alias) do
      {:ok, ms} ->
        if System.monotonic_time(:millisecond) - ms < state.idle_ms, do: :loaded, else: :idle

      :error ->
        :idle
    end
  end

  # ── el apagado ────────────────────────────────────────────────────────
  #
  # A proposito NO esta escrito aqui. Se escribe en F5, despues de medir que
  # apagar de verdad libera la VRAM. Este stub no hace nada, y aun asi borra
  # los timers, para que el temporizador sea observable sin que se mate nada:
  # un apagado sin medir es un apagado que se ha inventado alguien.
  defp release(state, _model_alias), do: state
end
```

### II.2 · Por qué un ref y no un `cancel_timer/1` a secas

Es la parte que casi todo el mundo se salta, y es la que produce el peor fallo
posible: **un cliente se queda sin servidor a mitad de una respuesta**, y no
hay log que lo diga.

```
t=0s    peticion A  ->  timer VIEJO (ref1) ya esta en el buzon
t=1s    peticion B  ->  cancel_timer(ref1)   ... pero el mensaje YA esta
                      ->  Process.cancel_timer/1 devuelve false
                      ->  se pone timer NUEVO (ref2)
t=1s+   llega {:idle_expired, alias, ref1}
        ... sin comprobar, esto APAGA el modelo que B acaba de usar
```

Con la comparación de refs, el mensaje de `ref1` se ignora porque
`state.timers[alias]` es `ref2`. El `cancel_timer/1` sigue estando, porque sin
él se acumulan N temporizadores; pero **la comprobación es la que manda**.

Esto tiene un test propio en `§4.3`, y es el que hay que romper a propósito
primero para ver que dice algo.

### II.3 · El proceso que muere, que no es lo mismo que «está ocioso»

Cuatro casos, y **cuatro conversas distintas**:

| Caso | Cómo se sabe | Qué hay que hacer | Quién lo hace |
|---|---|---|---|
| **Ocioso** | pasaron `idle_ms` desde el último `touch/1` | `Engine.stop/1` y quitar las entradas | `Lifecycle.Idle`, en `handle_info({:idle_expired, ...})` |
| **Murió** | `:DOWN` del monitor, o `Engine.healthy?/2` es `false` con entrada en `EnginePool` | **nada que apagar**. Quitar la entrada de `EnginePool` y de `instances.json` | un supervisor, **no** el `Reaper` (que no mata, y sigue sin deber hacerlo) |
| **No arrancó nunca** | está en el catálogo, no en `EnginePool` | nada. El refusal dice el comando | el llamante |
| **De otro** | `Instances.find/1` lo tiene con un `owner` que no es esta VM | **nada**. Ni tocarlo ni contarlo como nuestro | nadie, a propósito |

El caso **murió** es el que más se cuela, y hay una razón concreta en el
código: `Candil.Instances.Reaper.prune/0` filtra por
`Instances.alive?/1`, y `alive?/1` pregunta por el **dueño**
(`lib/candil/instances.ex:223`), y el dueño de una instancia local es el pid
de la VM (`lib/candil/instances.ex:323`). La VM sigue viva. El `llama-server`
no. Y el predicado pregunta por la primera, no por la segunda.

Consecuencia medida en el código: un engine caído deja una fila en
`instances.json` **para siempre**, y su puerto sigue saliendo como ocupado en
`EnginePool.claim_port/2` (`engine_pool.ex:221-228`). `candil status` lo
enseña como `DOWN` porque `Candil.CLI.Lifecycle.state_of/1` sí pregunta, y eso
es lo único que hoy lo delata.

---

## Anexo III · Smart Routing: el pipeline, capa por capa

### III.1 · El orden, y por qué no se toca

El orden real está en `lib/candil/router/decision_engine.ex:36-40`, escrito en
un `with`. Este módulo **agrega encima**; no reordena nada.

```
                    ┌─────────────────────────────────────────┐
  peticion ────────►│ 0. force_model      (por peticion)      │──► gana y sale
                    ├─────────────────────────────────────────┤
                    │ 1. cache            (hash del turno)    │──► gana y sale
                    ├─────────────────────────────────────────┤
                    │ 2. pin              (del consumidor)    │──► gana y sale
                    ├─────────────────────────────────────────┤
                    │ 3. reglas           (palabras)          │──► gana si >= 0.20
                    ├─────────────────────────────────────────┤
                    │ 4. embeddings       (coseno)            │──► gana si >= 0.55
                    ├─────────────────────────────────────────┤
                    │ 5. clasificador LLM (una inferencia)    │──► OFF por defecto
                    ├─────────────────────────────────────────┤
                    │ 6. default          (el ULTIMO)         │──► siempre gana
                    └─────────────────────────────────────────┘
                                    │
                                    ▼
                          REFUSAL (no arranca; dice el comando)
```

Cada umbral es distinto porque cada capa mide una cosa distinta. El de las
reglas es **0.20** y no 0.70 (`decision_engine.ex:303`): la regla `code` tiene
8 palabras y un prompt real de código toca dos o tres
(`test/candil/router_test.exs:51` mide 3/8 = 0.375). Contra un umbral de las
capas semánticas, la capa de reglas **nunca** dispararía y todo caería al
default en silencio.

### III.2 · Qué se puede MEDIR en cada capa

Nada de cajas negras: en cada capa, la señal que dice si vale.

| Capa | Qué devuelve hoy | **Qué se mide** | Dónde se mide | Cómo se sabe que **no** vale |
|---|---|---|---|---|
| **0 · force_model** | `:forced`, score 1.0 (`decision_engine.ex:104`) | nº de veces que se fuerza, por consumidor | `Metrics.by_strategy[:forced]` | que aparezca más veces que el default. Un forzado que se usa a diario no está arreglando el router, lo está apagando |
| **1 · cache** | la decisión anterior (`cache.ex:69`) | acierto / toca, por consumidor | ratio `cache.get` que devuelve `{:ok, d}` | el acierto sube y **la calidad no**. Se mide cruzando con la Anexo III.3 |
| **2 · pin** | `:pinned`, score 1.0 (`decision_engine.ex:140`) | nº de pins vivos, y desde cuándo | `Consumer.pinned/1` + `last_used` | un pin que dura días es una regla mal escrita con más autoridad |
| **3 · reglas** | razón de aciertos / 8 (`scorer.ex:66`) | **cobertura**: % de peticiones que caen aquí, y cuántas caen al default | `by_strategy[:rule] / decisions` | cobertura alta con fp altos. Y aquí está el bug medible: el vocabulario es inglés y fijo (§2.6) |
| **4 · embeddings** | `:miss` siempre (`scorer.ex:55-60`) | coberturaFp, y sobre todo **cuánto se parece a la cobertura de las reglas**. Si se parecen, no vale | `by_strategy[:embedding]` y el solape con `:rule` | solape > 0.9 ⇒ es una capa que cuesta una inferencia para repetir lo que ya se sabía |
| **5 · clasificador LLM** | `:miss` siempre (`decision_engine.ex:225`) | todo lo de arriba, **más** lo único que él puede decir: precisión sobre los casos que las capas de abajo fallaron | por encima de F0 | su acierto sobre el subconjunto difícil no supera al del default |
| **6 · default** | el último candidato, score 0.5 (`decision_engine.ex:72-87`) | **el número que decide todo lo demás** | `by_strategy[:default] / decisions` | este número **alto** es el que justifica (o no) F10 |
| **en todas** | `confidence: :full \| :degraded` (`lib/candil/router.ex:55`) | % degradado | `Metrics.degraded / decisions` | degradado alto con los mismos scores ⇒ se está comparando una decisión medida con una sin medir |
| **en todas** | `latency` de la decisión | p50 y p99, **por capa** | `Metrics.latency_us` por estrategia | una capa que gana el 5 % y cuesta el 20 % del presupuesto es una capa que sobra |

### III.3 · La comparación que hay que poder hacer

Las tres preguntas, en este orden, y ninguna se responde sola:

1. **Cuántas peticiones caen al default.** Es la cobertura del sistema. Sin
   este número, las capas siguientes no tienen contra qué medirse.
2. **Sobre las que NO caen al default, cuántas estaban bien.** El acierto
   **fuera** del default, con la respuesta buena guardada a mano. Sin esto, un
   clasificador puede subir la cobertura y bajar la calidad, y las dos cosas
   se ven igual en `by_strategy`.
3. **Qué gana cada capa sobre el subconjunto donde fallan las de arriba.** Si
   la capa 4 gana el 3 % de los casos difíciles, no es una capa.

Y la trampa, que ya se ha pagado una vez en este repo: los scores **no** se
renormalizan al degradar (`decision_engine.ex:309-313`). Un 0.2 no se
presenta como un 0.9. Cualquier métrica que renormalice está mintiendo sobre
lo poco que se sabe.

---

## Anexo IV · Los contratos

### IV.1 · Lo que ya está declarado (y se usa tal cual)

Esto no se toca. Se reproduce para que quede escrito qué se puede apoyar.

```elixir
# lib/candil/router.ex
@type strategy :: :cache | :rule | :embedding | :llm | :default | :pinned | :forced
@spec route([map()], keyword()) :: {:ok, decision()} | {:error, Error.t() | atom()}
@spec candidates(atom()) :: {:ok, [atom()]} | {:error, :no_models_for_consumer}
@spec pin(atom(), atom()) :: :ok | {:error, term()}
@spec pinned(atom()) :: {:ok, atom()} | :error
@spec resolve(decision()) :: {:ok, Candil.Model.t(), term()} | {:error, term()}

# lib/candil/router/decision_engine.ex
@spec decide([map()], [atom()], keyword()) ::
        {:ok, Decision.t()} | {:error, :no_models_for_consumer}

# lib/candil/router/scorer.ex
@type layer :: :rule | :embedding | :llm
@spec score([map()], [atom()], layer(), map()) :: [{atom(), float()}] | :miss
@spec rule_score([map()], atom()) :: float()

# lib/candil/engine.ex
@spec start(t(), Candil.Model.t()) :: {:ok, pid()} | {:error, binary()}
@spec stop(atom()) :: :ok | {:error, :not_running}
@spec healthy?(atom(), timeout()) :: boolean()
@spec base_url(atom()) :: binary() | nil
@spec for_model(term(), pos_integer(), boolean()) :: {:ok, t()} | {:error, :not_found}

# lib/candil/engine_pool.ex
@type instance :: %{alias:, port:, pid:, model:, engine:, started_at:, healthy:}
@spec put(atom(), pos_integer(), pid() | nil, Model.t(), Engine.t()) :: :ok
@spec delete(atom(), pos_integer()) :: :ok
@spec by_model(atom()) :: [instance()]
@spec claim_port(pos_integer(), pos_integer()) :: {:ok, pos_integer()} | {:error, :no_free_port}

# lib/candil/instances.ex
@spec read() :: [instance()]
@spec all() :: [instance()]
@spec alive?(instance()) :: boolean()
@spec delete({binary(), pos_integer()}) :: :ok | {:error, File.posix()}
```

### IV.2 · Lo que hay que declarar (nuevo)

```elixir
# ── Candil.Router.Dispatch ──────────────────────────────────────────────

@typedoc "Por que no se puede despachar."
@type refusal_reason ::
        :model_not_loaded     # esta en el catalogo, no esta cargado
        | :model_not_downloaded # el .gguf no esta en disco
        | :engine_missing      # el modelo no tiene engine en la config
        | :no_port             # no se pudo resolver un puerto libre

@spec attempt(decision()) ::
        {:ok, Model.t(), target(), :already_running}
        | {:error, Error.t()}
# El refusal NO devuelve {:error, :not_running} a secas: lleva el comando en
# error.context.command. Un error sin el comando deja al usuario adivinando,
# y adivinar el comando equivocado con 20 GB de por medio es caro.

# ── Candil.Lifecycle.Idle ───────────────────────────────────────────────

@type model_state :: :idle | :loaded | :dead | :unknown

@spec touch(atom()) :: :ok
@spec status(atom()) :: model_state()

# ── Candil.Lifecycle.LoadSet ────────────────────────────────────────────

@typedoc "El coste de un modelo en GB. Unknown NO es cero."
@type cost :: %{vram_gb: non_neg_float(), value: non_neg_integer()}

@spec admit(atom(), cost(), device()) :: {:ok, atom()} | {:error, :insufficient_vram | :unknown_cost}
@spec select([{atom(), cost()}], device()) :: {:ok, [atom()]} | {:error, :no_candidate}
# El campo que NO puede faltar es `vram_gb`. Un modelo sin coste declarado
# devuelve {:error, :unknown_cost} y no se admite: el knapsack con un Unknown
# no es un knapsack, es una adivinanza con presupuesto.

# ── Candil.Detector.VRAM ────────────────────────────────────────────────

@type device :: %{
        index: non_neg_integer(),
        backend: Candil.Detector.GPU.gpu_backend(),
        total_gb: non_neg_float(),
        free_gb: non_neg_float(),
        source: :nvidia_smi | :rocm_smi | :unavailable
      }

@spec devices() :: [device()]
# `source: :unavailable` con `free_gb: 0.0` NO es "no hay GPU". Es "no lo se".
# La distincion importa: con 0.0 libre, el knapsack no admite nada y el
# usuario ve un refusal que no tiene nada que ver con su problema.

# ── Candil.Router.Complexity ────────────────────────────────────────────

@type complexity :: :trivial | :normal | :hard
@type requirement :: :code | :vision | :logic | :long_context | :structured

@type t :: %__MODULE__{
        complexity: complexity(),
        requires: [requirement()],
        heuristic_score: float(),
        signals: [String.t()]   # por que, en texto
      }

# BEHAVIOUR, no modulo suelto. Un solo callback, como Candil.Backend y
# Candil.Engine.Launcher.
@callback classify([map()]) :: t()
@spec classify([map()]) :: t()
# NO devuelve un alias. Devuelve requisitos. El cruce con el mapa de modelos
# es OTRO modulo, y es el que se mide por capas. Un clasificador que devuelve
# el modelo se ha tragado al router entero y no hay forma de saber que capa
# decidio.
#
# Con behaviour, la segunda implementacion (F10) NO toca el router. Con un
# modulo suelto, la tiene que tocar, y ahi es donde un router deja de ser
# medible por capas.

# ── Candil.Router.Metrics ───────────────────────────────────────────────

@type snapshot :: %{
        decisions: non_neg_integer(),
        by_strategy: %{Candil.Router.strategy() => non_neg_integer()},
        degraded: non_neg_integer(),
        latency_us: %{Candil.Router.strategy() => non_neg_integer()}
      }

@spec record(map()) :: :ok
@spec snapshot() :: snapshot()
@spec reset() :: :ok
```

### IV.3 · Las formas de error, todas

| Forma | Dónde | Qué dice |
|---|---|---|
| `{:error, :no_models_for_consumer}` | `Router.route/2` | el consumidor no tiene candidatos. **No** cae a `hd(models)` |
| `{:error, %Error{reason: :model_not_in_candidates}}` | `DecisionEngine.decide/3` | el forzado no está en la lista del consumidor. `context.candidates` dice cuáles sí |
| `{:classifier_unavailable, %Error{}}` | `DecisionEngine.decide/3` | el clasificador está **encendido** y no hay modelo. Un router que degrada en silencio es un router roto y escondido |
| `{:error, %Error{reason: :model_not_loaded}}` | **nuevo**, F1 | en el catálogo, no cargado. `context.command` es la orden |
| `{:error, :model_not_loaded}` | `Engine.start/2` | el binario no está. Distinto del de arriba: uno es «no lo arranco», el otro es «no puedo» |
| `{:error, :insufficient_vram}` | **nuevo**, F7 | no cabe en lo que queda. Nombra cuánto pedía y cuánto hay |
| `{:error, :unknown_cost}` | **nuevo**, F7 | el modelo no declara `vram_gb`. No se admite |
| `{:error, :not_running}` | `Engine.stop/1` | no había nada que parar. **No** es un fallo de la petición |

Y una forma que hay que arreglar de paso: el `@type reason` de
`lib/candil/error.ex:18-36` **no incluye** `:model_not_in_candidates` ni
`:no_classifier_model`, y los dos se construyen en `error.ex:64` y
`error.ex:79`. Los dos tests de la §4.1 pasan igual. Dialyzer puede que no.

---

## Anexo V · Medir antes de añadir

> «Un número sin medirlo no entra.» Si aquí pone algo, sale de
> `./scripts/vram-check.sh` o de `candil models list` **en la máquina del
> dueño**, y se escribe en `DECISIONES.md` de esta fase.

### V.1 · Las cinco medidas, y qué sale de cada una

| # | Qué se mide | Cómo | Qué DECIDE |
|---|---|---|---|
| **M1** | **Cuánta VRAM hay y cuánta queda, con y sin un modelo cargado** | `./scripts/vram-check.sh` en vacío, luego con `coder` cargado | Si F5 puede afirmar que el temporizador sirve de algo. Y el número que va a `device.total_gb` |
| **M2** | **Cuántas peticiones caen al default** | `Router.Metrics.snapshot()` tras un día de uso real de `opencode` | Si hace falta la capa 4, la 5, o ninguna |
| **M3** | **Sobre las que caen al default, cuántas estaban bien** | 30 casos sacados del registro, con la respuesta buena escrita a mano | Si el default es un default **bueno**. Un default que acierta el 80 % no necesita un clasificador: necesita más candidatos |
| **M4** | **Cuánto tarda de verdad un arranque en frío** | `time candil run coder` con la tarjeta vacía | El presupuesto del `idle_timeout`. Y si el temporizador es de 15 minutos o de 3 |
| **M5** | **Cuánto cuesta una inferencia de clasificación** frente a una inferencia normal | `[:candil, :inference, :stop]` con `tokens_out` | Si F10 es un negocio o una pérdida |

**M3 es la que más cuesta y la que más vale.** Sin ella, M2 dice «el 40 % cae
al default» y no dice si el default acierta o no. Un clasificador que sube la
cobertura del 60 % al 90 % y no cambia el acierto **ha empeorado el sistema**:
ahora paga una inferencia para acertar lo mismo.

### V.2 · Por qué SemIf (o cualquier clasificador externo) no entra sin M2 y M3

> **Aviso**: no he averiguado qué es exactamente SemIf. Lo trato aquí como
> «una capa de clasificación semántica que no es de Candil» — un modelo, un
> servicio, o un proceso aparte. Si es una dependencia concreta con su propia
> forma de fallar, esta sección hay que revisarla con esa dependencia delante.
> **Sin medir**.

Cinco razones, y ninguna es «es más complicado»:

1. **Sería una capa que no se puede medir por capas.** Las capas 1–6 del
   `Anexo III` dicen cada una qué estrategia decidió y con qué score. Una capa
   externa que devuelve un modelo no deja ni `reason` ni `alternatives`: deja
   un modelo. Y un router que devuelve un modelo sin explicación es un router
   que se depura apagándolo (`lib/candil/router.ex:39-42`).

2. **Su fallo es silencioso por naturaleza.** Si el clasificador no está
   arrancado, o contesta con basura, o tarda 400 ms: el sistema **sigue
   funcionando** y **respondiendo peor**. Esto no es hipotético en este repo: el
   `enable_llm_classifier` fue una constante durante toda una línea y nadie lo
   notó (`lib/candil/router.ex:214-220`), y `general.log_dir` validaba y no lo
   leía nadie (`lib/candil/instances.ex:84-93`). Lo que se mide es lo que
   nadie nota.

3. **Añade un proceso que puede morir, y Candil no lo sabrá.** El sistema
   está construido para que un fallo sea ruidoso: el clasificador LLM, cuando
   está encendido y no puede, **falla** (`decision_engine.ex:225-240`). Una
   capa externa que degrada en silencio deshace esa decisión de diseño.

4. **El coste sale antes de que exista el dato.** Una inferencia de
   clasificación por petición, para ahorrar un décimo de inferencia. La
   cuenta no se puede hacer sin M5, y M5 **no está medido**.

5. **Y lo más importante: el problema puede que no sea de clasificación.** Por
   §2.6, la capa de reglas está **fíja en el código**, en inglés, apuntando a
   tres alias. Antes de pagar por una capa más, lo razonable es arreglar la
   que ya existe y mirar si el número de M2 baja. Si baja, no hace falta
   SemIf. Y esa medición cuesta un día; la integración, un mes.

### V.3 · El orden de las decisiones

```
M1 ──► ¿dormir con --sleep-idle-seconds libera VRAM?
        NO ──► F4: el temporizador de Candil, y se paga el arranque en frío (M4)
        SI ──► el flag, y F4 se reduce a reconciliación (F6)

M2 + M3 ──► ¿el default acierta?
             NO ──► el problema es la cobertura: más candidatos, mejor vocabulario (§2.6)
             SI ──► el problema es el reparto: F8, el clasificador barato

M2 + M3 + M5 ──► ¿el reparto barato se queda corto?
                   NO ──► F9 (embeddings) y ya está. F10 no se abre
                   SI ──► F9, y F10 con el dato delante
```

### V.4 · Lo que este documento **no** mide

Se dice aquí para que nadie lo dé por hecho:

- **Cualquier** tiempo de arranque en frío.
- Cuánta VRAM ocupa cada modelo **de esta** máquina. La cifra depende del
  GGUF, de la cuantización y del contexto, y no hay un número universal.
- Cuánto tarda un apagado en devolver la memoria. Un `SIGTERM` a un
  `llama-server` con 20 GB puede tardar lo que tarda el driver.
- Si `--sleep-idle-seconds` baja la VRAM. La documentación de llama.cpp dice
  «RAM» y «KV cache», y eso **no** dice nada de la VRAM.
- Cuánto cuesta de verdad una inferencia de clasificación aquí.
- Qué es SemIf.

---

## Lo que sigue

- La política de reparto entre varios clientes (round-robin justo o FIFO con
  VIP) sigue **abierta** y bloquea F11. Está anotada en `docs/README.md`.
- F10 sigue **bloqueada** hasta que existan M2, M3 y M5.
- `docs/02-orden/` es donde estas fases se ordenan con las de los otros cuatro
  módulos. Este documento no las pone en un orden global: no puede, porque no
  conoce los prerrequisitos de los otros.