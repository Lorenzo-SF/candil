# Candil — cómo retomarlo

> **Estado a 2026-10-12, medido, no supuesto.** `main` en verde ·
> **967 tests + 27 doctests, 0 fallos** · credo 0 · dialyzer 0.
> **Rama de trabajo: ninguna.** Todo está en `main`.

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

Y si quieres el detalle fino, esta es la prueba de fuego. Con el modelo
cargado, se toma un turno y se mira **cuánto dura**:

```bash
# en una terminal
candil run <su-modelo-exclusivo>

# en otra
CANDIL_DATA_DIR=$(mktemp -d) mix run -e '
  alias Candil.{Store, Model, Policy}
  :ok = Store.register_model(%Model{
    alias: :cargado, type: :local, engine: :llama_cpp, name: "cargado",
    port: 9999, exclusive: true})

  {:ok, t} = Policy.enter(:cargado)
  t0 = System.monotonic_time(:millisecond)
  IO.inspect(Policy.status(:cargado), label: "cola con el turno tomado")
  :ok = Policy.finish(t)
  IO.puts("turno: " <> inspect(System.monotonic_time(:millisecond) - t0) <> " ms")
'
```

> **Lo que hay que mirar, y por qué:** si el turno dura **0 ms** con un modelo
> de verdad, **el reloj no está midiendo la inferencia y la política no sirve
> de nada**. Es el fallo más probable, y es **invisible desde los tests**: con
> modelos remotos falsos no hay inferencia que medir, y por eso los 967 tests
> pueden estar en verde y la política no servir para nada.

Las otras cuatro, en el mismo sitio y con los mismos comandos:

| | Qué tiene que pasar |
|---|---|
| 2.1 | la segunda petición **espera de verdad** y sale cuando la primera suelta |
| 2.2 | dos peticiones al **mismo** destino se serializan |
| 2.3 | una petición a un destino **distinto no espera** |
| 2.4 | tumbar un motor con el turno tomado **deja el destino libre** |

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

| # | Qué | Por qué |
|---|---|---|
| **A-1** | **La métrica del tribunal**: un evento de telemetría en la decisión, con **la capa que la produjo** | es instrumentación pura; decide si un LLM entra como clasificador |
| **A-2** | quitar la dependencia del binario `zip` | 12 tests que fallan donde no está, y el rojo no habla de Candil |
| **A-3** | que los tests de cmake no **desaparezcan** si no hay cmake | sin él son 878 en vez de 882: dos suites distintas |
| **A-4** | limpiar el check inexistente de `.credo.exs` | ruido en cada ejecución |
| **A-5** | revisar **una a una** las 25 ramas sin mergear | aquí **no** se ha comprobado, y traen la estructura vieja |

**A-1 es la urgente.** `DISENO-MOTOR.md` §10 pone una condición antes de meter un
LLM como clasificador: se mide qué fracción resolvió la política, y si es el 60%
en vez del 97%, el motor estático está mal hecho y hay que arreglarlo antes.
**Esa métrica no existe**, así que hoy nadie puede saber si el clasificador está
justificado.

> **Trampa que ya se ha pagado:** tomar el turno con `enter/2` **también cuenta**
> como turno servido y emite su propio evento. Una petición que espera son
> **tres** eventos, no dos: el de `run/3` que no espera, el de `enter/2` que
> toma el turno, y el de la que espera de verdad. Un contador mal pensado cuenta
> turnos donde cuentan peticiones, y sale un número que no significa nada.

---

## Lo único que necesita al dueño

**Son decisiones, no trabajo:**

- **El defecto del refusal** — `fail` · `wait` · `degrade`. Configurable, pero
  **el defecto no está puesto**, y **bloquea la fase 5**. Las tres son
  defendibles y ninguna es de diseño. Está en
  [`06-capacidad-y-politica` §4](06-capacidad-y-politica/README.md).
- **Si entra un LLM como clasificador** — se deduce de A-1, pero la política es
  suya.

---

## Lo que NO hay que hacer

- **No implementes el refusal** por decidir tú el defecto.
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
