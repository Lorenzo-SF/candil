# Fases 5, 9 y 10 — planes de ejecución paralela

> Documento de trabajo para `main`/`4.0`. No es un contrato: es la ruta más
> corta desde donde estamos. Los criterios de aceptación son del documento de
> diseño y no se negocian; el reparto en carriles sí es una decisión operativa.

## Dónde estamos

```
4.0   e49940e  fases −1, −0, 0, 1 y 2 mergeadas
4.0-f3-cli     fase 3 abierta (PR #25), 8/8 gates en local
```

**Fases −1 a 3 hechas.** Las tres de este documento no dependen de la 4.

## Por qué estas tres y no otras

El grafo del §4 del `PLAN-PARALELO.md` pone F5, F9 y F10 fuera de la ruta
crítica, y dice por qué:

- **F9 (MCP)** depende de `Candil.Tool`, que existe desde 3.0 y no lo toca
  nadie de aquí.
- **F10 (RAG)** depende de `Candil.embed/3`, que existe desde 3.0.
- **F5 (Doctor)** depende de `Store`, `Source`, `Build` y `EnginePool` — todo
  carril A, todo listo tras F2. **No necesita la CLI**, y por eso es el más
  independiente de los tres.

Ninguna toca un struct de contrato. Las tres pueden correr a la vez.

## Reparto de carriles

| Fase | Carril | Ficheros exclusivos |
|---|---|---|
| **5** | A (núcleo) | `doctor.ex` + `test/candil/doctor/**` |
| **9** | F (MCP) | `mcp.ex` `mcp/**` + `test/candil/mcp/**` |
| **10** | G (RAG) | `rag.ex` `rag/**` + `test/candil/rag/**` |

Los tres son disjuntos. **El único fichero compartido que tocan es
`mix.exs`**, y solo para `groups_for_modules`, que es del carril H. Las tres
ramas abren su PR pidiendo esa línea y H la aplica una vez.

### Por qué esto no es solo Theoretical

`Candil.MCP` y `Candil.RAG` **ya existen** con sus structs, `@type` y `@spec`
congelados en la fase −1, y sus ocho funciones devuelven
`{:error, %Candil.Error{reason: :not_implemented}}`. El trabajo es ponerles
cuerpo, no diseñarlos. Por eso pueden ir los tres a la vez: no hay nada que
decidir primero.

---

## Fase 5 — Doctor (3 d)

**Objetivo**: `candil doctor` que dice qué está mal y qué hacer.

### 5.1 Los checks (§17)

Siete, en este orden, y cada uno con su mensaje:

```
✓ config     válido · 11 modelos · 1 engine · 1 provider
✓ binario    llama_cpp → ~/.candil/llm/bin/llama-server
✓ sources    9/11 descargados  (faltan qwenvision, deepcoder)
✓ puertos    :9990 :9998 :9999 :10000-10099 libres
✓ auth       llama_cpp: api_key_env=LLAMA_API_KEY (seteado ✓)
✓ gpu        CUDA 12.8 · 15.2/16.0 GB VRAM libre
✓ memoria    41.3 GB libres
```

- **Botica** para lo genérico (memoria, disco). `Botica.Doctor.fix/1` para lo
  que sepa arreglar. Es la interacción correcta: cada uno en su dominio.
- `doctor --fix` arregla lo que puede y **lista lo que no con el comando
  exacto**. Un check que sabe lo que está mal y no dice cómo arreglarlo es la
  mitad del trabajo.
- Sin `Config.Hydrate` el check de `config` no ve nada: la fase 3 lo escribió y
  la 5 lo necesita.

### 5.2 Limpieza de deuda (1 d)

- `Cost` con precios de 2024 → fichero de datos, `@deprecated` en la tabla
  embebida. Los locales valen `0.0`.
- El moduledoc de `Application` dice `{:arrea, "~> 2.1.0"}` y arrea está en
  3.0.0. Corregir.
- Quitar los TODOs y los `Process.sleep` fuera de health polling.
- **No** se borra `Batteries.LlamaServer` de botica. Está fuera de su dominio y
  su sitio es aquí, pero borrar cosas del repo de otro es cosa del dueño.

### Criterio de aceptación

```bash
$ ./candil doctor              # 0 errores, y cada advertencia dice qué hacer
$ ./candil doctor --fix        # arregla lo que puede, lista lo que no
```

---

## Fase 9 — MCP (4 d)

**Objetivo**: servidor y cliente en la revisión `2025-11-25`.

### Lo que casi se hace mal

La revisión es **`2025-11-25`**, y los tres documentos previos del repo usaban
`"2024-11-05"`. Tres consecuencias concretas:

1. **Handshake `initialize` obligatorio** antes que nada. El cliente manda la
   revisión que soporta; el servidor responde con la suya.
2. **`MCP-Protocol-Version` en todas las peticiones HTTP posteriores.** Si
   falta, se asume `2025-03-26` por retrocompatibilidad. Si trae una no
   soportada, `400`.
3. **Sin JSON-RPC batching**, que se eliminó en `2025-06-18`. Una petición por
   mensaje. Un array de requests es un error, no algo que se procese.

### Transports

| Transport | Para | Notas |
|---|---|---|
| `stdio` | que opencode lo lance como subprocess | el shim por defecto |
| `http` | compartido y clientes remotos | header de versión obligatorio |

### API (ya congelada en `mcp.ex`, solo falta el cuerpo)

```elixir
Candil.MCP.version/0            # "2025-11-25"
Candil.MCP.supported?/1
Candil.MCP.serve/1              # transport: :stdio | :http, port, tools
Candil.MCP.connect/1
Candil.MCP.list_tools/1
Candil.MCP.call_tool/3
Candil.MCP.disconnect/1
```

### Criterio de aceptación

```bash
mix test test/candil/mcp/
#   initialize con cada revisión soportada
#   initialize con una no soportada → responde la del servidor
#   HTTP sin MCP-Protocol-Version → asume 2025-03-26 y funciona
#   HTTP con versión inválida → 400
#   batching (array de requests) → error
#   tools/list lista lo registrado
#   un tool que lanza → error -32603, no tumba el servidor

echo '{"jsonrpc":"2.0","id":1,"method":"initialize", ...}' | ./candil mcp serve --transport stdio
./candil mcp serve --transport http --port 7778
```

---

## Fase 10 — RAG (5 d)

**Objetivo**: chunking, índice, retrieval híbrido, rerank opcional.

### Modelo

```
Docs → Chunker(sentence·paragraph·fixed) → Chunk{id,text,embedding,metadata,position}
     → Embedder(Candil.embed/3) → Index(memory default · postgres opt-in)
Query → Embedder → Retrieval(BM25 + vector + RRF) → Rerank(opt-in) → top_k
```

### API (congelada en `rag.ex` y `rag/chunk.ex`)

```elixir
Candil.RAG.create_index/2  drop_index/1  list_indexes/0
Candil.RAG.index/3         search/3      embedder/1
Candil.RAG.Chunk           # id, text, embedding, metadata, position, score, document_id
```

### Lo que hay que acertar

- **RRF (Reciprocal Rank Fusion)**: 1º en ambas listas gana a 1º en una y 5º
  en la otra. Es la razón de ser del retrieval híbrido, y es un número, no una
  opinión.
- **Sin embedder** → `{:error, :no_embedder}` **con el nombre del que falta**.
- El chunker `:sentence` **no parte una frase** por la mitad. El solapamiento
  tiene que ser verificable, no declarativo.

### Criterio de aceptación

```bash
mix test test/candil/rag/
#   chunker: 10k tokens → ~20 chunks de 512, solapamiento verificable
#   chunker: :sentence no parte una frase
#   retrieval: palabra exacta sale primero vía BM25
#   retrieval: semánticamente cercano sale primero vía vector
#   RRF: 1º en ambas listas gana a 1º en una y 5º en la otra
#   sin embedder → {:error, :no_embedder} con el nombre del que falta

$ ./candil rag index vault --path ~/lasaca/PENDIENTE
$ ./candil rag query vault "dónde está la decisión sobre el daemon"
```

---

## Los ocho gates, y la referencia

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

Referencia medida en `4.0` con las fases 0, 1 y 2: **8/8, 623 tests + 25
doctests, 0 fallos, 66.8 %**. Con la fase 3: **663 tests + 26 doctests, 64.9 %**.
La cobertura baja un poco al añadir CLI, que es sobre todo presentación; los
tests suben. **Si el número de tests baja respecto a la base, el conflicto se
resolvió mal.**

## Ramas

```
F5:  4.0-f5-doctor   → PR contra 4.0
F9:  4.0-f9-mcp      → PR contra 4.0
F10: 4.0-f10-rag     → PR contra 4.0
```

⚠ **La barra del guion no puede ir con guion.** `refs/heads/4.0` y
`refs/heads/4.0/f5-doctor` no pueden coexistir. El plan dice `4.0/f5-doctor` y
es imposible: se llaman `4.0-f5-doctor`, `4.0-f9-mcp`, `4.0-f10-rag`.

`main` **no se toca**. Todo el trabajo va contra `4.0`.

## Merge

Las tres son independientes y cada PR se mergea cuando su CI esté verde, en
cualquier orden. La única coordinación es `groups_for_modules`, y va una sola
vez al final, por el carril H.

## Lo que este documento no resuelve

- **Los tests de un carril los escribe otro agente.** El plan lo dice y tiene
  razón: un agente que escribe el módulo y sus tests escribe tests que pasan.
  Si son tres agentes en paralelo, cada PR debería traer un revisor que solo
  lea el módulo como usuario.
- **El CI hay que mirarlo antes de mergear.** En este repo se mergeó un PR con
  un job en rojo porque nadie miró, y hubo que abrir otro para arreglarlo.
