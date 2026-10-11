# Fase 3 · El enrutado: las capas que faltaban — entregable

> **Rama**: `fase-3-capas-routing` (desde `main` @ `a1790e6`)
> **Fecha**: 2026-10-11
> **Toolchain**: OTP 28.5.0.7 · Elixir 1.19.5-otp-28 · `cmake` y `ninja` en el PATH
> **Alcance**: las dos capas que `@type layer :: :rule | :embedding | :llm` prometía
> desde la fase 1 y que nadie implementaba, **más** el dato que a la capa
> `:embedding` le faltaba para existir. Ni afinidad (fase 4), ni política (fase 4),
> ni nada de `ropero` ni de `arrea`.

---

## 1 · Los números, antes y después

| | Antes (`a1790e6`) | Después (`fase-3-capas-routing`) |
|---|---|---|
| Tests | 882 + 27 doctests | **936 + 27 doctests** |
| Fallos | 0 | **0** |
| Credo `--strict` | 43 | **43** |
| Dialyzer | 0 | **0** |
| Cobertura total | *(no medida)* | **68.4 %** |
| Líneas de `scorer.ex` | 121 | 604 |

**+54 tests**, ninguno borrado, ninguno saltado, ninguno debilitado.

El credo **no sube**, y eso no fue gratis: la primera versión de los ficheros de
test traía 21 avisos nuevos (casi todos `[D] NestedModules` por llamar a
`Candil.Router.route/2` con el nombre completo, y dos `[R] AliasOrder`), y están
todos corregidos —con `alias` y con el orden que Credo quiere, que ordena por el
nombre **completo**: `Candil.Embeddings` va antes que `Candil.Engine` porque
`emb` < `eng`—.

La cobertura de `main` **no la he medido**, así que no la comparo: solo pongo la
de después.

⚠ **El sandbox no tiene `zip`.** En la primera ejecución de la suite de `main`
salieron **12 fallos en `Candil.Build.PrecompiledTest`**, todos con
`** (ErlangError) Erlang error: :enoent` y `System.cmd("zip", …)`. No es de esta
fase y no es del repo: es una dependencia del sistema que este entorno no tiene
(`apt-get install zip` → *no installation candidate*). Para poder medir el
baseline con la suite **completa** puse un shim mínimo de `zip` (solo lo que ese
test usa, `python3` + `zipfile`) en `/workspace/tools/shim/zip` y lo añadí al
`PATH` de las ejecuciones de abajo. Con el shim, `main` da **882 + 27 doctests,
0 fallos**, que es el baseline que dice el enunciado. Sin el shim, 12 fallos
—los mismos 12 antes y después—.

---

## 2 · Lo que había, y por qué era una contradicción escrita

`Scorer` declaraba tres capas y solo tenía una. Las otras dos caían en un
catch-all:

```elixir
def score(_messages, _candidates, layer, _settings) do
  # Not computed yet. Returning zeros would clear no threshold but would
  # make `candil router stats` claim the layer ran.
  _ = layer
  :miss
end
```

Y `DecisionEngine` ya las llamaba, y además **se comía el resultado**:

```elixir
_alias -> Scorer.score(messages, candidates, :llm, settings)   # el valor, descartado
...
_miss_or_decision -> :miss
```

O sea: la cuarta capa estaba encendida por un flag, gastaba una inferencia, y su
respuesta no llegaba a ninguna parte. Un router que paga una inferencia para no
mirar el resultado.

---

## 3 · Lo que he añadido

### 3.1 · La capa `:llm` — filtra, y no sabe elegir modelo

`Scorer.score/4` tiene ya su cláusula. Pide un veredicto a un
`Candil.Router.Classifier` **registrado** y usa la dificultad para descartar por
`usage`:

| Veredicto | Se quedan |
|---|---|
| `:deep` | solo los modelos con `:reasoning` |
| `:normal` | todos |
| `:fast` | los que **no** son `:reasoning` |

- **Sin clasificador → `:miss`.** No hay clasificador por defecto, y eso no es un
  descuido: uno por defecto decide por omisión cuánto se gasta.
- **`{:error, :unknown}` → `:miss`**, no un error. Es la tercera respuesta, y es
  la razón de que el behaviour la tenga.
- **Filtro a cero → `:miss`**, no «todos». Un `:deep` sin ningún modelo de
  razonamiento tiene que poder decirse.
- **La confianza no se normaliza**: sale tal cual, con la escala del clasificador.
- **Una dificultad que no existe** (`:medium`) es `{:error, {:unknown_difficulty, d}}`,
  no un `:normal` disfrazado.
- **Un fallo de verdad** (el clasificador reventó) sale como
  `{:error, {:classifier_failed, reason}}` y el motor lo propaga. Antes, un
  clasificador roto era indistinguible de uno que no sabe.
- **El filtro no ordena**: dentro de lo que pasa el filtro manda el orden del
  consumidor. La afinidad es la fase 4 y sus pesos no están decididos.

### 3.2 · El bucle, que era un `raise` sin escribir

`DecisionEngine.classifier_model/0` coge **cualquier** modelo con `usage: [:chat]`
y la capa lo llama. Un clasificador escrito por el usuario que pida un modelo al
router **se llama a sí mismo para siempre**, con un síntoma que es un proceso
muerto por stack y no dice nada de routers.

La regla está escrita en **los dos sitios que la van a leer** —el `@doc` del
callback `classify/2` en `Router.Classifier` y el `@moduledoc` del `Scorer`—:

> Un clasificador llama al **modelo** directamente —el `Candil.Store`, el engine,
> el provider—, saltándose el router. El router es lo que llama al clasificador.

Y no es solo texto: `Scorer` levanta una bandera de proceso con **el módulo**
mientras dura la llamada, y `DecisionEngine.decide/3` la comprueba **en la
puerta** y reventa nombrando a quien montó el bucle y qué hacer. En la puerta y
no junto a la llamada al clasificador, a propósito: un clasificador puede llamar
al router por más de un camino (`Router.route/2`, `DecisionEngine.decide/3`) y
todos son el mismo bucle. **Hay tests para las dos cosas**: que reventa, y que el
mensaje dice qué hacer.

### 3.3 · La capa `:embedding` — y el dato que le faltaba

`Candil.Model` **no tenía `description`**, y sin descripción no hay nada con lo
que comparar el prompt. Así que primero el dato:

- `Candil.Model`: campo `description`, en el `@moduledoc`, en el struct y en el `@type`.
- `Candil.Config.Hydrate`: lo lee del TOML, tal cual.
- `Candil.Config.Schema`: valida que sea un string (la descripción se **embeddea**;
  un número ahí falla mucho después, dentro de una capa, sin mencionar el fichero).
- `Candil.Config.Template`: la declara, **comentada**, con lo que pasa si te la
  saltas. La plantilla se genera, no se escribe: `docs/05-cli/config/candil.toml`
  es `Template.build/0` y lo he regenerado con las 19 líneas de cabecera de antes
  (`diff <(tail -n +20 …) <(mix run -e 'Template.build()')` → idéntico).

Y luego la capa, con `Candil.Embeddings.Adapter` (el behaviour de la fase 1):

- **Sin embedder → `:miss`**, y `supports?(:text) == false` → `:miss`. No hay
  embedder por defecto, por la misma razón que no hay clasificador por defecto.
- **Similitud del coseno**, y la aritmética se nota: `[0.9, 0.1, 0]` contra
  `[1, 0, 0]` vale `0.9938…`, no `0.9`.
- **Dimensiones que no cuadran → `{:error, {:dimension_mismatch, expected:, got:}}`**,
  nunca un `0.0`. Un 0 ahí sería indistinguible de «no se parecen», y por tanto
  de «no se ha comparado nada». También hay `{:not_a_vector, x}` para el embedder
  que devuelve `[1.0, 0.0, 0.0]` para un texto, que *parece* un vector.
- **Un modelo sin `description` no se compara**, con el alias ni con el nombre del
  `.gguf`. Si no hay ninguna descripción, la capa devuelve `:miss` **sin llamar al
  embedder**: un 0 de similitud sacado de un texto que nadie escribió no es una
  medida.
- **El resultado se cachea** (`Candil.Router.Scorer.VectorCache`, ETS): por texto y
  por embedder, con el módulo en la clave. Es una decisión de **coste**, no de
  exactitud —el vector de un texto no cambia porque se le haya pedido dos veces—,
  y por eso está escrita como tal en el `@moduledoc` del módulo. El tope son 512
  entradas y, al pasarlo, se tira la cache entera: un LRU sería contabilidad para
  no crecer un número que ya es pequeño.

### 3.4 · Tres salidas, y el `reason` lo pone la capa

`Scorer.score/4` pasó de `[{alias, float}] | :miss` a:

```elixir
@type result :: {:ok, ranking(), String.t()} | :miss | {:error, term()}
```

El `reason` viaja con el ranking porque **el veredicto se muere dentro de la
capa**: su dificultad, su confianza y su «por qué» son lo único que puede decir
por qué se eligió ese modelo, y `DecisionEngine` no puede reconstituirlo sin
llamar al clasificador por segunda vez. Antes lo ponía
`Scorer.explain(:llm, messages)`, que no tenía nada que mirar.

Un cambio de comportamiento que sale de aquí y que conviene conocer: **una capa
que se rompe de verdad corta el enrutado.** Un `{:dimension_mismatch, …}` o un
`{:classifier_failed, …}` salen por `Router.route/2` como `{:error, …}` en vez de
caer al default. Es la política que el propio `DecisionEngine` ya aplicaba a la
cuarta capa («un router que se rompe cuando le falta algo es preferible a uno que
responde mal y no lo dice»), y es una decisión **mía**, no tuya: si prefieres que
una capa rota degrade en silencio, se cambia en un sitio y se dice en el entregable.

### 3.5 · `[router] classifier` y `[router] embedder`

Las dos capas necesitan un **nombre** para encontrar su implementación, y
`Router.settings/0` no tenía ninguno. Añadidos a `@defaults` (`nil` = la capa no
existe) y leídos de `[router]`. El TOML da strings y el registro es por átomos,
así que se convierten con el mismo criterio de forma de identificador que usa
`Config.Hydrate.alias_of/1` (`[a-z][a-z0-9_]*`); un valor con otra forma se deja
como estaba y no se convierte en un átomo nuevo.

Y la sección `[router]` **no estaba en la plantilla**, que es donde se enteraría
alguien de que existe. Añadida, comentada, con lo que significa tenerla a `nil`.

### 3.6 · Un bug que salió de camino

`force_strategy: :llm` con la cuarta capa encendida **llamaba al clasificador
dos veces**: una en `forced/5` y otra al llegar a `by_llm/5`. Con la capa siendo
un stub no costaba nada; ahora son **dos inferencias por la misma pregunta**.
`by_embeddings/5` y `by_llm/5` reciben la capa forzada y no la vuelven a correr.
Hay test de que el clasificador se llama **una** vez.

---

## 4 · Los tests

`test/candil/router/scorer_layers_test.exs` (33) — la capa, con la llamada
externa **mockeada** con Mox, que es el patrón de los tests de Elasticsearch:
primero el mock, la llamada real en otro sitio. Los dos behaviours mockeados están
en `test/test_helper.exs` (`Candil.Router.ClassifierMock`,
`Candil.Embeddings.AdapterMock`).

`:llm`: sin clasificador → `:miss` · `:unknown` → `:miss` · `:deep` con un modelo
`:reasoning` y otro que no → **solo el de razonamiento** · `:deep` sin ninguno →
`:miss`, y el test dice por qué no puede ser la lista entera · `:fast` deja los que
no son de razonamiento · `:normal` deja todos · la confianza sale con la escala
del clasificador (3.0 sigue siendo 3.0) · el filtro no reordena · el `why` del
clasificador acaba en el `reason` · `:medium` es error · un clasificador apagado no
se usa (su `classify/2` revienta si se le llama) · **el bucle**: un clasificador
que llama a `Router.route/2` revienta con un mensaje que dice qué hacer · otro que
llama a `DecisionEngine.decide/3` también · la bandera se levanta al salir y no
envenena el proceso · la puerta sigue abierta fuera de un clasificador.

`:embedding`: sin embedder → `:miss` · `supports?(:text) == false` → `:miss` ·
ordena por similitud y **no** por el orden de los candidatos (el caso del test
pone al mas dissimilar primero) · el coseno se nota · `1.0` y `0.0` exactos ·
dimensiones que no cuadran → error explícito con los dos números · vectores de
distinta longitud entre sí → error · lo que no es un vector → error · un modelo sin
descripción no se compara · sin ninguna descripción, `:miss` **sin llamar al
embedder** · un embedder que falla no es «no se parece a nada» · más o menos
vectores de los pedidos → error · **la cache**: el prompt repetido no se vuelve a
embeddear (`expect(…, 1, …)` para dos decisiones), un prompt nuevo sí, y dos
embedders no comparten vectores.

`test/candil/router/decision_engine_layers_test.exs` (10) — lo que cambia **arriba**:
la capa `:llm` gana cuando su confianza pasa el umbral y dice que es la capa `:llm` ·
por debajo del umbral no es una decisión · **un `:unknown` no rompe el enrutado** ·
`:deep` sin razonamiento no manda a uno que no lo es · `:deep` manda a ese y no al
primero de la lista · flag encendido y sin modelo de chat → `{:classifier_unavailable, …}`
con el nombre del modelo que se buscaba · la capa de embeddings ordena, y por
debajo del umbral no decide · **las dimensiones que no cuadran cortan el
enrutado por `Router.route/2`** · el bucle por la puerta del motor.

Más, en los ficheros que ya existían: `Model` (el campo), `Hydrate` (el camino
TOML → struct, incluido el caso de que **no** haya descripción), `Schema` (string
obligatorio, opcional permitido), y `test/candil/config/template_test.exs` (nuevo,
5 tests: que el esqueleto se valida a sí mismo, que menciona **todas** las
secciones del schema, que declara `description`, `classifier` y `embedder`, y que
está comentado entero).

Cada aserción dice **qué no puede ocurrir**, no solo qué responde. Las que más
importan, con la línea:

- `refute` implícito en `[:coder, :gpt4o] → :miss`: si saliera la lista, el `:deep`
  no habría filtrado nada.
- `assert Enum.map(ranked, &elem(&1, 0)) == [:verifier]`: si apareciera `coder` o
  `gpt4o`, la dificultad se habría aplicado al revés.
- `assert {:error, {:dimension_mismatch, expected: 3, got: 5}}`: si devolviera
  `:miss` o un `0.0`, el fallo sería indistinguible de una comparación real.
- `expect(AdapterMock, :embed, 1, …)` para dos `score/4`: si la cache no
  existiera, el `verify_on_exit!` de Mox lo cantaría.

---

## 5 · Los gates, con la salida real

Todos con `. /workspace/tools/env.sh`, `export CANDIL_DATA_DIR=$(mktemp -d)`,
`MIX_BUILD_PATH` sin tocar, y `cmake`/`ninja` en el PATH.

```
### mix format --check-formatted
exit=0

### mix compile --force --warnings-as-errors
Compiling 94 files (.ex)
Generated candil app
exit=0

### mix credo --strict
Analysis took 12.8 seconds (0.7s to load, 12.1s running 70 checks on 175 files)
1801 mods/funs, found 43 software design suggestions.

### MIX_ENV=test mix test --cover
27 doctests, 936 tests, 0 failures
 78.0% lib/candil/model.ex                           339       50       11
 80.0% lib/candil/router/classifier.ex               220       25        5
 97.1% lib/candil/router/decision_engine.ex          381       71        2
 93.6% lib/candil/router/scorer.ex                   604      125        8
[TOTAL]  68.4%

### mix dialyzer
Total errors: 0, Skipped: 0, Unnecessary Skips: 0
done (passed successfully)
```

El `compile` **sale limpio**: los dos `warning:` que aparecen son de
`deps/alaja/mix.exs` (`unlink_if_symlink/1`, `install_binary/2`), de una
dependencia, y salen igual en `main`. `grep -c "candil/lib" /tmp/compile.log` → **0**.

Y por semilla, que es donde un test que depende del orden se hace el passa:

```
$ for s in 1 42 99991; do MIX_ENV=test mix test --seed $s; done
27 doctests, 936 tests, 0 failures
27 doctests, 936 tests, 0 failures
27 doctests, 936 tests, 0 failures
```

### El `zip` del sandbox, otra vez

Sin `/workspace/tools/shim` en el `PATH` (es decir, tal y como entras tú), la
suite da **12 fallos, todos en `Candil.Build.PrecompiledTest`**, antes y después de
esta fase. No los he tocado porque no son de esta fase; los escribo aquí para que
el número rojo de tu máquina no se me atribuya.

---

## 6 · Lo que NO he verificado, y por qué

### 6.1 · Que un LLM real clasifique bien — **pendiente, es una medición**

**No es un test.** Un clasificador que devuelve `:deep` siempre pasaría los 33
tests de `scorer_layers_test.exs`, y eso tiene que quedar dicho: esos tests
comprueban el **mecanismo**, no la **utilidad**.

**Cómo se mide**, en tu máquina:

```bash
. /workspace/tools/env.sh
cd /workspace/repos/candil
export CANDIL_DATA_DIR=$(mktemp -d)
mix run scripts/router-layers-check.exs
```

**Qué tiene que imprimir para que la medición sirva**:

1. Las **ocho** líneas de la `SECCION 1`, con el ranking o el motivo de cada caso.
   Un `:miss` ahí es el resultado correcto; un `ERROR` no.
2. La tabla de la `SECCION 2`: una fila por prompt con el ranking **real** y qué
   modelo ganó. Un `0.83` no dice nada: la pregunta es si el que gana es el que
   tú habrías puesto a mano.
3. El **RECUENTO** de aciertos al final. Ese número —no la similitud— es lo que
   decide si la capa se enciende. **Por debajo del 90 % en la máquina real, la
   conclusión no es «cambia el clasificador»**: es que las `description` de los
   modelos no distinguen, o que tienes dos modelos que dicen casi lo mismo. Un
   embedder no arregla un catálogo que no sabe distinguir.

Para que la `SECCION 2` mida algo hay que sustituir `MiEmbedder` y
`MiClasificador` por los módulos reales; el script lo dice en la salida.

### 6.2 · Que un embedder real dé similitudes útiles — **pendiente, misma medición**

Lo mismo, y con la misma honestidad: el `0.9938…` del test es un vector escrito a
mano en el propio test. **Ningún test de este repo ha metido un vector de verdad
por la capa `:embedding`.**

### 6.3 · El coste real de la capa `:llm`

No medido. Cuántas veces clasifica al día, y si eso paga lo que ahorra, solo se
sabe con `Candil.Telemetry` (que emite) y contando en la máquina real. **La capa
está apagada por defecto** y sigue apagada: encenderla es tu decisión y depende de
esta medición.

### 6.4 · La afinidad — **no existe, y es lo correcto**

Las capas **filtran**. No escribí pesos, ni una ordenación, ni un `score`
compuesto: es la fase 4 y sus pesos no están decididos. Dentro de lo que pasa el
filtro manda el **orden del consumidor**, que es su orden de preferencia y no una
opinión sobre la calidad de los modelos. Está escrito en el `@moduledoc` del
`Scorer` y en un test.

### 6.5 · `docs/02-orden/README.md` sigue marcando la fase 3 con ⬜, a propósito

La convención del repo dice que *ninguna fase se cierra con el resultado de un
comando, se cierra con lo que pasó en la máquina del dueño*. Las dos capas están
escritas y los gates pasan; que la fase esté cerrada es tuyo, y depende de §6.1.
No he tocado la tabla.

### 6.6 · Cosas que encontré y **no** he tocado

- `[router.rules]` sigue sin leerse. `@rules` y `@default_rules` están fijos en el
  código, y el test de `router_test.exs` que dice que `[router.rules]` da
  vocabulario español **sigue mintiendo**. Es F8, y es anterior a esta fase. Lo he
  dejado escrito en el `docs/04-modulos`.
- `Scorer.explain/2` para `:llm` y `:embedding` sigue diciendo
  *«layer did not clear its threshold»*. Ahora solo se llega a esa cláusula cuando
  la capa ha devuelto `:miss`, que es exactamente cuando es verdad.
- `docs/04-modulos/01-routing-y-ciclo-vida/README.md` lo he actualizado en lo que
  esta fase vuelve falso (la tabla de ficheros, F9, y las cuatro referencias de
  línea que el cambio movió). El resto del documento **no** lo he revisado.

---

## 7 · Los ficheros

**Nuevos**

| Fichero | Qué |
|---|---|
| `test/candil/router/scorer_layers_test.exs` | 33 tests de las dos capas, con Mox |
| `test/candil/router/decision_engine_layers_test.exs` | 10 tests de lo que cambia arriba |
| `test/candil/config/template_test.exs` | 5 tests del esqueleto generado |
| `scripts/router-layers-check.exs` | la medición, que no es un test |

**Modificados**

| Fichero | Qué |
|---|---|
| `lib/candil/router/scorer.ex` | las dos capas, la cache, el `@type result/0`, la bandera del bucle |
| `lib/candil/router/decision_engine.ex` | usa el resultado de la capa, la guardia del bucle, no corre dos veces una capa forzada |
| `lib/candil/router/classifier.ex` | la regla del bucle en el `@doc` del callback; el módulo deja de decir que el hueco sigue abierto |
| `lib/candil/router.ex` | `classifier` y `embedder` en `[router]`, y su conversión string → átomo |
| `lib/candil/model.ex` | `description` |
| `lib/candil/config/{hydrate,schema,template}.ex` | `description` de punta a punta, y la sección `[router]` de la plantilla |
| `docs/05-cli/config/candil.toml` | regenerado desde `Template.build/0` |
| `docs/04-modulos/01-routing-y-ciclo-vida/README.md` | lo que esta fase vuelve falso |
| `test/test_helper.exs` | los dos Mox |
| `test/fixtures/config/ejemplo.toml` | `description` en tres modelos, y uno **sin** a propósito |

**Nada de commit, push ni PR.** El árbol está en `fase-3-capas-routing`.
