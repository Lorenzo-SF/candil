# 08 · Decisiones

> **Qué se decidió, cuándo, por qué, y qué costó.** No solo el plan: también
> lo que se decidió *a mitad de una fase*, cuando el plan resultó estar
> equivocado, y lo que se cambió *entre* fases.
>
> Decidido hasta 2026-10-16 · `main` `1cc5cf0`

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
