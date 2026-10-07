# 03 · Módulo 3 — Subsistema RAG

> **Recuperar documentos, y poder citar de dónde.**

> **Qué es este bloque**: el plano de las fases que convierten
> `lib/candil/rag.ex` —tipos congelados y cinco stubs— en algo que recupera.
>
> **Base**: rama `docs-v2`, `main` en `e168ccd` · **Medido el**: 2026-10-07
> **Fase en el orden global**: la **7** de [`docs/02-orden/`](../../02-orden/README.md),
> más la tarea **0.3** (RAG mínimo) de la fase 0.
> **Estado**: **nada de esto está escrito.** Este documento es el plano, no el
> parte.

---

## 1 · Qué es

**El problema, en una frase**: cuando le preguntas a un modelo por sus propios
documentos, no puede responder porque esos documentos no están en su
ventana de contexto, y meterlos enteros no cabe.

**Por qué ahora**: porque sin esto, el resto del producto responde con lo que el
modelo se sabe de memoria, y `docs/01-inventario/README.md` §6 ya señala el hueco
paralelo más grave: *«un módulo entero que decide, y nadie lo consulta»*. El RAG
es el segundo consumidor natural del router.

**Y no es lo que parece.** El nivel 1 de los seis niveles de diseño —cortar en
trozos fijos, guardar, devolver los más parecidos— **cabe en un módulo**. Los
niveles 4, 5 y 6 —grafo, agéntico, multimodal— son **meses**. Confundir esas dos
cosas es la forma más rápida de no sacar nunca nada.

### Los seis niveles, y lo que vale cada uno hoy

| # | Nivel | Qué hace | Cuándo | Cuánto |
|---|---|---|---|---|
| **1** | **Naive** | cortar, guardar, quedarse con los más similares | **primero** | una fase |
| **2** | **Advanced** | *query rewriting* + *reranking* (recuperar 20, quedarse con 3) | **segundo** | una fase |
| **3** | **Modular** | cambiar embedder o encender traducción sin tocar el backend | **sale solo** de la fase 1 | el resto del día |
| **4** | **Graph RAG** | extraer entidades y relaciones a una base de grafos | **no es lo siguiente** | **sin medir — meses** |
| **5** | **Agentic RAG** | la búsqueda deja de ser lineal; el LLM decide si busca más | **no es lo siguiente** | **sin medir** |
| **6** | **Multimodal RAG** | tablas, diagramas e imágenes en un espacio vectorial común | **no es lo siguiente** | **sin medir — meses** |

> **La fila 3 no es una fase: es una consecuencia.** Si el embedder y el chunker
> son `behaviour`, el nivel 3 ya está hecho. Si son funciones, el nivel 3 es
> imposible. Por eso la fase 1 de este bloque es *antes* que la de recuperar
> nada, y no por gusto del orden.

> **Honestidad sobre 4, 5 y 6**: se documentan aquí para que se sepa que existen y
> **qué necesitarían**, no porque sean el siguiente paso. Graph RAG exige elegir
> base de grafos, definir qué es una entidad en español técnico y decidir si las
> relaciones se extraen con un LLM o a mano. Multimodal RAG exige un modelo de
> visión, un espacio común donde texto e imagen vivan juntos, y una decisión
> sobre qué es un «trozo» de una tabla. **Ninguna de las dos cosas se responde
> escribiendo Elixir.**

---

## 2 · Por qué así

### 2.1 · ETS y SQLite FTS5. Ni Postgres, ni LanceDB, ni nada externo

**La regla dura**: el estado del RAG vive en **ETS**. Se parece a
`lib/candil/router/cache.ex:117-123`, que ya crea su tabla con
`:named_table, :public, :set, read_concurrency: true, write_concurrency: true`.
Copiar ese patrón es la decisión que más rápido sale bien.

Lo que **no** hay, y por qué:

| Descartado | Por qué |
|---|---|
| **Postgres + pgvector** | es un servidor que hay que instalar, configurar, respaldar y migrar. Para un índice de documentos es una dependencia operativa con tu vida alrededor |
| **LanceDB** | una base vectorial con su propio formato en disco, su garbage collector y su versión. Todo eso para recover 20 chunks |
| **Chroma / Qdrant / Weaviate** | igual que la anterior, pero por red |
| **Un índice HNSW en memoria** | el `lib/candil/rag.ex:44-47` ya lo dice por escrito: *«for 50k documents the index costs more to build than it saves»*. Y **50k chunks es el techo real** de este diseño |

**⚠️ Y aquí está el aviso que hay que decir en voz alta**: la decisión dice
*SQLite FTS5*, y **FTS5 es un módulo de SQLite, no un algoritmo**. En
`mix.exs` **no hay ninguna dependencia SQLite**: ni `exqlite`, ni `sqlite3`, ni
nada que traiga una biblioteca nativa. Hay dos caminos y los dos cuestan algo:

1. **Meter `exqlite`**: es una NIF. Necesita un compilador de C en la máquina de
   quien instala Candil. Candil hoy es una librería Elixir pura; eso la convierte
   en una librería con toolchain.
2. **Hacer la léxica en ETS**: inverted index, `String.jaro_distance` o
   normalización + tokens. Se pierde el *stemming* y el *snippet* de FTS5, y se
   gana cero dependencias.

Esto está marcado como **decisión abierta** en el Anexo IV y **bloquea la fase R-2**.

### 2.2 · El chunking es una FUNCIÓN, y los modos son valores

El tipo ya está escrito, y dice exactamente lo que hay que hacer
(`lib/candil/rag.ex:69`):

```elixir
@type strategy :: :sentence | :paragraph | :fixed
```

Eso es **un tipo con tres valores**, no tres módulos. El tipo congelado ya
contiene la decisión: `sentence`, `paragraph` y `fixed` son **modos del mismo
`chunker`**, no chunkers distintos. Tres módulos que hacen lo mismo con
divididores distintos es tres sitios donde arreglar un error de codificación.

Y el `@moduledoc` de `lib/candil/rag.ex:62-68` ya dice cuál gana:
*«`sentence` is the default because it is the one that respects meaning at the
boundary. `fixed` splits at a token count and is a fallback, not an
improvement.»*

### 2.3 · Los embeddings se cachean por hash del texto

Un embedding de un texto es **determinista**. Si el mismo párrafo sale en tres
documentos, se paga una vez. La clave es el hash del texto —como
`lib/candil/router/cache.ex:41-62` ya hace con los prompts— y el valor es el
vector. Sin esto, reindexar un documento que cambió en una línea vuelve a pagar
embeddings de párrafos idénticos.

### 2.4 · Indexado INCREMENTAL, no snapshot completo

Reindexar todo por cada cambio es lo que hace el prototipo y es lo que hace que
la segunda indexación tarde más que la primera. El `id` de un chunk tiene que
**ser estable** si su texto no ha cambiado, y eso es lo que permite indexar solo
lo que cambió. Es también lo que hace posible el watcher.

### 2.5 · El watcher es OPCIONAL y con eventos *debounced*

No es un proceso encendido siempre. Es `Trebejo.File.watch/3`, que **ya existe** en
`deps/trebejo/lib/trebejo/file.ex:31`:

```elixir
@spec watch([binary()], ([{binary(), [atom()]}] -> any()), keyword()) ::
        {:ok, pid()} | {:error, term()}
def watch(dirs, callback, opts \\ []) when is_list(dirs) and is_function(callback, 1)
```

Opciones reales, leídas del fichero: **`:debounce_ms`** (por defecto `100`) y
**`:name`**. El callback recibe una lista de **`{path, [atom()]}`**. Y existe
`Trebejo.File.unwatch/1` para pararlo.

El *debounce* no es un detalle: un editor escribe un fichero en tres o cuatro
escrituras seguidas, y sin *debounce* indexas cuatro veces lo mismo.

> **⚠️ Prerrequisito técnico, medido**: en `mix.exs`, Trebejo está declarado
> `optional: true, runtime: false`. **Por defecto Candil no lo tiene cargado.**
> Llamar a `Trebejo.File.watch/3` desde `lib/candil/rag/watcher.ex` sin más es
> una llamada a un módulo que puede no existir. Las dos salidas son: quitar
> `optional: true` de Trebejo (y ajustar el resto de la declaración en
> `mix.exs`), o
> envolver la llamada en `Code.ensure_loaded?(Trebejo.File)` y devolver
> `{:error, :watcher_unavailable}`. **Está marcado como decisión abierta** en el Anexo IV.

### 2.6 · Sin embedder, la búsqueda sigue funcionando

Este es el contrato de degradación, y es la razón por la que la fase R-2 es
**léxica primero**:

- **Hay embedder y hay léxica** → híbrido, RRF de las dos listas.
- **No hay embedder, hay léxica** → solo léxica. **Funciona.** No es un error.
- **No hay embedder y no hay léxica** → `{:error, :no_embedder}`, y el error
  **dice el nombre de lo que falta**.

`Candil.RAG.embedder/1` (`lib/candil/rag.ex:142-153`) ya tiene esa última forma y
su `@spec` (`lib/candil/rag.ex:141`) ya la declara:

```elixir
@spec embedder(map()) :: {:ok, atom()} | {:error, :no_embedder | {:unknown_embedder, binary()}}
```

**Y las tres formas están probadas hoy**, en
`test/candil/rag_test.exs:74-93`. Eso no se toca: es la base sobre la que se
construye el resto.

### 2.7 · RRF, y por qué no una suma de puntuaciones

El `lib/candil/rag.ex:34-40` lo explica y es la razón correcta:

> *BM25 and cosine similarity produce numbers on different scales. Adding them
> needs calibration that nothing here can do for you.*

El RRF solo usa **la posición**, no la puntuación:

```
score(d) = Σ  1 / (k + rank_i(d))        con k = 60
```

`Candil.RAG.rrf_k/0` (`lib/candil/rag.ex:163`) devuelve `60`, y
`Candil.RAG.rrf/2` (`lib/candil/rag.ex:180-198`) ya lo implementa **exacto**, con
los empates rompiéndose por el `id` para que el resultado sea estable. Está
probado en `test/candil/rag_test.exs:9-53`, incluido el caso del empate real.

> **Si alguien lo reescribe de otra manera, el `@moduledoc` de
> `lib/candil/rag.ex` tiene que decir por qué.** La convención de
> [`docs/03-convenciones/`](../03-convenciones/README.md) §4 dice que el
> contrato va primero y que la razón del «por qué» va con el código. Un RRF
> reimplementado sin ese comentario es una regresión silenciosa.

### 2.8 · El coseno es un escaneo lineal, y por debajo de 50k

`Candil.RAG.cosine/2` (`lib/candil/rag.ex:215-232`) ya está escrito, ya trata el
vector cero como `0.0` en vez de dividir por cero, y ya **levanta** `ArgumentError`
si las longitudes no coinciden. Los dos comportamientos están probados en
`test/candil/rag_test.exs:55-72`.

El escaneo lineal es la decisión: sobre una lista de 50k float en BEAM, comparar
contra la consulta es **más rápido que construir un índice**. El techo de este
diseño son ~50k chunks, y cuando se llegue ahí la respuesta honesta es una base
de datos de verdad, no un índice casero.

### 2.9 · Lo que queda congelado

El `Candil.RAG.Chunk` (`lib/candil/rag.ex:1-28`) tiene `@enforce_keys [:id, :text]`
y un `@type t` con ocho campos. **No se cambia.** Si algún día hace falta un
campo, es una fase con su `@spec` viejo retiring y su test de contrato.

> **Y hay una contradicción que hay que decir, no tapar.**
> `lib/candil/rag.ex:60` declara `@type backend :: :memory | :postgres`, y el
> `@moduledoc` de las líneas 44-47 habla de *«the Postgres backend with
> pgvector»*. **La decisión de este bloque dice que Postgres no.** El tipo está
> congelado, así que **no se toca**, pero el tipo y la decisión no pueden
> quedar los dos. Está en el Anexo IV como decisión abierta, y es de las que hay que
> cerrar **antes** de escribir el primer `store`.

---

## 3 · Qué toca

Lista cerrada. Cualquier fichero que no esté aquí no se toca en estas fases.

### Ficheros que ya existen y **se modifican**

| Fichero | Qué se le hace |
|---|---|
| `lib/candil/rag.ex` | la fachada. Sus cinco stubs pasan a cuerpo real, uno a uno |
| `lib/candil/config/schema.ex` | añadir `@sections` la palabra `rag` (hoy son `general engine model provider consumer`) |
| `lib/candil/config/template.ex` | la sección `[rag]` comentada, porque el esqueleto tiene que mencionar todas |
| `lib/candil/application.ex` | un hijo más: el `GenServer` que crea las tablas ETS |
| `mix.exs` | **solo si** se cierra la decisión de SQLite (Anexo IV) |

### Ficheros nuevos

| Fichero | Qué vive en él |
|---|---|
| `lib/candil/rag/chunk.ex` | el `Candil.RAG.Chunk` **movido** de `lib/candil/rag.ex`. El módulo y el `@type t` no cambian |
| `lib/candil/rag/chunker.ex` | el `behaviour` y los tres modos |
| `lib/candil/rag/embedder.ex` | el `behaviour` y el caché por hash |
| `lib/candil/rag/store.ex` | las tablas ETS y los ids estables |
| `lib/candil/rag/lexical.ex` | la búsqueda léxica |
| `lib/candil/rag/semantic.ex` | el escaneo por coseno |
| `lib/candil/rag/hybrid.ex` | RRF de las dos listas |
| `lib/candil/rag/rewriter.ex` | *query rewriting* (nivel 2) |
| `lib/candil/rag/reranker.ex` | el *reranking* opt-in (nivel 2) |
| `lib/candil/rag/watcher.ex` | `Trebejo.File.watch/3` con *debounce* (opcional) |

### Tests nuevos

`test/candil/rag/chunker_test.exs` · `test/candil/rag/embedder_test.exs` ·
`test/candil/rag/store_test.exs` · `test/candil/rag/lexical_test.exs` ·
`test/candil/rag/hybrid_test.exs` · `test/candil/rag/rewriter_test.exs` ·
`test/candil/rag/reranker_test.exs` · `test/candil/rag/watcher_test.exs`

### ⚠️ Un movimiento que conviene declarar aquí

`Candil.RAG.Chunk` vive **dentro de `lib/candil/rag.ex`**, en el mismo fichero que
la fachada. Moverlo a `lib/candil/rag/chunk.ex`:

- **no cambia el módulo**: sigue siendo `Candil.RAG.Chunk`
- **no cambia el `@type t`**: se copia byte a byte
- **no rompe `mix.exs`**: el grupo `RAG: [Candil.RAG, Candil.RAG.Chunk]` de `docs()`
  sigue resolviendo los dos
- **sí rompe el `@moduledoc` de `Candil.RAG`**, que hoy empieza con
  `alias Candil.RAG.Chunk`. Eso se actualiza en la misma fase.

Se declara aquí porque el plano pide una lista cerrada y **callarlo sería peor**
que hacerlo.

---

## 4 · Los tests primero

Los cuatro patrones de [`docs/03-convenciones/`](../03-convenciones/README.md) §3,
y cuál usa cada fase:

| Fase | Patrón | Por qué |
|---|---|---|
| R-1 | **contrato** | un `@spec` que cambia de forma es un `@spec` que devuelve algo distinto |
| R-2 | **de necesidad** | que la documentación apunte a algo real: `candil --help` listando lo declarado |
| R-3 | **contrato** + **de orden** | el caché por hash comparte estado entre tests |
| R-4 | **contrato** | 20 entran y 3 salen; el número es el contrato |
| R-5 | **de frente** | un fichero cambia de verdad y el índice se entera |

### 4.1 · El test de la fase R-1 (behaviours)

Escrito **antes** que el código, y rojo:

```elixir
defmodule Candil.RAG.ChunkerTest do
  use ExUnit.Case, async: true

  alias Candil.RAG.{Chunk, Chunker}

  doctest Candil.RAG.Chunker

  describe "un chunker de verdad, no una lista cerrada" do
    test "el modo por defecto es sentence" do
      assert Chunker.strategy() == :sentence
    end

    test "los tres modos son modos del MISMO chunker" do
      # Esta es la decisión del bloque. Si un día hay tres módulos distintos,
      # este test es el que se pone rojo y dice por qué.
      for mode <- [:sentence, :paragraph, :fixed] do
        assert {:ok, chunks} = Chunker.chunk(TEXTO, mode: mode, document_id: "d1")
        assert Enum.all?(chunks, &match?(%Chunk{}, &1))
      end
    end

    test "sentence no parte una frase por la mitad" do
      {:ok, chunks} = Chunker.chunk("Uno. Dos! Tres? Cuatro.", mode: :sentence, document_id: "d1")
      texts = Enum.map(chunks, & &1.text)
      assert "Uno." in texts
      assert "Cuatro." in texts
    end

    test "la posición es correlativa y empieza en cero" do
      {:ok, chunks} = Chunker.chunk(TEXTO, mode: :paragraph, document_id: "d1")
      assert Enum.map(chunks, & &1.position) == Enum.to_list(0..(length(chunks) - 1))
    end

    test "cada chunk lleva el document_id que le han pasado" do
      {:ok, chunks} = Chunker.chunk(TEXTO, mode: :fixed, document_id: "d1")
      assert Enum.all?(chunks, &(&1.document_id == "d1"))
    end

    test "texto vacío es una lista vacía, no un error" do
      assert {:ok, []} = Chunker.chunk("", mode: :sentence, document_id: "d1")
    end

    test "sin document_id es un error que lo dice" do
      assert {:error, %Candil.Error{reason: :invalid_request}} = Chunker.chunk("texto", [])
    end
  end
end
```

Y el behaviour, que es lo que hace posible el nivel 3:

```elixir
defmodule MiApp.Chunker do
  @behaviour Candil.RAG.Chunker

  @impl true
  def chunk(text, opts) do
    # El chunker de otra casa, con las reglas de otra casa.
    {:ok, Chunk.from_parts("miapp", texto, partes())}
  end

  defp partes(), do: :binary.split(texto(), ["\n===\n"], trim: true)
end
```

### 4.2 · El test de la fase R-2 (nivel 1, léxica)

```elixir
defmodule Candil.RAG.LexicalTest do
  use ExUnit.Case, async: false

  alias Candil.RAG

  setup do
    start_supervised(Candil.RAG.Store)
    Candil.RAG.Store.reset()
    :ok
  end

  describe "indexar y recuperar, sin embeddings" do
    test "el chunk vuelve" do
      assert {:ok, 3} = RAG.index("docs", FICHERO)
      assert {:ok, [primer | _]} = RAG.search("docs", "llamaradas")
      assert primer.text =~ "llamaradas"
    end

    test "el resultado se puede citar" do
      # Un chunk sin posición no se puede citar, y una respuesta que no se
      # puede comprobar no sirve. Esto es lo que dice el @moduledoc de Chunk.
      assert {:ok, [chunk | _]} = RAG.search("docs", "llamaradas")
      assert is_integer(chunk.position)
      assert chunk.document_id == FICHERO
    end

    test "SIN embedder la búsqueda funciona igual" do
      # La degradación es el contrato. Este test es el que falla si alguien
      # empieza a exigir embeddings para devolver algo.
      assert {:error, :no_embedder} = RAG.embedder(%{})
      assert {:ok, [_ | _]} = RAG.search("docs", "llamaradas")
    end

    test "un término que no está en ningún sitio devuelve vacío, no un error" do
      assert {:ok, []} = RAG.search("docs", "zzzz-no-existe-zzzz")
    end

    test "sin nada indexado devuelve vacío" do
      assert {:ok, []} = RAG.search("vacio", "lo que sea")
    end
  end
end
```

### 4.3 · El test de la fase R-4 (nivel 2: recuperar 20, quedarse con 3)

```elixir
describe "el reranking" do
  test "20 entran y 3 salen, y salen por el score del reranker" do
    {:ok, veinte} = RAG.search("docs", PREGUNTA, retrieve: 20)
    assert length(veinte) == 20

    {:ok, tres} = RAG.search("docs", PREGUNTA, retrieve: 20, rerank: true)
    assert length(tres) == 3
  end

  test "sin reranker los 20 salen en orden de recuperación" do
    # El rerank es opt-in y NUNCA el default. El @moduledoc de Candil.RAG lo
    # dice: "roughly a hundred times the cost".
    {:ok, con} = RAG.search("docs", PREGUNTA, retrieve: 20)
    {:ok, sin} = RAG.search("docs", PREGUNTA, retrieve: 20, rerank: false)
    assert Enum.map(con, & &1.id) == Enum.map(sin, & &1.id)
  end

  test "un reranker que lanza degrada a sin rerank, no tumba la búsqueda" do
    {:ok, siete} = RAG.search("docs", PREGUNTA, retrieve: 20, rerank: MiApp.Reranker.QueFalla)
    assert length(veinte(7)) == 7
  end
end
```

### 4.4 · El test de la fase R-5 (indexado incremental y watcher)

```elixir
describe "indexar solo lo que cambió" do
  test "reindexar el mismo fichero no cambia los ids de los chunks iguales" do
    {:ok, _} = RAG.index("docs", FICHERO)
    antes = RAG.Store.ids("docs")

    # Se toca un párrafo del final, no el primero.
    escribir(FICHERO, texto_modificado())
    {:ok, _} = RAG.index("docs", FICHERO)
    despues = RAG.Store.ids("docs")

    assert Enum.take(antes, 1) == Enum.take(despues, 1)   # el primero no se movió
  end

  test "un párrafo borrado no deja chunks fantasma" do
    {:ok, n_antes} = RAG.index("docs", FICHERO)
    escribir(FICHERO, texto_sin_ultimo_parrafo())
    {:ok, n_despues} = RAG.index("docs", FICHERO)
    assert n_despues < n_antes
  end
end
```

---

## 5 · Cómo se hace

**Los comandos, en orden.** El orden de las fases está en el Anexo I; aquí está
**qué se ejecuta**, literal, para no tener que decidir nada mientras se ejecuta.

### 5.1 · Preparar

```bash
cd /ruta/al/repo/candil
git checkout docs-v2
git status                     # debe decir: working tree clean
mix deps.get
mix compile                   # debe decir "Compiled N files", 0 errores
mix test                      # debe decir: 27 doctests, 800 tests, 0 failures
```

Los números `27 doctests` y `800 tests` son los de
[`docs/01-inventario/`](../01-inventario/README.md), medidos el 2026-10-07. **Si
los tuyos no son esos, para aquí**: lo que sigue no vale hasta saber por qué.

### 5.2 · Escribir el test, y verlo ROJO

```bash
mix test test/candil/rag/chunker_test.exs
```

**Qué se espera ver**: una lista de fallos, cada uno con la razón. Si sale
`0 failures` antes de haber escrito el módulo, **el test no está probando nada**:
está leyendo algo que ya existía.

### 5.3 · Escribir el código mínimo

Editar el fichero de §3. Y **solo ese**.

### 5.4 · Verlo verde

```bash
mix test test/candil/rag/chunker_test.exs
```

**Qué se espera ver**: `0 failures`, y el número de tests ha subido respecto al
paso 5.2.

### 5.5 · Comprobar que el test **falla cuando el código está mal**

Esto es lo que separa un test de una descripción. **No es opcional**:

```bash
# 1. Romper algo a propósito
mix test test/candil/rag/chunker_test.exs      # debe decir: 0 failures

# 2. Cambiar el divisor por otro en lib/candil/rag/chunker.ex
mix test test/candil/rag/chunker_test.exs      # debe decir: 1 failure, Y DECIR POR QUÉ
```

**Si sale `0 failures` con el código roto, el test es decoracion**
([`docs/03-convenciones/` §3](../03-convenciones/README.md)). Vuelve a escribirlo.

### 5.6 · Refactorizar con el test en verde

```bash
mix format
mix format --check-formatted
mix test
```

### 5.7 · Las siete puertas, en orden

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix escript.build
```

Y después, la verificación por semilla — **que aquí no es superstición, porque el
store es ETS y el ETS sobrevive entre tests**:

```bash
for s in 1 42 99991; do mix test --seed $s; done
```

Y, si de golpe salen muchos fallos sin razón:

```bash
rm -rf /tmp/build-candil && mkdir -p /tmp/build-candil
MIX_BUILD_PATH=/tmp/build-candil mix deps.get
MIX_BUILD_PATH=/tmp/build-candil mix compile
MIX_BUILD_PATH=/tmp/build-candil mix test
```

### 5.8 · Y lo que no es un comando

> **Ninguna fase de este bloque se cierra con el resultado de una orden.** Se
> cierra con los `mix run -e '…'` de §7, y con que alguien lo haya ejecutado en su
> máquina. [`docs/01-inventario/`](../01-inventario/README.md) §9: *«los tres
> fallos de esta semana salieron ejecutando el binario en la máquina del dueño,
> con los 800 tests en verde»*.

---

## 6 · Las puertas

Las siete de [`docs/03-convenciones/`](../03-convenciones/README.md) §5, en
**este** orden, y qué falla si no pasan:

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix escript.build
```

| Puerta | Si falla en RAG, significa |
|---|---|
| `format` | hay comillas o indentation cambiados en `lib/candil/rag/**` |
| `compile --warnings-as-errors` | un `behaviour` declarado sin `@callback` (hoy **`Candil.Tool` tiene exactamente eso**: `@behaviour` en el `use` y ningún `@callback` en el módulo) |
| `credo --strict` | complejidad en `Candil.RAG.rrf/2`, o un `Enum` anidado de más |
| **`test`** | **esta es la que mira RAG.** El resto es hygiene |
| `dialyzer` | un `@spec` que promete una forma y el cuerpo devuelve otra. Con `:no_underspecs` en `mix.exs`, es el dialyzer el que dice que el contrato es más estrecho de lo que es |
| `escript.build` | Candil ya no arranca como binario. **No es menor**: es la regla 1 de [`docs/README.md`](../../README.md) |

Y después de las siete, la que no es una puerta:

> **Ninguna de estas fases se cierra con el resultado de un comando.** Se cierra
> con `mix run -e '…'` recovering de un fichero de verdad, y con alguien
> ejecutándolo en su máquina.

Y la verificación por semilla, porque **el ETS se comparte entre tests**:

```bash
for s in 1 42 99991; do mix test --seed $s; done
```

Y si salen muchos fallos de golpe sin razón aparente:

```bash
rm -rf /tmp/build-candil && mkdir -p /tmp/build-candil
MIX_BUILD_PATH=/tmp/build-candil mix deps.get
MIX_BUILD_PATH=/tmp/build-candil mix compile
MIX_BUILD_PATH=/tmp/build-candil mix test
```

---

## 7 · Cómo se sabe que funciona

**Y cómo se sabe que falla.** Las dos columnas, porque un test que solo sabe
decir «verde» no sabe decir nada — es la razón por la que la sección 7 no se
puede quitar de [`docs/03-convenciones/`](../03-convenciones/README.md) §1.

### 7.1 · Que funciona

```bash
# 1. Indexar un fichero real, con el embedder ausente A PROPÓSITO
mix run -e '
  {:ok, n} = Candil.RAG.index("demo", "README.md")
  IO.puts("chunks: #{n}")
  {:ok, hits} = Candil.RAG.search("demo", "protocolo")
  IO.puts("hits: #{length(hits)}")
  IO.inspect(Enum.take(hits, 1))
'
```

**Qué se espera ver**: `chunks:` con un número **mayor que cero**, `hits:`
con un número mayor que cero, y un `%Candil.RAG.Chunk{}` con `position` entero
y `document_id` igual a `"README.md"`.

### 7.2 · Que **falla**

Esto es lo que de verdad hay que ejecutar, y es lo que nadie hace:

```bash
# Romper el chunking a propósito: cambiar el divisor por uno que no existe
mix run -e '
  IO.inspect(Candil.RAG.Chunker.chunk("Uno. Dos. Tres.", mode: :fixed, document_id: "d1"))
'
```

**Qué se espera ver**: `{:error, %Candil.Error{reason: :invalid_request, ...}}` con
el modo en el mensaje. **Un `:ok` aquí es un fallo**, porque significa que un
documento se ha partido por un sitio que nadie eligió.

```bash
# Y el otro: quitar el embedder y comprobar que la búsqueda NO se cae
mix run -e '
  IO.inspect(Candil.RAG.embedder(%{}))
  IO.inspect(Candil.RAG.search("demo", "protocolo"))
'
```

**Qué se espera ver**: `{:error, :no_embedder}` **y una lista con resultados**.
Si la segunda línea es un error, la degradación está rota.

```bash
# Y el más caro: un índice de verdad, y medir
mix run -e '
  texto = Enum.map_join(1..2000, "\n", &"párrafo #{&1} sobre oto y protocolo")
  {:ok, n} = Candil.RAG.index("grande", texto)
  IO.puts("chunks: #{n}")
  {us, res} = :timer.tc(fn -> Candil.RAG.search("grande", "oto") end)
  IO.puts("search: #{Float.round(us / 1000, 2)} ms, #{length(res)} hits")
'
```

**Qué se espera ver**: un número. **Este es el número que decide si el escaneo
lineal aguanta**, y **hoy no está medido**. Está en el Anexo III.

### 7.3 · Los cuatro patrones, usados

| Patrón | Dónde | Qué falla si el código está mal |
|---|---|---|
| **Contrato** | `test/candil/rag_test.exs:95-107` (los cinco stubs) | cambia un stub por un `:ok` falso y falla |
| **De orden** | el store en ETS | con una semilla concreta, un test lee lo que dejó otro. Ya pasó con los pins |
| **De frente** | §7.2 | el índice contesta `[]` y nadie lo ve |
| **De necesidad** | `mix run -e '…'` de arriba | el comando devuelve `:not_implemented` y el binario no se entera |

---

## 8 · Cuando sale mal

Los fallos **esperados**, con lo que hay que hacer en cada uno. La mitad de las
horas perdidas de este proyecto se fueron buscando el motivo de un fallo cuyo
mensaje no lo explicaba.

| Síntoma | Qué es | Qué hacer |
|---|---|---|
| `{:error, %Candil.Error{reason: :no_embedder}}` al buscar | **No es un bug. Es el contrato.** No hay modelo de embeddings configurado | Poner `[rag] embedder = "…"` en `~/.config/candil/candil.toml`, o seguir con la léxica, que funciona |
| `{:error, {:unknown_embedder, "nombre"}}` | el nombre del TOML no existe como átomo | Es `String.to_existing_atom/1` haciendo su trabajo (`lib/candil/rag.ex:142-151`). **No lo cambies por `String.to_atom/1`**: eso convierte un nombre mal escrito en un átomo que se cuela en la tabla de átomos para siempre. El fallo ruidoso es el diseño |
| `the table identifier does not refer to an existing ETS table` | el `Candil.RAG.Store` no está en `lib/candil/application.ex`, o está **después** de quien lo lee | Orden de supervisión. Es el mismo error que ya documenta `lib/candil/application.ex` con `Candil.Store` |
| Un test verde con una semilla y rojo con otra | el ETS se comparte entre tests | Particionar por índice, como ya hace `Candil.Context` por `{consumer, session_id}`. Y correr `for s in 1 42 99991; do mix test --seed $s; done` |
| `ArgumentError: Candil.RAG.cosine/2 needs vectors of equal length` | un embedder devolvió vectores de distinta longitud, o un chunk de otra dimensión se coló en la caché | Es `lib/candil/rag.ex:217-220` cumpliendo su `@spec`. **La caché por hash tiene que guardar también la dimensión**, o el cambio de modelo rompe búsquedas viejas |
| Un `-32603` de un LLM al reescribir | el modelo de embeddings se usa para escribir, y no sabe escribir | El nivel 2 es un extra. `rewriter` tiene que devolver `{:ok, original}` y seguir |
| `Trebejo.File.watch/3` dice `UndefinedFunctionError` | Trebejo está `optional: true` en `mix.exs` | La decisión abierta de §2.5 (Anexo IV). Mientras no se cierre, la fase R-5 **no arranca** |
| SQLite no compila en la máquina de alguien | `exqlite` necesita un compilador de C | Ver el Anexo IV. O el usuario no tiene toolchain y Candil no instala |
| La búsqueda tarda **mucho** | más de ~50k chunks | El `lib/candil/rag.ex:44-47` ya dice cuál es la respuesta honesta a ese tamaño: una base de datos de verdad. **No se arregla con un índice casero** |

---

## Anexo I · Desglose en fases

Las fases van en este orden. **Cada una nombra su prerrequisito**, y una fase
cuyo prerrequisito no existe no es difícil: es imposible
([`docs/02-orden/` §1](../../02-orden/README.md)).

### 🔶 FASE R-1 · Los dos behaviours — `lib/candil/rag/chunker.ex`, `lib/candil/rag/embedder.ex`

> **Prerrequisito**: **ninguno**. Es la fase 1 de
> [`docs/02-orden/`](../../02-orden/README.md), y puede empezar hoy.
> **Desbloquea**: el nivel 3, entero, sin trabajo extra.

Por qué va **primera**: mientras el chunker y el embedder sean funciones dentro
de `lib/candil/rag.ex`, cambiar de embedder es editar el mismo fichero que hace
la recuperación. El nivel 3 no es una mejora: es la ausencia de ese problema.

1. Escribir `test/candil/rag/chunker_test.exs` entero, y verlo rojo.
2. `lib/candil/rag/chunker.ex`: `@callback chunk(binary(), keyword()) :: {:ok, [Chunk.t()]} | {:error, term()}`,
   y `sentence/2`, `paragraph/2`, `fixed/2` delegando a **una** función privada
   `split/3` que recibe el divisor. `strategy/0` devuelve `:sentence`.
3. Mover `Candil.RAG.Chunk` a `lib/candil/rag/chunk.ex` **sin tocar el `@type`**.
4. Escribir `test/candil/rag/embedder_test.exs` y ver el rojo. `@callback
   embed([binary()], keyword()) :: {:ok, [[float()]]} | {:error, term()}`, con la
   caché por hash detrás.
5. Un test **de necesidad**: `grep -rn "RAG.Chunker" lib/` tiene que dar el
   behaviour, la façade y el test. Cero usos más, porque todavía no hay nadie.
6. Correr las siete puertas de §6.

> **Lo que esta fase NO hace**: no recupera nada. No toca `Candil.RAG.index/3`
> ni `search/3`. Al terminar, los cinco stubs siguen devolviendo
> `{:error, %Candil.Error{reason: :not_implemented}}`, y eso es lo correcto.

### 🔶 FASE R-2 · Nivel 1 en léxica — `lib/candil/rag/store.ex`, `lib/candil/rag/lexical.ex`, y `search/3` deja de ser stub

> **Prerrequisito**: **R-1**, y **la decisión de SQLite cerrada** (Anexo IV).
> **Desbloquea**: recuperar algo. Y el contrato de degradación.
> **Cierra la tarea 0.3 de [`docs/02-orden/` §5](../../02-orden/README.md)**.

1. Cerrar la decisión: `exqlite` o léxica en ETS. Escribirla en un `DECISIONES.md`
   de esta fase, porque cambia el rumbo.
2. Test de `store`: alta, baja, `ids/1`, y **que dos tests no se pisen** (es ETS,
   y `Candil.Context` ya tiene el particionado por consumidor justamente por esto).
3. `lib/candil/rag/store.ex`: tablas ETS con las **mismas opciones** que
   `lib/candil/router/cache.ex:117-123`. `id` de chunk estable:
   `:crypto.hash(:sha256, document_id <> position <> texto)` truncado.
4. Test de `lexical` **antes** del módulo.
5. `Candil.RAG.index/3` con cuerpo: lee, chunkea con `Candil.RAG.Chunker`, guarda.
   `Candil.RAG.search/3` con cuerpo: léxica, y **si no hay embedder, ahí se acaba**.
6. Los tres stubs que quedan (`create_index/2`, `drop_index/1`, `list_indexes/0`)
   pasan a cuerpo también, porque el store los tiene.
7. `lib/candil/config/schema.ex`: `rag` en `@sections`. `lib/candil/config/template.ex`:
   la sección comentada. Sin esto, `Candil.RAG.embedder/1` recibe un mapa que
   **nada produce**, y su `@spec` es decoracion.

> **El `@spec` de `embedder/1` ya funciona con un mapa, no con la config.** Es
> deliberado: `lib/candil/rag.ex:125-128` lo dice — *«the conversion happens here
> rather than at every call site»*. La fase R-2 solo tiene que **producir** ese
> mapa, no cambiar la función.

### 🔶 FASE R-3 · Nivel 1 completo — `lib/candil/rag/semantic.ex`, `hybrid.ex`, y el RRF conectado

> **Prerrequisito**: R-2, y **un modelo de embeddings en el catálogo** (`[model]`),
> que hoy existe (`lib/candil/config/schema.ex:16` acepta `model`) pero no hay
> ninguno de embeddings escrito.
> **Desbloquea**: la búsqueda híbrida.

1. Test de `semantic`: mismo texto, mismo vector; vector cero, `0.0`.
2. `lib/candil/rag/semantic.ex`: escaneo lineal con `Candil.RAG.cosine/2` sobre
   los embeddings del store. **Nada de índice.**
3. Test de `hybrid`: las dos listas se fusionan y el resultado es el de
   `Candil.RAG.rrf/2`. **Reutilizar `rrf/2`, no reescribirlo.**
4. El test que **falla si alguien reimplementa el RRF**: compara el orden de
   `RAG.search/3` con el de `Candil.RAG.rrf/2` sobre las mismas dos entradas.
5. `Candil.RAG.search/3` con las cuatro ramas del §2.6, y `rerank: false` como
   **default explícito** (no por omisión: escrito).
6. El contrato `{:error, :no_embedder}` con **el nombre de lo que falta**, como ya
   hace `embedder/1` desde `lib/candil/rag.ex:142`.

### 🔶 FASE R-4 · Nivel 2 — `rewriter.ex`, `reranker.ex`

> **Prerrequisito**: R-3. **Y un modelo para reescribir**, que es el mismo tipo de
> cosa que R-3 necesita y por eso va después.
> **Desbloquea**: recovering 20 y quedarse con 3.

1. `rewriter.ex`: **una** pasada de LLM que devuelve una consulta alternativa.
   El `{:ok, original}` cuando no hay modelo, porque reescribir es una mejora
   opcional, no una condición.
2. `reranker.ex`: cross-encoder, **opt-in**, con `use: false` por omisión.
   El coste está en el `@moduledoc` de `lib/candil/rag.ex:49-53` y es de unas
   **cien veces** la recuperación. Que nadie lo descubra al abrir la factura.
3. Un reranker que **lanza** devuelve los candidatos sin rerank y anota el
   `metadata`. Un retrieval que tumba la búsqueda por un reranker roto es peor
   que un retrieval sin rerank.

### 🔶 FASE R-5 · Indexado incremental y watcher opcional — `watcher.ex`

> **Prerrequisito**: R-3 (los ids ya son estables) y **la decisión de Trebejo
> cerrada** (Anexo IV).
> **Desbloquea**: nada de lo siguiente. Es comodidad.

1. Test de incremental: el `id` de un chunk cuyo texto no cambió **no cambia**.
2. `watcher.ex` con `Trebejo.File.watch/3`, `:debounce_ms` explícito y
   `Trebejo.File.unwatch/1` al parar. **Nada de `Task.start` por evento sin
   plafond**: un *save-all* de un editor son 200 ficheros.
3. Un test que mira **qué pasa si Trebejo no está**: ese es el test que decide la
   pregunta de §2.5, y por eso se escribe antes que la respuesta.

---

## Anexo II · Los contratos

Las formas, escritas. `docs/03-convenciones/` §4: *un contrato que no dice qué
pasa cuando falla es un contrato que no existe*.

### Lo que YA existe y no cambia

```elixir
# lib/candil/rag.ex — congelado
@type index_name :: binary()
@type backend :: :memory | :postgres          # ⚠️ contradice la decisión, ver §8
@type strategy :: :sentence | :paragraph | :fixed

@spec create_index(index_name(), keyword()) :: :ok | {:error, term()}
@spec index(index_name(), binary(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
@spec search(index_name(), binary(), keyword()) :: {:ok, [Chunk.t()]} | {:error, term()}
@spec drop_index(index_name()) :: :ok | {:error, term()}
@spec list_indexes() :: [index_name()] | {:error, term()}

@spec embedder(map()) :: {:ok, atom()} | {:error, :no_embedder | {:unknown_embedder, binary()}}
@spec rrf_k() :: pos_integer()                                   # devuelve 60
@spec rrf([[{binary(), float()}]], pos_integer()) :: [{binary(), float()}]
@spec cosine([float()], [float()]) :: float()
```

### Lo que las fases añaden

```elixir
# Candil.RAG.Chunker
@callback chunk(binary(), keyword()) :: {:ok, [Chunk.t()]} | {:error, term()}
@spec strategy() :: strategy()                                  # :sentence
@spec chunk(binary(), strategy() | keyword()) :: {:ok, [Chunk.t()]} | {:error, term()}

# Candil.RAG.Embedder
@callback embed([binary()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
@spec embed(binary(), keyword()) :: {:ok, [float()]} | {:error, term()}

# Candil.RAG.search/3, las cuatro ramas
#   {:ok, [Chunk.t()]}                      embedder + léxica   (RRF)
#   {:ok, [Chunk.t()]}                      solo léxica         (degradado)
#   {:ok, [Chunk.t()]}                      solo semántica
#   {:error, :no_embedder}                  no hay ninguna      (CON EL NOMBRE)
```

> **Invariante**: un `id` de chunk es función de `(document_id, position,
> texto)`. Si el texto no cambia, el `id` no cambia. **Si esto se rompe, el
> indexado incremental y el watcher se caen los dos**, y no por un fallo ruidoso
> sino por duplicados silenciosos.

> **Invariante**: un embedding cacheado **solo se sirve si el modelo y la
> dimensión son los mismos** que los del texto. Una caché sin esa clave es una
> búsqueda que devuelve números sin sentido después de cambiar de modelo.

---

## Anexo III · Lo que queda SIN MEDIR

[`docs/01-inventario/`](../01-inventario/README.md) §1: *«todo número sale de
ejecutarlo»*. Esto es lo que **no** está ejecutado:

| | Sin medir | Por qué importa |
|---|---|---|
| **El techo real de chunks** | cuántos chunks aguanta el escaneo lineal antes de que duela | **decide si hace falta un índice**, y §7.2 no se ha ejecutado nunca |
| **Coste de FTS5 vs. inverted en ETS** | cuál de los dos | **decide la dependencia de las dos** (Anexo IV) |
| **Cuántos chunks sale de un documento real de 50 páginas** | el tamaño medio de chunk | decide si el `metadata` se infla y si el prompt se desborda |
| **Si el reranker merece el coste** | si recupera algo que el híbrido ya no tenía | el nivel 2 se justifica o se borra |
| **Si el modelo de embeddings elegido sirve en español técnico** | si el coseno separa | **si no separa, el híbrido es la léxica con pasos extra** |
| **Coste de `exqlite` en la instalación** | si Candil sigue siendo instalable sin toolchain | decide si la NIF entra |
| **Las fases 4, 5 y 6** | todo | **no hay ni un número. Son meses** |

---

## Anexo IV · Las decisiones abiertas

Ninguna cerrada. Las cuatro primeras **bloquean** la fase que las nombra.

| # | Decisión | Bloquea |
|---|---|---|
| **1** | **SQLite FTS5 o léxica en ETS.** No hay ninguna dependencia SQLite en `mix.exs` | **R-2, entera** |
| **2** | **`@type backend :: :memory \| :postgres` vs. la regla de no-Postgres.** El tipo está congelado y la decisión lo contradice | **R-2**. Hay que declararlo: o se retira `:postgres` del tipo en su propia fase, o se dice que el tipo se queda como está y no se cumple |
| **3** | **Trebejo `optional: true`.** ¿Se deja de ser opcional, o el watcher va con `Code.ensure_loaded?/1` y su `{:error, :watcher_unavailable}`? | R-5 |
| **4** | **La sección `[rag]` en el schema.** Sin ella, `embedder/1` recibe un mapa que nada produce | **R-2** |
| **5** | **El id de chunk: ¿hash de `(document_id, position, texto)` o un contador?** El hash sobrevive a reordenamientos; el contador es legible | R-5, y de ella depende el incremental |
| **6** | **¿Dónde vive el RAG en el catálogo: `[model]` con `kind = "embeddings"`, o un `[rag] embedder = "alias"`?** | R-3 |
| **7** | **¿La fase 0.3 y la R-2 son la misma fase, o la 0.3 es una medición y la R-2 la implementación?** [`docs/02-orden/` §5](../../02-orden/README.md) las trata como una; este bloque las separa | El orden global |
| **8** | **Los niveles 4, 5 y 6. ¿Alguna vez, o se descartan por escrito?** Lo que no se decide, se vuelve a discutir en seis meses | El final de este módulo |

---

## Anexo V · Lo que este documento NO decide

| | |
|---|---|
| **Cuánto cuesta** | En sesiones, no en días. El calendario es tuyo |
| **Si el RAG va en el router o aparte** | [`docs/02-orden/` §8](../../02-orden/README.md) lo deja explícitamente a cada módulo |
| **El prompt que se le pasa al modelo** | Esto devuelve chunks. Quien arma el prompt es otro módulo |
| **Los niveles 4, 5 y 6** | Documentados para saber que existen. **No son el siguiente paso** |