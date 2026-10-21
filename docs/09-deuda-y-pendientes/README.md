# 09 · Deuda, pendientes y lo que falta por probar

> **Lo que está sin terminar, lo que se sabe roto, y lo que no se ha podido
> verificar porque no había con qué — y que desde el 2026-10-12 sí se puede,
> porque hay una máquina con una RTX 5080 delante.**
>
> 2026-10-21 · `main` `398a1b9` · **1327 tests + 33 doctests, 0 fallos** (6
> skipped) · la reserva de VRAM medida con una GPU de verdad (D-27).
>
> ⚠️ **Corregido el 2026-10-21**: la cabecera de abajo decía 1159 tests y
> «la verdad de la VRAM sin reservar». Las dos cosas ya no son ciertas —la
> reserva está cableada y medida—; los números de arriba son los de hoy, y
> §5 (P-4, P-10) y §6 dicen en qué punto está cada cosa.
>
> ⚠️ **Corregido el 2026-10-15/16**: tres cosas de este documento eran viejas y se
> contradecían con el código (§5: P-1, P-4, P-7, P-8). Están marcadas con lo
> medido al lado. Dos de ellas —**P-7 y P-8**— no estaban viejas por descuido:
> las devolvió a su estado anterior el `revert` del PR #82 el 2026-10-15, que
> deshizo el campo `reasoning` **y, con él, la fila que ya lo daba por cerrado**.
> Es lo que tiene revertir: el documento vuelve con el código.
> Y el **976** de la cabecera era de dos días antes: la suite creció con los
> tests del gateway, del tribunal y de la fase 4.
>
> ⚠️ **Y el 2026-10-16 aparecieron dos agujeros que ningún documento listaba**,
> los dos del mismo tipo —código escrito, probado por dentro y *sin enchufar*—:
> `candil stats` **reventaba al invocarlo**, y la **auth del gateway no estaba
> llamada desde el pipeline** (un `auth = api_key` contestaba 200 sin
> credencial). Los dos arreglados, con tests que los miran desde fuera. Ver §5.
>
> ⚠️ **Y la cabecera se quedó vieja otra vez el 2026-10-17**: cerró la **fase
> 5** —el refusal llega al cliente como 503 + `Retry-After`— y con ella se
> escribieron las **condiciones de retorno** de `:degrade` (P-1) y la mitad que
> no cubre el breaker de los agentes (P-9). Lo medido hoy va abajo (§1); la
> cabecera de arriba (1159) es del 2026-10-16.

---

## 1 · Progreso real

| Fase | Qué | Estado |
|---|---|---|
| **0** | Probar lo que existe sin probar | ✅ `01-inventario/HALLAZGOS-FASE-0.md` |
| **1** | Los behaviours que faltaban | ✅ mergeada |
| **2** | `Arrea.Resource` (Arrea 4.0.0) | ✅ mergeada y publicada en Hex |
| **3** | **El enrutado: las capas `:embedding` y `:llm`** | ✅ mergeada |
| **4** | **La política: quién va primero** | ✅ mergeada y **medida contra una GPU de verdad** |
| **5** | El refusal, en los tres tipos | ✅ **cerrada el 2026-10-17**: `fail` y `wait` llegan al cliente HTTP —503 + `Retry-After` y el motivo dentro, con test de punta a punta—; `:degrade` sigue declarado y no alcanzable, con el porqué y las condiciones de retorno en §5 (P-1) |
| **8** | Gateway `candil serve` | ✅ **cerrada el 2026-10-16, medida con `curl`**: los módulos, los diez handlers, los tests de punta a punta **y el comando** `candil serve` (banner, `--host/--port/--auth/--api-key`, `CANDIL_API_KEYS`, se queda en primer plano). De paso: la **auth no estaba enchufada al pipeline** y se arregló (§5). El control de concurrencia ya estaba: el chat pasa por `Policy.run/3` |
| **11** | `candil stats` | ✅ existe y **corre** hoy: `candil stats` + `--quality`, `Candil.Telemetry.Decisions`/`Quality` y `GET /metrics` en el gateway. Hasta el 2026-10-16 el comando **reventaba** al invocarlo (ver §5) |
| 6, 7, 9, 10, 12 | RAG · MCP · mesa camilla · agentes (D-13: en Candil) · el CLI entero | ⬜ |

**`main` hoy** (2026-10-17): **1247 tests + 27 doctests, 0 fallos**, credo 0,
dialyzer 0, y el CI —que ahora corre **dos semillas**, 0 y 1: los dos fallos de
orden medidos esta semana no se veían con una sola— en verde. La 4 ya no es
«verde sin medir»: está medida. La **8** ya no es «el
gateway no existe»: ver §5, P-7, y ya no es «falta el comando»: existe y sirve.

---

## 2 · Lo que se escribió sin poder probar, y ya se ha probado

Esta sección estaba entera escrita y aprobada **sin ejecutarse**, porque el
entorno donde se escribió no tenía GPU, ni modelos, ni `nvidia-smi`, ni `cmake`.
**Desde el 2026-10-13 ya no es verdad.** Lo que faltaba era una máquina con una
RTX 5080 delante, y está. Se ejecuta con `bash scripts/medir-en-mi-maquina.sh` y
con la sonda de §2 de [`COMO-RETO-MARLO`](../COMO-RETO-MARLO.md).

### 2.1 · La cola con un destino REALMENTE exclusivo — **medido, funciona**

**Medido el 2026-10-13** con `llama-server` compilado y un modelo de 14B cargado
en la RTX 5080, declarado `exclusive = true`:

| | | |
|---|---|---|
| **1.1** | inferencia suelta | **6793 ms** |
| | **la misma dentro de un turno** | **6655 ms** |
| **1.2** | la segunda pidió 6652 ms y salió al soltar la primera | ✅ |
| **1.3** | `p1 entra 0 → sale 6650`; `p2 entra 6650 → sale 13300` | ✅ sin solape |
| **1.4** | otro destino distinto, con la GPU ocupada | respondió en **150 ms** |
| **1.5** | motor tumbado con el turno tomado | la siguiente entró en **11 ms** |

> **El 1.1 es el que no se podía deducir leyendo el código**, y sale bien:
> `Policy.run/3` ejecuta `fun` en el proceso que llama, entre `enter/2` y
> `finish/1`, así que el turno cubre la inferencia entera. **6655 ms, no 0.**

> **Y el 1.5 va más allá de lo que pedía.** La pregunta era si tumbar el motor
> dejaba el destino libre, y sí. Pero la que de verdad da miedo es la otra:
> **matar el proceso que tenía el turno**. `Policy` vigila a su titular y lo
> suelta solo —`[Candil.Policy] el destino se queda libre: quien tenía el turno
> ha muerto (:killed)`—, **aunque sea con `kill` y sin soltar nada**. La cola no
> se queda colgada esperando a un proceso que ya no existe.

### 2.2 · Las capas del enrutado, con modelos de verdad

`scripts/router-layers-check.exs` tiene dos secciones. La **1** (mecanismo, con
un embedder y un clasificador falsos) corre en cualquier máquina. La **2**, que
es la medición, hay que rellenarla:

```elixir
defmodule Medir do
  @prompts [
    {"refactoriza este modulo de Elixir y dime por que esta roto", :coder},
    # las TUyas, con el modelo que TU quieres que gane en cada una
  ]
end
```

**Con un embedder de mentira el recuento no significa nada**, y el script lo dice
en su salida: `RECUENTO: 0/5`.

| # | Qué | Por qué importa |
|---|---|---|
| **2.1** | Qué fracción de prompts llega **al modelo que tú esperabas** | >90%: la capa sirve y lo que falta es bajar el umbral. <90%: **no cambies el umbral**, suele estar en las `description` de tus modelos |
| **2.2** | Qué **similitud** da cada pairing prompt↔modelo | la tabla que permite mover el umbral mirándola, no adivinando |
| **2.3** | El recuento de la **tribunal** (§3) | ver abajo |

### 2.3 · El hardware que Candil ve — **ya verificado, pero en un solo modelo**

`Candil.Detector.Devices` se probó en la RTX 5080 Laptop:

```
NVIDIA GeForce RTX 5080 Laptop GPU   total_mb: 16303   free_mb: 13271   usable: true
```

**Lo que no se ha probado**: nada más que una GPU. Con **dos** GPUs, con una
**ROCM/Intel Arc**, y con una máquina **sin GPU** (ahí solo se ha comprobado que
`detect/0` contesta `{:ok, %{backend: :cpu, devices: []}}`).

### 2.4 · La suite en una máquina que no tiene `zip`

12 tests de `Build.PrecompiledTest` llaman a `System.cmd("zip", ...)` y fallan
con `:enoent` en una máquina sin ese binario. **Un rojo que no habla de
Candil**, y por eso merece arreglo aparte: `sudo pacman -S zip` lo desbloquea,
pero el arreglo de fondo es que la suite no dependa de un binario del sistema.

### 2.5 · La ruta de librería

Sin `libcandil` de producción ni documentación de consumo. Es la **fase 10** del
plan, y sigue sin dueño.

---

## 3 · El tribunal: lo que decide si el LLM entra

`DISENO-MOTOR.md` §10 pone una condición antes de meter un modelo de lenguaje
como clasificador:

> Se mide **qué fracción de decisiones resolvió la política**. Si es el 97%, al
> LLM se le llama el 3% y es ruido caro. **Si es el 60%, el motor estático
> está mal hecho y hay que arreglarlo antes de meter un modelo.**

**Esa métrica ya existe** (A-1, 2026-10-13): `[:candil, :router, :decision]`, con
la capa que produjo la decisión. Y el tribunal **sentencia**:

```
lo resolvió la política estática .... 2/12  = 16.7%
hubo que llamar al LLM ............. 10/12 = 83.3%
```

Medido con embedder y clasificador **reales** (`scripts/tribunal-real.exs`), no
con vectores de mentira: `jina-code-embeddings` en `:embedding` y
`DeepCoder-14B` en `:llm`. La barra de §10 es el 60% y **no se llega ni de
cerca**. La conclusión del propio diseño es la que dice §11: *«que el motor
estático se quede en 60% y nadie lo mire»* — y ahora sí hay alguien mirando.

> **Y dice más cosas, que es lo que lo hace útil.** La tabla de similitudes sale
> al final del script, y en el catálogo de la máquina el modelo correcto **ya es
> el primero** en casi todos los prompts: lo que fallaba era que el umbral de la
> capa `:embedding` estaba en **0.55** y los scores buenos estaban en **0.49-0.54**.
> No es el caso malo que el documento avisa —«un embedder no arregla un
> catálogo que no distingue»—: aquí **el catálogo sí distingue y el listón está
> alto**. Por eso este dato sí permite decidir, y el otro no.

> **RESUELTO el 2026-10-14.** El umbral por defecto de la capa `:embedding` pasa
> de **0.55 a 0.35**, con el barrido completo sobre 106 peticiones reales en
> cuatro idiomas: `0.55 -> 9/106` (5/5 aciertos), `0.35 -> 32/106` (**11/11**),
> `0.30 -> 43/106` (12/13), `0.25 -> 72/106` (14/19). 0.35 triplica lo que
> resuelve la capa **sin perder un solo acierto**, y con él el reparto gana
> **+22** sobre "mandarlo todo al modelo normal" (34/48 frente a 12/48). A 0.30
> ya entra un error y a 0.25 se decide la mitad de lo que la capa decide.
>
> El número es del embedder, no de Candil: por eso sigue siendo configurable en
> el toml, y recalibrarlo es lo primero que hay que hacer al cambiar de embedder.

**Lo que queda por decidir no es el dato, es la política**: qué señales tocar y
hasta dónde. Eso es del dueño, no del motor.

**La trampa sigue ahí, y es la que casi se paga por segunda vez.** El
`[:candil, :policy, :turn]` emite al **tomar** el turno y al **soltarlo**: una
petición que espera son **tres** eventos, no dos. El hermano de esa trampa en
`[:candil, :router, :decision]` es peor, porque **no suena**: `decide_by/5` se
puede llamar hasta cuatro veces en una petición —reglas, embeddings, LLM—, y
emitir ahí contaría **capas**, no peticiones. El denominador del tribunal saldría
3-4 veces mayor y el porcentaje de LLM más bajo de lo que es. Por eso se emite en
el cuello de botella, una vez por `decide/3`, y hay un test que lo fija: **tres
capas ejecutadas, una petición, un evento**.

---

## 4 · Deuda técnica

| # | Qué | Dónde | Estado |
|---|---|---|---|
| ~~T-1~~ | **12 tests dependían del binario `zip`** | `test/candil/build/precompiled_test.exs` | ✅ **arreglado.** El archivo se escribe byte a byte en vez de con el binario |
| ~~T-2~~ | **4 tests de cmake solo existían si hay `cmake`** | `test/candil/build/source_real_test.exs` | ✅ **arreglado.** 976 tests con y sin cmake; sin toolchain pasan **diciéndolo** |
| **T-3** | **`charlist` deprecado en el lexer de `toml`** | dependencia | ruido en cada compilación; no es nuestro |
| ~~T-4~~ | **`.credo.exs` nombraba un check inexistente** | `.credo.exs` | ✅ **arreglado.** `NestedModules` no existe en Credo 1.7.19 |
| **T-5** | **25 ramas sin mergear** | GitHub | ✅ **revisadas una a una** (2026-10-13): ninguna aporta trabajo que no esté en `main`. **Ninguna se ha borrado todavía** — es una decisión, no una tarea |
| ~~T-6~~ | **El `SLOT` de `candil status` es teatro**: `if rem(port, 100) >= 90, do: "dGPU"` | `lib/candil/cli/lifecycle.ex` | ✅ **arreglado.** La columna ya no existe: la primera columna es `gpu_layers` del modelo, un campo del catálogo, no un cálculo sobre el puerto. Y el `device_index` del scheduler sale del PID medido (`Detector.Devices.processes/0`), no del puerto |
| ~~T-7~~ | **No había telemetría de decisiones del router** | `Candil.Telemetry` | ✅ **arreglado** (A-1): `[:candil, :router, :decision]`, una vez por `decide/3` |
| ~~T-8~~ | **3 PR de dependabot abiertos** | #41, #42, #43 | ✅ **mergeados** el 2026-10-13 |

**Sobre T-5, y por qué el método importa.** No se ha contado por ficheros ni por
líneas: ramas de la estructura vieja traen **más** contenido que `main` y no
aportan nada, porque `main` reestructuró. El método que lo decide es comparar
el **conjunto de funciones definidas en `lib/`** contra el de `main`: cuatro de
las 25 no tienen ni una, y las de la era `4.0/` tienen 21-43 que son
**delegaciones a módulos que `main` tiene con otro nombre** (`def estimate_tokens(t),
do: Context.estimate_tokens(t)`, donde `main` lo tiene en `Context.TokenEstimator`).
`git cherry` no sirve aquí: cuenta identidad de parche, y `main` reestructuró.

### Sobre T-5, y por qué no se han borrado

A diferencia de Arrea —donde las ramas eran **más antiguas** que `main` y se
verificó fichero a fichero que no apportaban nada—, aquí las ramas traen **más
líneas que `main`**, porque son de la estructura vieja `proyecto 4.0/`. **Que
traigan más contenido no significa que apporten nada**: significa que `main`
restructuró. Borrarlas sin mirar el contenido sería exactamente el error del
`git add -A` de esta semana.

---

## 5 · Problemas sin resolver

| # | Problema | Estado |
|---|---|---|
| **P-1** | `:degrade`, el tercero de los tres tipos | ✅ **decidido** (D-09) y **`fail`/`wait` entregados** — fase 5 cerrada el 2026-10-17: el gateway pinta el refusal como **503 + `Retry-After`**, probado por HTTP de punta a punta (§1). **`:degrade` sigue sin ser alcanzable**, y así se queda hasta que exista el enrutado por cobertura — saber **qué pide la pregunta**, cuya materia prima es la capa `:classifier` (hoy apagada) o el RAG (fase 6). Configurarlo revienta con un `ArgumentError` que lo dice con esas palabras. **Cómo retomarlo**: cuando la cobertura exista, la pregunta ya no es «¿se puede?» sino «¿hace falta?» — y si nadie la echa de menos, la relectura honesta es que el caso que la pedía (varios candidatos y la espera no cabe) ya lo resuelve elegir otro candidato **antes** de rechazar, que es lo que hace la escalera del `Scorer`; entonces D-09 se revisa, no se amplía |
| ~~P-2~~ | La métrica del tribunal | ✅ **cerrado** (A-1). Ya existe, y ha sentenciado: 16.7% |
| **P-3** | `rest_for_one` sin implementar | **a propósito**: no tiene caso hasta que exista un destino que ceda el turno (D-02) |
| **P-4** | Quién escribe la verdad de la VRAM | ✅ **la escribe `Candil.Engine.Resource`** (D-27, 2026-10-21): registra `Arrea.Resource` por device con la capacidad del motor (16303 MiB del total, 370 reservados como `:system`), reserva antes de arrancar, **corrige al peso real medido en los dos sentidos**, y libera si el motor muere o se para. **Y el ledger ve la memoria real**: la que usan procesos que Candil no gestiona entra como un titular más, `:foreign`, y se reajusta antes de cada colocación —medido: la disponible pasó de 15933 (el total, que no existía) a **11348** (= 11718 libres de verdad − 370)—. Con la GPU **llena**, la disponible cae a **0** en vez de mentir con el total: la memoria ajena no cabe en el ledger y el titular se recorta a lo representable. Lo que sigue: multi-GPU real (P-6) |
| **P-10** | La 8b está construida y parcialmente conectada | 🟡 **la reserva está cableada y el CLI ya no se sale del scheduler** (D-27, 2026-10-21): `Candil.Engine.start_placed/2` es **el** camino de arranque, lo usan igual la API (`Candil.chat/2`, `Candil.serve/0`) y el CLI (`candil run`), así que ya no hay dos comportamientos; la reserva se hace antes de `fit-params`, se corrige al peso medido **en los dos sentidos** y se libera en `Server.terminate/2`; y el ledger descuenta la memoria ajena (titular `:foreign`). El scheduler decide con la **cifra del ledger**, la misma que usa la reserva, para que los dos no puedan discrepar. Un motor de CPU **no consulta el scheduler**: `candil run --cpu` no se rechaza por falta de GPU. **Sigue fuera**: (a) reintento en otro device (D-27 opción C; solo con >1 GPU); (b) **`vram_mb` en el catálogo: no se rellena, y es una decisión** —el mismo modelo mide **795, 7978 o 10452 MiB** según la memoria libre del instante (medido 3 veces), así que un número del catálogo sería la cifra de un momento; queda como **pista opcional** y la reserva la sustituye con la medición; (c) `estimate_model_size/1` sigue siendo `div(ctx,1024)*4` (512 MiB para ctx 131072) y solo sirve de suelo al scheduler; (d) el reintento en otro device y la capa de señales. La capa de señales y el multi-dispositivo real siguen pendientes |
| **P-11** | La carrera del circuito en `simple_reflex_test.exs` | ✅ **arreglada**: el circuito se comprobaba en `init/1`, que corre DESPUÉS de que `GenServer.start_link` registre el nombre; si el nombre seguía tomado, contestaba `{:already_started, pid}` y el circuito ni se miraba. Ahora se comprueba en `start_link/1`, antes de registrar. El test verde dependía de que el nombre se liberara a tiempo; ahora no depende de timing |
| ~~P-5~~ | La fase 4 sin mergear | ✅ **cerrado** — mergeada y medida (§2.1) |
| **P-6** | La colocación de modelos en varias GPUs | es la parte de la 8b que falta, y **depende de P-4** |
| ~~P-7~~ | ~~**El gateway no existe**~~ | ✅ **es falso, y esta fila es un retroceso de hoy**: el `revert` del PR #82 (2026-10-15) devolvió a este documento dos filas que ya estaban cerradas. `Gateway.start/1` arranca Bandit y devuelve el puerto real, los diez handlers están escritos y `test/candil/gateway/end_to_end_test.exs` los prueba con HTTP de verdad a los dos lados (20 tests). Ya no falta el comando: **`candil serve` existe y sirve** (2026-10-16, medido con el escript y `curl`), y el control de concurrencia ya estaba — el chat pasa por `Policy.run/3`. El enrutado **sí** es alcanzable desde un cliente real: `POST /v1/chat/completions` con `"model": "auto"` |
| ~~P-8~~ | ~~**`reasoning_content` se descarta**~~ | ✅ **cerrado dos veces, y la segunda a propósito**. La descripción era falsa por dos motivos: (1) medido el 2026-10-14 con `Qwen3.8-27B` y `--reasoning-format deepseek`, `content` **sí** trae la respuesta final y el razonamiento viene al lado (`stop` en los dos casos); (2) el campo que se añadió para no perderlo se **revirtió** en el PR #82 porque no lo lee nadie — ni el enrutado, ni la calidad, ni el CLI, que no muestra respuestas. Lo único que queda en pie es el **diagnóstico** cuando un modelo razona y se queda sin presupuesto: sale `content: ""` con `finish_reason: length` y nada lo explica en el cuerpo, que es lo que `Candil.Telemetry.Quality` marca como anomalía por el lado de la telemetría |
| **P-9** | La otra mitad del §8.3 de los agentes: un agente que **revienta** en bucle | 🟡 **a medias, y las dos primeras mitades cerradas el 2026-10-17**: el breaker cubre el **cuelgue** (5 seguidos abren, la puerta contesta sin pagar el plazo) y ahora **sobrevive al reinicio** — el circuito vive en `Candil.Agents.Breakers` (ETS en el árbol, por nombre, como los snapshots), así que un agente nombrado que revienta y vuelve encuentra su circuito como lo dejó y se niega a trabajar en vez de volver a colgarse. La mitad que sigue fuera: un agente **sin nombre** (no tiene identidad que sobrevivir) y un crash que no es un cuelgue —un `raise` en bucle—, que el breaker no cuenta (solo el plazo es fallo) y que el supervisor solo frena con su intensidad 10/5 s global. Y ahora tiene **presupuesto de crashes por agente** (`Candil.Agents.Crashes`: 5 crashes en 60 s y el agente se niega a arrancar con `:crash_budget_exceeded`). Lo que sigue fuera: un agente **sin nombre**. D-25 abre la tercera opción —darle identidad derivada (`{módulo, hash de las opciones}` o el `goal`) para que caiga en la misma puerta que los nombrados—. Si se prefiere que sigan sin protección, queda escrito como decisión explícita. Relectura si al llegar ahí no hay señal: quizá no hace falta un breaker, sino no reiniciar |


### Lo que se midió el 2026-10-15, y que arregló un 500 vacío

Buscando por qué la suite dependía de la máquina salió un fallo de verdad, y
no era del test: un `[consumer.X] models` que nombra un alias que no existe
como átomo en la VM levantaba `ArgumentError` dentro de
`Candil.Router.Consumer.candidates/1`, y `GET /v1/models` contestaba **500 con
el cuerpo vacío**. Un cliente OpenAI no puede leer eso.

Tres arreglos, cada uno con su test (y los tres rojos antes):

1. `Consumer.candidates/1` devuelve `{:error, {:unknown_model, nombre}}` en vez
   de reventar. El 400 y el mensaje ya estaban escritos en
   `Gateway.error_body/1`; no llegaban a pintarse.
2. `Candil.Gateway.Handlers.reason/2` es el único sitio que pinta un error del
   motor con su status —vivía dentro de `ChatCompletions`, y `Models` necesita
   ya el mismo mapa—, y `{:unknown_model, _}` va al 400: es configuración, no
   un fallo de Candil, y un 500 en un cliente OpenAI significa «reintenta».
3. `Candil.Gateway.Plug.dispatch/3` es una red: un handler que revienta sale
   como un **500 CON cuerpo** en la forma de OpenAI, y el stacktrace va al log.
   Antes Bandit contestaba un 500 sin nada que leer.

### Y `candil stats` reventaba al invocarlo — medido el 2026-10-16

La otra cara de lo mismo: un documento que dice «existe» sobre algo que nadie ha
**corrido**. El comando estaba declarado en `Candil.CLI`, el módulo
`Candil.CLI.Stats` existía y la telemetría existía… y al ejecutarlo:

    ** (FunctionClauseError) no function clause matching in Keyword.get/3
      # 1  %{_args: [], quality: false}
      (candil 4.0.0) lib/candil/cli/stats.ex:32: Candil.CLI.Stats.run/1
      (candil 4.0.0) lib/candil/cli.escript.ex:112: Candil.CLI.Escript.dispatch/1

Alaja le pasa al handler el **mapa** de argumentos parseados, y `Stats.run/1` lo
trataba como una lista de `Keyword`. Los otros seis handlers del CLI ya tenían
las dos cláusulas —`when is_map(opts)` / `when is_list(opts)`—; este no, y no
tenía test: `candil stats` no lo corría ninguna otra prueba. Arreglado, con
`test/candil/cli/stats_test.exs`, que lo corre por el camino de verdad
(`Candil.CLI.main/1`, como el escript) y por el contrato del handler.

### Y la auth del gateway no estaba enchufada — medido y arreglado el 2026-10-16

El mismo patrón, con peores consecuencias. `Candil.Gateway.Auth` está escrito
entero —dos modos, comparación en tiempo constante, la clave fuera del TOML—,
está documentado («requires a key on every request») y tiene sus diez tests
unitarios en `Candil.GatewayTest`… y **`Auth.verify/3` no lo llamaba nadie desde
el pipeline HTTP**. Medido: un gateway arrancado con `auth: :api_key` contestaba
**200 a una petición sin `Authorization`**. La promesa era una promesa que el
pipeline no cumplía, y la tabla de status ya tenía su fila —`status_for/1`
mapea `:auth_error` a 401— sin ningún camino que la produjera.

El arreglo está en `Candil.Gateway.Plug.call/2`, **antes** de resolver la ruta:
sin credencial válida no se llega a un handler, y un 401 dice cómo autenticarse
(`WWW-Authenticate: Bearer`, que es lo que pide la RFC 7235). Va en el único
sitio por el que pasan todas las rutas y no en cada handler: diez handlers son
diez sitios donde olvidarse. Los tests que lo miran son los que faltaban —HTTP
de verdad, en `test/candil/gateway/end_to_end_test.exs`—: 401 sin cabecera, 401
con la clave equivocada (sin filtrar cuál era la buena), 200 con la buena, y 401
en la ruta del chat, que es la que gasta GPU.

Y con esto `candil serve` se pudo cerrar entero y medirlo por fuera: el escript
construido, `./candil serve --port 18177`, `curl` al `/health` y al
`/v1/models`, y con `--auth api_key` + `CANDIL_API_KEYS="sk-uno, sk-dos"` el 401
sin cabecera, el 401 con la clave mala y el 200 con `sk-dos` —con el espacio de
sobra del entorno recortado, que es como lo escribe cualquiera—.

### Y el 11/12 del enrutado se repitió, con los destinos comprobados — medido el 2026-10-16

El **11/12** con doce preguntas en cuatro idiomas se había medido (2026-10-15)
con un catálogo en el que `coder` —el `model_default`— apuntaba a una
cuantización que no existía en disco. El número decía a dónde va cada pregunta,
pero no que el destino pudiera contestar. Repetido con el catálogo de hoy, y
esta vez comprobando los destinos, que era lo que faltaba:

| | |
|---|---|
| El enrutado | **11/12**, otra vez, y por la misma razón de siempre: «analiza el bug y escribe el informe» va a `:coder` cuando se esperaba `:verifier` — la compuesta que el comentario de `rule_threshold` ya describe como discutible y no como umbral mal puesto |
| Los destinos del veredicto | `coder` (9), `verifier` (2), `coder_lite` (1) — los tres **existen en disco** (12,8 · 12,1 · 14,5 GB) y se **arrancaron de verdad**: los tres llegan a `/health` y contestan en 1,5–3,5 s (el `verifier`, con presupuesto corto, razona y devuelve `content: ""` — P-8 otra vez; con presupuesto suficiente contesta) |

El comprobador queda en `scripts/enrutado-12-preguntas.exs`: cuenta las dos
cosas sin arrancar ningún modelo — el veredicto por pregunta y el `File.stat`
del fichero elegido.

Y arrancarlos destapó el fallo que el número tapaba en la otra dirección: el
catálogo local tenía `api_key_env = "sk-local-dev-key"` —el **valor** donde va
el **nombre** de la variable—. `System.get_env/1` devolvía `nil`, Candil no
mandaba `Authorization`, y como el shell tiene `LLAMA_API_KEY=sk-local-dev-key`
exportada, el llama-server que el propio Candil arrancó contestaba **401 a su
propio cliente**. El `doctor` ya lo marcaba como el único `error` de la config
(`api_key_env=sk-local-dev-key pero sk-local-dev-key NO esta puesta`); arreglado
a `api_key_env = "LLAMA_API_KEY"`, los tres destinos contestan.

### Y la única red que faltaba: el digest que nadie rellenaba — arreglado el 2026-10-16

`Candil.Source` tenía `sha256` y lo verificaba al vuelo —incluso sembrando el
hash de un `.part` reanudado—, pero **ningún camino lo escribía**: en la
práctica `checksum_ok?` decía que sí a todo. Con las redirecciones de #85
arregladas era la única comprobación que quedaba suelta.

HuggingFace promete el sha256 en el `x-linked-etag` de la respuesta que
redirige al CDN, y esa respuesta **ya se pedía** para seguir la redirección:
leerlo no añade ninguna petición. Ahora, cuando `sha256` no está puesto, lo
aprendido es la expectativa.

Medido el 2026-10-16:

| | |
|---|---|
| El valor que promete HF | es el sha256 del contenido: los cuatro ficheros del catálogo real tienen `x-linked-etag` = `sha256sum` en disco |
| De punta a punta, contra HF real | un LFS de 1,1 MB baja y se marca completo; un `.part` corrupto reanudado se **rechaza** con el struct en `sha256: nil` — la expectativa solo pudo salir del `x-linked-etag` |
| El `etag` del CDN, en cambio | **no** es el sha256: es el `xetHash` de Xet (`187d19…` contra `b44e34…` para el mismo fichero). Comprobar contra él habría fallado toda descarga buena |

Un `sha256` escrito a mano (un espejo, un `url` que no lo diga) gana al
aprendido; los tests van en `test/candil/source_fetch_test.exs`, con su
servidor local real y las rutas `etiquetado` / `etiquetado-malo`.

---

## 6 · El resumen, en una frase

> **1326 tests + 33 doctests en verde** y **dos preguntas sin responder** — y
> ninguna es técnica: la colocación en varias GPUs, y la política de señales a
> la vista del 16.7%. Las dos necesitan una decisión, no código.
>
> La tercera ya no es una pregunta: **la VRAM se reserva** (D-27, 2026-10-21).
> La reserva va antes del arranque, se corrige al peso medido, ve la memoria
> que usa la gente de fuera de Candil, y el CLI y la API arrancan por el mismo
> camino. Lo que **no** se rellena es el `vram_mb` del catálogo, y es una
> decisión con medición detrás: el mismo modelo ocupa 795, 7978 o 10452 MiB
> según la memoria libre del instante, así que un número escrito a mano sería
> la cifra de un momento y no la verdad.
>
> El defecto del refusal ya no es una de ellas: D-09 lo decidió el 2026-10-11 y
> `fail` es el defecto, con `Retry-After` y todo.

---

## 12 · Módulos internos y sus llamadores (D-10, aplicada)

La regla: una pieza interna sin llamador en `lib/` es trabajo sin empezar, no
una fase cerrada. Una API pública sin llamador interno es lo normal y no cuenta.

Medido el 2026-10-21 sobre la rama `fix/d27-resource-reservation` (base `main` `398a1b9`):

| Módulo | Llamadores en `lib/` | Estado |
|---|---|---|
| `Candil.Scheduler` | 1 (`Candil.Engine.start_placed/2`) | **Cableado (P-10)**: `start_placed/2` es el camino **único** de arranque, y lo usan igual la API (`Candil.chat/2`, `Candil.serve/0`) y el CLI (`candil run`) — el scheduler decide dónde va el modelo y quien expulsa a las víctimas es `start_placed/2` |
| `Candil.Scheduler.Signal` | 0 | Construido y desconectado |
| `Candil.Scheduler.Devices` | 2 (`Candil.Scheduler`, `Candil.Engine.Resource`) | Cableado: además de la detección del scheduler, `Resource.sync_foreign/1` lo usa para leer la memoria real del device y descontar la ajena |
| `Candil.Engine.Resource` | 2 (`Candil.Engine`, `Candil.Scheduler`) | Cableado (D-27): reserva antes de arrancar, corrige al peso medido, libera al parar o morir el motor, y **descuento la memoria ajena** (titular `:foreign`) antes de cada colocación |
| `Candil.RAG.Store` | 1 (`Candil.RAG`) | Cableado (fase 6) |
| `Candil.MCP.Server` | 1 (`Candil.MCP.serve/1`) | Cableado (fase 7 Nivel 1) |
| `Candil.Storage.Store` | 1 (`Candil.Context`) | Cableado (F2.3) |
| `Candil.Agents.Breakers` | 2 (`SimpleReflex`, `ModelBasedReflex`) | Cableado |
| `Candil.Agents.Crashes` | 2 (`SimpleReflex`, `ModelBasedReflex`) | Cableado |
| `Candil.Agents.Snapshots` | 1 (`ModelBasedReflex`) | Cableado (F5.4) |

**Regla para el futuro**: cuando se proponga una fase, decir qué la va a llamar,
con fichero y línea. Si la respuesta es «nadie, todavía», eso es una nota de
trabajo, no una fase cerrada.
