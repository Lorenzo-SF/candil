# Prompts de traspaso — Fases 5, 9 y 10

Tres planes, tres sesiones. Copia el bloque que corresponda entero en la sesión
nueva. Están pensados para **correrse en paralelo**: los carriles no se tocan.

---

## Fase 5 — Doctor

```text
Estoy implementando Candil 4.0. Las fases -1, 0, 1 y 2 estan mergeadas en la
rama 4.0; la 3 (la CLI) esta en el PR #25. Tu tarea es la FASE 5: `candil
doctor`.

════════════════════════════════════════════════════════════════════════
1. ENTORNO
════════════════════════════════════════════════════════════════════════

Repositorio: https://github.com/Lorenzo-SF/candil
Rama:        4.0-f5-doctor   (creala desde origin/4.0)
PR:          contra 4.0, NUNCA contra main
Toolchain:   Erlang/OTP 28.5.0.7 · Elixir 1.19.5-otp-28

    git clone https://github.com/Lorenzo-SF/candil.git && cd candil
    git checkout 4.0 && git pull && git checkout -b 4.0-f5-doctor
    mix deps.get && mix compile

En sandbox efimero: bash /workspace/tools/setup.sh  (reconstruye Hex, deps y
compilacion). El mirror de Hex tiene que correr como tarea de background, o
`mix deps.get` falla con econnrefused al 127.0.0.1:4000.

⚠ La rama NO puede llamarse `4.0/f5-doctor`. `refs/heads/4.0` y
`refs/heads/4.0/f5-doctor` no pueden coexistir. El guion es obligatorio.

════════════════════════════════════════════════════════════════════════
2. LEE ESTO
════════════════════════════════════════════════════════════════════════

  (a) `proyecto 4.0/PLAN-F5-F9-F10.md`             <- la seccion de la fase 5
  (b) `proyecto 4.0/HANDOFF.md` §2 y §3            <- que hay y que sigue
  (c) `proyecto 4.0/candil-4.0-final.md`
        · Seccion 17 (linea ~1419)  Candil.Doctor, la salida exacta
        · Fase 5    (linea ~2552)  el bloque entero, con la limpieza de deuda
      NO leas el documento entero. Son 3.000 lineas.

════════════════════════════════════════════════════════════════════════
3. QUE HAY YA - NO LO REPITAS
════════════════════════════════════════════════════════════════════════

  · Candil.Store            con la validacion en la entrada
  · Candil.Config.File      load/1, save/2, expand/1 — el TOML se lee y se
                             escribe. Ya NO es un stub.
  · Candil.Config.Hydrate   el puente TOML -> Store, de la fase 3. Sin el, el
                             check de `config` de doctor no ve nada.
  · Candil.Source           fetch/2 con Range, checksum en streaming y
                             progress/1. Ya NO es un stub.
  · Candil.Build            install/2 con las dos estrategias, check/1
  · Candil.EnginePool       registro de instancias, claim_port/2
  · Candil.Engine           con api_key/1, auth_headers/1,
                             base_url_and_headers/2 (H1, fase 0)
  · botica                  ya es dependencia: usala para memoria y disco

Tests: test/candil/config/hydrate_test.exs, test/candil/build/**,
test/candil/engine_pool_test.exs

════════════════════════════════════════════════════════════════════════
4. QUE TIENES QUE HACER
════════════════════════════════════════════════════════════════════════

▓▓▓ 4.1  Candil.Doctor  (2 d)  ▓▓▓

Los siete checks de la seccion 17, en ese orden, cada uno con su mensaje:

  config     valido · N modelos · N engines · N providers
  binario    llama_cpp -> ruta, y si existe
  sources    N/M descargados, y CUALES faltan por nombre
  puertos    los del rango, libres o no
  auth       api_key_env=... y si la variable esta puesta de verdad
  gpu        CUDA/ROCm version y VRAM
  memoria    ← de Botica, no lo reescribas

Reglas que no son negociables:

  · `doctor --fix` delega en `Botica.Doctor.fix/1` para lo que botica sepa
    arreglar. Para el resto **dice el comando exacto**. Un check que sabe lo
    que esta mal y no dice como arreglarlo es la mitad del trabajo.
  · Cada check devuelve `:ok | :warning | :error` con un mensaje accionable.
    "engine failed" no es accionable. "llama-server no esta en
    /root/.candil/llm/bin; ejecuta candil engine install" si.
  · Los checks genéricos van a botica. Los de LLM, aqui. Es la interaccion
    correcta: cada uno en su dominio.

API congelada, respectala:

    doctor()            :: {:ok, report} | {:error, term}
    doctor(opts)        :: opts: fix?: boolean
    report              :: %{checks: [...], errors: n, warnings: n}

▓▓▓ 4.2  Limpieza de deuda  (1 d)  ▓▓▓

  · `Cost` con precios de 2024 -> fichero de datos, `@deprecated` en la tabla
    embebida. Los locales valen 0.0.
  · El moduledoc de `Application` dice `{:arrea, "~> 2.1.0"}` y arrea esta en
    3.0.0. Corregir.
  · Quitar los TODOs y los `Process.sleep` fuera de health polling.
  · **NO** borres `Batteries.LlamaServer` del repo de botica. Esta fuera de su
    dominio y su sitio es aqui, pero borrar cosas del repo de otro es del
    dueno. Dejalo anotado.

▓▓▓ 4.3  `./candil doctor`  ▓▓▓

El comando va en el carril de la CLI (`lib/candil/cli/**`). La fase 3 ya
tiene el esqueleto; anade `doctor` a su tabla de comandos. Si el carril de la
CLI esta ocupado por el PR #25, **para y pregunta** en vez de tocarlo.

▓▓▓ 4.4  Tests  ▓▓▓

  test/candil/doctor_test.exs
    · cada check con un :ok, un :warning y un :error
    · cada warning nombra el comando que lo arregla
    · --fix arregla lo que puede y lista lo que no
    · un check que lanza no tumba el doctor entero: sale :error, no crash
    · la salida de `--json` es una lista, no un objeto

════════════════════════════════════════════════════════════════════════
5. LOS OCHO GATES
════════════════════════════════════════════════════════════════════════

    mix format --check-formatted
    mix compile --force --warnings-as-errors
    mix credo --strict --format=oneline
    mix test --cover
    mix dialyzer
    mix docs --warnings-as-errors
    mix hex.audit
    mix deps.unlock --check-unused

Referencia en 4.0: 8/8, 623 tests + 25 doctests, 0 fallos, 66.8 %. Con la
fase 3 mergeada seran mas. **Si el numero de tests baja, algo esta mal.**

Un stub que hace `raise` es `none()` para dialyzer. Si escribes uno, devuelve
`{:error, %Candil.Error{reason: :not_implemented}}`, que cumple su @spec.

════════════════════════════════════════════════════════════════════════
6. GIT
════════════════════════════════════════════════════════════════════════

Rama:      4.0-f5-doctor
PR:        contra 4.0, nunca contra main
Commits:   export GIT_AUTHOR_DATE="YYYY-MM-DDTHH:MM:SS+02:00"
           export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
           Fecha entre 20:00 y 02:00 Europe/Berlin, de lunes a viernes.
Tag:       candil-4.0.0-alpha.3 al mergear

Documentos, en el mismo commit que el cambio: CHANGELOG.md con los nombres de
funcion reales, y el moduledoc de lo que toques.

`groups_for_modules` en mix.exs necesita `Candil.Doctor`: dejalo apuntado en
el PR y lo aplica el carril H. **No toques mix.exs.**

════════════════════════════════════════════════════════════════════════
7. LO QUE NO VAS A HACER
════════════════════════════════════════════════════════════════════════

· No toques mcp.ex, rag.ex ni sus submodulos. Son las fases 9 y 10, y se
  estan haciendo en paralelo ahora mismo.
· No toques ficheros del carril A fuera de doctor.ex: model.ex, engine.ex,
  engine_pool.ex, build.ex, source.ex, store.ex, config/**.
· No toques mix.exs.
· No anadas flags de cmake, ni cambies la estrategia de instalacion.
· No uses String.to_atom/1 con nada que venga de fuera. La unica excepcion
  documentada esta en Config.Hydrate, y es deliberada.
· No hagas git push --force.
· No borres nada del repo de botica.

════════════════════════════════════════════════════════════════════════
8. AL TERMINAR
════════════════════════════════════════════════════════════════════════

Actualiza HANDOFF.md §2 (que se hizo) con numeros medidos del output real de
los comandos. Commit, push, PR, y avisame con los ocho gates.

MIRA EL CI DEL PR ANTES DE PEDIR EL MERGE. En este repo se mergeo un PR con un
job en rojo porque nadie miro.

Si te bloqueas en algo, PARA y pregunta. No improvises una decision de
diseno: estan todas escritas, y si ninguna encaja, eso es informacion que
necesito.
```

---

## Fase 9 — MCP

```text
Estoy implementando Candil 4.0. Las fases -1, 0, 1 y 2 estan mergeadas en la
rama 4.0; la 3 (la CLI) esta en el PR #25. Tu tarea es la FASE 9: MCP, servidor
y cliente en la revision 2025-11-25.

════════════════════════════════════════════════════════════════════════
1. ENTORNO
════════════════════════════════════════════════════════════════════════

Repositorio: https://github.com/Lorenzo-SF/candil
Rama:        4.0-f9-mcp      (creala desde origin/4.0)
PR:          contra 4.0, NUNCA contra main
Toolchain:   Erlang/OTP 28.5.0.7 · Elixir 1.19.5-otp-28

    git clone https://github.com/Lorenzo-SF/candil.git && cd candil
    git checkout 4.0 && git pull && git checkout -b 4.0-f9-mcp
    mix deps.get && mix compile

En sandbox efimero: bash /workspace/tools/setup.sh
⚠ La rama NO puede llamarse `4.0/f9-mcp`. El guion es obligatorio.

⚠ ESTA FASE CORRE EN PARALELO CON LAS FASES 5 Y 10. Los carriles son
disjuntos. NO toques doctor.ex, rag.ex ni sus tests. Si te sale un conflicto en
esos ficheros, es que estas en la rama equivocada.

════════════════════════════════════════════════════════════════════════
2. LEE ESTO
════════════════════════════════════════════════════════════════════════

  (a) `proyecto 4.0/PLAN-F5-F9-F10.md`             <- la seccion de la fase 9
  (b) `proyecto 4.0/candil-4.0-final.md`
        · Seccion 21 (linea ~2676)  MCP entero: revision, transports, API
        · Fase 9    (linea ~2676)  el bloque con los siete tests
      NO leas el documento entero.

════════════════════════════════════════════════════════════════════════
3. QUE HAY YA - NO LO REPITAS
════════════════════════════════════════════════════════════════════════

`Candil.MCP` y `Candil.MCP.Protocol` **ya existen** con el struct, los `@type`
y los `@spec` congelados en la fase -1. Lo que hay que hacer es ponerles
cuerpo:

    Candil.MCP.serve/1        -> {:error, %Error{reason: :not_implemented}}
    Candil.MCP.connect/1      ->idem

Ademas ya existen y **no los toques**:
  · `Candil.Tool`             el registro de tools, existe desde 3.0
  · `Candil.MCP.Protocol`     los structs de laRevision, congelados

════════════════════════════════════════════════════════════════════════
4. QUE TIENES QUE HACER
════════════════════════════════════════════════════════════════════════

▓▓▓ 4.1  La revision del protocolo  (C21)  ▓▓▓

La revision es **2025-11-25**, en la era de *handshake*. Los tres documentos
previos de este repo usaban "2024-11-05": dos generaciones de retraso. Tres
cosas concretas que un servidor DEBE cumplir:

  1. **Handshake `initialize` obligatorio** antes que nada. El cliente manda
     la revision que soporta; el servidor responde con la suya. Si el cliente
     pide una que no conoces, respondes con la tuya, no con un error.
  2. **`MCP-Protocol-Version` en TODAS las peticiones HTTP posteriores.**
     Si falta, se asume `2025-03-26` por retrocompatibilidad y funciona.
     Si trae una version no soportada, **400**.
  3. **Sin JSON-RPC batching**, que se elimino en `2025-06-18`. Una peticion
     por mensaje. Un array de requests es un **error**, no algo que se procese
     request a request.

    @supported_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

▓▓▓ 4.2  Los dos transports  ▓▓▓

    stdio  el shim por defecto: opencode lo lanza como subprocess
    http   compartido y clientes remotos, con el header obligatorio

▓▓▓ 4.3  Un tool que lanza NO tumba el servidor  ▓▓▓

Es el test mas importante de la fase, y el mas facil de perder. Un tool que
lanza una excepcion tiene que producir **error -32603** en la respuesta de esa
peticion, y el servidor sigue escuchando. Si el tool tumba el proceso, un
cliente con una tool rocosa se queda sin servidor y no sabe por que.

▓▓▓ 4.4  `./candil mcp serve`  ▓▓▓

Va en el carril de la CLI (`lib/candil/cli/**`). La fase 3 tiene el esqueleto.
Si ese carril esta ocupado por el PR #25, **para y pregunta**.

════════════════════════════════════════════════════════════════════════
5. CRITERIO DE ACEPTACION
════════════════════════════════════════════════════════════════════════

    mix test test/candil/mcp/
    #   initialize con cada revision soportada
    #   initialize con una no soportada → responde la del servidor
    #   HTTP sin MCP-Protocol-Version → asume 2025-03-26 y funciona
    #   HTTP con version invalida → 400
    #   batching (array de requests) → error
    #   tools/list lista lo registrado
    #   un tool que lanza → error -32603, no tumba el servidor

    echo '{"jsonrpc":"2.0","id":1,"method":"initialize",
           "params":{"protocolVersion":"2025-11-25","capabilities":{},
                     "clientInfo":{"name":"test","version":"1"}}}' \
      | ./candil mcp serve --transport stdio

    ./candil mcp serve --transport http --port 7778 &
    curl -X POST localhost:7778/mcp -H 'MCP-Protocol-Version: 2025-11-25' \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

Un PR cuyo criterio de aceptacion no se ejecuto no entra.

Mas los ocho gates. Referencia: 8/8, 623 tests + 25 doctests, 0 fallos, 66.8 %.

════════════════════════════════════════════════════════════════════════
6. GIT
════════════════════════════════════════════════════════════════════════

Rama:      4.0-f9-mcp
PR:        contra 4.0, nunca contra main
Commits:   fecha entre 20:00 y 02:00 Europe/Berlin, de lunes a viernes
Tag:       candil-4.0.0-rc.1 al mergear

`groups_for_modules` necesita `Candil.MCP` y `Candil.MCP.Protocol`: apuntado
en el PR, lo aplica el carril H. **No toques mix.exs.**

════════════════════════════════════════════════════════════════════════
7. LO QUE NO VAS A HACER
════════════════════════════════════════════════════════════════════════

· No toques doctor.ex, rag.ex, mcp.ex de otro carril, ni sus tests. Las fases
  5 y 10 se hacen EN PARALELO ahora mismo.
· No toques ficheros del carril A: model.ex, engine.ex, engine_pool.ex,
  build.ex, source.ex, store.ex, config/**, detector.ex, engine/**.
· No toques tool.ex. Es la dependencia de la que cuelga esta fase, y es de otro
  carril.
· No toques mix.exs.
· No anadas batching. Se elimino del protocolo.
· No hagas git push --force.

════════════════════════════════════════════════════════════════════════
8. AL TERMINAR
════════════════════════════════════════════════════════════════════════

Actualiza HANDOFF.md §2 con numeros medidos. Commit, push, PR, y avisame con
los ocho gates y el criterio de aceptacion.

MIRA EL CI DEL PR. En este repo se mergeo un PR con un job en rojo.

Si te bloqueas, PARA y pregunta.
```

---

## Fase 10 — RAG

```text
Estoy implementando Candil 4.0. Las fases -1, 0, 1 y 2 estan mergeadas en la
rama 4.0; la 3 (la CLI) esta en el PR #25. Tu tarea es la FASE 10: RAG.

════════════════════════════════════════════════════════════════════════
1. ENTORNO
════════════════════════════════════════════════════════════════════════

Repositorio: https://github.com/Lorenzo-SF/candil
Rama:        4.0-f10-rag     (creala desde origin/4.0)
PR:          contra 4.0, NUNCA contra main
Toolchain:   Erlang/OTP 28.5.0.7 · Elixir 1.19.5-otp-28

    git clone https://github.com/Lorenzo-SF/candil.git && cd candil
    git checkout 4.0 && git pull && git checkout -b 4.0-f10-rag
    mix deps.get && mix compile

En sandbox efimero: bash /workspace/tools/setup.sh
⚠ La rama NO puede llamarse `4.0/f10-rag`. El guion es obligatorio.

⚠ ESTA FASE CORRE EN PARALELO CON LAS FASES 5 Y 9. Los carriles son disjuntos.
NO toques doctor.ex, mcp.ex ni sus tests.

════════════════════════════════════════════════════════════════════════
2. LEE ESTO
════════════════════════════════════════════════════════════════════════

  (a) `proyecto 4.0/PLAN-F5-F9-F10.md`             <- la seccion de la fase 10
  (b) `proyecto 4.0/candil-4.0-final.md`
        · Seccion 22 (linea ~2705)  RAG entero: modelo, API
        · Fase 10   (linea ~2705)  el bloque con los seis tests
      NO leas el documento entero.

════════════════════════════════════════════════════════════════════════
3. QUE HAY YA - NO LO REPITAS
════════════════════════════════════════════════════════════════════════

`Candil.RAG` y `Candil.RAG.Chunk` **ya existen** con el struct, los `@type` y
los `@spec` congelados en la fase -1. Cinco funciones, todas stub:

    create_index/2  drop_index/1  list_indexes/0
    index/3         search/3     embedder/1
    -> {:error, %Error{reason: :not_implemented}}

Y **ya existe y no lo tocas**:
  · `Candil.embed/3`             el embedder, existe desde 3.0
  · `Candil.Model`               con `type: :local` y `usage: [:embeddings]`
  · `Candil.Store`               para resolver el modelo del embedder

Tests: test/candil/rag_test.exs (solo contratos, fase -1)

════════════════════════════════════════════════════════════════════════
4. QUE TIENES QUE HACER
════════════════════════════════════════════════════════════════════════

▓▓▓ 4.1  El pipeline  ▓▓▓

    Docs → Chunker(sentence·paragraph·fixed)
         → Chunk{id,text,embedding,metadata,position}
         → Embedder(Candil.embed/3)
         → Index(memory por defecto · postgres opt-in)
    Query → Embedder → Retrieval(BM25 + vector + RRF) → Rerank(opt-in) → top_k

▓▓▓ 4.2  Tres cosas que hay que acertar  ▓▓▓

**RRF (Reciprocal Rank Fusion).** 1º en ambas listas gana a 1º en una y 5º en
la otra. Es la razon de ser del retrieval hibrido, y es un numero, no una
opinion. `score = sum(1 / (k + rank))` con k = 60, que es lo que usa el
paper original. Si lo haces de otra manera, explica por que en el codigo.

**El chunker `:sentence` no parte una frase.** Corta entre frases. El
solapamiento tiene que ser **verificable** en un test, no declarativo.

**Sin embedder**, `{:error, :no_embedder}` **con el nombre del que falta**.
"no embedder" sin el nombre obliga a ir a buscarlo.

▓▓▓ 4.3  `./candil rag index` y `./candil rag query`  ▓▓▓

Va en el carril de la CLI (`lib/candil/cli/**`). La fase 3 tiene el esqueleto.
Si ese carril esta ocupado por el PR #25, **para y pregunta**.

    $ ./candil rag index vault --path ~/lasaca/PENDIENTE
    ✓ 1.284 documentos · 18.402 chunks · 31.2s

    $ ./candil rag query vault "donde esta la decision sobre el daemon"
    1. [0.82] PENDIENTE/principal/daemon.md:44
         "...el dueno es un proceso, no un daemon..."

El score, la ruta con linea y un trozo del texto. Eso es lo que se pega en una
respuesta.

════════════════════════════════════════════════════════════════════════
5. CRITERIO DE ACEPTACION
════════════════════════════════════════════════════════════════════════

    mix test test/candil/rag/
    #   chunker: 10k tokens → ~20 chunks de 512, solapamiento verificable
    #   chunker: :sentence no parte una frase
    #   retrieval: palabra exacta sale primero via BM25
    #   retrieval: semanticamente cercano sale primero via vector
    #   RRF: 1º en ambas listas gana a 1º en una y 5º en la otra
    #   sin embedder → {:error, :no_embedder} con el nombre del que falta

Un PR cuyo criterio de aceptacion no se ejecuto no entra.

Mas los ocho gates. Referencia: 8/8, 623 tests + 25 doctests, 0 fallos, 66.8 %.

⚠ El retrieval necesita un embedder real, y eso necesita un llama-server con
un modelo de embeddings corriendo. En un sandbox no hay. Los tests de
retrieval se pueden hacer con un embedder **de mentira** inyectado, y el
criterio de aceptacion a mano es tuyo. Di cual de las dos cosas estas
haciendo, no lo que creas que estas haciendo.

════════════════════════════════════════════════════════════════════════
6. GIT
════════════════════════════════════════════════════════════════════════

Rama:      4.0-f10-rag
PR:        contra 4.0, nunca contra main
Commits:   fecha entre 20:00 y 02:00 Europe/Berlin, de lunes a viernes
Tag:       candil-4.0.0-rc.2 al mergear

`groups_for_modules` necesita `Candil.RAG` y `Candil.RAG.Chunk`: apuntado en
el PR, lo aplica el carril H. **No toques mix.exs.**

════════════════════════════════════════════════════════════════════════
7. LO QUE NO VAS A HACER
════════════════════════════════════════════════════════════════════════

· No toques doctor.ex, mcp.ex ni sus tests. Las fases 5 y 9 se hacen EN
  PARALELO ahora mismo.
· No toques ficheros del carril A: model.ex, engine.ex, engine_pool.ex,
  build.ex, source.ex, store.ex, config/**, inference/**.
· No toques el modulo de embeddings. Es la dependencia de la que cuelga esta
  fase, y es de otro carril.
· Postgres es opt-in. El indice por defecto es en memoria (regla 4 del
  Apendice D: ETS siempre, Postgres no).
· No hagas git push --force.

════════════════════════════════════════════════════════════════════════
8. AL TERMINAR
════════════════════════════════════════════════════════════════════════

Actualiza HANDOFF.md §2 con numeros medidos. Commit, push, PR, y avisame con
los ocho gates y el criterio de aceptacion.

MIRA EL CI DEL PR. En este repo se mergeo un PR con un job en rojo.

Si te bloqueas, PARA y pregunta.
```

---

## Cómo lanzarlas

Tres sesiones, en cualquier orden. El plan de la skill `team` pide
`developer` + `tester` por carril; aquí lo que se recomienda es más simple y
más honesto: **una sesión por fase, y el revisor es otra sesión que lee el PR
sin el diff del autor**.

```
sesion A -> 4.0-f5-doctor
sesion B -> 4.0-f9-mcp
sesion C -> 4.0-f10-rag
```

Los tres tocan `mix.exs` en un solo punto — `groups_for_modules` — y los tres
lo piden en el PR en vez de hacerlo. H lo aplica una vez al final.
