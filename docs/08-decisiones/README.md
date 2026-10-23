# 08 · Decisiones

> **Qué se decidió, cuándo, por qué, y qué costó.** No solo el plan: también
> lo que se decidió *a mitad de una fase*, cuando el plan resultó estar
> equivocado, y lo que se cambió *entre* fases.
>
> Decidido hasta 2026-10-21 · `main` `398a1b9` · D-27 (device + peso calculado,
> revisada tras arrancar un modelo de verdad)

---

## La regla de este bloque

> **Una decisión que no está escrita, no se ha tomado: se ha sofreado
>/defaulted, y el default ha ganado.**

Cada entrada dice qué se cambió, por qué se cambió, y **qué se dejó de
hacer**. Eso último es lo que se pierde cuando solo se escribe el "qué".

---

## D-01 · El centro de gravedad: el enrutado, no la GPU

**Cuándo**: 2026-10-11, por el dueño.
**Qué**: la fase 4 pasa a ser la política de turnos y el trabajo local se aparca.

El plan anterior tenía como fases 1-4 "que mi máquina funcione bien":
behaviours, motor local, VRAM, scheduler. Un usuario que **solo llama a APIs**
se salta las cuatro. Y el diseño del motor de decisión
(`04-modulos/01-routing-y-ciclo-vida/DISENO-MOTOR.md`) menciona
`vram`/`gpu`/`cuda`/`device` **0 veces**, mientras que el router ya
distingue los tres tipos de destino (`:local`, `:remote`, `:external`).

**Medida**:

| | |
|---|---|
| Menciones de GPU en el diseño del motor | **0** |
| Menciones de `provider`/`remote`/`precio` | 2 |

**Se dejó de hacer**: la 8b · Scheduler no está en el plan. Está en
[`07-local-aparcado`](../07-local-aparcado/) con lo que hay y lo que falta.

**La frase que resume todo**:
> El centro de gravedad de Candil es el enrutado. La inferencia local es un
> backend más.

---

## D-02 · `exclusive` es una propiedad del destino, no un interruptor

**Cuándo**: 2026-10-11, por el dueño.
**Qué**: no hay enum de modos. Hay una propiedad por destino.

El diseño anterior era un interruptor global con tres modos
(`one_for_all` / `rest_for_one` / `one_for_one`). Se cayó por una razón
concreta: **quien tiene tres APIs y una GPU tiene que elegir un modo para los
cuatro, y cualquier elección es mala para tres de ellos.**

```toml
[model.coder]
exclusive = true     # si lo tiene uno, no caben dos
[model.embedder]
exclusive = false    # una API: no se estorba con nadie
```

**El defecto es `false`** y el schema **no lo exige**: exigirlo sería obligar a
declarar "esto no es exclusivo" para no usar la cola, que es al revés. El
defecto tiene que ser el aburrido y el que no toca la cola.

**Se dejó de hacer**: `rest_for_one` **no está implementado ni stubeado**. Solo
tendría sentido cuando existiera un destino que pueda soltar el turno antes de
terminar. Y de los dos modos seriales (`one_for_all` y `rest_for_one`) solo
existe el primero, porque con peticiones de una vez **son el mismo resultado**:

```
cola con A, B, C esperando

one_for_all  :  A entra -> sale -> B entra -> sale -> C entra.   FIN
rest_for_one :  A entra -> sale -> B entra -> sale -> C entra.   FIN
                                        ↑
              A ha vuelto AL FINAL, pero ya no hay a quien darle turno
```

**El fallo que la evitó**: no invocar un "quantum" para forzar que se diferencien.
En una GPU **no se puede cortar una inferencia a medias** —la mitad del trabajo ya
está hecho—, así que el quantum habría sido unconcepto sin caso de uso.

---

## D-03 · La capacidad en megas enteros, la cuota en decimal

**Cuándo**: 2026-10-10, al escribir `Arrea.Resource`.
**Qué**: `capacity` entera, `quota` decimal con tolerancia.

Un solo eje decimal no vale: el byte es una unidad, no *la* unidad, y con
decimales la aritmética devolvía `0.19999999999999998` de margen y rechazaba un
modelo que cabía.

**Se dejó de hacer**: nada. Se hizo de una: capacidad entera (exacto, sin
tolerancia) y cuota decimal (con tolerancia y redondeo al publicar).

---

## D-04 · El ejemplo de la GPU parecía mal y no lo estaba

**Cuándo**: 2026-10-10.
**Qué**: yo afirmé que el ejemplo de `@moduledoc` de `Bulkhead` —"un modelo de
12 GB y otro de 1,8 no caben en 16 GB"— tenía la cuenta mal, porque 12 + 1,8 =
13,8.

**El dueño**: *«puede que haya que contar con la KV cache y otros archivos que
hacen falta para que funcione»*.

Tenía razón. El ejemplo **no está mal, está incompleto**: un modelo no ocupa
solo sus pesos, también la caché KV y los ficheros auxiliares, y con 2,2 GB de
margen no llega.

**Lo que salió de ahí** y que es lo reutilizable:

> Si `N/A` se convierte en `0`, el planificador dice *«no cabe»* con un número
> inventado. Si se convierte en el total, dice *«hay sitio»* y lanza un modelo que
> no entra. **Un `0` y un `total` son los dos extremos del mismo fallo: decir con
> seguridad algo que no se sabe.**

Por eso `Detector.Devices` devuelve `usable: false` con las cifras a `nil`:
**un planificador tiene que poder distinguir "no hay sitio" de "no lo sé", y esa
diferencia tiene que estar en el tipo**, no en la cabeza de quien lee.

---

## D-05 · Las siete hermanas desde su `main`, no desde Hex

**Cuándo**: 2026-10-10, por el dueño.
**Qué**: Candil deja de tomar `apero`, `arrea`, `trebejo`, `batamanta`, `alaja` y
`botica` de Hex y los toma de su `main`.

**El motivo medido**: lo publicado en Hex era `arrea 3.1.0` y el repo estaba
también en 3.1.0. Mergeado `Arrea.Resource` en `main`, **para Candil no había
cambiado nada**, y Hex no admite republicar una versión ya publicada. La fase 2
no desbloqueaba la 3 hasta hacer eso a mano.

**El coste de conocer, escrito en `mix.exs`**: Candil no recoge automáticamente un
fix de una hermana. `mix deps.update <hermana>` a propósito.

**Y una trampa que costó un rato**: `botica ~> 2.2` depende de `arrea ~> 3.1`
**desde Hex**. Sin `override: true` el solvedor ve dos Arreas distintas y se
niega. Con el flag, Candil y botica reciben la misma.

**Lo que NO se cede**: `mix.lock` fija el **SHA exacto** de cada una. La build
sigue siendo reproducible y una build vieja no se rompe sola.

---

## D-06 · Sin clasificador ni embedder por defecto

**Cuándo**: decisión del dueño, 2026-10-11.
**Qué**: las capas `:llm` y `:embedding` quedan **inertes** hasta que se registre
un clasificador o un embedder.

**El motivo, textual**: *«no podemos poner llm ni embeddings modelos por defecto
porque implica que el proyecto los lance. Y si el usuario no los usa?»*

Es más fuerte que el argumento que había en el `@doc` del clasificador
—*«tomarlo por omisión es tomarlo sin querer»*—, porque añade la consecuencia
práctica: **un default que arranca un LLM por su cuenta consume GPU sin que nadie
lo haya pedido**.

**Consecuencia medible**: con `exclusive = false` y sin capas registradas, el
camino caliente **no arranca ninguna cola y no emite ningún evento**.

---

## D-07 · El enrutado sube de fase, y el gateway baja al 8

**Cuándo**: 2026-10-11, por el dueño.
**Qué**: el orden nuevo pone el enrutado en la 3 y el gateway en la 8.

El enrutado estaba **fuera de la tabla** y es el producto: `Scorer` solo tenía
`score/4` para `:rule`, y `:embedding` y `:llm` caían en un catch-all que
devolvía `:miss` mientras `DecisionEngine` ya las llamaba. El
`Candil.Router.Classifier` —que existe desde la fase 1— **no lo invocaba
nadie**.

El gateway baja porque **va justo detrás de lo que tiene que servir**, y porque
un gateway montado antes del enrutado expone una respuesta que no cambia.

---

## D-08 · `one_for_all` y `rest_for_one` se escribieron como si fueran distintos

**Cuándo**: 2026-10-11.
**Qué**: documentado que **son el mismo resultado** con peticiones de una vez, y
que la diferencia solo aparece con un destino que pueda ceder el turno.

Los dos nombres estaban en el plan desde el principio. No se quitó ninguno: se dejó No se quitó ninguno: se dejó No se quitó ninguno: se dejó
**un solo modo implementado** y el otro escrito como lo que es.

**Una verdad, un sitio**: el `@moduledoc` de `Policy` lo dice y el test lo
demuestra.

---

## D-09 · El refusal se configura, no se decide de una vez

**Cuándo**: 2026-10-11, por el dueño.
**Qué**: cuando el destino está ocupado y no cabe, `fail` · `wait` · `degrade`,
**configurable**, y las tres son válidas.

**La pregunta que yo tenía mal planteada**: *"¿qué pasa si no hay candidato?"*.
Eso **ya estaba resuelto** desde antes: `Router.Consumer` tiene tres niveles de
búsqueda y el tercero es `model_default`, y **el schema lo exige** — un
`[consumer.X]` sin él no valida y el TOML falla al arrancar.

La pregunta de verdad es la del destino **ocupado**, que no tiene default: el
default es un modelo, y lo que falta es el sitio.

**Dos reglas que el valor no puede cambiar**, escritas:

1. **Ninguna devuelve un modelo vetado.** Es seguridad, no política.
2. **`fail` nunca miente con números**: o sale el motivo con
   `requested`/`available`/`capacity`, o sale *que no se sabe*. Un `-1` que
   significa "no lo sé" y un `0` que significa "no hay" son el mismo bug (D-04).

---

## D-10 · Una fase no se cierra por el CLI, ni por los tests, ni por un verde

**Cuándo**: en vigor desde el principio, y **reforzado tres veces** esta semana.
**Qué**: una fase se cierra cuando el criterio se ha **ejecutado de verdad**.

La forma concreta que se ha repetido:

| | |
|---|---|
| Los 800 tests en verde y el refusal inexistente | fase 0 |
| 4 tests de cmake que **solo existen si hay cmake** | compara "0 fallos" con dos suites distintas |
| La cola al revés y un test llamado *"la prioridad manda"* **que no comprobaba la prioridad** | 4 fallos locales, 0 en CI |
| La suite escribiendo en el `~/.candil` del developer | 4 rojos en CI, 0 en local |

**La regla que sale de las cuatro**: un verde que no se puede reproducir **es peor
que un rojo**, porque un rojo por lo menos señala un fichero.

---

## D-11 · Lo que NO se decidió, y por eso está escrito

Estas las encontró el proceso, y **ninguna se ha cerrado**:

| # | Pregunta | Dónde |
|---|---|---|
| 1 | ¿Cuando algo no cabe, `fail`, `wait` o `degrade`? **Configurable**, pero el defecto no está puesto | `06-capacidad-y-politica` §4 |
| 2 | ¿La memoria compartida comparte historial o solo patrones? | `docs/README.md` |
| 3 | ¿Quién escribe la verdad de la VRAM? Hoy la **lee**; escribirla sigue sin dueño | `docs/README.md` |
| 4 | ¿`Candil.Provider` es un registro o una lista cerrada? | `docs/README.md` |
| 5 | ¿El camino de librería entra en las fases, o se queda fuera? | `docs/README.md` |
| 6 | ¿El LLM entra como clasificador? **No se puede saber**: no hay métrica de qué fracción resolvió el motor estático | `01-inventario` §"lo que falta" |

**La 6 es la que bloquea a la 5**: `DISENO-MOTOR` §10 pone un tribunal antes de
meter el LLM — *"si la política resuelve el 97%, el LLM se llama el 3% y es ruido
caro. Si es el 60%, **el motor estático está mal hecho** y hay que arreglarlo
antes de meter un modelo"*. **Y esa métrica no existe: no hay telemetría de
decisiones por capa.** Es lo más pequeño que falta y decide lo más gordo que
queda.

---

## D-12 · Candil manda la pregunta; la respuesta no es suya

**Cuándo**: 2026-10-14, por el dueño.

**Qué**: Candil **enruta**. No sabe si una respuesta es correcta y no debe
intentar saberlo. La respuesta la evalúa **quien ha hecho la pregunta**: el
usuario de la línea de comandos, o el consumidor del gateway.

### Por qué está escrito, porque es lo contrario de lo que parece

Medido el 2026-10-14 sobre los GGUF de esta máquina, con una pregunta de
aritmética y `temperature 0`:

| modelo | `reasoning_content` | respuesta |
|---|---|---|
| `gpt-oss-20b` | 639 bytes | «10 patas en total.» ✓ |
| `Qwen3.8-27B` | 1996 bytes | «10. En total hay 10 patas.» ✓ |
| `DeepCoder-14B` | 558 bytes | ✓ |
| `Qwen3-Coder-30B` | ausente | ✓ |
| `Ministral-3-14B` | ausente | **«18 patas (3×2 + 2×2)»** ✗ |
| `Devstral-Small-2-24B` | ausente | **«Hay 14 patas»** ✗ |

`Devstral` es el `coder_lite` del catálogo y **se equivoca**, y no falla de
ninguna forma técnica: devuelve un 200 con texto equivocado, con `temperature
0`, que es el caso más fácil que hay.

Si Candil juzgara la respuesta, ¿con qué? No tiene la verdad terrena. Y un
motor que finge saber si una respuesta es buena es peor que uno que no lo
sabe, porque sus decisiones dejan de ser auditables.

### Lo que esto NO significa

| | |
|---|---|
| **El enrutado no se evalúa** | sí se: el tribunal de `DISENO-MOTOR` §10 mide si la **capa decide bien**, que es otra pregunta |
| **La calidad no se vigila** | `Candil.Telemetry.Quality` mide la **salud del destino**: un `finish_reason` anómalo dice que se quedó corto, un reintento dice que algo falló. Ninguna de las dos mira si la respuesta es *cierta* |
| **El razonamiento se tira** | se expone en `response().reasoning` para quien pidió, y **no se usa para enrutar** |

### Por qué importa para lo que viene

La fase `:llm` del router no sería «un modelo que juzga respuestas», sería
**una capa más para decidir a quién mandar**. Si alguien propone que el LLM
evalúe la respuesta, esta decisión está escrita y hay que cambiarla a
propósito, no de paso.

Es también lo que hace que el 16.7% del tribunal **no sea una alarma**: mide
la capacidad de decisión del motor estático, no si los modelos saben contar
patas. Son dos preguntas, y la que le importa a Candil es la primera.

---

## D-13 · La frontera con Arrea: lo que Arrea usa, o lo que piden dos

**Cuándo**: 2026-10-16, por el dueño.
**Qué**: algo sube a Arrea si Arrea lo necesita **para sí**, o si lo pide un
**segundo consumidor**. Si solo lo necesita Candil, se queda en Candil.

La decisión resuelve una contradicción que estaba abierta entre tres documentos:
`00-arrea` §5 lista «abstracción de agente» como carencia, `05-agentes` §5.2
proponía `Arrea.Agent` y `02-orden` fase 10 ya lo daba por hecho («`Arrea.Agent`
(en Arrea)»). Se resolvió midiendo, y las cuatro medidas van juntas:

| Hecho | Medición |
|---|---|
| `Arrea.Agent` ha existido | **no**: cero `agent.ex` en el repo hermano, en toda su historia |
| `Arrea.Resource` existe | **sí**: 23 KB, tests y property test, en `main` desde el 2026-10-10 (fase 2 ✅; D-03, D-05), publicado |
| Consumidores de `Arrea.Resource` hoy | **ninguno**: en Candil solo se le cita en tres `@moduledoc`; en Arrea solo está registrado en el supervisor |
| Consumidores de Arrea | cuatro: trebejo, candil, botica, delfos (`ARCHITECTURE.md`) |

El behaviour nace en **Candil**. Un contrato con un solo consumidor y **cero
implementaciones dentro de Arrea** se congela antes de que nadie lo haya probado
— el de §5.2 nació de *leer* `Candil.Agent.loop/7`, y ese bucle no cerró hasta
#87. La fila de `Resource` es el precio ya pagado de adelantarse: 23 KB que hoy
no usa nadie. **El chasis no adivina lo que va a ser de todos; lo posee cuando
ya lo es.**

**Por qué rectificar no va a costar caro**: Candil consume Arrea de su `main`
con `override: true` (D-05). El día que haya segundo consumidor, extraer el
behaviour es *mover un módulo*, no una release de Hex.

**Se dejó de hacer**: la F5.1 como PR en `Lorenzo-SF/arrea` con su CI, la F5.2
esperando un merge que este repo no controla, y `Arrea.Agent` /
`Arrea.Agent.Supervisor` como ficheros **[PROPUESTO]** del repo hermano.

**No se aplica hacia atrás**: `Arrea.Resource` está mergeado y publicado, su
forma no tiene vocabulario de Candil (el titular es opaco) y la fase 2 está
cerrada. La regla rige lo que entra **desde ahora**; lo que queda de este lado es
**usar** la cuenta —la admisión—, no reescribirla.

**La frase que resume todo**:
> A Arrea sube lo que Arrea usa para sí, o lo que piden dos. Lo que solo
> necesita uno, vive con quien lo necesita.

---

## D-14 · «Agente» significa una sola cosa: el proceso; la mesa tiene voces

**Cuándo**: 2026-10-16, por el dueño.
**Qué**: «agente» se queda con el sentido que ya tiene `Candil.Agent` — un
proceso que decide paso a paso, con bucle, herramientas y estado (la fase
**10**). La mesa camilla (la fase **9**) no reutiliza la palabra: sus
participantes se llaman **voces**. `[agent.X]` queda reservado para agentes de
verdad; el día que la mesa necesite catálogo será suyo (`[mesa.…]` o una lista
dentro de ella), no una segunda acepción de «agente».

La palabra tenía dos candidatos, y por eso estaba en el relevo:

| Candidato | Qué es | Dónde está escrito |
|---|---|---|
| **El proceso** | `use Candil.Agent, name:, goal:, tools:, max_steps:` — bucle, traza, cancelación | `lib/candil/agent.ex`, el diseño entero de [`05-agentes`](../04-modulos/05-agentes/README.md) y la fase **10** |
| **El participante de las rondas** | un `(modelo, rol)` de la mesa, configurado desde el TOML | la decisión 2 de la ronda 7 del consejero: qué modelos participan, sus roles, si se les permite |

Es la misma trampa que `usage`, que mezclaba endpoints y capacidades: una
palabra, dos conceptos, y el que llega segundo se lee como si fuera el primero.
Se cierra dándosela al de casa, y la razón es de reloj:

| Hecho | Medición |
|---|---|
| Consumidores de `use Candil.Agent` en `lib/` | **cero**: los dos únicos usos del repo están en tests |
| Menciones de `Candil.Agent` que costaría renombrar hoy | 56 (6 en `lib`, 15 en tests, 35 en docs) |
| Secciones del catálogo | una palabra por concepto: `[engine.X]`, `[model.X]`, `[provider.X]`, `[consumer.X]` |
| Diseño de la mesa | **no existe**: solo las rondas del consejero |

El de casa tiene diseño completo, tests y una fase que se abre justo ahora
(F5.1, tras D-13); a la mesa le falta el diseño entero, así que su vocabulario
se escribe sin coste. Al revés —renombrar lo de hoy para que la mesa herede la
palabra— se pagaría dos veces.

**No prohíbe sumar**: si el día de mañana un participante de la mesa es un
proceso que decide paso a paso, **es** un agente de la taxonomía (un tipo 1 o 2
con el modelo pineado) y usa el vocabulario de siempre. La regla es de sentido,
no de censo: una palabra, una cosa; si la cosa se vuelve un agente, la palabra
ya la tenía.

**Se dejó de hacer**: renombrar `Candil.Agent` (a `Candil.ReAct` u otro);
abrir `[agent.X]` con el sentido de «participante de las rondas»; y dejar el
nombre del behaviour `Candil.Agents.Behaviour` —que la F5.1 va a fijar— colgando
de un diseño que aún no existe.

**La frase que resume todo**:
> «Agente» es el proceso que decide paso a paso; los que participan en la mesa
> son voces.

---

## D-15 · El scheduler: round-robin justo por defecto, prioridad como peso

**Cuándo**: 2026-10-18, por el dueño (recomendación del agente, aceptada).
**Qué**: el scheduler (8b, aparcado) usa **round-robin justo** por defecto y
una **prioridad como peso opcional por consumidor** (`[consumer.X] priority = N`)
que solo rompe empates cuando dos consumidores quieren el mismo destino, con
envejecimiento para que un VIP no mate al resto. No se construye la «línea de
cajas» completa (FIFO con VIP estricto) hasta que la mesa camilla (fase 9)
muestre que el envejecimiento no basta.

**Por qué**: el enrutado es el producto y el scheduler es una extensión
(`02-orden` §2). Construir una cola con prioridad real antes de tener varios
consumidores reales es adelantarse: los consumidores ya se identifican
(`[consumer.X]`), y la equidad evita la inanición. El caso de VIP estricto
(como un servicio que factura por rpm) se cubre con el peso opcional, no con
una cola distinta.

**Se dejó de hacer**: la cola FIFO con VIP estricto, el scheduler como fase
bloqueante, y el `rest_for_one` (D-19).

**Desbloquea**: 8b (scheduler), y con él la Fase 10 (agentes multi-modelo) y
P-4/P-6 (verdad de la VRAM y varias GPUs).

---

## D-16 · La verdad de la VRAM: Arrea mide, Candil consume y decide

**Cuándo**: 2026-10-18, por el dueño (recomendación del agente, aceptada).
**Qué**: la medida física de la VRAM (y de la capacidad) la produce **Arrea**
(`Arrea.Resource`, que ya existe desde la fase 2 y hoy no tiene consumidor):
Arrea corre el motor, conoce el PID, lee `/proc` o `nvidia-smi`. Candil la
**consume** para enrutar y colocar, y no mide por su cuenta. La columna `SLOT`
de `candil status` deja de deducirse del número de puerto y pasa a leer la
medida real (`Candil.Detector.Devices` ya la produce por PID).

**Por qué**: medir pertenece al componente que posee el recurso. Dos verdades
que se contradigan (Candil diciendo una cosa, Arrea otra) es el fallo que ya
se tuvo con el refusal de VRAM. `Arrea.Resource` tiene capacidad (megas
enteros) y cuota (decimal) con identidad del titular: eso es exactamente lo
que un knapsack de GPU necesita, y Candil no tiene por qué reimplementarlo.

**No se aplica hacia atrás**: `Arrea.Resource` está mergeado y publicado; su
forma no tiene vocabulario de Candil (el titular es opaco). La regla rige lo
que entra desde ahora.

**Desbloquea**: P-4 (verdad de la VRAM), P-6 (varias GPUs), 8b (scheduler).

---

## D-17 · `Candil.Provider`: registro, no lista cerrada

**Cuándo**: 2026-10-18, por el dueño (recomendación del agente, aceptada).
**Qué**: los providers se registran en un registro abierto (`Candil.Registry`,
el mismo patrón que `Policy.Destination` y los agentes), y cada uno implementa
un behaviour `Candil.Providers.Provider` (chat, embed, models). Añadir un
provider es registrar un módulo, no cambiar código ni hacer una release.

**Por qué**: el gateway (fase 8) y MCP (fase 7) van a querer añadir providers
en tiempo de ejecución, y una lista cerrada exige cambio de código + release
por cada provider nuevo. La pérdida de exhaustividad en compile-time se
compensa con el behaviour, que es la misma forma que ya usan los agentes
(D-13, D-14).

**Desbloquea**: Fase 7 (MCP), Fase 8 (Gateway), Fase 12 (CLI).

---

## D-18 · El camino de librería: fuera de las fases

**Cuándo**: 2026-10-18, por el dueño (recomendación del agente, aceptada).
**Qué**: la librería (`lib/candil/`) no es una fase: es el sustrato sobre el
que se construye todo (el behaviour, los agentes, el router). El CLI es el
empaquetado y tiene su propia fase (12). Lo que merece una fase es la
**documentación pública** (ExDoc ya se genera) y la **estabilidad del
contrato** (`@type result/0` y compañía, cerrado en F5.0).

**Por qué**: tratar la librería como fase confunde «entregable» con
«fundamento». El gateway (fase 8) existe precisamente para que procesos que
no son Elixir usen Candil, pero la librería es la base.

---

## D-19 · `rest_for_one`: no se implementa

**Cuándo**: 2026-10-18, por el dueño (recomendación del agente, aceptada).
**Qué**: `rest_for_one` no se implementa. Sin caso de uso real, YAGNI.

**Por qué**: un agente que cede el turno a otro no existe hoy. La mesa camilla
(fase 9) es el primer candidato; si allí aparece la necesidad, se reabre.

**Se revisará cuando**: la mesa camilla (fase 9) muestre un caso donde un
agente deba caer junto a otro.

---

## D-20 · El breaker de crashes: ETS persistente + `restart: :transient`

**Cuándo**: 2026-10-18, por el dueño (recomendación del agente, aceptada).
**Qué**: la mitad restante del §8.3 se cierra con **`restart: :transient`** para
los agentes cuyo circuito esté abierto, combinado con el estado del breaker en
ETS (ya implementado en `Candil.Agents.Breakers`). Un agente que revienta en
bucle deja de reiniciarse cuando su circuito está abierto; los agentes sin
nombre se quedan con la intensidad global del supervisor (10/5 s), que es la
única defensa disponible sin identidad.

**Por qué**: es consistente con la arquitectura ya establecida (ETS en el árbol
de la aplicación, por nombre, como `Snapshots` y `Breakers`). No requiere
rediseñar el supervisor.

**Se dejó de hacer**: un presupuesto de crashes por agente en el supervisor
(ya implementado en tanda 3 para los nombrados), y el diseño de supervisor
completo para los sin nombre.

---

## D-21 · `:degrade` se mantiene declarado y se reinterpreta al existir la cobertura

**Cuándo**: 2026-10-18, por el dueño (recomendación del agente, aceptada).
**Qué**: `:degrade` sigue en el tipo del refusal (D-09) y sigue sin ser
alcanzable. Cuando exista el enrutado por cobertura, «degradar» es simplemente
pedirle al scorer que elija el siguiente candidato capaz (excluyendo el que
falló). Eso hace que `:degrade` deje de ser un tercer valor de la estrategia
y se convierta en comportamiento automático del enrutado. D-09 pasaría de «tres
estrategias» a «dos, y el tercero es cómo funciona el enrutado». Se mantiene
declarado hasta que la cobertura exista y se pueda medir si alguien lo echa de
menos.

**Por qué**: no borrar una decisión del dueño sin medir antes; y no implementar
algo que quizá se colapse en lo que ya hay.

---

**La frase que resume todo**:
> Las decisiones abiertas se cierran registrando la respuesta y el porqué, no
> implementando lo que aún no tiene caso. El código llega cuando la decisión
> tiene un consumidor que lo pida.

---

## D-22 · La memoria común: un mapa clave→valor, no historial

**Cuándo**: 2026-10-19, por el dueño.
**Qué**: la memoria común (F2.4, fase 9) es un **mapa clave→valor compartido**
que todos los consumers leen y escriben, con su propia clave (`mem:*`). No es
historial: responde a «qué sabemos», no «qué hemos dicho». Cuatro respuestas:

1. **¿Qué es?** Un mapa clave→valor compartido, con prefijo propio `mem:*`.
   No es historial: es un producto distinto porque responde a otra pregunta.
2. **¿Quién escribe?** Todos, con marca de autor (`meta.author`). Con varios
   consumers escribiendo a la vez hace falta `put_new/2` o compare-and-swap.
3. **¿Se puede desmentir?** Sí, y tiene que poder. Sin desmentir, la memoria
   miente cada vez más fuerte. Se desmiente creando una nueva entrada con
   `superseded_by`, o borrando y volviendo a escribir.
4. **¿Se resume?** No. Se poda por antigüedad y caducidad (`expires_at` por
   entrada). Resumir una memoria compartida produce una memoria que nadie
   reconoce.

**No depende del RAG ni de un embedder**: una memoria que se busca por clave
(`mem:proyecto_42`) es un `get`, no un vector. Los embeddings solo harían
falta si se busca por significado («¿qué sabemos del proyecto 42?» sin decir
el 42). Atarla al RAG le ponía un prerrequisito que no necesita.

**Desbloquea**: F2.4 (SharedMemory), F2.7 (voces / mesa camilla).

---

## D-23 y D-24 · Ya decididas (D-21 y D-19)

**D-23 = D-21.** `:degrade` se mantiene declarado y no alcanzable; se
reinterpreta cuando exista la cobertura. Eso es literalmente «se colapsa en
el scorer». Misma decisión, otro número; no se reabre.

**D-24 = D-19.** `rest_for_one` no se implementa. Sin caso de uso real, YAGNI.
Se revisa cuando la mesa camilla (fase 9) sea el primer candidato.

No se crean entradas nuevas para estas: el registro ya tiene la respuesta.

---

## D-25 · El breaker de los agentes sin nombre

**Cuándo**: 2026-10-19, por el dueño.
**Qué**: `restart: :transient` ya está en los dos `child_spec` (D-20). La
pregunta real no era «breaker o transient» — ambas ya conviven — sino que **un
agente sin nombre se salta las dos puertas** (presupuesto de crashes y
circuito), porque no tiene dónde persistir nada:

```elixir
cond do
  name != nil and Crashes.count(name, now()) >= budget -> {:stop, :crash_budget_exceeded}
  name != nil -> ... Breakers.load(name) ...          # el circuito
  true -> init_state(name, opts)                      # sin nombre: ni presupuesto ni circuito
end
```

Tercera opción, la correcta: **darle identidad derivada** —`{módulo, hash de
las opciones}` o el `goal`— para que caiga en la misma puerta que los
nombrados. Evita el caso raro de tener que decir «los agentes anónimos son
los que cuelgan».

**Si se prefiere que sigan sin protección**, queda escrito como decisión
explícita: «un agente anónimo no tiene identidad y aceptamos que un cuelgue
suyo lo mate». Lo que no puede ser es que siga siendo una pregunta abierta
mientras el código parece protegerlo.

**Desbloquea**: P-9 última mitad.

---

## D-26 · El cargador del catálogo avisa de claves desconocidas

**Cuándo**: 2026-10-19, por el dueño.
**Qué**: `Candil.Config.Hydrate` ahora emite un `Logger.warning` cuando una
sección (`engine`, `model`, `provider`) tiene claves que no conoce. La causa
de fondo: tres veces el mismo fallo —`typical_latency_s`, `engine_pid`,
`vram_mb`— donde un campo existía en el struct pero nadie lo rellenaba ni
validaba, y el cargador lo ignoraba en silencio.

La raíz no es el cuarto campo: es que el cargador no avisaba. Con el aviso,
el cuarto se habría visto solo. Ahora se ve.

**También**: `Model.vram_mb` se hidrata (`spec["vram_mb"]`) y se valida en
el schema (entero no negativo). El template del TOML lo documenta.

---

## D-27 · Quién elige el device y cómo se le dice al motor

**Cuándo**: 2026-10-20, por el dueño (medición + corrección de la
propuesta del agente).
**Qué**: **Candil elige el device y se lo impone al motor.** La reserva
(`Arrea.Resource`) se hace **antes** de arrancar, con un peso que sale de
la configuración y no del catálogo. El motor arranca con `--device CUDA<N>
--split-mode none --main-gpu N`, y el `--fit` se deja en `on` como red de
seguridad, pero el número de capas que Candil le pasa es un **entero
calculado**, no `-1`.

### La medición que decide la pregunta

El mismo modelo (`Qwen3-Coder-30B-IQ3_XXS`, 12,8 GB), la misma RTX 5080
(16303 MiB), cuatro configuraciones:

| Configuración | Resultado |
|---|---|
| `--n-gpu-layers 99`, caché f16 | **OOM** — pedía 12288 MiB de KV cache |
| `--n-gpu-layers 99`, caché `q8_0` | **OOM** — pedía 6528 MiB de KV cache |
| `--n-gpu-layers 99`, caché `q8_0`, ctx 32768 | carga, **15551 MiB** |
| `--n-gpu-layers -1`, caché `q8_0`, ctx 131072 | carga, **14913 MiB** |
| `--n-gpu-layers -1`, caché `q8_0`, ctx 131072, `--fit off` | **OOM — muere** |

Dos hechos que la decisión depende:

1. **`-1` depende de `--fit`.** Con `--fit off`, `-1` pide todo y hace OOM.
   Con `--fit on`, `-1` se recorta y carga. El catálogo usa `-1` en casi
   todos los modelos, así que «apagar `--fit` y dejar `-1`» es lo que
   el consejero propuso primero y la medición muestra que **no carga**.

2. **La huella no es del modelo, es de la configuración.** El mismo fichero
   ocupa 15551 MiB con ctx 32768, 14913 con ctx 131072 y `-1`, y **no
   cabe** con `99` en ningún contexto. Las tres variables —`ctx-size`, tipo
   de caché, `n-gpu-layers`— viven en `model_args` o se derivan de ellas.

**Conclusión**: `vram_mb` **no puede ser un número del modelo**. El mismo
modelo con distinto `model_args` ocupa 15551 o 14913 MiB, o no cabe. Un
número en el catálogo no puede ser la verdad porque la verdad depende de
unos flags que el catálogo también tiene.

### Las tres correcciones a la opción A

**A.1 · Nada de `--fit off`.** Al revés: `--fit` **on** es lo que permite
que el `-1` del catálogo funcione. Si Candil decide el device y quiere que
el motor no recorte, la forma de decirlo no es apagar `--fit` — es **no
poner `-1`** y poner el número de capas que Candil calcula. Si Candil
decide, decide también las capas, y entonces `--fit` no tiene nada que
recortar.

**A.2 · `--device` no acepta índices.** El formato real es el nombre que da
`--list-devices` —`CUDA0`, no `0`— (medido: `--device 0` → `invalid
device: 0`). Hay que traducir `device_index` (entero) → `CUDA<N>`. Y
`--main-gpu` **sí** es un índice. **Dos sistemas de coordenadas en la misma
línea de comando.** `--split-mode none` para un solo device.

**A.3 · El peso de la reserva se calcula, no se declara.** Ver abajo.

### El peso de la reserva

La huella que se reserva al cargar es **los pesos del modelo + el KV cache
al `ctx-size` declarado**, porque el KV cache se reserva entera al cargar:
no depende del contexto que se use, sino del máximo que se declara. Eso es
un dato que se puede calcular **antes** de arrancar.

El catálogo da la configuración (`context_size`, `model_args` con el tipo
de caché), y el peso es una función de ella. `vram_mb` **no es la verdad**:
es una estimación que el usuario escribe a mano, en un campo que el
cargador avisa cuando está vacío pero no cuando está equivocado (D-26). Es
el mismo patrón por tercera vez.

**De dónde sale el peso**: de la configuración y del tamaño del fichero
GGUF (los pesos). La fórmula del KV cache necesita los parámetros de la
arquitectura (capas, cabezas KV, dimensión de cabeza), que están en los
metadatos del GGUF. El mecanismo concreto —parser de GGUF en Elixir vs.
llamar a `llama-fit-params` vs. un fichero de medición aprendida— se decide
en la implementación; la decisión es que **el peso no puede ser un número
del catálogo**, y que debe ser calculable antes de arrancar. `vram_mb`
queda como fallback/estimación, no como verdad.

### La reserva tiene tres estados

La medición muestra que el OOM **mata el proceso**: no es un error suave,
es llama-server saliendo con «exiting due to model loading error». Por eso
la reserva necesita **tres estados, no dos**:

1. **`reservada`** — Candil ha adquirido capacidad en `Arrea.Resource`
   antes de arrancar, con el peso calculado.
2. **`arrancada`** — el motor ha cargado y Candil ha medido la VRAM real
   por PID (D-16). Si la medición es mayor que la reserva, se corrige
   (`release` + `acquire` con la medición, opción (ii) de D-27). Si es
   menor, la reserva se queda como está (conservador).
3. **`liberada`** — el motor se para o muere. La reserva se libera.

El paso de `reservada` a `arrancada` **falla** cuando el motor muere (OOM).
En ese caso la reserva se libera y el caller recibe el error. Sin este
paso, un OOM deja una reserva fantasma y el planificador cree que ese
device está ocupado.

### Reintento

Con **varios devices**, si el motor falla al cargar en uno, se libera la
reserva y se reintenta en otro (opción C). Con **una sola GPU**, un OOM es
un OOM: no hay a dónde reintentar, y la respuesta honesta es «no cabe», no
«reintenta». El reintento es un beneficio de tener varios devices, no un
requisito de la reserva.

### Lo que esto NO hace

- **Multi-GPU con split** (`--split-mode layer`, `--tensor-split`): es otro
  problema (P-6), no se toca ahora. Cada motor va a un solo device.
- **Cablear `Arrea.Resource`**: hecho en la implementación (2026-10-21).
  Queda el reintento multi-device (P-6). **Y `vram_mb` en el catálogo no se
  rellena** (P-10): la medición dice que el mismo modelo ocupa 795, 7978 o
  10452 MiB según la memoria libre del instante, así que un número del
  catálogo sería la cifra de un momento y no la verdad.
- **Medición fuera de NVIDIA**: el peso se calcula de la configuración y de
  la medición por PID (`nvidia-smi`). En Metal/ROCm no hay `nvidia-smi`;
  ahí la reserva queda como estimación hasta que exista su equivalente.

### Consecuencias

- **D-16 se hace real**: Candil consume la medida (por PID) y decide el
  device. La columna `SLOT` del `candil status` ya no usa el puerto (T-6).
- **El `-1` del catálogo deja de pasarse tal cual**: `build_args` pasa un
  entero que Candil calcula, o `0` cuando `--cpu`. El `--fit` se queda
  encendido como red de seguridad, pero no tiene nada que recortar si el
  número es correcto.
- **`vram_mb` se degrada a fallback**: la verdad es el peso calculado +
  la medición. `vram_mb` sigue sirviendo cuando no hay otra cosa (CPU, o
  sin GPU).
- **P-4 queda desbloqueado**: la reserva se hace antes de arrancar, en el
  device que el plan eligió, con un peso que sale de la configuración.

### Lo que se decidió al implementarlo (2026-10-21)

La implementación encontró tres cosas que la decisión no había fijado, y una
que estaba mal en el primer intento:

- **La cuota de `Arrea.Resource.acquire/4` es `0`, no `:infinity`.** El eje
  blando de `acquire/4` valida `is_number/1` en los dos importes; `:infinity`
  solo vale como opción `:quota` del resource. Pasar el átomo devolvía
  `:unknown_cost` y **abortaba todos los arranques de GPU**. El wrapper
  `Candil.Engine.Resource.acquire/3` ya no acepta cuota: siempre `0`.
- **`vram_mb` no es obligatorio.** Si falta, el modelo **arranca** igualmente:
  se reserva una **estimación** provisional —un marcador de posición para los
  segundos que tarda `llama-fit-params` en medir— y en cuanto llega la
  medición, la reserva se **sustituye** por el peso real. Se avisa por
  `Logger.warning`. La reserva es planificación, no arranque: un modelo sin
  `vram_mb` no puede planificarse bien, pero no puede dejar de funcionar por
  eso.
- **`vram_mb` es una cota inferior declarada, y la reserva la sustituye.**
  El peso que se reserva es **el que el motor va a ocupar**, no
  `max(declarado, real)`. Si el peso medido es mayor, la reserva sube; si es
  menor, **también baja**, porque quedarse en la cota inferior reservaría
  memoria de más. Y esa bajada no es un detalle: con el mismo modelo y la
  misma GPU, el `vram_mb` medido en el pie (`coder`, 12744) es **mayor** que
  el peso ajustado que de verdad ocupa cuando llama.cpp recorta las capas que
  no caben (7978 con la memoria que había). Si la reserva se quedase en
  12744, no cabría en el device y **el modelo no arrancaría**: el `vram_mb`
  medido impediría que el modelo arrancase recortado.
- **La estimación por contexto no puede ser la reserva final.**
  `div(ctx, 1024) * 4` daba 512 MiB para un modelo que ocupa 7978: reservar
  de menos es peor que no reservar, porque el knapsack afirma capacidad que
  no tiene. Por eso la estimación es solo el marcador de posición de los
  segundos que tarda la medición, y lo que se reserva al final es **el peso
  real**.
- **La capacidad es la del motor.** Se registra el total de `nvidia-smi`
  (16303 MiB en la RTX 5080) y se reservan 370 MiB como titular `:system`;
  `available/1` devuelve 15933. La cuota de ese acquire también es `0`.
  **Pero 15933 no es la memoria que hay**: es la que habría si nadie más
  usara la GPU. La memoria que usa **otra gente** entra como un titular
  más, `:foreign` (ver la segunda ronda abajo).
- **El titular es `{alias, port}` y se construye en un solo sitio**
  (`Candil.Engine.holder/2`). `Engine.start/3` reserva; `Server.terminate/2`
  libera. Si `init/1` falla, `terminate/2` no se llama y libera `Engine.start/3`.
  Los titulares ajenos a Candil usan el átomo `:foreign`, que es otra cosa y
  no se confunde con ninguno de ellos.
- **`Server` atrapa salidas (`trap_exit`).** Sin eso, la salida de `LongRunning`
  —el motor murió— mataba el GenServer por el link **sin pasar por
  `terminate/2`**, y la reserva se quedaba puesta para siempre. El
  `handle_info` de `{:EXIT, lr_pid, reason}` para el server por la misma razón y
  así `terminate/2` corre. `Engine.stop/1` tolera la carrera con una parada en
  curso.

### La segunda ronda (2026-10-21): lo que falló al arrancarlo de verdad

La primera implementación pasó los tests y **no arrancaba un modelo**. Los
tests medían las funciones, no el camino real. Estos son los fallos que solo
aparecieron al poner un GGUF delante, y lo que se cambió en cada uno.

**1 · El peso se leía de la línea equivocada.** `parse_weight/1` leía el
`projected to use` (19053 MiB) en vez del `mem=` ajustado (7978 MiB). La
diferencia no es un detalle: el `projected to use` es lo que haría falta **si
TODO el modelo cupiera en GPU**, y el `mem=` es lo que ocupará **después** de
recortar. Reservar 19053 contra una capacidad de 15933 se rechaza siempre, así
que **el modelo que necesita recorte era justo el que no podía arrancar** —
el recorte es lo que permite que un modelo grande quepa en una GPU pequeña.
llama.cpp puede escribir **varias** líneas `mem=` (prueba varias
configuraciones), así que ahora gana la última, validada contra el `-ngl` de
los args ajustados.

**2 · El `-ot` llegaba con las comillas dentro.** Partir la línea de args por
espacios deja el valor del `-ot` como `"blk\.11\.ffn_down.*=CPU,…"`, y
llama-server responde `error while handling argument "-ot": unknown buffer
type` y **no arranca**. Medido en las dos formas: con las comillas no arranca;
sin ellas carga y responde `{"status":"ok"}`. Ahora el tokenizador trata el
valor entrecomillado como una unidad y le quita las comillas.

**3 · La reserva solo subía, y había que bajar.** La corrección subía al peso
medido pero nunca bajaba, porque el diseño original decía que «bajar
devolvería capacidad que el motor sigue ocupando». La medición dice lo
contrario: el `vram_mb` del pie (12744) es **mayor** que el peso ajustado real
(7978), así que quedarse en la cota superior **impedía arrancar** al modelo
recortado. La reserva es **el peso real**, en los dos sentidos.

**4 · El ledger no veía la memoria ajena.** Decía 15933 MiB libres cuando los
reales eran menos: en la medición, 11518, de los que 4216 ocupaba un modelo de
**otra sesión**. La reserva se tomaba sobre memoria que ya no estaba, y el OOM
pasaba con la cuenta «correcta». `Arrea.Resource` no tiene API para cambiar la
capacidad de un resource registrado —y re-registrarlo perdería el ledger
entero—, así que la memoria ajena entra como **un titular más**, `:foreign`,
al lado de `:system`. Con eso, `available == free_real − 370`, que es
exactamente lo que un motor nuevo puede usar. Se reajusta antes de cada
colocación, con un umbral de 64 MiB para no provocar un `release`+`acquire`
por unos megas de diferencia entre dos lecturas de `nvidia-smi`.

**5 · Sin `vram_mb` no se reservaba nada.** Un modelo del catálogo sin
`vram_mb` arrancaba **sin reserva**: el planificador creía que ese device
estaba libre. Ahora se reserva la estimación como marcador de posición y se
sustituye por el peso medido en cuanto llega.

**6 · Un modelo de CPU pedía VRAM.** `Scheduler.plan/1` pasaba por el
knapsack de GPU a un modelo con `gpu_layers == 0`: con la GPU llena, un modelo
que corre en CPU se rechazaba con `:no_room`. **Un modelo de CPU no puede
quedarse sin arrancar por falta de GPU**, así que ahora devuelve
`{:ok, nil}`.

**7 · El CLI y la API arrancaban por caminos distintos.** `candil run` llamaba
`Engine.start/2` con `device = nil`: sin scheduler, sin reserva y sin
`--device`. El camino que usaba una persona era el que no reservaba. Ahora
los dos usan `Candil.Engine.start_placed/2`, que es **el** camino: el
scheduler decide dónde va el modelo, se reserva la VRAM, y si hay que expulsar
a alguien, se expulsa.

**8 · `candil stop` no paraba el motor.** El `engine_pid` del registro es el
pid del `llama-server`, un **proceso del sistema operativo**, y el dueño es un
BEAM: matar al dueño no se lleva por delante al motor. Medido: `candil stop`
decía «1 instancia parada», el registro quedaba vacío, `candil status` decía
«no hay instancias»… y el `llama-server` seguía ahí con **8116 MiB de VRAM
cogidos**. Dos herramientas diciendo verdad sobre cosas distintas, y la que
decía «parado» mintiendo. Ahora `stopped_remote/1` mata también al motor.

**9 · Cuando la GPU está llena, el recorte no cabía en el ledger.** Con otra
sesión ocupando la GPU (42 MiB libres de verdad), la memoria ajena que había
que descontar eran 16261 MiB, y el hueco que queda tras `:system` son 15933:
**no cabía**. El `acquire` del titular fallaba, el error se tragaba, y la
disponible se quedaba en **15933** — la cifra que no existía. Justo la
mentira que este módulo viene a quitar, en su forma extrema. Ahora el titular
se recorta a lo que queda representable, y la disponible cae a **0**: un 0 es
honesto; un 15933 no. Lo malo es que este caso **solo aparece cuando la GPU
está llena**, o sea cuando más importa.

**10 · Un motor de CPU pedía una GPU que no necesitaba.** El camino único
(`start_placed/2`) consulta al scheduler, y el scheduler solo ve el modelo: un
modelo del catálogo con `gpu_layers: 99` que se arranca con `--cpu` lo pide
igual. En una máquina sin GPU, `candil run --cpu` se rechazaba con
`:no_room` — **un modelo que corre en CPU no puede quedarse sin arrancar por
falta de GPU**. Ahora el scheduler se consulta solo cuando el motor va a la
GPU.

**11 · El scheduler y la reserva podrían decir cosas distintas.** El scheduler
decía «cabe» comparando con `free_mb` de `nvidia-smi` (42 MiB), y la reserva
decía «no cabe» con la del ledger (0, porque el motor nuevo necesita 370 MiB
de contexto CUDA). El modelo no arrancaba, con un error que no explicaba nada.
Ahora **los dos sides usan la cifra del ledger**, que es la que descuenta el
overhead: `available` es exactamente lo que le cabe a un motor nuevo. Con la
misma cifra en los dos lados, la respuesta es la misma por construcción.

Y de ahí salió lo más caro de esta ronda: **un test que dependía de la
máquina**. `cpu_args_test.exs` arrancaba un motor de mentira por el CLI, y el
CLI ahora pasa por el scheduler: en CI (sin GPU) no había dónde colocarlo, y
en local la GPU podía estar ocupada por otra sesión. El test fallaba —o
pasaba— según la máquina, y **el fallo no era del código**.

Lo destapó el propio CI: en el runner **sin GPU** fallaron 8 tests, y ninguno
por un fallo del código —todos por `{:error, :capacity_unknown}` («no hay
capacidad») o por no haber sitio donde colocar el motor. La solución no es
saltarse el test (`@tag :skip`), que dejaría el caso sin cubrir: es **poner
delante un `nvidia-smi` de mentira** (`Candil.FakeGPU`) que diga lo que el
test necesita. El código de producción no cambia, y el test además puede
reproducir un caso que en la máquina real es difícil: **la GPU llena**, que es
donde el titular `:foreign` no cabe en el ledger y la disponible tenía que
caer a 0. Un test que depende del hardware de quien lo corre no es un test: es
una lotería.

**12 · Y debajo de eso había un crash de producción.** El `nvidia-smi` de
mentira destapó un bug que no era de tests: `Candil.Detector.GPU` pregunta la
versión de CUDA con `System.cmd("nvcc", ...)`, y **`System.cmd/3` no devuelve
un error cuando el binario no existe: lanza una `ErlangError` con `:enoent`**.
El driver de NVIDIA se puede instalar **sin el toolkit de CUDA**, así que
`nvcc` no está en muchísimas máquinas que sí tienen GPU —y en todas ellas
Candil reventaba al detectar el hardware. En el CI se ve porque el runner
tiene `nvidia-smi` (el de mentira) y no tiene `nvcc`.

El arreglo es preguntar antes de ejecutar (`Candil.Detector.GPU.cmd/2`), que
además cubre el caso de un binario que existe pero no se puede arrancar. Es
un crash de producción que llevaba años ahí, y lo ha destapado un test que
dependía de la máquina: **un test frágil no solo da falsos negativos, también
enseña cosas**.

### La tercera ronda (2026-10-21): la revisión del consejero

El consejero revisó el PR y retiró tres cosas: **la semántica de
`vram_mb`**, **el error de «no hay GPU»** y **la identidad del titular**. Las
tres están cambiadas, y una de ellas ha encontrado un bug de verdad.

**`vram_mb` es una cota inferior, no una foto.** Es el **mínimo** que el
modelo ocupa con seguridad —el peso *después* de que llama.cpp recorte las
capas que no caben—, no el footprint completo y no «cuánto ocupaba la última
vez». Con esa semántica, el acquire inicial es seguro (si la cota no cabe, el
peso real, que es >= la cota, tampoco cabe) y el scheduler no rechaza un
modelo recortable por un número alto. **El catálogo no lleva ninguno**, y el
`template.ex` lo dice con esas palabras.

**El mutex no es una reserva.** Sin `vram_mb`, lo que se toma es un **mutex**
—una estimación provisional para serializar los arranques concurrentes
mientras `fit-params` mide—, y un mutex **no puede rechazar**: si no cabe,
el modelo sigue y **la medición** decide, que es lo único que sabe cuánto va
a ocupar de verdad. La honestidad del ledger la da el titular `:foreign`, no
la estimación.

**`:no_gpu` no es `:no_room`.** «Esta máquina no tiene GPU» y «no cabe» son
hechos distintos, y el primero tiene salida (`--cpu`) mientras el segundo no.
Ahora el scheduler devuelve `{:error, :no_gpu}` cuando no hay devices
usables, y la API y el CLI devuelven **el mismo** error. Unificar el
comportamiento sin unificar el error no arregla nada.

**El titular lleva una generación.** `{alias, port}` no es único en el
tiempo: si el puerto se reutiliza y el `terminate/2` del server viejo llega
tarde, su `release/2` —que quita la primera entrada de ese titular— podía
soltar la reserva **del modelo nuevo**. Ahora el titular es
`{alias, port, make_ref()}`, se crea **una vez** en `Engine.start/3` y lo
usan el acquire, la corrección y el `terminate/2`.

> Medido: con el titular sin generación, el test nuevo falla con «un release de
> un titular viejo soltó la reserva del nuevo». Con ella, verde.

Y una limitación que se ha **documentado** en vez de resuelta: el ajuste de
`:foreign` son dos llamadas (`release` + `acquire`) y entre ellas hay un hueco
—microsegundos— en el que otro arranque ve una disponible demasiado grande. El
daño está acotado, porque la corrección al peso **medido** es la que sí es
atómica y el modelo que no quepa se para. Con un solo usuario es despreciable;
si algún día el scheduler coloca dos modelos a la vez, hay que serializarlo
por device.

### La cuarta ronda (2026-10-22): tres decisiones del consejero

El consejero revisó la ronda anterior y decidió tres cosas. Las tres están
hechas, y **una de ellas era un bug de verdad** que solo se vio al medir.

**1 · Las víctimas se contaban con la estimación, no con la verdad.** El
scheduler expulsa a las víctimas **por tamaño**, así que la cuenta decide si
dice «no cabe» o expulsa a alguien. Y la cuenta era
`model.vram_mb || estimate_model_size(model)`: un modelo **corriendo** sin
`vram_mb` contaba como 512 MiB (la estimación) cuando ocupaba 7978 de
verdad.

Medido el 2026-10-22 con un `coder` corriendo: `nvidia-smi` decía **1054 MiB**
y el scheduler contaba **512**. Con un modelo de 8 GB la diferencia es de 7 GB,
y la expulsión no libera lo que cree que libera.

Ahora el tamaño de una instancia es el que dice `nvidia-smi`
(`Candil.Scheduler.size_mb/2`), y la estimación solo se usa cuando **no hay
medición** —un modelo en CPU, o una máquina sin `nvidia-smi`.

**2 · Decidir y reservar son una sola operación, y no había cerrojo.** Dos
`start_placed/2` concurrentes pueden medir **la misma** memoria libre (el
`sync_foreign` de uno todavía no ve lo que el otro acaba de reservar) y decidir
los dos que su modelo cabe. El primero reserva; el segundo recibe un error de
acquire que no explica nada y su modelo no arranca, cuando lo que había era
sitio de sobra y una carrera.

Ahora hay un **semáforo** (`Candil.Engine.Resource.Placement`): el segundo
espera y vuelve a decidir con la memoria ya cambiada.

> Y un detalle que costó un rato: el cerrojo **no** es `:global.trans/3`. En
> OTP 28 la API de cerrojos de `:global` ya no existe y `trans/3` se quedó
> **sin hacer nada**: medido, dos llamadas concurrentes de `trans/3` tardaron
> 1,0 s en vez de 2,0 s. El semáforo es un `GenServer` que **da el turno** (el
> motor tiene que seguir siendo hijo de quien lo pide, no del cerrojo) y
> suelta el turno aunque el que lo tenía se muera.

**3 · Un modelo que fija las capas en GPU se rechaza.** `llama-fit-params` no
puede ajustar un `--n-gpu-layers` que el usuario puso: aborta con *«n_gpu_layers
already set by user to 99»*. Sin medición no hay peso real, la reserva se
queda en una suposición y el motor arranca a ciegas.

Ahora el scheduler devuelve `{:error, :gpu_layers_fixed}` con un mensaje que
dice qué hacer (usa `-1` o `--cpu`), **en vez de arrancar a ciegas**. La
excepción son los modelos con `--n-cpu-moe`: los expertos se van a la RAM, lo
que queda en la VRAM cabe, y el modelo arranca bien — pero su reserva **tampoco
se mide**, y de eso avisa el motor con un warning.

Medido el 2026-10-22 con un modelo de 13 GB y la GPU con 15 886 MiB libres: con
99 el fit aborta y el motor sale con código 1; con `-1` el fit ajusta y el
modelo arranca.

### Verificación de la implementación (2026-10-21)

Medido con `Agents-A1-4B-Q8_0.gguf` (4,48 GB), ctx 32768, caché `q8_0`,
device 0, y un `vram_mb` declarado de 1000:

| Paso | Medida |
|---|---|
| `available` antes | 15933 MiB (16303 − 370 de overhead) |
| `llama-fit-params` | 5395 MiB, `-c 32768 -ngl -1` |
| `available` con el motor cargado | 10538 MiB (reserva corregida de 1000 a 5395) |
| `available` tras parar | 15933 MiB |
| motor cargado | `healthy: true`, 5458 MiB en `nvidia-smi` por PID |

Los tests de máquina `resource_machine_test.exs` (arranque fallido y motor que
muere), `fit_params_machine_test.exs` y `scheduler_machine_test.exs` pasan con
la GPU real.

La primera ronda **no pudo arrancar un modelo del catálogo**: los GGUF de
`~/models/gguf/` habían desaparecido durante la sesión y ningún modelo del
catálogo declaraba `vram_mb`. La segunda ronda sí, y con el modelo que
importa: el que necesita recorte.

#### La segunda medición, con el modelo que necesita recorte

La tabla anterior usa un modelo de 4,48 GB que cabe de sobra. El caso
interesante es el otro: un modelo **grande** que solo arranca si llama.cpp
recorta las capas que no caben. Medido con `Qwen3-Coder-30B-IQ3_XXS` (12,8 GB),
ctx 131072, caché `q8_0`, tres veces con la GPU en distinto estado:

| Memoria libre en el momento | Peso ajustado (`mem=`) | `projected to use` |
|---|---|---|
| GPU ocupada | **795 MiB** | 19053 MiB |
| GPU medio libre | **7978 MiB** | 19053 MiB |
| GPU libre | **10452 MiB** | 19053 MiB |

Tres cosas salen de esta tabla:

1. **El peso que hay que reservar es el `mem=` ajustado**, no el
   `projected to use`: con 19053 contra una capacidad de 15933, la reserva se
   rechaza siempre y **el modelo que necesita recorte no puede arrancar**.
2. **El mismo modelo ocupa 795, 7978 o 10452 MiB** según cuánta memoria
   hubiera libre. No es una propiedad del modelo: es una propiedad del
   modelo **en esa GPU, en ese momento**.
3. Por lo tanto **`vram_mb` no se rellena en el catálogo** (P-10): un número
   escrito a mano sería la cifra de un instante, y Candil lo corrige igual
   con el peso medido. Queda como **pista opcional** —una estimación previa
   para que un arranque que no cabe falle pronto en vez de a los 4 s—, y el
   comentario del `template.ex` lo dice así.

El criterio de aceptación del plan era que la disponible **dejase de mentir**:
que `available` fuese la memoria real menos el overhead, y no el total del
device. Medido: con 11718 MiB libres de verdad, la disponible pasó de **15933**
(la del total, que no existía) a **11348** (= 11718 − 370).

Y el arranque de verdad, con `candil run --detach --port 9991 coder`: la
columna `VRAM` mostró **8116 MiB**, los mismos que `nvidia-smi` —el motor
usando lo que dice y no lo que el catálogo promete.

La puerta de máquina (`resource_machine_test.exs`) arranca el modelo **por el
camino único** —`Candil.Engine.start_placed/2`—, así que el scheduler está en
el camino de verdad, y comprueba que hay reserva después de arrancar. Eso es
lo que prueba que `place/3` **se ejecutó**: `Engine.start/3` con `device = nil`
no reserva nada, así que que haya reserva prueba que alguien decidió un
device, y el único que decide es el scheduler. Medido el 2026-10-21 con
`Qwen3-Coder-30B-A3B-Instruct-UD-IQ3_XXS`: 3/3 en verde, el motor sano y la
reserva igual al peso ajustado.

Y la suite se pasa **con GPU y sin GPU**: los tests que miden hardware usan
el `nvidia-smi` de mentira, así que el resultado es el mismo en el runner de
CI (que no tiene GPU) y en la máquina con la RTX 5080 delante.

### Cómo se revisa

- Si el peso calculado resulta sistemáticamente mayor o menor que la
  medición, la fórmula (o el parser de GGUF) se ajusta, no el contrato.
- Si un modelo con split multi-GPU resulta necesario, se abre P-6 con
  `--split-mode layer` + `--tensor-split`, y la reserva pasa a ser por
  device, no por motor.
- Si alguien quiere apagar `--fit` (para tener control total), primero hay
  que medir que el entero calculado cabe en el device elegido. Eso es un
  gate de máquina, no de CI.

## D-28 · Qué es un «device» y de dónde salen sus cifras

**Cuándo**: 2026-10-22, a propuesta del dueño, escrita por el consejero.
**Qué**: un device no es «una GPU NVIDIA». Es **un slot con un nombre, un
presupuesto y una sola fuente de medida**. El nombre con el que se le habla al
motor sale del motor; las cifras salen de una única fuente por backend; y
`:system` desaparece del ledger.

**Por qué ahora**: D-27 dejó la reserva escribiendo en MiB de VRAM, y P-12
surgió de medir que Candil **no ve** una GPU que no sea de NVIDIA ✓. No es un
detalle de implementación: es el punto donde el «device» del scheduler deja de
ser una GPU y pasa a ser un presupuesto con nombre ✓.

### El nombre lo publica el motor

`llama-server --list-devices` publica el nombre real:

```
CUDA0: NVIDIA GeForce RTX 5080 Laptop GPU (15933 MiB, 15683 MiB free)
```

Ese `CUDA0` es el que acepta `--device` ✓. **No se deriva del índice** ✓:
`CUDA#{device}` vale para CUDA y es **falso** para ROCm, SYCL o Vulkan ✓.

`--main-gpu` sigue siendo un índice ✓, pero es **otra coordenada** ✓: no se
confunde con el nombre del device ✓.

El índice del scheduler es el que acompaña a ese nombre en la lista del motor
✓. Si la medida viene del sistema y no se puede emparejar el índice del
sistema con el nombre del motor, el device queda `usable: false` ✓: no se
inventa el nombre ni se cruzan coordenadas ✓.

### Una sola fuente por backend

La invariante es:

```
available = capacity − foreign − candil_used
```

donde:

- `candil_used` = suma de los titulares de modelos de Candil, **excluyendo
  `:system` y `:foreign`** ✓.
- `foreign` = la memoria que no es de los modelos de Candil, medida **en la
  misma fuente que `capacity`** ✓.

**La fórmula miente si `capacity` viene de una fuente y `free` de otra** ✓. No
se registra la capacidad de `nvidia-smi` y se mide el libre del motor ✓, ni al
revés ✓.

#### Convención A · la del motor

`capacity = total_engine` y `free = free_engine`, los dos de
`--list-devices` ✓:

```
foreign   = max(capacity − free_engine − candil_used, 0)
available = max(free_engine − candil_used, 0)
```

El overhead ya está **fuera** de `capacity` ✓: no se resta otra vez ✓ y no se
registra `:system` ✓.

#### Convención B · la del sistema

`capacity = total_system` y `free = free_os`, los dos de la misma medición del
sistema ✓ (`nvidia-smi` en CUDA ✓):

```
foreign   = max(total_system − free_os − candil_used + overhead, 0)
available = max(free_os − overhead − candil_used, 0)
```

El `overhead` va **dentro** de `foreign` ✓, no como titular aparte ✓.

**Y el overhead no es una constante universal** ✓: los 370 MiB son la medida
de CUDA **en esta máquina** ✓ (16303 − 370 = 15933 ✓, que es exactamente el
total que ve llama-server ✓). En ROCm, SYCL, Vulkan o Metal se mide o se
declara desconocido ✓; **no se hereda** ✓.

### Memoria unificada

En un backend de memoria unificada no hay una GPU con memoria separada: hay
un presupuesto del sistema ✓. La fórmula es:

```
foreign   = max(total − free − candil_used, 0)
available = max(free − candil_used, 0)
```

`foreign` **nunca es 0 por defecto** ✓: se calcula ✓. Si no hay una medida real
de `free`, el device queda `usable: false` ✓; no se pone `free = total` ✓.

### Sin medición no hay cifra

Si `capacity` o `free` no son enteros **medidos** ✓:

- no se registra el resource, o se registra con `usable: false` ✓;
- el scheduler devuelve `:no_gpu` o `:memory_unknown` ✓;
- **nunca** se devuelve `available = 0` como si fuera una medida ✓.

Un `0` solo es válido si `capacity` y `free` se midieron y la resta da 0 ✓ (la
GPU está llena de verdad ✓). «No lo sé» no es «no queda nada» ✓.

### Se retira `:system`

`Candil.Engine.Resource` deja de adquirir el titular `:system` ✓. Con la
fuente del motor el overhead ya está fuera de `capacity` ✓; con la del
sistema va dentro de `foreign` ✓. **Tenerlo además como titular lo descuenta
dos veces** ✓.

`@overhead_mb` deja de ser una constante global ✓: pasa a ser una
**calibración por backend** ✓, con su procedencia medida ✓. Si no se conoce,
el backend no usa la convención del sistema ✓ o queda `usable: false` ✓.

### Lo que esta decisión NO hace

- **Multi-GPU con split** (`--split-mode layer`, `--tensor-split`): sigue en
  P-6 ✓. El engine lo hace ✓; el ledger cuenta por device ✓.
- **CPU**: no hay device que reservar ✓; `--device none` ✓.
- **Proveedores remotos**: no ocupan esta GPU ✓; no entran en el ledger ✓.

### Verificación

- `--list-devices` con `CUDA0` → `--device CUDA0` ✓; con ROCm → `ROCm0` ✓,
  **nunca** `CUDA0` ✓.
- **Ningún** resource registra `:system` ✓.
- `unified_memory/0` **no** devuelve `free = total` con `usable: true` ✓.
- `sync_foreign/1` que no puede medir devuelve `:memory_unknown` ✓, y el
  scheduler **no coloca** ✓.
- GPU llena de verdad → `available: 0` **medido** ✓; medición ausente →
  `:memory_unknown` ✓, no 0 ✓.
- Un caso por backend simulado con `Candil.FakeGPU` ✓ y una puerta de máquina
  con GPU real ✓.

### Consecuencias

- **P-12 deja de ser una deuda y pasa a ser la implementación de esta
  decisión** ✓. Y toca más ficheros de los que parecía ✓:
  `engine/server.ex` ✓, `engine/fit_params.ex` ✓, `engine/resource.ex` ✓,
  `scheduler.ex` ✓, `scheduler/devices.ex` ✓ y `detector/devices.ex` ✓.
- **D-27 deja de decir que `CUDA<N>` es la forma general** ✓: era la
  convención de CUDA ✓, no la del proyecto ✓.
- El **nombre interno del resource** (`resource.ex:2-10` ✓) sigue siendo
  `:cuda0`… `:cuda31` ✓ → D-28 tiene que decidir si es el nombre del backend
  ✓ o un identificador neutro ✓; no se deja como deuda oculta ✓.

### Implementación (2026-10-23)

**La convención que se ha implementado es la del motor** ✓, y el resultado es
que **la fórmula del overhead desaparece** ✓: con la fuente del motor la
capacidad que se registra **ya viene sin el contexto** ✓, así que no hay
titular `:system` ✓ ni constante de overhead ✓.

Medido el 2026-10-22 con el motor real:

```
$ llama-server --list-devices
Available devices:
  CUDA0: NVIDIA GeForce RTX 5080 Laptop GPU (15933 MiB, 857 MiB free)

$ nvidia-smi --query-gpu=memory.total,memory.free --format=csv,noheader,nounits
16303, 1057
```

Las dos fuentes dan **la misma disponible** ✓ —15933 − (15933 − 857) = 857 ✓—
y no es casualidad: es la misma memoria contada desde dos sitios ✓.

**Una corrección a esta misma decisión** ✓: las dos líneas de `available` de
más arriba —la de la convención A y la de la B— restan `candil_used` **dos
veces** ✓. La invariante —`available = capacity − foreign − candil_used`— ya
lo dice bien ✓, y de ella sale:

```
available = free                   (convención A: la del motor)
available = free_os − overhead     (convención B: la del sistema)
```

El `free` que publica el motor **ya excluye** lo que ocupa Candil ✓, así que
restarlo otra vez sería descontarlo dos veces ✓. Lo que se ha implementado es
la invariante ✓, y las dos líneas quedaban mal ✓.

**Y el resto de lo que D-28 exigía**, con dónde quedó ✓:

| Lo que D-28 pedía | Dónde está |
|---|---|
| El nombre lo publica el motor | `Candil.Detector.EngineDevices` ✓ |
| Una sola fuente por backend | el ledger mide con la del motor ✓ |
| Se retira `:system` | `Resource.register/2` no lo adquiere ✓ |
| Sin medición no hay cifra | `sync_foreign/1` devuelve `{:error, :memory_unknown}` ✓ y el scheduler no coloca ✓ |
| `unified_memory/0` no dice `free = total` | mide con `vm_stat` ✓, y si no puede, `usable: false` ✓ |
| El nombre interno del resource | `:device0`…`:device31` ✓ (neutro) ✓ |

**Lo que la implementación ha añadido** ✓, y que D-28 no decía ✓: el error
`:memory_unknown` ✓, que es un **tercero** —«no hay GPU» ✓, «no lo sé» ✓ y
«no cabe» ✓— y que antes no existía ✓: los tres se confundían en `:no_room` ✓.

---


---

**La frase que resume todo** (ampliada):
> Las decisiones abiertas se cierran registrando la respuesta y el porqué, no
> implementando lo que aún no tiene caso. El código llega cuando la decisión
> tiene un consumidor que lo pida. Y un campo que nadie rellena no es un
> campo: es una mentira con nombre. **Y un `-1` que depende de un `--fit`
> que nadie controla no es una decisión: es una delegación.**
