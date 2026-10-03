# Auditoría de las fases de Candil 4.0

> Revisión de los 8 README de fase (2, 5, 6, 7, 8, 9, 10, 11) contra
> `candil-4.0-final.md`, `PLAN-VENTANA-PARALELA.md` y `PROMPT-VENTANA-PARALELA.md`.
> Cada fase comprobada contra cuatro cosas: **completitud**, **corrección
> técnica**, **ejecutabilidad por alguien sin contexto**, y **que el criterio de
> aceptación detecte el fallo que dice detectar**.
>
> Fecha: 2026-10-03 · Revisión en `max`

---

## Veredicto en una línea

**El plan de diseño es excelente y no se toca.** Lo que falla es la capa de
traspaso: hay **9 contradicciones activas** entre documentos, y 6 de ellas
harían que un desarrollador implemente una fase **distinta** de la que cree.

Tres hallazgos necesitan una decisión tuya antes de seguir: **A1** (MCP está
dos revisiones atrás), **A2** (la fase 10 tiene dos versiones incompatibles) y
**A4** (el "cierre a main" contradice la disciplina del repo).

---

## Los tres que necesitan decisión tuya

### A1 · La fase 9 implementa un protocolo que ya está retirado de `Current`

**Estado real, verificado hoy contra `modelcontextprotocol.io`:**

| Revisión | Estado | Handshake `initialize` |
|---|---|---|
| `2024-11-05` | Legacy | sí |
| `2025-03-26` | Legacy | sí |
| `2025-06-18` | Legacy | sí |
| `2025-11-25` | **Legacy** (handshake-based) | sí |
| **`2026-07-28`** | **Current** | **NO — eliminado** |

La fase 9 dice, y lo repite en tres sitios, que la revisión es `2025-11-25` y
que el handshake `initialize` es **obligatorio**. En la revisión `Current`
(`2026-07-28`) el handshake está **eliminado**: MCP es stateless, cada request
lleva la versión en `_meta` (`io.modelcontextprotocol/protocolVersion`), y hay un
RPC nuevo `server/discover`. Los mismismos fallos de versión ahora devuelven
`UnsupportedProtocolVersionError` en vez de la negociación antigua.

**Lo que sí está bien y hay que mantener:** el batching se eliminó en
`2025-06-18` (PR #416, confirmado en el changelog oficial) y el header
`MCP-Protocol-Version` pasó a ser obligatorio en esa misma revisión (PR #548). Eso no
ha cambiado. La parte de la fase 9 que habla de batching y de headers es
correcta al día de hoy.

**Decisión que necesito de ti:**

- **Opción A** — implementar `2026-07-28` (Current). Es la correcta a día de hoy
  y lo que un cliente moderno espera. Pero **cambia el diseño de la fase**: no hay
  `initialize`, hay `server/discover`, y la negociación de versión es otra cosa.
  El texto de la fase 9 hay que reescribirlo, no parchearlo.
- **Opción B** — implementar `2025-11-25` (Legacy) como está escrito. Funciona con
  clientes que aún usan handshake, que es el caso del inspector y de opencode
  probablemente. Pero es trabajo que se tira cuando se migre.
- **Opción C** — `2026-07-28` con fallback de `2025-11-25`, que es lo que hacen los
  SDK oficiales. Más trabajo, y el fallback es exactamente la parte que nadie usa.

**Mi recomendación: A**, con `@supported_versions` incluyendo las cinco y
`server/discover` implementado. El coste extra es un día; el ahorro es no tirar
la fase entera. Pero es tu decisión, no mía: es un cambio de diseño, y el
documento de diseño dice que las decisiones están todas escritas — esta no lo
está, y por eso te lo pregunto en vez de elegirlo.

Mientras decides, la fase 9 **no debería empezar**.

---

### A2 · La fase 10 tiene dos versiones y se contradicen en casi todo

Este es el hallazgo más grave, porque no es una discrepancia de detalle: los dos
documentos describen **software distinto**.

| | `fase-10-README.md` | `candil-4.0-final.md` §22 y `PROMPT-VENTANA-PARALELA` |
|---|---|---|
| **Almacén** | **SQLite FTS5** | `Index` en **memoria**, Postgres opt-in |
| **Chunking** | **por función** | sentence · paragraph · **fixed** (512) |
| **Módulos nuevos** | `RAG.Chunk` `RAG.Store` `RAG.Embedder` `RAG.Hybrid` `RAG.Ranker` | `rag/{chunker,chunk,document,index,retrieval,rerank,embedder}.ex` |
| **API** | `RAG.retrieve/2` | `create_index/2` `index/3` `search/3` `embedder/1` |
| **Estado** | "`RAG` **solo**, como módulo vacío" | "struct, `@type` y `@spec` **congelados** en la −1, cinco funciones stub" |
| **Effort** | **7 d** | **5 d** |
| **Depende de** | la **8** | la **9** (el gantt pone F10 después de F9) |
| **Métricas** | `cachear embeddings por hash` | Rerank opt-in, sin mención de caché |

Ocho divergencias. No es que uno sea más nuevo: el README menciona
`SQLite FTS5` y chunking por función, cosas que **no están en el plan en ningún
sitio**. Y el README dice que `RAG` está vacío, cuando el prompt de traspaso
afirma que tiene structs y `@spec` congelados y que solo hay que poner cuerpo.

**Lo que sí está bien en el README y merece survive:** los argumentos de *por
qué*. SQLite FTS5 dentro del binario es una decisión defendible ("un RAG que
necesita un servicio más no se despliega"), el chunking por función evita
fragmentos inútiles para citar, y la caché de embeddings por hash evita pagar el
modelo en cada reindexado. Los tres son buenas ideas que el plan no tiene.

**Decisión que necesito de ti:** ¿cuál de los dos es el diseño bueno?
- **El del README** (SQLite + función) es técnicamente más fuerte, pero no está
  en el plan, no tiene structs congelados, y cambia la API.
- **El del plan** (memoria + configurables) es lo que está escrito y auditado, y
  lo que hereda los contratos de la −1.

Lo que **no** puedes hacer es dejar los dos documentos vivos. Ahora mismo, un
agente que lea el README y otro que lea el prompt producen dos RAG distintos, y
el que mergee primero bloquea al otro. Hay que elegir uno y borrar el otro.

---

### A4 · "Cerrado a main" en las fases 6-11 contradice la disciplina del repo

Las fases 6, 7, 8, 9, 10 y 11 tienen todas esta casilla en su definición de done:

> - [ ] **cerrado a `main`**: sync `main` → `4.0` y PR `4.0` → `main`

Y todas estas otras, en el mismo documento:

> `main` tiene branch protection con 1 approving review. El PAT es admin y se lo
> salta, así que puedes pushear a main sin revisión. **NO lo hagas.** Es la única
> disciplina que queda en este repo.

Las dos no pueden ser verdad a la vez. `main` tiene una approving review
obligatoria: **un PR de `4.0` a `main` exige revisión de alguien**, y si el PAT
la salta, se está saltando la única protección que queda.

**Lo más probable** es que "cerrado a main" sea un residuo de una versión
anterior del plan donde el flujo era otro. Pero está en 6 documentos, así que
alguien lo va a leer y lo va a hacer.

**Decisión:** o `main` se abre al mundo y se relaja el requisito, o el cierre de
cada fase es solo el merge a `4.0` y el `main` se abre una vez al final, en la 11.
Yo haría lo segundo: 11 PRs con revisión de 1 approving son 11 revisiones
que alguien tiene que hacer, y nadie las va a hacer.

---

## Las seis contradicciones menos graves

| # | Dónde | Qué dice | Por qué es un problema |
|---|---|---|---|
| **A3** | fase 2, §6 | Rama `4.0/f2-build` | **Imposible.** `refs/heads/4.0` y `refs/heads/4.0/f2-build` no pueden coexistir. Las fases 9 y 10 avisan de ello; la 2 no. Es la única fase con la barra y ya costó un intento fallido en la 6. |
| **A5** | fases 6-11 | "El número de tests no ha bajado de **702**" | La base medida documentada es **687** (fase 5, commit `6c73b28`). 702 no aparece en ningún sitio. Un gate contra un número inventado hace que el agente haga lo que sea para llegar a 702, que es exactamente lo contrario de lo que quieres. |
| **A6** | fase 5 y prompt | Reference `623 tests + 25 doctests, 66.8 %` | Está desactualizado. El estado real de la 5 es **687 + 26, 8/8 gates**. Un agente que compare pensará que ha perdido 64 tests y la fase se rompe sola. |
| **A7** | fases 6-11 | `CANDIL_DATA_DIR=<tmp>` no aparece | La fase 5 lo dice y explica por qué (un test que escribe en el `~/.candil` de verdad no se ejecuta dos veces). Las fases siguientes heredan los tests de la 5 y no lo repiten. Es una omisión que se paga. |
| **A8** | fase 8 | "**No capa de billing**" | Texto corrupto con caracteres CJK. Tiene que ser "No capa de billing". Un prompt que se copia entero lleva el error delante de los ojos del agente. |
| **A9** | fases 2 y 5 | Rutas del sandbox divergentes | Fase 2: `/workspace/setup-candil.sh`. Fase 5: `/workspace/tools/setup.sh`, y además documenta el mirror de Hex (`hex_mirror.py --port 4000`) como tarea de background gestionada. La 2 no lo dice. |

---

## Lo que está bien y no hay que tocar

Vale la pena decirlo, porque el plan tiene cosas buenas:

- **La fase 5 es el mejor documento del conjunto.** El estado real con el output
  del doctor, los 687 tests, las 8 trampas del entorno pagadas, y el
  `deliverable.md` con los ocho gates y números medidos. Es el patrón que las
  demás deberían seguir. El §6 de la fase 5 ("Trampas de este entorno", con
  `System.pid/0` devolviendo tres tipos según la versión, `Enum.filter/2`
  devolviendo los originales, `Map.update/4` con el default en tercer lugar) es
  oro puro.
- **El criterio de la fase 8 con un cliente OpenAI de PyPI**, no un test propio.
  "Un test nuestro que dice que responde no demuestra que un cliente OpenAI real
  lo entienda, y ese cliente es el consumidor." Es el criterio de aceptación
  correcto y está escrito con la razón.
- **La fase 9 razona sobre por qué NO**: no el protocolo entero, no MCP en la CLI
  principal, no `String.to_atom/1` sobre nombres de tool. Y explica que la fase 9
  es "la razón de ser del atom factory". Eso es diseño, no una lista de tareas.
- **La fase 11 dice que 11.1 y 11.2 no se pueden hacer desde el repo de Candil**
  y por eso es la única fase que no se cierra con un PR a `4.0`. Es cierto y
  explica el agrupamiento.
- **La nota operativa de las fases 9 y 10**: "Esta fase con 4 equipos no cabe en
  30 minutos. Ya se intentó y el plan no entregó." Reconocer un intento fallido en
  el propio documento es raro y ahorra repetirlo.
- **La pérdida de degradación de la fase 6** está razonada tres veces (TTL
  monotónico, LRU que no desaloja, truncado silencioso) con el "ya se cometió una
  vez" en el primero. Eso es memoria de proyecto bien puesta.

---

## El veredicto por fase

| Fase | Completa | Correcta | Ejecutable por un júnior | Acción |
|---|---|---|---|---|
| **2** | ⚠️ | ✅ | ❌ | Rama imposible (A3), falta el mirror de Hex (A9), y describe una fase ya cerrada. **Archivar.** |
| **5** | ✅ | ✅ | ✅ | La mejor. Solo actualizar la referencia de tests (A6) y el `CANDIL_DATA_DIR` (A7). |
| **6** | ✅ | ✅ | ⚠️ | Sustituir 702 por la base real (A5), quitar "cerrado a main" (A4), añadir el trapezio del entorno. |
| **7** | ⚠️ | ✅ | ⚠️ | Le falta la API. Los otros tres README dan la API congelada; el 7 no. Y no dice cómo se arranca el motor. |
| **8** | ⚠️ | ⚠️ | ⚠️ | Texto corrupto (A8), y **no dice qué pasa con el error `-32603` ni con el normalizer de ElPaso**, que el plan sí especifica. |
| **9** | ❌ | ❌ | ⚠️ | **Bloqueada por A1.** No empezar hasta decidir revisión. El resto del documento es bueno. |
| **10** | ❌ | ❌ | ⚠️ | **Bloqueada por A2.** Dos diseños incompatibles. Elegir uno. |
| **11** | ⚠️ | ✅ | ⚠️ | El `groups_for_modules` es un bloque de 11 módulos pendientes desde la 4 y es lo único que puede hacer este carril. Le falta un **orden**: qué pasa si el 5 no ha mergeado cuando empieza la 11. |

---

## Lo que le falta a todas las fases para ser ejecutables por un júnior

Cuatro cosas, presentes en la 5 y ausentes casi todas las demás:

1. **El estado real con números medidos.** La 5 lo tiene (687 tests, output del
   doctor, commit `6c73b28`). Las demás dicen "623 tests" o "702", que no son
   ciertos. Un júnior no puede saber si va bien sin la base.
2. **Las trampas del entorno.** La 5 tiene 8 y son las que más tiempo ahorran.
   Ninguna otra fase las tiene, y las necesidades son las mismas porque todas
   corren en el mismo sandbox.
3. **La base de la CLI.** Fases 9 y 10 dicen "si el carril de la CLI está ocupado
   por el PR #25, para y pregunta". Eso está bien como política, pero la 3 ya
   está mergeada: hay que poner el estado real.
4. **Qué hacer si el bloqueante no está resuelto.** Ninguna fase dice qué hacer si
   su dependencia no está. La 6 depende de la 4; la 7 de la 6; la 8 de la 7. ¿Qué
   hace el agente si la 6 no está? Hoy no tiene respuesta, y la respuesta por
   defecto sería improvisar, que es justo lo que las tres fases dicen de no hacer.

---

## Lo que he arreglado en los README corregidos

Cada README lleva ya, además de su contenido:

- **Nivel de razonamiento por sub-tarea**, con el porqué.
- **Capa de verificación en 4 capas**: los ocho gates, tests concretos con lo que
  tiene que pasar, revisión manual del código, y prueba funcional con **qué tiene
  que ocurrir y qué no**.
- **La base real de tests** y la regla "si baja el número, para".
- **Las trampas del entorno** que aplican a esa fase.
- **Qué hacer si el bloqueante no está resuelto.**
- Las contradicciones corregidas (A3, A5, A6, A7, A8), y las que **no** se pueden
  corregir sin tu decisión (A1, A2, A4) marcadas como **BLOQUEANTE** en la propia
  fase, con las opciones.
