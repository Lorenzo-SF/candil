# Fase 10 — RAG


> **Para probar esta fase**: [`../PRUEBAS-MANUALES.md`](../PRUEBAS-MANUALES.md) — comandos, comportamiento esperado y el script `scripts/manual-check.sh`.

> Estado: **pendiente**. Depende de la 8. Carril G.
> Original: `../original/candil-4.0-final.md` §22 y la Fase 10.
> Effort: 7 d. **La más larga de la ruta crítica.**

## Qué es

Búsqueda sobre la documentación y el código, con SQLite FTS5. `RAG.retrieve/2`
devuelve fragmentos con sus rutas de fichero, para que el LLM pueda citar.

## Por qué aquí y no antes

Es la fase más larga del plan, y por eso va **la última de la ruta crítica**.
Además depende de la 8 para poder medir qué fragmento se usó de verdad, y de la
9 para que un LLM pueda llamarla como herramienta.

Nada de lo anterior la necesita. Adelantarla solo pone a dos carriles a tocar
el mismo código.

## Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/rag.ex` y `lib/candil/rag/**` |
| Tests | `test/candil/rag/**` |
| Ya existe | `RAG` **solo**, como módulo vacío |
| **Hay que crearlos** | `RAG.Chunk`, `RAG.Store`, `RAG.Embedder`, `RAG.Hybrid`, `RAG.Ranker` — **no existen**. Es la fase más grande de todo lo que queda |

**Carril G.** No toques `gateway/**`, `mcp/**` ni `router/**`.

## Qué hay que hacer

1. **Chunking por función**, no por tamaño fijo. El diseño es explícito: un
   fragmento que parte una función por la mitad es inútil para citar.
2. **FTS5** para el camino sin embeddings. **Se degrada solo**: sin modelo de
   embeddings, la búsqueda léxica sigue funcionando.
3. **Embeddings** como segundo camino, y **`RAG.Hybrid` combina ambos con
   RRF** (reciprocal rank fusion), no con una suma de scores. Las dos escalas
   no son comparables.
4. **Reranking** opcional, y si falla, la búsqueda sin rerank sigue
   funcionando.
5. **Cachear embeddings** por hash del texto. Sin eso, cada indexado vuelve a
   pagar el modelo.

## Cómo se comprueba

```bash
mix test test/candil/rag/
#   - chunking: una función no se parte en dos fragmentos
#   - FTS5 sin embeddings: busca y encuentra
#   - sin modelo de embeddings, el camino léxico sigue
#   - RRF combina los dos runs en un orden estable
#   - reranker caído → el resultado sin rerank
#   - cache: el mismo texto no se re-embeddea
```

El primer caso —que una función no se parte— es el que más se olvida y el más
caro: un chunking por tamaño produce fragmentos que parecen razonables y no
sirven.

## Por qué NO

- **No LanceDB ni Qdrant ni nada externo.** SQLite FTS5 va en el propio binario.
  Un RAG que necesita un servicio más no se despliega.
- **No reranking por defecto.** Es una llamada a un LLM por consulta, y la
  mayoría de las veces no compensa.
- **No `embedding_provider: "ollama"` por defecto.** El sandbox y la máquina
  del usuario no lo tienen; el default es la API.
- **No tocar `mix.exs`** desde este carril. Lo pide el PR.

## Definición de done

- [ ] `mix test test/candil/rag/` en verde, los seis casos
- [ ] Una búsqueda de verdad devuelve fragmentos con ruta de fichero
- [ ] El camino léxico funciona sin modelo de embeddings
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de 702
- [ ] `CHANGELOG.md` y `HANDOFF.md` al día
- [ ] PR contra `4.0`, CI verde
- [ ] **cerrado a `main`**: sync `main` → `4.0` y PR `4.0` → `main`

## La rama

```
git fetch origin
# antes: sincroniza, para que 4.0 no se vaya atrasando de main
# git checkout 4.0 && git merge origin/main && git push origin 4.0
git checkout -b 4.0-f10-rag origin/4.0
```

## Nota operativa

⚠ Misma advertencia que la 9: 7 días de trabajo no entran en una ventana de
30 minutos con equipos. Trocear o hacer secuencial. Este documento sustituye al
`PROMPT-VENTANA-PARALELA.md`, que ya no aplica.
