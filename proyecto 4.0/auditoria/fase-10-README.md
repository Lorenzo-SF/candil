# Fase 10 — RAG

> Estado: **BLOQUEADA — pendiente de decisión.** Depende de la 9. Carril G.
> Original: `candil-4.0-final.md` §22 y la Fase 10.
> Effort: 5 d (plan) / 7 d (README) — **la discrepancia es parte del bloqueo**.
>
> **Nivel de razonamiento de la fase: `xhigh` — sube a `max` en §0 y §3.1.**
> Razón: RRF y el chunker son donde un error es invisible. Los tests pasan y las
> respuestas son malas.

---

## 🛑 0. BLOQUEANTE — lee esto antes de nada

**Hay dos versiones de esta fase y se contradicen en ocho cosas.** Un agente que
lea una y otro que lea la otra producen **software distinto**, y el que mergee
primero bloquea al otro. Hay que elegir una y borrar la otra.

| | Este README | `candil-4.0-final.md` §22 y `PROMPT-VENTANA-PARALELA` |
|---|---|---|
| **Almacén** | **SQLite FTS5** | `Index` en **memoria**, Postgres opt-in |
| **Chunking** | **por función** | sentence · paragraph · **fixed** (512) |
| **Módulos nuevos** | `RAG.Chunk` `RAG.Store` `RAG.Embedder` `RAG.Hybrid` `RAG.Ranker` | `rag/{chunker,chunk,document,index,retrieval,rerank,embedder}.ex` |
| **API** | `RAG.retrieve/2` | `create_index/2` `index/3` `search/3` `embedder/1` |
| **Estado real** | "`RAG` **solo**, como módulo vacío" | "struct, `@type` y `@spec` **congelados** en la −1, cinco funciones stub" |
| **Effort** | **7 d** | **5 d** |
| **Depende de** | la **8** | la **9** (el gantt pone F10 después de F9) |
| **Métricas** | `cachear embeddings por hash` | Rerank opt-in, sin mención de caché |

**Lo que sí está bien en este README y merece survive**, aunque no esté en el
plan:

- **SQLite FTS5 dentro del binario**: un RAG que necesita un servicio más no se
  despliega. El argumento es bueno.
- **Chunking por función**: un fragmento que parte una función por la mitad es
  inútil para citar. También es un buen argumento.
- **Cachear embeddings por hash del texto**: sin eso, cada reindexado vuelve a
  pagar el modelo.

**Lo que sí está bien en el plan y este README pierde:**

- Los structs y `@spec` **congelados en la fase −1**. Cambiar la API tira ese
  trabajo.
- `Index` como módulo aparte, con `memory` y `postgres` como implementaciones.
  Eso permite que el Postgres entre en v5 sin tocar la fase 10.
- El chunker configurable en tres modos.

**Decisión que necesito de ti:**

- **El del README** (SQLite + función) es técnicamente más fuerte, pero no está
  en el plan, no tiene structs congelados, y cambia la API.
- **El del plan** (memoria + configurables) es lo que está escrito y auditado, y
  hereda los contratos de la −1.

Mi inclinación: **el del plan como base, más las tres ideas buenas de este
README** — la caché de embeddings por hash, el argumento de FTS5 como opción de
v5, y el chunking por función como **un modo más** del chunker ( `:function` junto
a `:sentence`, `:paragraph`, `:fixed`). Eso conserva los contratos congelados y
no pierde nada de las dos versiones.

Pero es decisión tuya, y hasta que la tomes **esta fase no arranca**.

---

## 1. Qué es

Búsqueda sobre la documentación y el código, con fragmentos que llevan su ruta
de fichero, para que el LLM pueda citar.

Es la fase más larga del plan, y por eso va **la última de la ruta crítica**.
Además depende de la 8 para poder medir qué fragmento se usó de verdad, y de la 9
para que un LLM pueda llamarla como herramienta. Nada de lo anterior la necesita:
adelantarla solo pone a dos carriles a tocar el mismo código.

---

## 2. Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/rag.ex` y `lib/candil/rag/**` |
| Tests | `test/candil/rag*_test.exs` |
| Ya existe | `RAG` y `RAG.Chunk` — **congelados en la −1, cinco funciones stub** *(según el plan; según este README, `RAG` vacío. Ver §0)* |
| **Hay que crearlos** | `Chunker`, `Embedder`, `Index`, `Retrieval`, `Rerank` |

**Carril G.** No toques `gateway/**`, `mcp/**` ni `router/**`.

---

## 3. Qué hay que hacer

### 3.1 RRF · `max`

**1º en ambas listas gana a 1º en una y 5º en la otra.** Es la razón de ser del
retrieval híbrido, y es un número, no una opinión:

```elixir
score = sum(1 / (k + rank))   # k = 60, el del paper original
```

Si lo haces de otra manera, **explica por qué en el código**.

Es `max` porque es verificable numéricamente y porque el fallo es invisible: un
RRF mal hecho sigue devolviendo resultados, solo que mal ordenados, y con
suficientes documentos en el índice parece que funciona.

### 3.2 El chunker · `max`

El modo `:sentence` **no parte una frase** por la mitad. Corta entre frases. Y el
solapamiento tiene que ser **verificable en un test**, no declarativo.

Es el `max` de la fase junto al RRF, por la misma razón: un chunker malo produce
fragmentos que parecen razonables y no sirven. Los tests pasan.

**El test de solapamiento tiene que ser de contenido, no de tamaño:**

```elixir
# MAL: comprueba que el número de chunks es el esperado
assert length(chunks) == 20

# BIEN: comprueba que el último chunk empieza antes de donde acaba el primero
assert String.ends_with?(first.text, String.slice(overlap_text, 0, 50))
```

### 3.3 El camino léxico · `high`

**Se degrada solo**: sin modelo de embeddings, la búsqueda léxica sigue
funcionando. Este es un requisito de degradación, no una optimización.

### 3.4 Sin embedder · `medium`

`{:error, :no_embedder}` **con el nombre del que falta**. "no embedder" sin el
nombre obliga a ir a buscarlo.

### 3.5 El `Embedder` · `medium`

`Candil.embed/3` ya existe desde 3.0. Cableado.

### 3.6 Reranking · `medium`

Opt-in, y si falla la búsqueda sin rerank sigue funcionando. Es una llamada a un
LLM por consulta, y la mayoría de las veces no compensa.

### 3.7 La caché de embeddings · `medium`

**Si se adopta la opción del README:** cachear por hash del texto. Sin eso, cada
indexado vuelve a pagar el modelo. Si se adopta la del plan, esto no está y hay
que decidirlo aparte.

---

## 4. Capa 1 — Los ocho gates

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict --format=oneline
mix test --cover
mix dialyzer
mix docs --warnings-as-errors
mix hex.audit
mix deps.unlock --check-unused
```

Todos en verde. **La base se mira en `main` al abrir la rama.** Las referencias
"702" y "687 + 26" estaban mal: la base real medida es **705 + 26 doctests**, 0 fallos, 66.2 % (2026-10-03, `7fc0920`).
Mídela al abrir la rama; este número envejece como los otros.

---

## 5. Capa 2 — Qué tiene que pasar al ejecutar

```bash
mix test test/candil/rag_test.exs
```

| Test | Qué tiene que ocurrir | Qué NO puede ocurrir |
|---|---|---|
| chunker de 10k tokens | ~20 chunks de 512 | que el número sea correcto y el solapamiento no |
| chunker `:sentence` | **no parte una frase** | un chunk que acabe a mitad de frase |
| solapamiento | **verificable por contenido** | un assert de que el tamaño es el esperado |
| BM25 | una palabra exacta sale primero | que salga segundo "porque el índice es pequeño" |
| vector | algo semánticamente cercano sale primero | que salga porque es el único documento |
| RRF | 1º en ambas listas gana a 1º en una y 5º en la otra | un RRF que ordene por media de scores |
| sin embedder | `{:error, :no_embedder}` con el **nombre** | un `{:error, :no_embedder}` a secas |
| reranker caído | el resultado sin rerank | un error que tumba la búsqueda |

**Los dos primeros son los que más se cuelan.** Un assert de tamaño de chunk
pasa siempre y no comprueba nada del chunking.

---

## 6. Capa 3 — Revisión manual del código

- [ ] `grep -n "k = 60\|k = 60.0\|1 /" lib/candil/rag/retrieval.ex` — la constante
      del paper está escrita, no inferida.
- [ ] ¿El RRF **combina ranks**, o suma scores? Sumar scores de BM25 y de
      coseno es comparar dos escalas que no son comparables. Es el error que este
      README quiere evitar explícitamente.
- [ ] ¿El chunker `:sentence` busca un límite de frase antes del corte, o corta a
      los 512 tokens y ya?
- [ ] ¿El solapamiento se **verifica por contenido** en algún test?
- [ ] ¿Sin embedder, el camino léxico funciona **y devuelve resultados**? No que
  devuelva `[]` sin error, que es un fallo disfrazado de respuesta vacía.
- [ ] ¿El error `:no_embedder` **incluye el nombre** del modelo que falta?
- [ ] ¿Rerank es opt-in y su fallo degrada, no rompe?
- [ ] Si se adoptó la caché: ¿la clave es el **hash del texto**, y no el índice
  del chunk? Con el índice, reindexar invalida la caché entera.

---

## 7. Capa 4 — La prueba funcional

```bash
$ ./candil run embed --detach
$ ./candil rag index vault --path ~/lasaca/PENDIENTE
✓ 1.284 documentos · 18.402 chunks · 31.2s

$ ./candil rag query vault "dónde está la decisión sobre el daemon"
1. [0.82] PENDIENTE/principal/daemon.md:44
     "…el dueño es un proceso, no un daemon. Si hace falta uno,
      se cambia el dispatch de owner, no el código de stop…"
```

**Lo que tiene que ocurrir:** score, ruta con línea, y un trozo del texto. Los
tres. Es lo que se pega en una respuesta.

**Qué NO tiene que ocurrir:**

- ❌ que el fragmento de la respuesta no exista en el fichero. Un score de 0.82
  sobre un chunk inventado es peor que un error.
- ❌ que la ruta sea relativa y no se pueda abrir
- ❌ que el segundo resultado sea el mismo fichero con otra línea sin motivo

**Y con el embedding apagado**, que es la prueba de degradación:

```bash
# sin modelo de embeddings corriendo
$ ./candil rag query vault "daemon"
```

Tiene que devolver resultados por el camino léxico, o un error que **diga** que
no hay embedder. Lo que no puede es devolver `[]` sin explicación: eso parece
que no hay nada en el índice.

### En sandbox

> El retrieval necesita un embedder real, y eso necesita un `llama-server` con
> un modelo de embeddings corriendo. **En un sandbox no hay.** Los tests de
> retrieval se pueden hacer con un embedder **de mentira** inyectado, y el
> criterio de aceptación a mano es tuyo.

**Di cuál de las dos cosas estás haciendo, no lo que creas que estás haciendo.**
Un `deliverable.md` que dice "criterio ejecutado" cuando se ejecutó el unitario
con un embedder falso está mintiendo, y el siguiente agente lo va a dar por
bueno.

---

## 8. Por qué NO

- **No LanceDB ni Qdrant ni nada externo.** *(si se adopta la opción del
  README:)* SQLite FTS5 va en el propio binario. Un RAG que necesita un servicio
  más no se despliega.
- **No reranking por defecto.** Es una llamada a un LLM por consulta, y la
  mayoría de las veces no compensa.
- **No `embedding_provider: "ollama"` por defecto.** El sandbox y la máquina del
  usuario no lo tienen; el default es la API.
- **No Postgres por defecto.** *(si se adopta la opción del plan:)* regla 4 del
  Apéndice D: ETS siempre, Postgres no.
- **No tocar `mix.exs`** desde este carril. Lo pide el PR.

---

## 9. Lo que NO vas a hacer

- No toques `doctor.ex`, `mcp.ex` ni sus tests: son las fases 5 y 9.
- No toques ficheros del carril A: `model.ex`, `engine.ex`, `engine_pool.ex`,
  `build.ex`, `source.ex`, `store.ex`, `config/**`, `inference/**`.
- No toques el módulo de embeddings. Es la dependencia de la que cuelga esta
  fase, y es de otro carril.
- No hagas `git push --force`.

---

## 10. Definición de done

- [ ] **El diseño está decidido y escrito en `HANDOFF.md`** (ver §0)
- [ ] `mix test test/candil/rag_test.exs` en verde, los seis casos
- [ ] El solapamiento se verifica **por contenido**, no por tamaño
- [ ] Una búsqueda de verdad devuelve fragmentos con ruta de fichero
- [ ] El camino léxico funciona sin modelo de embeddings
- [ ] `deliverable.md` dice **qué criterio se ejecutó de verdad**
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de la base real anotada
- [ ] `CHANGELOG.md` y `HANDOFF.md` al día
- [ ] PR contra `main`, CI verde
- [ ] Tag `candil-4.0.0-rc.2`

---


## 11. Nota operativa

⚠ Misma advertencia que la 9: 5-7 días de trabajo no entran en una ventana de 30
minutos con equipos. Trocear o hacer secuencial.

Este documento **sustituye** al prompt de `PROMPT-VENTANA-PARALELA.md` para la
10 — y le añade el bloqueante de §0, que no estaba.


## 12. Cómo se ejecuta esta fase

**Una sesión principal, secuencial, en `mcode`.** El nivel se cambia **por
sub-tarea** con `/model` (verificado: `/model` cambia modelo **y** effort, y
`/status` muestra el par). El modelo no puede cambiar su propio effort a mitad de
respuesta: el ajuste es **entre turnos**, y por eso la unidad es la sub-tarea.

### El ciclo

```bash
# 1. en main, actualizado
git checkout main && git fetch origin && git pull --ff-only origin main

# 2. rama de la fase  (CON GUION, nunca barra)
git checkout -b f10-rag

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    cambiando el nivel con /model en cada frontera

# 4. verificar las 4 capas (abajo)

# 5. publicar
git push -u origin f10-rag

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    HANDOFF.md §2 con números MEDIDOS · CHANGELOG.md · el tag
```

Un worktree por sesión, un `_build` por carril.

### El nivel, sub-tarea por sub-tarea

| Sub-tarea | Nivel | Verificación |
|---|---|---|
| Puerta: decidir el diseño (A2) | `PARA` | Decisión del dueño. Sin esto no arranca la fase |
| 3.1 RRF (k=60, combina ranks) | `max` | L3: 1º en ambas listas gana a 1º+5º |
| 3.2 Chunker `:sentence` no parte frase | `max` | L3: solapamiento verificable **por contenido** |
| 3.3 Camino léxico se degrada solo | `high` | L3: sin embeddings, la búsqueda sigue |
| 3.4 Sin embedder: error con nombre | `medium` | L3: `{:error, :no_embedder}` NOMBRA el modelo |
| 3.5 El `Embedder` sobre `embed/3` | `medium` | L3: cableado |
| 3.6 Reranking opt-in y degradado | `medium` | L3: reranker caído → resultado sin rerank |
| Revisión de la fase (sesión aparte) | `max` | L4: la query real devuelve la ruta con línea |

**Y al final, siempre:** una sesión de revisión aparte, a `max`, leyendo el PR
**sin el diff del autor**. Es la única tarea del plan donde el nivel base es el
máximo, porque es la única donde el agente no puede estar calibrado por haber
escrito el módulo.

### Las 4 capas, en cada sub-tarea

| Capa | Qué | Obligatoria |
|---|---|---|
| **L1** | `mix format --check-formatted` + `mix compile --force --warnings-as-errors` | siempre |
| **L2** | `mix credo --strict` + `mix dialyzer` | si toca código compartido |
| **L3** | `CANDIL_DATA_DIR=$(mktemp -d) mix test <ruta>/` con el caso nombrado | siempre |
| **L4** | un comando con salida observable, **y qué NO puede ocurrir** | si es visible para el usuario |

La **aserción negativa** es la que importa: un criterio que solo dice "responde"
pasa con un `[]` de respuesta.

### Si se bloqueas

**PARA.** No improvises una decisión de diseño: están todas escritas. Anótala en
`deliverable.md` y sigue con la siguiente sub-tarea que no dependa de eso.

**Y si un criterio no se ejecutó porque el entorno no lo permite, dilo.** Escribe
*"criterio ejecutado: unitario, no integración"*. Un `deliverable.md` que dice
"criterio ejecutado" cuando se ejecutó la mitad es una mentira, y la siguiente
sesión la da por buena.
