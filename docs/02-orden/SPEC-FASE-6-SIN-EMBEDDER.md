# Spec de tarea: Fase 6 (RAG) sin embedder — léxica, RRF cableado, ids estables, chunker alineado, Store.reset

## Stack y versiones (literal)
- Elixir 1.19, OTP 28
- Repo: `/home/lorenzo/workspace/github/zaguan/candil`
- Branch de trabajo: `docs/carril-0-contrato-y-plan` (base `main` `92bb062`)
- Sin dependencias nuevas: no `exqlite`, no SQLite, no LanceDB.

## Contexto del proyecto
- `Candil.RAG` ya tiene índice en ETS, búsqueda vectorial, rewrite y rerank opcionales (`lib/candil/rag.ex:78-260`).
- `Candil.RAG.rrf/2` existe y está probado (`rag.ex:341-359`), pero `search/3` no lo llama.
- `Candil.RAG.Chunker` existe, pero su contrato no coincide con el plan: devuelve una lista en éxito (`chunker.ex:113`), el callback es `chunk/2 :: [Chunk.t()]` (`:54`), expone `default_strategy/0` (`:170`) y los ids son `"doc:0"` (`:140`).
- `Candil.RAG.Store` no expone `reset/0`.
- No existe `lib/candil/rag/lexical.ex`, `hybrid.ex`, `embedder.ex` ni `watcher.ex`.
- `config/schema.ex` no tiene la sección `rag` (`@sections ~w(general engine model provider consumer)`).

## Archivos existentes a REUTILIZAR (no reimplementar)
- `lib/candil/rag.ex:78-89` — `create_index/2`, delega en `Store`.
- `lib/candil/rag.ex:91-120` — `index/3` y `do_index/4`; ya chunkea y enriquece.
- `lib/candil/rag.ex:144-196` — `search/3` y `rank_chunks/4`; aquí se cablea RRF.
- `lib/candil/rag.ex:341-359` — `rrf/2`, reutilizar sin reescribir.
- `lib/candil/rag.ex:375-393` — `cosine/2`.
- `lib/candil/rag/chunker.ex:111-128` — `chunk/2`, a alinear.
- `lib/candil/rag/chunker.ex:130-146` — `do_chunk/4`, donde se generan los ids.
- `lib/candil/rag/store.ex:89-104` — `put_chunks/2` y `get_chunks/1`.
- `lib/candil/config/schema.ex:16` — `@sections`.
- `lib/candil/config/template.ex` — esqueleto comentado.
- `test/candil/rag/chunker_test.exs` — tests del chunker, a actualizar al contrato nuevo.
- `test/candil/rag_test.exs` — RRF, coseno y embedder; no se tocan salvo llamadas al chunker.

## Cambios concretos

1. `lib/candil/rag/lexical.ex` — nuevo módulo `Candil.RAG.Lexical`:
   - `@spec rank([Candil.RAG.Chunk.t()], binary()) :: [{binary(), float()}]`
   - tokeniza consulta y texto con `String.downcase/1` y `String.split/2` sobre `~r/[^[:alnum:]]+/u`;
   - puntúa cada chunk por solape de tokens, normalizado por el número de tokens de la consulta;
   - devuelve solo chunks con puntuación `> 0.0`, ordenados por puntuación descendente y `id` como desempate;
   - si no hay solape, devuelve `[]`.

2. `lib/candil/rag.ex` — `index/3`:
   - generar chunks con el contrato nuevo (`{:ok, chunks}` o `{:error, reason}`);
   - tras `put_chunks/2`, borrar los chunks del índice cuyo id no esté en el conjunto nuevo;
   - para ello añadir `Store.replace_chunks/2` o `Store.delete_missing_chunks/2` (ver punto 4).

3. `lib/candil/rag.ex` — `search/3` / `rank_chunks/4`:
   - calcular `vector_ranking` solo si hay embeddings en los chunks y se puede resolver un embedding de consulta;
   - calcular `lexical_ranking` con `Candil.RAG.Lexical.rank/2`;
   - si ambas listas no están vacías, fusionar con `rrf([vector_ranking, lexical_ranking])`, mapear ids a chunks y asignar `score`;
   - si solo hay una, usar esa lista;
   - si ninguna, devolver `{:ok, []}` (no `{:error, :no_embedder}`: la léxica siempre está disponible);
   - mantener rewrite y rerank opcionales como están (`rag.ex:158-196`).

4. `lib/candil/rag/store.ex`:
   - añadir `@spec reset() :: :ok` que borra todas las filas de `:candil_rag_indexes` y `:candil_rag_chunks`;
   - añadir `@spec delete_missing_chunks(index_name(), [binary()]) :: :ok` (o `replace_chunks/2`) para el borrado de stale chunks.

5. `lib/candil/rag/chunker.ex` — alinear contrato:
   - `chunk/2` devuelve `{:ok, [Chunk.t()]}` en éxito y `{:error, term()}` en fallo (incluido `{:error, {:unknown_strategy, strategy}}`);
   - texto vacío devuelve `{:ok, []}`;
   - renombrar `default_strategy/0` a `strategy/0` (mantener `default_strategy/0` como delegado temporal si se quiere compatibilidad, pero el nombre canónico es `strategy/0`);
   - ids estables: `id = Base.encode16(:crypto.hash(:sha256, "#{document_id}:#{position}:#{text}"), case: :lower)` truncado a 16 caracteres, o equivalente estable;
   - actualizar doctests (`chunker.ex:104-109`) al nuevo retorno.

6. `lib/candil/config/schema.ex`:
   - `@sections ~w(general engine model provider consumer rag)`.

7. `lib/candil/config/template.ex`:
   - añadir una sección comentada `[rag]` con `embedder = ""` y `strategy = "sentence"`, para que el test de secciones pase y el usuario sepa que existe.

8. Tests:
   - actualizar `test/candil/rag/chunker_test.exs` a `{:ok, chunks}`;
   - actualizar `test/candil/rag/real_test.exs` y `test/candil/rag_test.exs` si llaman a `Chunker.chunk/2` directamente;
   - añadir `test/candil/rag/lexical_test.exs` con casos de solape, sin solape y vacío;
   - añadir test de `Store.reset/0` en `test/candil/rag/store_test.exs` si existe, o en `rag_test.exs`.

## Constraints duros (NO violar)
- NO añadir dependencias nuevas.
- NO tocar MCP, router, policy ni refusal.
- NO implementar embedder, watcher ni incremental completo: solo ids estables y borrado de stale chunks en `index/3`.
- NO cambiar `Candil.RAG.Chunk` ni su `@type t`.
- Mantener `rrf/2` y `cosine/2` sin cambios.
- Mantener compatibilidad de `Candil.RAG` pública: `create_index/2`, `index/3`, `search/3`, `drop_index/1`, `list_indexes/0`, `embedder/1`.

## Convenciones del repo
- Conventional Commits.
- `@spec` + `@doc` en funciones públicas.
- Cambios pequeños y reversibles.

## Verificación esperada
```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/candil/rag/chunker_test.exs test/candil/rag/lexical_test.exs test/candil/rag_test.exs test/candil/config/template_test.exs
mix dialyzer
```

## Acceptance criteria
- [ ] `Candil.RAG.Chunker.chunk/2` devuelve `{:ok, [Chunk.t()]}` en éxito y `{:error, term()}` en fallo.
- [ ] `Candil.RAG.Chunker.strategy/0` devuelve `:sentence`.
- [ ] Los ids de chunk son estables para el mismo `(document_id, position, text)`.
- [ ] `Candil.RAG.Store.reset/0` existe y limpia ambas tablas.
- [ ] `Candil.RAG.Lexical.rank/2` devuelve resultados por solape y `[]` sin solape.
- [ ] `Candil.RAG.search/3` usa `rrf/2` cuando hay vectorial y léxica.
- [ ] `Candil.RAG.search/3` funciona sin embeddings usando solo léxica.
- [ ] `Candil.Config.Schema.sections/0` incluye `"rag"`.
- [ ] El template menciona `[rag`.
- [ ] `mix test` pasa con 0 fallos en los tests tocados.

## Lo que NO debe hacer el ejecutor
- NO implementar el embedder ni la caché por hash.
- NO implementar el watcher ni Trebejo.
- NO tocar `lib/candil/mcp/*`.
- NO cambiar la firma pública de `Candil.RAG` salvo el retorno del chunker, que es el objetivo del spec.

## Lo que NO deben hacer qa y reviewer
- NO suavizar fallos.
- NO modificar código de producción.
- `qa` debe marcar cada AC con ✅/❌/⚠️ y justificar.
- `reviewer` debe reportar findings con severidad, ruta/línea, impacto y corrección concreta.
