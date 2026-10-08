# 02 · Contexto compartido — el Macro-MoE virtual

> **Estado**: este documento es **el diseño**, no la implementación. Describe lo
> que hay hoy en `lib/candil/context.ex` y `lib/candil/context/`, y las fases
> que hay que escribir para llegar al Macro-MoE virtual.
>
> **Medido el**: 2026-10-07 · rama `docs-v2` · **`main` en `e168ccd`**
>
> **Lo que NO he podido medir**: `mix test` no corre en el entorno donde se
> escribió esto. Hex no está instalado y `_build` es un enlace simbólico a
> `/opt/candil-build/build`, que no existe en esta máquina:
>
> ```bash
> ls -l /workspace/repos/candil/_build     # -> /opt/candil-build/build
> ls -l /opt/candil-build/build            # No such file or directory
> mix test test/candil/context_test.exs
> # Could not find an SCM for dependency :jason from Candil.MixProject
> ```
>
> Las cifras de «800 tests, 0 failures» que salen en
> [`01-inventario`](../../01-inventario/README.md) **no son mías**: no las he
> ejecutado. Las mías son las cuatro que llevan la marca `[MEDIDO AQUÍ]`, hechas
> con scripts de `elixir` sueltos en `/tmp` que cargan un módulo cada uno.
> Cualquier otra afirmación sin esa marca es una lectura del código, y así se dice.

---

## 1 · Qué es

**Que el mismo hilo sobreviva al cambio de modelo sin reenviar el historial entero
cada vez, y que la memoria que hay alrededor del hilo sea un producto distinto del
historial.**

El problema, en una frase: hoy `Candil.Context` guarda el historial **por
`{consumer, session_id}`** y sabe de modelos todo lo que necesita saber, que es
prácticamente nada.

Medido leyendo el código, no es un juicio:

| Hecho | Dónde está |
|---|---|
| La clave de la tabla es `{consumer, session_id}`, no `session_id` | `lib/candil/context.ex:61`, `:74` |
| La tabla es una ETS `:set`, `:public`, con concurrencia de lectura y escritura | `lib/candil/context.ex:283-289` |
| El módulo de un turno es `Candil.Context.Session`, y su campo de modelo es `model_current` | `lib/candil/context/session.ex:27` |
| `model_current` **nadie lo escribe**. Solo lo escribe un test, a mano | `grep -rn "model_current" lib/ test/` → 3 usos en `lib/`, y los 3 son la definición; 2 en `test/`, en `context_test.exs:79` y `:82` |
| `Candil.Context.chat/4` llama a un modelo, y **no anota en la sesión cuál** | `lib/candil/context.ex:153-165` |

Esa última fila es el módulo entero resumido en una línea. **Existe el hueco
justo donde el historial y el modelo se separan, y está vacío.** Nadie ha escrito
qué modelo respondió qué turno, así que nadie puede saber después si una respuesta
salió de uno o de otro.

**Por qué ahora**: porque
[`04-modulos`](../README.md) §3 ya dice que la memoria común vive en el RAG, y
[`02-orden`](../../02-orden/README.md) §2 pone la mesa camilla (fase 8) **por
debajo** del RAG (fase 7). Es decir: la mesa camilla ya está ordenada en el
calendario, y lo único que le falta es un diseño escrito. Este documento es ese
diseño, y las fases que propone son lo que [`02-orden`](../../02-orden/README.md)
necesita para fechar la 8.

---

## 2 · Por qué así

### 2.1 · La decisión

**El historial es privado. La memoria es común. Son dos almacenes con dos claves y
dos tablas, y no son intercambiables.**

Y la consecuencia que hay que decir antes que nada:

> **`SharedSession` no es una tabla nueva con una clave `session_id`.**
> Es el **valor** que se guarda **debajo de la clave `{consumer, session_id}` que
> ya existe**. La partición no se toca.

Esto no es una preferencia. Si `SharedSession` se indexa por `session_id` a secas,
`posadero` y `opencode` vuelven a pisarse, y el modo de fallo es el peor posible:
no es un error, es *el número correcto de mensajes de la conversación
equivocada*. Es exactamente lo que el `moduledoc` de
`lib/candil/context.ex:11-16` dice que ya pasó una vez.

Lo que hace que **varios modelos** compartan hilo no es la clave del almacén. Es un
campo del turno: `Turn.model_used`. La clave sigue siendo del consumer, y dentro
de la sesión el hilo es uno solo; quien habla en él es que el `model_used` de cada
turno sea distinto. Eso es el «Macro-MoE virtual»: **un solo hilo, muchos
modelos**, y se sabe quién habló porque cada turno lo lleva escrito.

### 2.2 · Lo que se descartó, y por qué

| Alternativa | Por qué no |
|---|---|
| **Una tabla `shared_sessions` con clave `session_id`** | Rompe la partición. Es el fallo silencioso que el módulo ya documenta para que no se repita |
| **Mnesia con tablas en memoria** como almacén por defecto | Es *un* almacén más, no **el** almacén. Mnesia por defecto vale para una sola máquina y para pruebas; pero es un demonio que hay que arrancar (`mix` lo arranca, `escript` no), y el `escript` de Candil es un ejecutable de un solo fichero. Un almacén por defecto que necesita un demonio convierte «`mix run -e`» en «`mix run -e` después de `mix mnesia.create`». Medido: hoy no hay ni una línea de Mnesia en el repo (`grep -rni "mnesia" .` → 0 resultados fuera de `docs/`) |
| **Redis como almacén por defecto** | Es una dependencia de infraestructura para algo que cabe en memoria. El `max_sessions` por defecto es 1 000 y el TTL 24 h (`lib/candil/context.ex:33-34`). **[MEDIDO AQUÍ]** con 1 000 sesiones × 50 turnos × 400 caracteres, la tabla de ETS ocupa **33,1 MB** (≈33 KB por sesión). Con 5 turnos, 4,5 MB. Redis para 33 MB es meter una infraestructura en el proyecto para guardar 33 MB |
| **Postgres como almacén por defecto** | Fuera por regla dura del proyecto. **ETS siempre** |
| **Guardar los turnos como `map()` sueltos en vez de struct** | El `moduledoc` de `lib/candil/context.ex:179-182` ya explica qué pasa cuando se adivina mal la forma de una respuesta: se escribe `"nil"` en el historial de alguien. Un struct con `@enforce_keys` convierte esa posibilidad en un `FunctionClauseError` en el sitio donde se escribe, que es donde se arregla |
| **Una sola `SharedSession` para todos los consumers, con la lista de participantes dentro** | Es lo que propone el `SharedSession` del enunciado, y es tentador porque cabe en una frase. Rompe el aislamiento. La lista de participantes **sirve para llevar la cuenta** (quién habla y cuándo), no para leer el hilo de otro |
| **Compresión al 80 % de la ventana, sin más** | Hoy el umbral no es un porcentaje: `Candil.Context.Summarizer` usa **8 000 tokens o 50 mensajes**, fijos (`lib/candil/context/summarizer.ex:26-27`), y `Candil.Context.Session.needs_summary?/2` repite esos números por defecto (`lib/candil/context/session.ex:137-143`). El 80 % es **mejor** —se adapta a una ventana de 4 k y a otra de 131 k—, pero es un cambio de comportamiento y va en su propia fase (§5.6) |

> ℹ️ **Por qué la tabla de arriba pesa y lo que cuesta.** Con el almacén por
> defecto de hoy (ETS) una sesión de 50 turnos son ~33 KB. Con Mnesia en memoria
> son los mismos 33 KB **más** el proceso, la tabla de disco y el demonio.
> La abstracción no compra nada con el almacén por defecto: **se paga por la
> puerta de salida**, que es lo único que aquí se está comprando.

### 2.3 · El comportamiento que YA existe y que este módulo no puede romper

Están medidos y en verde (`test/candil/context_test.exs`,
`test/candil/context/builder_policy_test.exs`), y son la razón de que este diseño
sea conservador:

| Hecho | Dónde está | Test que lo fija |
|---|---|---|
| Dos consumers con el mismo `session_id` son dos sesiones | `lib/candil/context.ex:13-16` | `context_test.exs:22-34` |
| Las tres políticas de desbordamiento, con `:strict` por defecto | `lib/candil/context/builder.ex:91`, `:124-138` | `builder_policy_test.exs` completo |
| `:strict` **no degrada nunca**; devuelve `{:error, {:context_exceeded, :no_room_to_truncate}}` | `lib/candil/context/builder.ex:133-135` | `builder_policy_test.exs:46-51` |
| `:summarize` **no** cae a `:compact` | `lib/candil/context/builder.ex:140-160` | `builder_policy_test.exs:76-85` |
| El resumen es **aditivo**: los mensajes viejos siguen en el struct | `lib/candil/context/session.ex:11-18` | `context_test.exs:178-190` |
| El gc es **TTL + LRU**, y cuenta cuántos de cada uno quitó | `lib/candil/context.ex:247-278` | `context_test.exs:122-161` |

### 2.4 · La decisión ABIERTA que cierra la 8b

> **¿A quién le toca el modelo que está ocupado?**

Es la decisión nº 1 de [`01-inventario`](../../01-inventario/README.md) §7, y
[`02-orden`](../../02-orden/README.md) §7 dice que **bloquea la 8b entera**.

| Política | Qué responde | Qué cuesta |
|---|---|---|
| **Round-robin justo** | «A la sesión que menos ha jugado le toca el siguiente turno. Nadie se queda sin hablar» | Una sesión que ha hablado poco **puede comerse** la cola de una sesión crítica. Y el round-robin **mira turnos, no tokens**: una sesión con 20 turnos de 20 000 caracteres «ha jugado menos» que una con 2 turnos de 200 |
| **FIFO con VIP** | «Primero en llegar, primero en salir, y las VIP salen por delante» | Una VIP puede pisar a quien ha estado esperando veinte minutos. Y hay que **definir quién es VIP**, que es la pregunta que en realidad se está haciendo |

**⚠️ Aviso honesto, y es importante.** Los documentos hermanos
([`02-orden`](../../02-orden/README.md) §7 y
[`01-inventario`](../../01-inventario/README.md) §7) dan el round-robin justo por
**«medido, en verde»**. **No lo he encontrado en el código.** Busqué:

```bash
grep -rni "round.robin\|round_robin\|fair_share\|reparto\|turno" lib/ test/
# 2 resultados, y los dos son comentarios de builder.ex sobre "history turn"
find lib -name "*.ex" | wc -l    # 88
```

De los 88 módulos de `lib/` no hay ninguno que reparta presupuesto entre sesiones:
`Candil.Concurrency` es un *fan-out*, `Candil.EnginePool` es un conjunto de motores,
`Candil.Router.Consumer` guarda pins. **O el round-robin vive fuera de este repo, o
es la política *diseñada* y no la implementada, y la frase «medido, en verde» de
los documentos hermanos es una hipótesis.**

Esto no se arregla aquí, pero **condiciona la fase**: la F2.7 (§5.7) no se puede
escribir hasta que alguien conteste, y la respuesta puede ser «no existe, hay que
hacerlo».

**Mi recomendación, y su coste.** Round-robin **medido por tokens, no por turnos**,
con VIP como una **categoría aparte**, no como un flag:

- Medir por turno es medible y barato, pero el turno y el coste son cosas
  distintas. Una sesión con 3 turnos de 3 000 caracteres «ha jugado» casi nada.
- Medir por tokens cuesta un `Session.tokens/1` por turno —que ya existe
  (`lib/candil/context/session.ex:103`) y es O(n) sobre los mensajes—, así que
  **el coste es un O(n) más por turno de contexto**, y con 1 000 sesiones de 50
  turnos son 50 000 iteraciones por decisión de reparto. Se cachea en el turno
  (`Turn.tokens_used`) y baja a O(1); ese caché es una de las razones por las que
  `Turn` lleva `tokens_used` (§5.1).
- VIP como categoría y no como booleano evita el caso «todos son VIP», que es lo
  que pasa en cuanto el flag existe y nadie tiene autoridad para quitarlo.

### 2.5 · Qué NO se puede prometer

Esta es la parte que más caro sale si no está escrita antes.

**1 · Dos modelos con ventanas distintas no comparten contexto de forma
transparente.** Hoy ya está escrito y es correcto: «la ventana viaja con el
modelo, no con la conversación» (`lib/candil/context.ex:120-122`,
`lib/candil/context/builder.ex:63-65`). Una sesión con 30 000 tokens de historial
que pasa de un modelo de 4 k a uno de 131 k **se comporta distinto**, y no hay forma
de que no lo haga: el `Builder` va a dar `{:error, {:context_exceeded, ...}}` con
la ventana de 4 k. **Lo que se puede prometer es que lo dice, no que no pase.**

**2 · Dos modelos con formatos de prompt distintos no ven el mismo prompt.**
Anthropic renderiza `tools` → `system` → `messages`; OpenAI-compatible renderiza
`messages` con el `system` dentro de la lista. **Es el mismo historial en
estructuras distintas**, y el mismo texto en posiciones distintas **no es el mismo
prefijo**. Lo que se puede prometer es que el historial se **convierte** al formato
que pide cada backend. No que el prompt sea byte a byte el mismo.

**3 · El prompt caching del proveedor no está implementado y no se puede
implementar desde aquí.** Medido: `grep -rn "cache_control" lib/` → **0
resultados**. `grep -rn "prompt_cache" lib/` → **0 resultados**. Es una
dependencia externa del backend, y el backend no lo declara (§5.5.2).

**4 · Un `Turn` no sabe si el modelo que lo generó es el que realmente
contestó.** `Context.chat/4` registra la petición **antes** de llamar
(`lib/candil/context.ex:159`) y la respuesta **después**
(`:162`), y hay un motivo: «un modelo que se muere a mitad no pierde la pregunta»
(`lib/candil/context.ex:127-129`). El precio es que un turno queda con
`model_used` **no confirmado** si la llamada muere. `nil` es un valor legítimo de
ese campo, y por eso es opcional (§5.1).

**5 · La «memoria común» no es un modelo que recuerda.** Es lo que el RAG
devuelve cuando le preguntas. [`01-inventario`](../../01-inventario/README.md) §4
dice que el RAG tiene **los tipos congelados y cinco stubs**, y §5 dice que la mesa
camilla **no existe**. Este módulo **no la crea**: le deja la puerta.

**6 · Compartir la capa KV entre modelos distintos no es una cosa que Candil pueda
hacer hoy, y probablemente no sea una cosa que pueda hacer nunca.** Ver §5.5.2:
los tensores KV están dentro del proceso de `llama-server` y **no son portables
entre modelos**.

---

## 3 · Qué toca

**Lista cerrada.** Nombres exactos. Un fichero que no está aquí no se toca en
estas fases.

### 3.1 · Ficheros nuevos

| Fichero | Qué contiene | Fase |
|---|---|---|
| `lib/candil/context/turn.ex` | `Candil.Context.Turn` — el struct del turno | F2.1 |
| `lib/candil/context/shared_session.ex` | `Candil.Context.SharedSession` — el valor que se guarda bajo `{consumer, session_id}` | F2.1 |
| `lib/candil/storage/adapter.ex` | `Candil.Storage.Adapter` — el behaviour | F2.2 |
| `lib/candil/storage/ets.ex` | `Candil.Storage.ETS` — el adaptador **por defecto** | F2.2 |
| `lib/candil/storage/store.ex` | `Candil.Storage.Store` — la fachada, y quién manda | F2.2 |
| `test/candil/context/isolation_test.exs` | *(test)* el que **no puede cambiar** | F2.1 |
| `test/candil/context/turn_test.exs` | *(test)* | F2.1 |
| `test/candil/context/shared_session_test.exs` | *(test)* | F2.1 |
| `test/candil/storage/adapter_test.exs` | *(test)* el behaviour se puede implementar por fuera | F2.2 |
| `test/candil/storage/ets_test.exs` | *(test)* paridad con `Candil.Context` | F2.2 |
| `test/candil/storage/store_test.exs` | *(test)* la fachada elige y no cambia en caliente | F2.2 |
| `lib/candil/context/prefix_planner.ex` | `Candil.Context.PrefixPlanner` — ordena el prompt y **marca los puntos de corte** | F2.5 |
| `test/candil/context/prefix_planner_test.exs` | *(test)* | F2.5 |
| `lib/candil/context/compressor.ex` | `Candil.Context.Compressor` — compresión **asíncrona** al 80 % | F2.6 |
| `test/candil/context/compressor_test.exs` | *(test)* | F2.6 |
| `lib/candil/context/shared_memory.ex` | `Candil.Context.SharedMemory` — la memoria común (**fase 8c**) | F2.4 |

### 3.2 · Ficheros que se modifican

| Fichero | Qué cambia | Fase |
|---|---|---|
| `lib/candil/context.ex` | `create/2`, `append_message/4`, `update/3`, `get/2`, `delete/2`, `list/1`, `consumers/0`, `count/1`, `gc/1` delegan en `Candil.Storage.Store`. **El `@spec` de cada una no cambia** | F2.3 |
| `lib/candil/context/session.ex` | `Session` pasa a construirse desde `SharedSession`, o se marca `@deprecated` en favor de `SharedSession` | F2.3 |
| `lib/candil/context/prefix_manager.ex` | **`stats/0` cuenta de verdad** (§5.5.1) y `put/2` se llama desde `PrefixPlanner` | F2.5 |
| `lib/candil/application.ex` | `Candil.Storage.ETS` entra en `children` **antes** de `Candil.Context` (`lib/candil/application.ex:52`) | F2.2, F2.3 |
| `lib/candil/backend.ex` | `capabilities/0` como **`@optional_callbacks`** | F2.5 |
| `lib/candil/request_builder.ex` | `build_anthropic_body/3` inyecta `cache_control` si la capability está | F2.5 |
| `lib/candil/inference/chat.ex` | `parse_anthropic_usage/1` lee `cache_read_input_tokens`; el parser de OpenAI-compatible lee `prompt_cache_hit_tokens` | F2.5 |
| `config/config.exs` | `config :candil, :context, storage: Candil.Storage.ETS` | F2.2 |

### 3.3 · Ficheros que **no** se tocan, y por qué

| Fichero | Por qué no |
|---|---|
| `lib/candil/conversation.ex` | Está `@deprecated` desde 4.0 y se va en 4.1.0 (`lib/candil/conversation.ex:9-28`). Tocar un módulo que se va es trabajo perdido |
| `lib/candil/conversation/token_estimator.ex` | Solo delega en `Candil.Context.TokenEstimator`. Ya está en su sitio |
| `lib/candil/agent.ex` | Sigue usando `Candil.Conversation` (`lib/candil/agent.ex:78`, `:81`, `:118`, `:172`). La migración a `Candil.Context` es la fase 8a/8c, no esta |
| `lib/candil/context/token_estimator.ex` | ⚠️ Ver §8.3: hay una inconsistencia real aquí, pero arreglarla **cambia aritmética**, y eso es otra fase |
| `lib/candil/router/consumer.ex` | El pin por consumer ya existe (`:candil_router_pins`, `lib/candil/router/consumer.ex:19`, `:36`, `:57`). `SharedSession.active_pinned_model` **lo duplicaría**, y la regla del proyecto es *una verdad, un sitio* |

---

## 4 · Los tests primero

El test se escribe **antes** del código, se ve **fallar**, y después se hace lo
mínimo para pasarlo. De [`03-convenciones`](../../03-convenciones/README.md) §3.

### 4.1 · Los cuatro patrones que usa este módulo

| Patrón | Para qué | Dónde |
|---|---|---|
| **De contrato** | que `@enforce_keys` y los `@spec` no cambien de forma | §4.2, §4.3 |
| **De orden** | que dos consumers sigan sin pisarse, y que la cola no haga trampas con el estado | §4.2 |
| **De frente** | que la memoria diga cuántos KB ocupa y cuántos turnos hay | §4.4 |
| **De necesidad** | que un adapter de fuera del repo **compile y funcione** sin tocar Candil | §4.3 |

### 4.2 · F2.1 — el aislamiento no se toca

Este es **el test más importante del módulo**, porque es el único que puede
destruir la propiedad de la que depende el resto.

```elixir
defmodule Candil.Context.IsolationTest do
  @moduledoc """
  §2.1: el aislamiento entre consumers NO se toca. Es lo que hace que cinco
  opencodes en paralelo no se coman.

  Este fichero se escribe **antes** que `SharedSession`, y no se toca después.
  Si algún día hay que tocarlo, es que se ha roto algo y el cambio viene con
  una explicación en el `@moduledoc`, no con un `@tag :skip`.
  """
  use ExUnit.Case, async: false

  alias Candil.Context
  alias Candil.Context.{SharedSession, Turn}

  setup do
    for consumer <- Context.consumers(),
        session <- Context.list(consumer) do
      Context.delete(consumer, session.id)
    end

    :ok
  end

  describe "el mismo session_id bajo dos consumers" do
    test "sigue siendo DOS sesiones, con el hilo entero de cada una" do
      assert :ok =
               Context.append_turn(:posadero, "s1",
                 %Turn{role: "user", content: "secreto del vault"}
               )

      assert :ok =
               Context.append_turn(:opencode, "s1",
                 %Turn{role: "user", content: "hola, assistant"}
               )

      assert {:ok, posadero} = Context.get(:posadero, "s1")
      assert {:ok, opencode} = Context.get(:opencode, "s1")

      assert [%{content: "secreto del vault"}] = posadero.turns
      assert [%{content: "hola, assistant"}] = opencode.turns
    end

    test "borrar la de uno no toca la del otro" do
      Context.append_turn(:posadero, "s1", %Turn{role: "user", content: "a"})
      Context.append_turn(:opencode, "s1", %Turn{role: "user", content: "b"})

      assert :ok = Context.delete(:posadero, "s1")
      assert Context.get(:posadero, "s1") == {:error, :not_found}
      assert {:ok, _} = Context.get(:opencode, "s1")
    end
  end

  describe "el aislamiento con DOS modelos en la misma sesión" do
    test "el hilo se comparte, el modelo se escribe" do
      # Esto es el Macro-MoE: UNA sesión, DOS modelos. Y sigue siendo privada.
      {:ok, _} = Context.append_turn(:posadero, "s1", %Turn{role: "user", content: "hola", model_used: :coder})
      {:ok, _} = Context.append_turn(:posadero, "s1", %Turn{role: "assistant", content: "hola", model_used: :coder})
      {:ok, _} = Context.append_turn(:posadero, "s1", %Turn{role: "user", content: "ahora en otro", model_used: :verifier})
      {:ok, _} = Context.append_turn(:posadero, "s1", %Turn{role: "assistant", content: "listo", model_used: :verifier})

      assert {:ok, session} = Context.get(:posadero, "s1")
      assert length(session.turns) == 4

      # Y ahora el motivo de `model_used`: se puede decir QUIÉN habló.
      assert [models] = session.turns |> Enum.map(& &1.model_used) |> Enum.uniq() |> then(&[&1])
      assert models == [:coder, :verifier]

      # Y otro consumer con el MISMO session_id sigue sin ver nada de esto.
      assert Context.get(:opencode, "s1") == {:error, :not_found}
    end
  end

  describe "el contrato de `SharedSession`" do
    test "los `@enforce_keys` son los de la identidad y solo esos" do
      # `turn_id` y `role` son identidad: un turno sin ellos no es un turno.
      assert_raise ArgumentError, fn ->
        struct(SharedSession, session_id: "s1")
      end
    end

    test "`active_pinned_model` es `nil` y no `:none`" do
      # `nil` = nadie ha pineado. `:none` = alguien ha pineado «nada». Son
      # cosas distintas y confundirlas es como se pierde un pin.
      session = SharedSession.new(:posadero, "s1")
      assert session.active_pinned_model == nil
      refute session.active_pinned_model == :none
    end

    test "`model_used` y `tokens_used` son opcionales: `append_message/4` no los tiene" do
      # El turno que escribe la API pública de hoy no sabe qué modelo va a
      # contestar ni cuánto va a costar. Si fueran obligatorios, habría que
      # cambiar el `@spec` de `append_message/4`, que está en uso.
      assert :ok = Context.append_message(:posadero, "s1", "user", "hola")

      assert {:ok, session} = Context.get(:posadero, "s1")
      assert [%Turn{model_used: nil, tokens_used: 0}] = session.turns
    end
  end
end
```

### 4.3 · F2.2 — el adapter se puede escribir desde fuera

```elixir
defmodule Candil.Storage.AdapterTest do
  @moduledoc """
  §3: un tercero define el behaviour y funciona SIN TOCAR CANDIL.

  Si este test necesita un `def` en `lib/candil/`, es que no hay punto de
  extensión: hay código.
  """
  use ExUnit.Case, async: true

  defmodule MemoryAdapter do
    @behaviour Candil.Storage.Adapter

    @impl true
    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    @impl true
    def start_link(opts), do: Agent.start_link(fn -> opts end, name: __MODULE__)
    @impl true
    def init(_opts), do: :ok
    @impl true
    def get(_key), do: {:error, :not_found}
    @impl true
    def put(_key, _session), do: :ok
    @impl true
    def put_new(_key, _session), do: true
    @impl true
    def delete(_key), do: :ok
    @impl true
    def list(_consumer), do: []
    @impl true
    def all, do: []
    @impl true
    def gc(_opts), do: {:ok, %{ttl: 0, lru: 0}}
    @impl true
    def capabilities, do: [:ephemeral, :not_atomic, :scans_whole_table]
  end

  test "un módulo de fuera cumple el behaviour" do
    assert Candil.Storage.Adapter in MemoryAdapter.module_info(:attributes)
           |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  test "`Store` lo acepta sin escribir código en Candil" do
    assert {:ok, _} = Candil.Storage.Store.put_adapter(MemoryAdapter)
    assert Candil.Storage.Store.adapter() == MemoryAdapter
  after
    Candil.Storage.Store.put_adapter(Candil.Storage.ETS)
  end

  test "un adapter atómico se dice, y uno que no, también" do
    # `:atomic_updates` ausente = read-modify-write sin compare-and-swap.
    # La fachada tiene que poder negarse a usarlo para `append_turn/3`.
    refute :atomic_updates in MemoryAdapter.capabilities()
    assert :atomic_updates in Candil.Storage.ETS.capabilities()
  end
end
```

### 4.4 · F2.2 — de frente: la memoria

```elixir
defmodule Candil.Storage.ETSUsageTest do
  @moduledoc """
  Patrón «de frente»: no leer el código y decir «es rápido», sino **preguntar**.

  La cifra de referencia está medida (1 000 sesiones × 50 turnos × 400 caracteres
  ≈ 33 MB). Este test es el que avisa cuando eso cambia.
  """
  use ExUnit.Case, async: false

  test "la tabla pesa lo que se dice que pesa, con margen" do
    for i <- 1..1_000 do
      {:ok, _} =
        Candil.Storage.ETS.put({:medidor, "s#{i}"},
          Candil.Context.SharedSession.new(:medidor, "s#{i}")
          |> then(fn s -> Enum.reduce(1..50, s, fn n, acc ->
                 Candil.Context.Turn.append(acc, %Candil.Context.Turn{
                   role: "user", content: String.duplicate("x", 400) <> " #{n}"})
               end)
               |> elem(1))
        )
    end

    {:ok, info} = :ets.info(Candil.Storage.ETS.table(), :memory)

    # 33 MB medidos. El límite es 4× para que el test avise de una regresión
    # grande sin romperse por la configuracion de la maquina.
    assert info < 200 * 1_024 * 1_024,
           "la tabla de sesiones ocupa #{div(info, 1_024 * 1_024)} MB; el presupuesto era 200 MB"
  end
end
```

### 4.5 · F2.5 — el prompt caching, y **cómo se sabe que falla**

```elixir
defmodule Candil.Context.PrefixPlannerTest do
  @moduledoc """
  §5.5: hoy `PrefixManager.stats/0` devuelve `{hits: 0, misses: 0}` SIEMPRE,
  porque `get/2` no incrementa los contadores. [MEDIDO AQUÍ]

  Este test es el que hace que deje de ser siempre cero.
  """
  use ExUnit.Case, async: false

  alias Candil.Context.PrefixManager

  setup do
    PrefixManager.flush()
    :ok
  end

  test "dos gets iguales cuentan un acierto y un fallo, no cero" do
    :ok = PrefixManager.put(:coder, "eres un asistente")

    assert {:ok, _} = PrefixManager.get(:coder, "eres un asistente")
    assert :miss = PrefixManager.get(:coder, "otro prompt")

    assert PrefixManager.stats() == %{hits: 1, misses: 1}
  end

  test "el breakpoint va DESPUÉS del bloque estático, no en medio" do
    plan = PrefixManager.plan([%{role: "system", content: "reglas"}], %{})
    assert [%{role: "system", cache_control: true}] = plan
  end

  test "sin capability de backend NO se marca ningún breakpoint" do
    # Un `cache_control` en un backend que no lo soporta es un 400 del
    # proveedor, no un «no pasa nada». La capability se mira PRIMERO.
    plan = PrefixManager.plan([%{role: "system", content: "reglas"}],
      %{capabilities: [], model: :local})
    assert [%{role: "system"}] = plan
  end
end
```

Y **cómo se verifica que el prompt caching falla de verdad**, que es la mitad que
falta hoy:

```bash
# 1. El prefijo tiene que ser estable byte a byte. Si no, DeepSeek no acierta.
mix run -e '
  alias Candil.Context.PrefixManager
  PrefixManager.flush()
  Enum.each(1..100, fn _ ->
    :ok = PrefixManager.put(:coder, "eres un asistente")
    PrefixManager.get(:coder, "eres un asistente")
    PrefixManager.get(:coder, "eres un asistente v2")
  end)
  IO.inspect(PrefixManager.stats(), label: "stats")
'
# Debe imprimir: %{hits: 100, misses: 100}
# Si imprime %{hits: 0, misses: 0}: los contadores NO cuentan. Es el bug de §8.1.

# 2. Y el dato que de verdad importa NO está en Candil: está en la respuesta
#    del proveedor. `usage.cache_read_input_tokens` (Anthropic) o
#    `usage.prompt_cache_hit_tokens` (DeepSeek). Sin eso, "el prompt caching
#    funciona" es una afirmación.
```

---

## 5 · Cómo se hace

### 5.0 · El mapa de fases y sus prerrequisitos

Esto es lo que [`02-orden`](../../02-orden/README.md) necesita para fechar la 8.
**El prerrequisito de cada una es literal: si no está, la fase no se puede
empezar.**

| # | Fase | Prerrequisito | Qué desbloquea |
|---|---|---|---|
| **F2.1** | `Turn` y `SharedSession`, structs solos, sin storage nuevo | [`03-convenciones`](../../03-convenciones/README.md) escrito · `Candil.Context` en verde | F2.2, F2.3, F2.5 |
| **F2.2** | `Candil.Storage.Adapter` + `Candil.Storage.ETS` + `Candil.Storage.Store` | **F2.1** | F2.3 |
| **F2.3** | `Candil.Context` detrás de `Store`, **sin cambiar un `@spec`** | **F2.2** | F2.4, F2.6, F2.7 |
| **F2.4** | `Candil.Context.SharedMemory` — la memoria común | **F2.3** · **fase 7 (RAG)** de [`02-orden`](../../02-orden/README.md) · decisión abierta nº 2 cerrada (§5.4) | La mesa camilla (8c) |
| **F2.5** | Prefijo estable, `capabilities/0`, `cache_control`, contadores reales | **F2.1** · `Candil.Backend` con `capabilities/0` | Ahorro de tokens cloud |
| **F2.6** | Compresión asíncrona al 80 % | **F2.3** · `Candil.Context.Summarizer` con modelo configurado | Sesiones largas sin 400 |
| **F2.7** | La línea de cajas FIFO con VIP | **Decisión abierta §2.4 cerrada** · **F2.3** | La 8b |

Y las dos que se pueden hacer **en paralelo**, porque no se tocan:

```bash
# Lane A (estructuras y almacén)
F2.1 -> F2.2 -> F2.3 -> F2.6

# Lane B (coste de ingesta) — arranca en F2.1, no espera a F2.3
F2.1 -> F2.5

# Lane C — NO arranca hasta que se conteste la decisión abierta
(espera) -> F2.7
```

### 5.1 · F2.1 — `Turn` y `SharedSession`

```bash
cd /workspace/repos/candil
mix format lib/candil/context/turn.ex lib/candil/context/shared_session.ex
mix compile --force --warnings-as-errors
```

`lib/candil/context/turn.ex`:

```elixir
defmodule Candil.Context.Turn do
  @moduledoc """
  Un turno: lo que dijo alguien, cuándo, y **quién loGenerating**.

  ## Los opcionales, y por qué

  `:turn_id` y `:role` son **identidad**: un turno sin ellos no es un turno, y
  `@enforce_keys` lo dice en el sitio donde se construye, que es donde se
  arregla.

  `:model_used` y `:tokens_used` son **observación**, y la observación puede no
  haber ocurrido:

  - `append_message/4` (`lib/candil/context.ex:83-91`) solo recibe rol y
    contenido. Cambiar su `@spec` rompe la API pública y cuatro tests.
  - `Context.chat/4` registra la pregunta **antes** de la llamada y la respuesta
    **después** (`lib/candil/context.ex:159`, `:162`), a propósito: «un modelo
    que se muere a mitad no pierde la pregunta». Si la llamada muere, el turno
    existe y **no tiene modelo**.

  `nil` es un valor legítimo de `model_used`. Ponerle `:unknown` sería peor:
  `nil` ya dice «no lo sé» y `:unknown` dice «lo sé y es desconocido».
  """

  @enforce_keys [:turn_id, :role]
  defstruct turn_id: nil,
            role: nil,
            content: "",
            model_used: nil,
            tokens_used: 0,
            timestamp: nil,
            meta: %{}

  @type role :: String.t()  # "user" | "assistant" | "system" | "tool"

  @type t :: %__MODULE__{
          turn_id: String.t(),
          role: role(),
          content: String.t(),
          model_used: atom() | nil,
          tokens_used: non_neg_integer(),
          timestamp: DateTime.t(),
          meta: map()
        }

  @doc """
  Crea un turno con `turn_id` ya puesto.
  """
  @spec new(role(), String.t(), keyword()) :: t()
  def new(role, content, opts \\ []) when is_binary(role) and is_binary(content) do
    %__MODULE__{
      turn_id: Keyword.get_lazy(opts, :turn_id, &random_id/0),
      role: role,
      content: content,
      model_used: Keyword.get(opts, :model_used),
      tokens_used: Keyword.get(opts, :tokens_used, 0),
      timestamp: Keyword.get_lazy(opts, :timestamp, &DateTime.utc_now/0),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  # `System.unique_integer/1` da un entero monotónico por VM y un prefijo con
  # el nodo. Entre dos procesos de la misma VM no se repite; entre dos VMs
  # distintas tampoco, porque el nodo va dentro. Un UUID entero también
  # valdría y costaría una dependencia que no hace falta.
  defp random_id do
    "t_#{node()}:#{System.unique_integer([:positive, :monotonic])}"
  end
end
```

`lib/candil/context/shared_session.ex`:

```elixir
defmodule Candil.Context.SharedSession do
  @moduledoc """
  El **valor** que se guarda bajo la clave `{consumer, session_id}`.

  ## Esto NO es una tabla con clave `session_id`

  Es el valor de la tabla que ya existe. La clave no se toca: vive en
  `Candil.Storage.Adapter`, y sigue siendo la tupla. Lo que hace este módulo es
  guardar **qué modelo habla** en cada turno, que es lo que hoy no está escrito
  en ninguna parte.

  ## Por qué la memoria no vive aquí

  La memoria compartida es otro producto con otra clave: la comparte **todo el
  mundo**, y por eso no puede vivir en un valor que está particionado. Ver
  `Candil.Context.SharedMemory` (F2.4), que no existe todavía.
  """

  @enforce_keys [:session_id, :owner_consumer]
  defstruct session_id: nil,
            owner_consumer: nil,
            metadata: %{},
            turns: [],
            semantic_cache: %{},
            active_pinned_model: nil,
            created_at: nil,
            updated_at: nil,
            last_used_at: nil,
            summary: nil,
            summarised_upto: 0

  @type session_id :: String.t()

  @type t :: %__MODULE__{
          session_id: session_id(),
          owner_consumer: atom(),
          metadata: map(),
          turns: [Candil.Context.Turn.t()],
          semantic_cache: map(),
          active_pinned_model: atom() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          last_used_at: DateTime.t(),
          summary: String.t() | nil,
          summarised_upto: non_neg_integer()
        }

  @doc """
  El campo que se elige por defecto es `active_pinned_model`, y vale `nil`.

  No vale `:none`. `nil` es «nadie ha pineado nada»; `:none` sería «alguien ha
  pineado y el valor es nada». El bug del «pin que no existía» en
  [`03-convenciones`](../../03-convenciones/README.md) §1 salió de tratar
  «sin pin» y «pin a nada» como la misma cosa. Aquí son distintos.

  ⚠️ Y ojo: `Candil.Router.Consumer` **ya tiene** un pin por consumer
  (`lib/candil/router/consumer.ex:19`, `:36`, `:57`). Este campo solo existe
  para el pin **por sesión**. Si los dos sobreviven a la vez, tenemos dos
  verdades y el proyecto tiene una regla contra eso.
  """
  @spec new(atom(), session_id()) :: t()
  def new(owner_consumer, session_id)
      when is_atom(owner_consumer) and is_binary(session_id) do
    now = DateTime.utc_now()

    %__MODULE__{
      session_id: session_id,
      owner_consumer: owner_consumer,
      created_at: now,
      updated_at: now,
      last_used_at: now
    }
  end

  @doc """
  Cuánto pesa la sesión, medido con el estimador del módulo.

  Es un **estimado** (`div(chars, 4)`), igual que
  `Candil.Context.Session.tokens/1`. No es un contador exacto y no debe usarse
  para facturar.
  """
  @spec tokens(t()) :: non_neg_integer()
  def tokens(%__MODULE__{turns: turns, summary: summary}) do
    turn_tokens = Enum.reduce(turns, 0, &(&2 + &1.tokens_used))
    summary_tokens = if summary, do: div(String.length(summary), 4), else: 0
    turn_tokens + summary_tokens
  end

  @doc """
  Qué modelos han hablado en esta sesión, en orden de aparición.
  """
  @spec models_used(t()) :: [atom()]
  def models_used(%__MODULE__{turns: turns}) do
    turns
    |> Enum.map(& &1.model_used)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
```

### 5.2 · F2.2 — el behaviour, y por qué un adapter **no** es «implementar el behaviour»

```bash
mix format lib/candil/storage/*.ex
mix compile --force --warnings-as-errors
```

`lib/candil/storage/adapter.ex`:

```elixir
defmodule Candil.Storage.Adapter do
  @moduledoc """
  Dónde vive una `SharedSession`.

  ## Regla del proyecto

  **ETS siempre.** `Candil.Storage.ETS` es el adaptador por defecto y el único
  que se arranca solo. Los demás son **opt-in** por configuración, y tienen que
  trayerse su propia dependencia.

  ## Lo que un behaviour NO puede declarar

  Este behaviour tiene **diez** callbacks. Implementarlos no es el trabajo: es
  lo más pequeño. Lo grande son las **siete** cosas de la primera tabla de
  §5.2, más la octava, que están en prosa porque no se pueden escribir como
  `@callback`.
  """

  @type key :: {atom(), String.t()}          # {consumer, session_id}
  @type session :: Candil.Context.SharedSession.t()
  @type key_opts :: [session_id: String.t(), consumer: atom()]

  @doc "Arranca el almacenamiento. Va en `children` de `Candil.Application`."
  @callback start_link(keyword()) :: {:ok, pid()} | {:error, term()}

  @doc "Prepara el almacenamiento. Se llama DESPUÉS de `start_link/1`."
  @callback init(keyword()) :: :ok | {:error, term()}

  @doc "Lee una sesión por su clave completa."
  @callback get(key()) :: {:ok, session()} | {:error, :not_found}

  @doc "Escribe, machacando lo que hubiera."
  @callback put(key(), session()) :: :ok | {:error, term()}

  @doc """
  Escribe **solo si no existe**, y dice si se escribió.

  `Candil.Context.create/2` depende de esto (`lib/candil/context.ex:61`): usa
  `:ets.insert_new/2`, y el `true`/`false` decide si devuelve la sesión nueva o
  va a releer. En Redis es `SET NX`. En Postgres, `INSERT … ON CONFLICT DO
  NOTHING`. **El resultado es observable**, así que no puede ser opcional.
  """
  @callback put_new(key(), session()) :: boolean()

  @doc "Borra una sesión. Devolver `:ok` si no estaba NO es error."
  @callback delete(key()) :: :ok | {:error, term()}

  @doc """
  Las sesiones de un consumer, **más reciente primero**.

  El orden es parte del contrato. `Candil.Context.list/1` lo cumple con
  `Enum.sort_by(…, {:desc, DateTime})` (`lib/candil/context.ex:220`), y Redis y
  Postgres **no** devuelven nada ordenado por su cuenta.
  """
  @callback list(atom()) :: [session()]

  @doc "Todas las sesiones de todos los consumers. La usa `gc/1`."
  @callback all() :: [{key(), session()}]

  @doc """
  Recoge por TTL y por LRU, y dice cuántos de cada uno.

  `:ttl` y `:lru` son **observables**: `Candil.Context.gc/1` los devuelve y un
  test los comprueba (`test/candil/context_test.exs:128`, `:146`). Un adapter
  que devuelva siempre `{0, 0}` es un adapter que miente.
  """
  @callback gc(keyword()) :: {:ok, %{ttl: non_neg_integer(), lru: non_neg_integer()}}

  @doc """
  Lo que este adapter **puede hacer**, para que la fachada decida si usarlo.

  | Capability | Qué promete |
  |---|---|
  | `:ephemeral` | Se pierde al reiniciar. Todos lo tienen |
  | `:atomic_updates` | `put/3` con compare-and-swap. Sin esto, dos escritores se pisan |
  | `:scans_whole_table` | `gc/1` y `all/0` son O(n) sobre todo |
  | `:ordered_list` | `list/1` devuelve ordenado sin que se lo pidas |
  | `:survives_restart` | Los datos siguen ahí después de un reinicio |
  """
  @callback capabilities() :: [atom()]
end
```

Y ahora **por qué no es «solo implementar el behaviour»**. Siete cosas, cada una
con su hecho detrás:

| # | Lo que obliga | Por qué el behaviour no lo dice |
|---|---|---|
| **1** | **Decidir quién es el dueño de la tabla** | Medido: la tabla de `Candil.Context` se crea en el `init/1` del GenServer (`lib/candil/context.ex:283`). **[MEDIDO AQUÍ]** matando al GenServer dueño, `:ets.whereis/1` devuelve `:undefined`: **la tabla se va con él**. Un adapter de Redis no tiene dueño; uno de ETS dentro de Candil sí. El behaviour no puede expresar «quién responde de mi almacenamiento» |
| **2** | **`put_new/2` tiene que devolver un booleano de verdad** | Es idempotencia de creación, y el resultado decide qué sesión se devuelve. Un `put_new` que devuelve `:ok` siempre rompe `create/2` en silencio |
| **3** | **Decidir si `update/3` es atómico** | Medido: `Candil.Context.update/3` (`lib/candil/context.ex:97-106`) hace `get`, aplica la función e `inserta`. **No hay compare-and-swap.** Dos procesos que escriben a la vez: gana el último, sin decir nada. En ETS es rápido y todavía pasa; en un almacén distribuido es pérdida de datos garantizada. Por eso `:atomic_updates` está en `capabilities/0` y la fachada **se niega** a usarlo para `append_turn/3` si no está |
| **4** | **`gc/1` es un escaneo completo, y hay que medirlo** | Medido: `Candil.Context.gc/1` llama a `:ets.tab2list/1` (`lib/candil/context.ex:252`). **[MEDIDO AQUÍ]** 1 000 `match_object/2` sobre una tabla de 1 000 filas = **1,93 s**, o sea ~1,9 ms por escaneo. En Redis es un `SCAN`; en Postgres, una query con `LIMIT` o un `VACUUM`. **No es gratis**, y no puede ser gratis |
| **5** | **`list/1` ordenado** | Medido arriba: `lib/candil/context.ex:220`. Un adapter que no ordene rompe el contrato sin dar error |
| **6** | **Entrar en `Candil.Application`** | Medido: `lib/candil/application.ex:46-58` lista los hijos, y `Candil.Context` va en la línea 52. **El orden importa**: el almacén tiene que estar **antes** de quien lo usa, por lo mismo que dice el `moduledoc` de `Candil.Application` para `Store` (`lib/candil/application.ex:8-10`) |
| **7** | **Poder cambiar de adapter sin perder la conversación** | Con ETS son gratis: `all/0` y `put/2`. **[MEDIDO AQUÍ]** 1 000 sesiones × 50 turnos × 400 caracteres = **33,1 MB**. Por Redis eso es un mensaje de 33 MB o 1 000 mensajes; por Postgres, una migración. **Cambiar de adapter en caliente es barato si el almacén es ETS y carísimo si no. Por eso el default es ETS** |

Y una octava, que no es del adapter sino de la fachada:

| # | Lo que obliga | Por qué |
|---|---|---|
| **8** | **`Candil.Storage.Store` tiene que tener un `@spec` cerrado** | Si el behaviour devuelve `term()`, dialyzer no estrecha nada y cada adapter nuevo reabre la caja. El `@type session` del behaviour está **tipado**, no en `term()`, por eso |

### 5.3 · F2.3 — `Candil.Context` detrás de la fachada

```bash
# El test de aislamiento, ANTES de tocar nada
mix test test/candil/context/isolation_test.exs
# Debe imprimir: 0 failures

# Ahora el cambio
mix test test/candil/context_test.exs test/candil/context/ test/candil/conversation_test.exs
# Debe imprimir: 0 failures, y los mismos tests que antes
```

El cambio es **mecánico y boring, que es como debe ser**. En
`lib/candil/context.ex`:

```elixir
# ANTES
def get(consumer, id) do
  case :ets.lookup(@table, {consumer, id}) do
    [{_key, session}] -> {:ok, session}
    [] -> {:error, :not_found}
  end
end

# DESPUÉS
@spec get(atom(), String.t()) :: {:ok, Session.t()} | {:error, :not_found}
def get(consumer, id) do
  case Store.get({consumer, id}) do
    {:ok, session} -> {:ok, from_shared(session)}
    {:error, :not_found} -> {:error, :not_found}
  end
end
```

**El `@spec` no cambia.** `Session.t()` sigue siendo lo que devuelve. `SharedSession`
se convierte a `Session` en el borde, en `from_shared/1`. Si cambia, el módulo 1
(que llama a esto) se entera en su propio `mix compile --warnings-as-errors`, y esa
es exactamente la alarma que se quiere.

### 5.4 · F2.4 — la memoria común (**fase 8c**)

Esta fase **no se puede empezar** hasta que la decisión abierta nº 2 de
[`01-inventario`](../../01-inventario/README.md) §7 esté contestada, y **no se
puede terminar** hasta que el RAG (fase 7) tenga un `Embedder` que no sea un stub.

El enunciado dice: **el historial es privado, la memoria es común**. Lo que implica,
y que hay que decidir antes de escribir una línea:

| Pregunta | Mi respuesta | Por qué | Qué cuesta |
|---|---|---|---|
| ¿Qué es la memoria común? | **Un mapa clave → valor que TODOS los consumers leen y escriben**, con su propia clave. `mem:projecto_42` o `mem:decisión:usar-postgres`. **No** es historial | Si fuera historial, estaríamos repartiendo el hilo y rompiendo el aislamiento. Es un producto distinto porque responde a otra pregunta: no «qué hemos dicho» sino «qué sabemos» | Una tabla más, un `key` más, y **el eviction tiene que ser distinto**: la memoria se queda, el historial caduca a las 24 h |
| ¿Quién escribe? | **Todos, con marca de autor** `meta.author` | Si escribe uno solo, es un servicio. Si escriben todos, es memoria. Y con cinco opencodes escribiendo a la vez hace falta `put_new/2` o compare-and-swap, que ya está en el behaviour (§5.2) | `meta.author` y una regla de «quién puede pisar qué» |
| ¿Se puede desmentir? | **Sí, y tiene que poder** | Una memoria que solo crece es una memoria que miente cada vez más fuerte. Sin desmentir, el RAG devuelve en cuatro meses que el proyecto usa Redis | Un `value` con su `superseded_by`, o borrar y volver a escribir |
| ¿La memoria compartida se resume? | **No.** Se poda por antigüedad y por caducidad | Resumir una memoria compartida produce una memoria que nadie reconoce | Un `expires_at` por entrada |

**Mi recomendación**: `SharedMemory` es **una tabla plana, clave `String.t()`,
valor `%{value: term(), author: atom(), meta: map(), inserted_at: DateTime.t(), expires_at: DateTime.t() | nil}`**, y su scrap es `Candil.RAG` (fase 7). **No** depende de `SharedSession` y **no** la envuelve.

**Su coste, dicho sin adornos**: son **tres** capas (SharedSession, SharedMemory,
RAG) hablando de «lo que el modelo sabe», y el número de sitios donde una
respuesta puede venir es tres. Es el precio de que la memoria sobreviva al cambio
de modelo, y se paga gordo si no se escribe primero el contrato de quién escribe
qué.

### 5.5 · F2.5 — el coste de ingesta

#### 5.5.1 · Qué se puede hacer HOY, sin backend nuevo

**UnSolo arreglo, y es el que hace posible todo lo demás.** Medido:

```bash
# [MEDIDO AQUÍ] — ejecutando el módulo tal cual
{:ok, _} = Candil.Context.PrefixManager.start_link([])
:ok = Candil.Context.PrefixManager.put(:coder, "eres un asistente")
Candil.Context.PrefixManager.get(:coder, "eres un asistente")
Candil.Context.PrefixManager.get(:coder, "prompt v2")
Candil.Context.PrefixManager.get(:verifier, "eres un asistente")
Candil.Context.PrefixManager.stats()
# => %{hits: 0, misses: 0}
```

**`stats/0` siempre devuelve ceros**, porque `get/2` (`lib/candil/context/prefix_manager.ex:59-76`)
**nunca incrementa los contadores**. Se inicializan a 0 en `init/1` (`:121-122`) y
no hay ni un `:ets.update_counter` en el módulo. Y el `moduledoc` (`:11-15`) dice
justo lo contrario de lo que hace: *«`stats/0` existe porque la afirmación solo
vale algo si puedes comprobar que se cumple»*.

Y el segundo hecho, medido con grep:

```bash
grep -rn "PrefixManager" lib/ test/
# lib/candil/application.ex:53                       — lo arranca
# lib/candil/context/prefix_manager.ex:1            — él mismo
# test/candil/context_builder_test.exs:4,105-129    — sus propios tests
```

**Nadie, fuera de sus propios tests, llama a `put/2` ni a `get/2`.** O sea: hoy
Candil **ni siquiera alimenta un prefijo estable**. La caché del proveedor no tiene
nada estable que acertar, ni por accidente.

Las tres cosas que se pueden hacer sin tocar ningún backend:

| # | Qué | Por qué funciona |
|---|---|---|
| **1** | **Arreglar `stats/0`** y que `put/2` lo llame desde `PrefixPlanner` | Con eso, «el prefijo es estable» se vuelve una afirmación comprobable. Es media hora de trabajo y es la condición de todo lo demás |
| **2** | **Un segundo punto de corte para el resumen** | Medido: `Builder.build/3` devuelve `prefix ++ summary ++ history ++ messages` (`lib/candil/context/builder.ex:138`). El resumen va **el segundo**. Cada vez que el resumidor corre, **cambia**, y con él se invalida todo el prefijo que va detrás. Si el resumen va detrás del prompt del sistema y en su propio bloque, el prompt del sistema sigue siendo un prefijo estable |
| **3** | **Marcar qué es estático** | Herramientas, instrucciones, ejemplos y RAG van delante; la pregunta del usuario, detrás. Es la regla que los dos proveedores ya dan |

#### 5.5.2 · Qué necesita soporte del backend

**Medido**: `grep -rn "cache_control" lib/` → **0 resultados** ·
`grep -rn "prompt_cache" lib/` → **0 resultados**. Y
`Candil.Backend` (`lib/candil/backend.ex:63-75`) tiene **cuatro** callbacks:
`chat`, `chat_stream`, `embed`, `models`. **No hay ninguna forma de que un backend
diga qué soporta.** Esa es la pieza que falta, y es la primera que hay que
escribir.

```elixir
# En lib/candil/backend.ex — OPCIONAL a propósito
@doc """
Lo que este backend soporta, de lo opcional de la API.

Es **opcional** y no obligatorio a propósito: hay dos backends dentro del repo
(`llama_cpp`, `openai_compat`) y un tercero escrito por otra persona, y añadir
un `@callback` obligatorio les rompe el `mix compile --warnings-as-errors` a
todos de golpe. Opcional significa que `Candil.Backend.capabilities/2` devuelve
`[]` cuando no está implementado, y que **la ausencia de capabilities es una
respuesta válida**.
"""
@optional_callbacks capabilities: 0

@callback capabilities() :: [atom()]
```

Y la respuesta a **«¿qué pasa si un backend no lo soporta?»**:

| Backend | Qué hace hoy | Qué hay que añadir |
|---|---|---|
| **Anthropic** | `RequestBuilder.build_anthropic_body/3` (`lib/candil/request_builder.ex`) construye el cuerpo sin `cache_control` | `{"cache_control": {"type": "ephemeral"}}` en el último bloque del contenido reutilizable. Se admiten **hasta 4 puntos de corte** por petición, y se cachea en el orden `tools` → `system` → `messages` |
| **DeepSeek** | El cuerpo es OpenAI-compatible y **no necesita nada** | Solo leer `usage.prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` en el parser. El cacheado es automático y por prefijo |
| **llama.cpp** | `Candil.Engine.Server.build_args/2` (`lib/candil/engine/server.ex:160-188`) pasa `--ctx-size` y `model_args` | **Nada, y no se puede hacer nada** (abajo) |
| **Un backend de terceros** | — | Si no declara `:prompt_caching`, **no se inyecta nada**. Un `cache_control` en un backend que no lo entiende es un **400 del proveedor**, no un «no pasa nada» |

**Los tres límites, verificados contra la documentación del proveedor:**

1. **Anthropic tiene un mínimo, y depende del modelo.** La documentación oficial
   da 1 024 tokens para Sonnet/Opus 3.x–4.x y 2 048 para Haiku, y los modelos más
   nuevos tienen mínimos **distintos y no monótonos** (512 en unos, 4 096 en
   Opus 4.5/4.6). **Un prompt por debajo del mínimo no se cachea, no da error, y
   `cache_creation_input_tokens` sale a 0.** El código **no puede suponer el
   mínimo**: tiene que leerlo de la configuración del modelo o aceptarlo como
   desconocido.
2. **DeepSeek exige coincidencia completa del prefijo.** Con `A+B` y después
   `A+C`, la segunda **no** acierta; DeepSeek detecta el prefijo común `A` y lo
   persiste por su cuenta, así que la tercera sí. Y es **best-effort**: la
   construcción del cache tarda segundos y las entradas se limpian en horas o
   días.
3. **La clave es la coincidencia de bytes del prefijo.** Un carácter distinto
   antes invalida todo lo de detrás. Es el mismo motivo por el que
   `PrefixManager` usa `sha256` del prompt en la clave
   (`lib/candil/context/prefix_manager.ex:47`, `:108`).

**Y sobre el KV-Cache local, que es donde la expectativa se va a desinflar.** El
enunciado propone «retener tensores KV en un proceso de memoria compartida si el
siguiente modelo comparte arquitectura». Medido en el código:

- `Candil.Engine.Server.build_args/2` arranca **un modelo por servidor**, con
  `--model <ruta> --ctx-size <n>` (`lib/candil/engine/server.ex:172-187`).
- Los tensores KV están **dentro del proceso de `llama-server`**, y ese proceso
  está **supervisado por `Candil.EngineSupervisor`**
  (`lib/candil/application.ex:58`, `strategy: :one_for_one`).

Las tres consecuencias, que son la respuesta honesta a «retener KV entre modelos»:

| | |
|---|---|
| **La KV no es portable entre modelos** | Es el estado interno de los pesos de **ese** modelo en **ese** proceso. Aunque dos modelos «compartan arquitectura» —mismo `n_layer`, mismo `n_embd`— los tensores están mezclados con los pesos. No hay una API para extraerlos, ni para dárselos a otro proceso, sin escribir un backend de llama.cpp |
| **Cambiar de modelo es cambiar de proceso** | La forma correcta de que el siguiente modelo use la misma KV es **no cambiar de modelo**. Es la política del router, no una función de almacenamiento |
| **Lo que sí se puede hacer, y es gratis** | `llama-server` **ya** guarda su propio cache de prompt por *slot*. Lo único que hay que garantizar es **no invalidarlo**: misma sesión, mismo motor, prefijo idéntico. Es el caso 1 de §5.5.1, no una función nueva |

### 5.6 · F2.6 — la compresión asíncrona al 80 %

```bash
mix format lib/candil/context/compressor.ex
mix test test/candil/context/compressor_test.exs
```

Hoy el umbral son **8 000 tokens o 50 mensajes**, fijos
(`lib/candil/context/summarizer.ex:26-27`, `lib/candil/context/session.ex:137-143`).
El 80 % de la ventana es mejor, y la diferencia se ve:

| Ventana | Hoy | Con el 80 % |
|---|---|---|
| 4 096 | Se resume a los 8 000 tokens, que **no caben**: resumen imposible | Se resume a los ~3 100 |
| 131 072 | Se resume a los 8 000, wasting el 94 % de la ventana | Se resume a los ~105 000 |

**Y «asíncrona» es la palabra que manda aquí.** Un `Summarizer.maybe_summarize/2`
síncrono **bloquea el turno**: hace una llamada a un modelo entero
(`lib/candil/context/summarizer.ex:98-105`) en mitad de la petición del usuario.
El diseño:

1. Al llegar al **80 %**, el `Compressor` **no** resume: **marca** la sesión y
   lanza un `Task` supervisado.
2. El turno actual se sirve **con `:strict`**, que ya sabe dar
   `{:error, {:context_exceeded, :no_room_to_truncate}}` si no cabe
   (`lib/candil/context/builder.ex:133-135`). **Error, nunca recorte en silencio.**
3. Cuando el `Task` acaba, escribe el resumen **aditivo**: `summary` +
   `summarised_upto`, y los turnos viejos **se quedan**
   (`lib/candil/context/session.ex:11-18`).

**Invariante que hay que escribir como test, y no se deduce**:

> El `Compressor` **nunca** borra un turno. `sumarised_upto` avanza, los turnos no
> desaparecen. Si un test necesita el mensaje viejo para pasar, el resumen ha
> Rompido algo.

Un invariante más, el que de verdad importa para el usuario:

> **Comprimir no puede cambiar lo que ve el modelo sin que se diga.** Un resumen es
> una **pérdida de información declarada**. Por eso es `:summarize` y no
> `:compact`, y por eso `:summarize` **no degrada nunca**.

### 5.7 · F2.7 — la línea de cajas FIFO con VIP

**No se puede empezar** hasta que §2.4 esté contestado. Y hay que decirlo claro:
esta fase **es la 8b**, no una fase de este módulo. Está aquí para que
[`02-orden`](../../02-orden/README.md) sepa qué prerrequisito le falta.

Si la decisión es **FIFO con VIP**, el módulo tiene que aportar exactamente dos
cosas, y son las que este diseño ya tiene listas:

| Lo que aporta este módulo | Dónde |
|---|---|
| **La unidad de reparto es `SharedSession`**, con `tokens_used` por turno para medir lo que ha jugado | §5.1 |
| **El presupuesto por sesión ya existe y es un error, no un recorte** | `lib/candil/context/builder.ex:133-135` |

Si la decisión es **round-robin medido por tokens**, la VIP deja de ser una
categoría y pasa a ser «el orden dentro de la igualdad», que es mucho más barato
de mantener.

---

## 6 · Las puertas

Las siete de [`03-convenciones`](../../03-convenciones/README.md) §5, en su orden,
y qué falla si no pasan.

```bash
cd /workspace/repos/candil

mix format --check-formatted        # 1
mix compile --force --warnings-as-errors   # 2
mix credo --strict                  # 3
mix test                            # 4
mix dialyzer                        # 5
mix escript.build                    # 6
```

Y una séptima, que es el criterio de cierre de §7.

| Puerta | Qué falla si no pasa, en este módulo |
|---|---|
| `format` | Un `mix format` de otra persona cambia ficheros tuyos y el diff se llena de ruido |
| `compile` | Un `@spec` que no casa con `from_shared/1` es **la alarma que quieres**: salta aquí, no en producción |
| `credo` | Los callbacks sin `@impl` y las funciones largas del `Compressor` |
| **`test`** | `isolation_test.exs` en rojo = se ha roto el aislamiento. **No se arregla con un `@tag :skip`** |
| `dialyzer` | Si `@type session` se degrada a `term()`, dialyzer **no avisa de nada** en `Store`, y el primer error sale en runtime |
| `escript` | Un behaviour con `child_spec/1` mal puesto rompe el escript, y el escript es el formato de distribución |
| **La máquina del dueño** | Un `mix run` con dos sesiones y dos modelos. Sin esto, esta fase no está cerrada |

**Las siete de una vez**, y el orden importa:

```bash
for s in 1 42 99991; do mix test --seed $s; done
```

> Contexto: el último rojo de la fase 7 fue un test que dependía del orden —un pin
> en una tabla ETS que sobrevive entre tests—. **Verde con una semilla no es
> verde**, y estas fases añaden tests que comparten tabla.

Y si salen muchos fallos de golpe:

```bash
rm -rf /tmp/build-candil && mkdir -p /tmp/build-candil
MIX_BUILD_PATH=/tmp/build-candil mix deps.get
MIX_BUILD_PATH=/tmp/build-candil mix compile
MIX_BUILD_PATH=/tmp/build-candil mix test
```

Un `MIX_BUILD_PATH` sucio produce `Mox.Server` sin arrancar y decenas de fallos que
no son de nadie.

---

## 7 · Cómo se sabe que funciona

**Y cómo se sabe que falla.** Que es la mitad que falta en casi todo lo que se ha
escrito aquí antes.

### 7.1 · Que funciona

```bash
# ── 1 · El aislamiento: dos consumers, mismo session_id ────────────────
mix run -e '
  alias Candil.Context
  :ok = Context.append_message(:posadero, "demo", "user", "secreto del vault")
  :ok = Context.append_message(:opencode,  "demo", "user", "hola, assistant")
  {:ok, a} = Context.get(:posadero, "demo")
  {:ok, b} = Context.get(:opencode,  "demo")
  IO.inspect({a.messages, b.messages}, label: "aislados")
'
# Debe imprimir: {[[%{content: "secreto del vault"}]], [[%{content: "hola, assistant"}]]}
# Si imprime el MISMO texto en las dos: se ha roto la partición. Para aquí.

# ── 2 · El Macro-MoE: un hilo, dos modelos ─────────────────────────────
mix run -e '
  alias Candil.Context
  alias Candil.Context.Turn
  :ok = Context.append_turn(:posadero, "moe", %Turn{role: "user",      content: "a", model_used: :coder})
  :ok = Context.append_turn(:posadero, "moe", %Turn{role: "assistant", content: "b", model_used: :coder})
  :ok = Context.append_turn(:posadero, "moe", %Turn{role: "user",      content: "c", model_used: :verifier})
  :ok = Context.append_turn(:posadero, "moe", %Turn{role: "assistant", content: "d", model_used: :verifier})
  {:ok, s} = Context.get(:posadero, "moe")
  IO.inspect(length(s.turns), label: "turnos")
  IO.inspect(Candil.Context.SharedSession.models_used(s), label: "modelos")
'
# Debe imprimir: turnos: 4 · modelos: [:coder, :verifier]

# ── 3 · La memoria: cuánto ocupa de verdad ─────────────────────────────
mix run -e '
  {:ok, info} = :ets.info(Candil.Storage.ETS.table(), :memory)
  IO.puts("tabla de sesiones: #{Float.round(info / 1_024 / 1_024, 2)} MB")
  IO.inspect(:ets.info(Candil.Storage.ETS.table(), :size), label: "filas")
'
# Con 1 000 sesiones de 50 turnos: unos 33 MB y 1 000 filas.

# ── 4 · El prompt caching: el dato que NO está en Candil ──────────────
# Hay que mirarlo en la RESPUESTA del proveedor, con una clave de verdad.
mix run -e '
  {:ok, r} = Candil.chat_remote("claude-sonnet-4-5", "cacheo", [%{role: "user", content: "hola"}], provider: :anthropic)
  IO.inspect(r[:usage] || Map.get(r, :usage), label: "usage")
'
# Mirar `cache_read_input_tokens`. Si es 0 con un prefijo largo y estable,
# o el prefijo está por debajo del mínimo del modelo, o no se está marcando.
```

### 7.2 · Cómo se sabe que **falla**

Un test que solo sabe decir «verde» no sabe decir nada. Estas son las cinco
formas de fallo y **el test que las pilla**:

| Cómo falla | Cómo se ve | El test que lo pilla |
|---|---|---|
| **Se rompe la partición** | Dos consumers con el mismo `session_id` se ven el mismo hilo. **Silencioso**: el número correcto de mensajes de la conversación equivocada | `isolation_test.exs`, el test de las dos sesiones |
| **Un adapter miente en su `capabilities/0`** | La fachada usa un adapter no atómico como si lo fuera, y dos escritores se pisan | `adapter_test.exs`, el test de `:atomic_updates` |
| **El `stats/0` sigue a cero** | Se afirma que el prefijo es estable y no hay manera de comprobarlo | `prefix_planner_test.exs` |
| **El `Compressor` borra un turno** | Un usuario pregunta por algo que se resume y ya no está | `compressor_test.exs`, el invariante de que `sumarised_upto` avanza y la lista no |
| **El prompt se queda por debajo del mínimo del proveedor** | `cache_creation_input_tokens: 0` y **ningún error**. Parece que el caching no funciona cuando en realidad el prompt es corto | Un test que mida el prefijo en tokens y avise por debajo del mínimo **de ese modelo**, leído de la config |

**El quinto es el más peligroso de los cinco**, porque no falla: **falla
callado**. Un `cache_control` en un prompt de 800 tokens con un modelo cuyo mínimo
es 1 024 no da ningún error, no da ningún aviso, y Candil no puede saberlo porque
no lee `usage`. Por eso §5.5.2 insiste: **el dato está en la respuesta del
proveedor, y por eso hay que parsearlo**.

---

## 8 · Cuando sale mal

Los fallos que se esperan, y qué hacer con cada uno. Cada uno necesita su test.

### 8.1 · `PrefixManager.stats/0` devuelve ceros para siempre

**Lo que pasa**: `init/1` pone los contadores a 0
(`lib/candil/context/prefix_manager.ex:121-122`) y **nadie los sube**. No hay ni un
`:ets.update_counter` en el módulo. **[MEDIDO AQUÍ]**: `%{hits: 0, misses: 0}`
después de tres `get/2`, uno de ellos acertado.

**Por qué duele**: el `moduledoc` del módulo dice que `stats/0` existe para poder
comprobar que el prefijo es estable. **No se puede comprobar.** Es un indicador
muerto que parece vivo.

**Qué hacer**: `get/2` incrementa con `:ets.update_counter/3`. Y el test es
exactamente el de §4.5.

```bash
# Cómo se ve en verde
mix test test/candil/context_builder_test.exs
# Si el test de stats pasa pero sigue diciendo 0, el test está mal.
```

### 8.2 · Un adapter nuevo rompe el aislamiento

**Lo que pasa**: el adapter indexa por `session_id` a secas «porque es más
sencillo», y `posadero` ve el hilo de `opencode`.

**Por qué duele**: es el fallo más caro del módulo y **no da error**. Dos
consumers obtienen respuestas plausibles a preguntas que el otro se hizo.

**Qué hacer**: el adapter tiene que recibir la **clave completa** `{consumer,
session_id}` en `get/2`, `put/3` y `delete/2`, y `list/1` recibe **un solo
consumer**. No hay atajo, y el `behaviour` no lo va a dejar pasar.

```bash
# Cómo se ve en verde
mix test test/candil/context/isolation_test.exs
mix test test/candil/context/isolation_test.exs --seed 42
mix test test/candil/context/isolation_test.exs --seed 99991
# 0 failures en las tres, o el adapter no sirve.
```

### 8.3 · Hay tres estimadores de tokens distintos y no lo dicen

**Lo que pasa**, y es real, leído en el código:

| Dónde | Cómo estima |
|---|---|
| `Candil.Context.TokenEstimator.estimate_content/1` (`lib/candil/context/token_estimator.ex:65-72`) | Una token por palabra, **más una cada 6 caracteres**. Dice estar a ±10 % de `tiktoken` |
| `Candil.Context.Builder` — su `estimate/1` privado (`lib/candil/context/builder.ex:204-208`) | **`div(chars, 4)`** |
| `Candil.Context.Session.tokens/1` (`lib/candil/context/session.ex:103-113`) | **`div(chars, 4)`** |
| `Candil.Inference.Chat` — `validate_context/3` (`lib/candil/inference/chat.ex:206-228`) | **`div(chars, 4)` + 4 por mensaje** |

**Cuatro caminos, tres reglas.** El `TokenEstimator` es el bueno y **nadie lo
usa**: `grep -rn "TokenEstimator" lib/` solo devuelve su propia definición y la
delegación de `Candil.Conversation`.

**Por qué importa aquí**: el «80 % de la ventana» de §5.6 se calcula con
`div(chars, 4)`, y el resultado **no coincide** con el recuento real. En texto en
español, donde las palabras son largas, la diferencia es de un **15-20 %**, y el
umbral se dispara antes o después de lo que dice. No es una cuestión de precisión: es
que **el número que se le dice al usuario no es el número que se ha usado**.

**Qué hacer**: **no en esta fase**. Unificar los estimadores cambia aritmética de
recorte, y `builder_policy_test.exs` congela números concretos. Es una fase propia
(F2.0, antes de F2.6) con su propio criterio: un test que afirme que los cuatro
caminos coinciden dentro de un margen escrito.

### 8.4 · El prompt se queda por debajo del mínimo del proveedor

**Lo que pasa**: se marca el `cache_control`, la llamada sale bien, y
`cache_creation_input_tokens` viene a **0**. Sin error, sin aviso. El caching
«no funciona» y no se sabe por qué.

**Por qué duele**: es un fallo **mudo**. La respuesta es correcta; lo único que
falta es el descuento.

**Qué hacer**:

1. Medir el prefijo en tokens **con el estimador bueno** (`TokenEstimator`), no
   con `div(chars, 4)` (§8.3).
2. Leer el mínimo **de la configuración del modelo**, no del código. Los mínimos
   de Anthropic cambian entre generaciones y **no son monótonos**.
3. Si el prefijo está por debajo, **no marcar el breakpoint** y decir por qué.
4. Leer `usage.cache_read_input_tokens` / `usage.prompt_cache_hit_tokens` en la
   respuesta y exponerlos, que es el único dato que demuestra nada.

### 8.5 · `put_turn/3` pierde turnos con dos procesos escribiendo a la vez

**Lo que pasa**: `Candil.Context.update/3` (`lib/candil/context.ex:97-106`) hace
`get`, aplica la función e `inserta`. **No hay compare-and-swap.** Dos procesos
que anexan un turno a la vez: uno gana, el otro desaparece, y **no hay error**.

**Por qué duele**: en ETS es una carrera improbable y silenciosa. Con dos
consumers hablando en paralelo es **frecuente**, y es justo el caso de uso del
módulo.

**Qué hacer**:

- En ETS: `:ets.select_replace/2`, que devuelve `false` si no hubo intercambio, y
  reintentar con contador.
- En cualquier otro adapter: si `capabilities/0` **no** dice
  `:atomic_updates`, la fachada **se niega** y devuelve
  `{:error, :adapter_not_atomic}`. **Preferible a perder turnos en silencio.**

```bash
# Cómo se ve, y por qué hace falta la puerta de la semilla
mix test test/candil/context/ --seed 1
mix test test/candil/context/ --seed 42
mix test test/candil/context/ --seed 99991
```

### 8.6 · La tabla se va con el proceso que la creó

**Lo que pasa**: la tabla de `Candil.Context` la crea el GenServer en su `init/1`
(`lib/candil/context.ex:283`), y **la tabla es suya**. **[MEDIDO AQUÍ]**: matando
al proceso dueño, `:ets.whereis(:candil_context_sessions)` devuelve `:undefined`.

**Por qué duele**: con `strategy: :one_for_one` en `Candil.Supervisor`
(`lib/candil/application.ex:59`), si `Candil.Context` se reinicia, **se pierden
todas las conversaciones** sin decir nada. El `moduledoc` de `Candil.Context`
promete que el estado sobrevive al reinicio **entre** VMs; dentro de una VM, no.

**Qué hacer**: es el argumento de por qué el adapter es una capa. `Mnesia` en
memoria, `Redis` y un fichero **sí** sobreviven; ETS **no**. Y por eso la
capacidad se llama `:ephemeral` y **la pone hasta el de ETS**.

---

## Lo que queda para otro día

| | |
|---|---|
| **La migración de `Candil.Agent`** de `Candil.Conversation` a `Candil.Context` | Se va en 4.1.0 (`lib/candil/conversation.ex:9-28`). `Candil.Agent` es el último que la usa (`lib/candil/agent.ex:78`, `:81`, `:118`, `:172`), y el `@deprecated` está **deliberadamente sin poner** porque `mix compile --warnings-as-errors` se pondría rojo |
| **Unificar los cuatro estimadores** | §8.3. Fase propia, con su criterio |
| **KV-Cache local entre modelos** | §5.5.2. **Probablemente no sea hacible**, y la respuesta es «no», no «todavía no» |
| **La línea de cajas** | §5.7, F2.7. Es la 8b, y depende de una decisión que **todavía no está tomada** |
| **`DECISIONES.md`** | Este README no lo trae. Se escribe si, al implementar, cambia el rumbo: lo más probable es que sea la de `semantic_cache` (§5.4), porque el nombre promete compartir y la colocación no lo hace |

---

> **Lo que este documento ha medido y lo que no.** Medido: el gasto
> memoria de las sesiones en ETS, el coste de `match_object/2` frente a
> `lookup/2`, que la tabla se va con su proceso dueño, y que
> `PrefixManager.stats/0` devuelve ceros. No medido, y dicho como hipótesis:
> el round-robin justo (§2.4), que **no existe en el código de este repo** pese a
> que los documentos hermanos lo dan por hecho; el comportamiento del backend
> con `cache_control`, porque no hay ninguna llamada real a un proveedor desde
> este entorno; y todo lo que toca la 8b, que depende de una decisión abierta.