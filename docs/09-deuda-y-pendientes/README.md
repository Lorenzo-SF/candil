# 09 · Deuda, pendientes y lo que falta por probar

> **Lo que está sin terminar, lo que se sabe roto, y lo que no se ha podido
> verificar porque no había con qué — y que desde el 2026-10-12 sí se puede,
> porque hay una máquina con una RTX 5080 delante.**
>
> 2026-10-13 · `main` `b43b56e` · **976 tests + 27 doctests, 0 fallos** · los
> cinco gates en verde · sin rama de trabajo.

---

## 1 · Progreso real

| Fase | Qué | Estado |
|---|---|---|
| **0** | Probar lo que existe sin probar | ✅ `01-inventario/HALLAZGOS-FASE-0.md` |
| **1** | Los behaviours que faltaban | ✅ mergeada |
| **2** | `Arrea.Resource` (Arrea 4.0.0) | ✅ mergeada y publicada en Hex |
| **3** | **El enrutado: las capas `:embedding` y `:llm`** | ✅ mergeada |
| **4** | **La política: quién va primero** | ✅ mergeada y **medida contra una GPU de verdad** |
| **5** | El refusal, en los tres tipos | ⬜ **bloqueada por D-09** |
| 6-12 | RAG · MCP · Gateway · mesa camilla · agentes · stats · CLI | ⬜ |

**`main` hoy**: **976 tests + 27 doctests, 0 fallos**, credo 0, dialyzer 0, CI en
verde. La 4 ya no es «verde sin medir»: está medida.

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
| **T-6** | **El `SLOT` de `candil status` es teatro**: `if rem(port, 100) >= 90, do: "dGPU"` | `lib/candil/cli/lifecycle.ex` | una columna que **miente** sobre el hardware. Deuda del trabajo local aparcado |
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
| **P-1** | El defecto del refusal | **abierto** — es decisión del dueño (D-09) y **bloquea la fase 5** |
| ~~P-2~~ | La métrica del tribunal | ✅ **cerrado** (A-1). Ya existe, y ha sentenciado: 16.7% |
| **P-3** | `rest_for_one` sin implementar | **a propósito**: no tiene caso hasta que exista un destino que ceda el turno (D-02) |
| **P-4** | Quién escribe la verdad de la VRAM | se **lee**, no se escribe. Sin dueño |
| ~~P-5~~ | La fase 4 sin mergear | ✅ **cerrado** — mergeada y medida (§2.1) |
| **P-6** | La colocación de modelos en varias GPUs | es la parte de la 8b que falta, y **depende de P-4** |
| **P-7** | **El gateway no existe** | `Gateway.start/1` devuelve `:not_implemented` (fase 8). **El enrutado no es alcanzable desde un cliente real**, solo desde el CLI |
| **P-8** | **`reasoning_content` se descarta** | `parse_openai_response/1` lee `message.content` y nada más. Con `--reasoning-format deepseek` en `coder`, `analyst` y `coder_lite`, una pregunta que exige razonar devuelve **1809 bytes de razonamiento y `content: 0`** |

---

## 6 · El resumen, en una frase

> **976 tests en verde** y **cuatro preguntas sin responder** — y ninguna es
> técnica: el defecto del refusal, quién escribe la verdad de la VRAM, la
> colocación en varias GPUs, y la política de señales a la vista del 16.7%.
> Las cuatro necesitan una decisión, no código.
