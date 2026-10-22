# Candil — cómo retomarlo

> **Estado a 2026-10-16, medido, no supuesto.** `main` en `4d8d3e5` en verde ·
> **1159 tests + 27 doctests, 0 fallos** · credo 0 · dialyzer 0.
> **Rama de trabajo:** `fix/agent-contract`, con lo mismo que `main` más lo del
> 2026-10-15/16.
>
> **Lo que ya se ha medido contra una GPU de verdad** (RTX 5080, `llama-server`
> compilado, un modelo de 14B cargado): la cola funciona. El turno dura **6655
> ms** sobre una inferencia de **6793 ms**, la segunda petición espera de verdad,
> un destino distinto no espera, y tumbar el motor con el turno tomado deja el
> destino libre. La sonda de §2 de más abajo es la que lo midió.

---

## Antes de nada: el entorno

```bash
git clone https://github.com/Lorenzo-SF/candil.git
cd candil && git checkout main && git pull
```

**El toolchain: búscalo, no lo des por puesto.** Una versión anterior de este
documento decía `. ~/tools/env.sh` sin más, y **esa ruta estaba inventada**:
cada máquina lo tiene en un sitio. Se localiza así:

```bash
which mix || ls -d ~/.asdf ~/tools /opt/candil-build /workspace/tools 2>/dev/null
```

| Dónde esté | Qué hacer |
|---|---|
| `~/.asdf` | `. "$HOME/.asdf/asdf.sh"` y ya |
| `~/tools/env.sh` o similar | `. ~/tools/env.sh` |
| en ningún sitio | hay que reconstruirlo; que lo haga alguien con la máquina delante |

Y dos avisos que cuestan caro si no se saben:

- **`MIX_BUILD_PATH` no se toca nunca.** Es la ruta **literal** del build dir y
  anula `MIX_BUILD_ROOT`: con las dos puestas, dev y test comparten un solo
  `_build`, aparece un `mox`/`excoveralls` podado y aparecen **70 tests "no
  process: Mox.Server"** que no tienen nada que ver con lo que has tocado.
- **`CANDIL_DATA_DIR` va SIEMPRE**, en un temporal. Sin él, la suite escribe un
  `instances.json` en el `~/.candil` real.

```bash
export CANDIL_DATA_DIR=$(mktemp -d)
```

---

## Si eres un agente: **tienes la GPU delante**

Esto cambia el relevo entero, y para bien. En la máquina del dueño **se puede
medir todo lo que parecía medible solo a mano**: hay una RTX 5080, hay modelos,
hay `~/.candil` con el catálogo real. **No hace falta pedirle nada.**

### 1 · Primero mira qué hay

Antes de teorizar, mide. Todo esto lo puede hacer el agente:

```bash
# 1 · qué hardware ve Candil de verdad
mix run -e 'IO.inspect(Candil.Detector.Devices.detect())'

# 2 · qué modelos hay en su configuración real
mix run -e 'IO.inspect(Candil.Store.list_models(), pretty: true)'

# 3 · qué dice la cola sobre un turno
mix run -e 'IO.inspect(Candil.Policy.status(:<alias>))'
```

El `1` es el mismo `Detector.Devices` que se escribió el 2026-10-10. **Si aquí
no ve la GPU, no tires de él**: significaría que el binario no está o que el
`PATH` no lo trae.

### 2 · La medición que más importa: la cola con un destino real

```bash
bash scripts/medir-en-mi-maquina.sh
```

Y si quieres el detalle fino, esta es la prueba de fuego. **La inferencia va
DENTRO del turno**, porque un turno sin nada dentro dura lo que dura un `IO.puts`
y no mide nada. Todo por la API del framework —nada de `candil run` en otra
terminal: el CLI es una aplicación, y esto es medir la biblioteca—:

```bash
CANDIL_DATA_DIR=$(mktemp -d) mix run -e '
  alias Candil.{Engine, Inference, Model, Policy, Store}

  engine = %Engine{alias: :llama_cpp, binary: "/ruta/a/llama-server",
                   host: "127.0.0.1", port: 9999}
  :ok = Store.register_engine(engine)

  modelo = %Model{alias: :cargado, type: :local, engine: :llama_cpp,
                  model_dir: "/ruta/a/gguf", filename: "tu-modelo.gguf",
                  context_size: 8192, port: 9999, usage: [:chat],
                  gpu_layers: -1, exclusive: true}
  :ok = Store.register_model(modelo)
  {:ok, _} = Engine.start(engine, modelo)

  # El motor tarda en cargar: sin esto se mide una conexion rechazada.
  Enum.reduce_while(1..90, false, fn _, _ ->
    if Engine.healthy?(:cargado, 3000), do: {:halt, true},
    else: (Process.sleep(1000); {:cont, false})
  end)

  msgs = [%{role: "user", content: "Explica en tres frases qué es un exclusive en una GPU."}]

  # (a) la inferencia suelta, sin la política encima
  t0 = System.monotonic_time()
  {:ok, _} = Inference.chat_local(:cargado, msgs, max_tokens: 64)
  suelta = System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

  # (b) LA MISMA inferencia, con el turno tomado alrededor
  t0 = System.monotonic_time()
  {:ok, _} = Policy.run(:cargado, fn ->
    Inference.chat_local(:cargado, msgs, max_tokens: 64)
  end)
  turno = System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

  IO.puts("inferencia suelta: #{suelta} ms")
  IO.puts("dentro de un turno: #{turno} ms")
  IO.puts(if turno > 0, do: "OK: el reloj cubre la inferencia",
                   else: "FALLA: el turno no mide la inferencia")
'
```

> **Lo que hay que mirar, y por qué:** el turno tiene que durar **lo que dura la
> inferencia**, no 0 ms. `Policy.run/3` ejecuta `fun` en el proceso que llama,
> entre `enter/2` y `finish/1`, así que si el turno envuelve a la inferencia, el
> reloj la cubre. Si sale 0, **el reloj no está midiendo y la política no sirve
> de nada**.
>
> Ojo con la trampa de la sonda anterior, que medía `enter` → `status` →
> `finish` **con nada dentro**: eso da 0 ms por construcción, haya motor o no, y
> no puede detectar nada. Una sonda que siempre sale bien no es una sonda.
>
> Y sigue siendo **invisible desde los tests**: con modelos remotos falsos no hay
> inferencia que medir, y por eso los tests pueden estar en verde y la política
> no servir para nada.

Las otras cuatro, en el mismo sitio y con los mismos comandos:

| | Qué tiene que pasar |
|---|---|
| 2.1 | la segunda petición **espera de verdad** y sale cuando la primera suelta |
| 2.2 | dos peticiones al **mismo** destino se serializan |
| 2.3 | una petición a un destino **distinto no espera** |
| 2.4 | tumbar un motor con el turno tomado **deja el destino libre** |

> Todas las van, y la 2.4 ha pasado con creces: `Policy` vigila al titular del
> turno y lo suelta solo cuando ese proceso muere, **aunque muera con `kill` y
> sin soltar nada**. Un `kill -9` al proceso que tenía el turno deja el destino
> libre, y no se queda colgado esperando a un proceso que ya no existe.

### 3 · Las dos capas del enrutado, con sus modelos

**No hay que inventar un embedder.** `Candil.Inference.embed_local/3` ya existe
y funciona contra un modelo local que tenga `:embeddings` en su `usage`. Y la capa
`:llm` toma **cualquier modelo con `chat`**, que también los hay.

Así que `scripts/router-layers-check.exs` **se rellena solo**: en su sección 2,
un módulo de embedder que llame a `Inference.embed_local/3` con el alias de
embeddings, y un clasificador que use el mismo camino de `chat` que ya usa el
`Scorer`. Con un embedder de mentira el recuento no significa nada, y el propio
script lo avisa.

Lo que hay que mirar al final: **qué fracción de prompts llega al modelo que uno
esperaba**.

- **>90%**: la capa sirve, y lo que falta es bajar el umbral mirando la tabla.
- **<90%**: **no cambies el umbral**. Suele estar en las `description` de tus
  modelos, y un embedder no arregla un catálogo que no distingue.

### 4 · Y estas cinco, también sin nadie delante

De [`09-deuda-y-pendientes`](09-deuda-y-pendientes/):

| # | Qué | Por qué | Estado medido el 2026-10-16 |
|---|---|---|---|
| **A-1** | **La métrica del tribunal**: un evento de telemetría en la decisión, con **la capa que la produjo** | es instrumentación pura; decide si un LLM entra como clasificador | ✅ **hecho** (2026-10-13): `[:candil, :router, :decision]`, y ya ha sentenciado |
| **A-2** | quitar la dependencia del binario `zip` | 12 tests que fallan donde no está, y el rojo no habla de Candil | ✅ **hecho**: no hay un solo `System.cmd("zip", …)` en `lib/` ni en `test/` |
| **A-3** | que los tests de cmake no **desaparezcan** si no hay cmake | sin él son dos suites distintas | ✅ **hecho** (T-2): sin toolchain pasan **diciéndolo** |
| **A-4** | limpiar el check inexistente de `.credo.exs` | ruido en cada ejecución | ✅ **hecho**: `mix credo` no avisa de ningún check desconocido |
| **A-5** | revisar **una a una** las ramas sin mergear | aquí **no** se ha comprobado, y traen la estructura vieja | ⬜ **pendiente**: hoy hay **19 ramas remotas** sin mergear en `origin/main`, y la mayoría son de PRs ya mergeados con *squash* — el `--no-merged` las lista aunque su contenido esté dentro. Una a una, como dice |

**Y el tribunal ya habló.** La métrica de A-1 existe y mide qué fracción resuelve
la política estática: **16.7%** (2/12) con embedder y clasificador reales, contra
la barra del 60% de `DISENO-MOTOR.md` §10. El barrido que salió de ahí dejó el
umbral de `:embedding` en **0.35** —de 9/106 a 32/106 y **11/11 aciertos**—, y
con eso la decisión que queda **no es el dato, es la política**: qué señales
tocar y hasta dónde. Es del dueño, no del motor.

> **Trampa que ya se ha pagado:** tomar el turno con `enter/2` **también cuenta**
> como turno servido y emite su propio evento. Una petición que espera son
> **tres** eventos, no dos: el de `run/3` que no espera, el de `enter/2` que
> toma el turno, y el de la que espera de verdad. Un contador mal pensado cuenta
> turnos donde cuentan peticiones, y sale un número que no significa nada.

---

## Lo único que necesita al dueño

**Son decisiones, no trabajo:**

- **El defecto del refusal** — `fail` · `wait` · `degrade`. ✅ **decidida**
  (D-09, 2026-10-11): `fail` es el defecto, `:fail` y `:wait` están escritos y
  `Candil.Refusal` lleva el porqué y los números. `:degrade` **no es alcanzable
  hoy** y no bloquea la fase 5.
- **Si entra un LLM como clasificador** — el tribunal ya lo midió (16.7% de
  resoluciones estáticas contra la barra del 60%), el umbral quedó barrido
  (0.35) y **lo que queda es la política de señales**: qué se toca y hasta
  dónde. Eso es del dueño.
- **La colocación en varias GPUs** — el scheduler coloca y expulsa, pero solo
  sobre un device: el reintento en otro cuando el motor no carga (D-27 opción
  C) **no está**, y solo tiene caso con más de una GPU (§5 de la deuda, P-6).
  La VRAM ya no está en esta lista: **se reserva** (P-4, D-27, 2026-10-21).

---

## Lo que NO hay que hacer

- **No decidas tú el defecto del refusal**: ya está decidido (D-09) y es
  `fail`, con su `Retry-After`. Lo que falte de la fase 5 no es eso.
- **No implementes `rest_for_one`**: está aplazado **a propósito**, no hasta que
  exista un destino que pueda ceder el turno antes de terminar.
- **No pongas un clasificador ni un embedder por defecto.** El proyecto no lanza
  modelos que el usuario no le ha pedido, y un default que arranca un LLM por su
  cuenta consume GPU sin que nadie lo haya pedido.
- **No confíes en un rojo que no se reproduce.** En este repo se ha pagado tres
  veces: los 4 tests de cmake, la suite escribiendo en el `~/.candil`, y los 12 de
  `zip`.
- **No borres las 25 ramas sin mergear** sin mirar su contenido. En Arrea se
  verificó que eran **más antiguas** que `main` y se pudieron borrar; aquí **no**,
  y traen la estructura vieja `proyecto 4.0/`.
- **No abras PR sin mirar su CI antes de pedir el merge**, y **no hagas push
  directo a `main`**, ni aunque el PAT lo permita.
- **No te creas el ejemplo de la GPU de `Bulkhead`.** `12 + 1,8 = 13,8` sí cabe
  en 16, y sin embargo el ejemplo dice que no — porque **falta la caché KV**. Un
  modelo no ocupa solo sus pesos.
