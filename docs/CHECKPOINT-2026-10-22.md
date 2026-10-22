# CHECKPOINT — Candil, 2026-10-22

> **Corte para el consejero.** Esto es una foto, no la verdad permanente.
> Si algo difiere, manda el repositorio: `git log`, `gh pr view` y los tests.
>
> **Decisión de este corte:** Candil se termina primero. El CLI se extrae
> **después**, a otro proyecto, y solo cuando el contrato de librería esté
> cerrado. No se añaden comandos nuevos al CLI de Candil mientras tanto.
>
> Este documento sustituye a `tmp/ESTADO-CANDIL.md` como corte compartible.
> `tmp/` está ignorado por git; el detalle de catálogo y máquina de ese fichero
> sigue siendo útil como apéndice local.

---

## 1 · Resumen ejecutivo

- **El núcleo está en verde.** `main` = `398a1b9`, CI en verde. Fases 0, 1, 2,
  3, 4, 5, 8 y 11 cerradas.
- **Los PR de esta tanda están los cuatro mergeados** (2026-10-22, con el aval
  del dueño): #129 (reserva de VRAM, D-27), #130 (`max_tokens`), #131 (limpieza
  de comentarios + este corte) y #132 (el embedder que el router creía tener y no
  tenía). `main` está en verde con la suite en **1360 tests + 33 doctests, 0
  fallos**, y la puerta de máquina pasa 3/3 con un modelo real que necesita
  recorte.
- **La extracción del CLI es viable**, pero no es el siguiente paso. Antes hay
  que cerrar tres cosas del núcleo: descarga del draft, borrado de modelos y
  desacoplo del `Holder` de una API interna del engine.
- **La fase 12 cambia de significado.** Ya no es «construir el CLI entero
  dentro de Candil»: es «cerrar el contrato de librería y mover el CLI a su
  proyecto». El binario puede seguir llamándose `candil`.
- **El proyecto nuevo puede preparar su contrato, pero no recibe el CLI hasta
  que Candil esté terminado.** El contrato mínimo que necesita es: `pull`
  completo, `remove`, `Engine` público y el resto de primitivas que ya existen.

---

## 2 · Estado medido

### 2.1 · `main`

| | |
|---|---|
| Commit | `2c517b2` |
| CI | Format, Lint & Audit ✅ · Compile & Test ✅ · Dialyzer ✅ · Docs ✅ · Deps In Sync (skipped) |
| Suite | 33 doctests + 1329 tests, 0 fallos (semillas 0 y 1) |
| Gates | `mix format --check-formatted` · `mix credo` · `mix dialyzer` · `mix docs` |
| Fases cerradas | 0, 1, 2, 3, 4, 5, 8, 11 |

### 2.2 · PR #129 — reserva de VRAM (D-27)

| | |
|---|---|
| URL | https://github.com/Lorenzo-SF/candil/pull/129 |
| Rama | `fix/d27-resource-reservation` |
| Base | `main`, sin PR apilados |
| Head | `4d91ec6` |
| Commits | 7 (`1e081f9`, `d682c72`, `bf1e966`, `7869f4b`, `2331fa6`, `546dd57`, `4d91ec6`) |
| Checks | Format, Compile & Test, Dialyzer, Docs: ✅ |
| Revisión | ✅ **mergeado** el 2026-10-22 (squash + delete-branch) |
| Suite declarada | 33 doctests + 1360 tests, 0 fallos, 6 skipped (semillas 0 y 1) |

> El cuerpo del PR dice «tres commits»; la rama tiene **siete**. Los cuatro
> restantes son rondas posteriores de CI, tests de hardware y ajustes del
> scheduler. Para el estado, manda
> `git log --oneline origin/main..origin/fix/d27-resource-reservation`.

**Qué cierra:** reserva antes de arrancar, liberación al caer el motor, peso
medido de `llama-fit-params`, memoria ajena como titular `:foreign`, camino
único `Engine.start_placed/2` para API y CLI, titular con generación
`{alias, port, make_ref()}`, y `candil stop` que también mata el
`llama-server` del sistema operativo.

**Lo que no se rellena:** `vram_mb` del catálogo. El mismo modelo mide 795,
7978 o 10452 MiB según la memoria libre del instante; un número fijo sería una
foto. Queda como cota inferior opcional y la reserva se corrige al peso medido.

### 2.3 · PR #130 — `max_tokens`

| | |
|---|---|
| URL | https://github.com/Lorenzo-SF/candil/pull/130 |
| Rama | `feat/max-tokens-razonamiento` |
| Base | `main`, sin apilar sobre #129 |
| Head | `4db9202` |
| Commits | 1 |
| Checks | Format, Compile & Test, Dialyzer, Docs: ✅ |
| Revisión | ✅ **mergeado** el 2026-10-22 (squash + delete-branch) |
| Suite declarada | 33 doctests + 1321 tests, 0 fallos, 3 skipped (semillas 0 y 1) |

**Qué cierra:** default global de 512 → 4096, `max_tokens` por modelo y aviso
cuando una respuesta sale vacía con `finish_reason: "length"`. Es la causa
medida de que `agenta1` contestara `content: ""` con 512 tokens.

### 2.4 · Lo que se mergeó en esta tanda

| PR | Qué |
|---|---|
| #129 | la reserva de VRAM completa (D-27), 7 commits en un squash |
| #130 | `max_tokens` por modelo y default global de 4096 |
| #131 | ocho comentarios con el texto corrupto reparados + este corte versionado en `docs/` |
| #132 | la capa `:embedding` del router solo corre si el embedder puede atender una petición |

Y la documentación, ya mergeada ✓: la **fila P-12** de vuelta en el registro
✓, el **contrato público** en
[`04-modulos/CONTRATO-PUBLICO.md`](04-modulos/CONTRATO-PUBLICO.md) ✓, la
**auditoría del acoplamiento a NVIDIA** en `docs/09` §5.1-5.4 ✓ y los **textos
que mienten** corregidos en el propio código ✓.

**Y desde entonces** ✓:
- **D-28 escrita** ✓ (la decisión de los backends ✓, en `docs/08` ✓).
- **Segunda lectura de la auditoría** ✓: el consejero encontró tres sitios más
  ✓ — `sync_foreign/1` se traga el fallo ✓, `size_mb/2` usa una suposición
  como si fuera una medición ✓, y la ruta del modelo se construye a mano en vez
  de con `Model.file_path/1` ✓ — y avisó de que **cinco filas de la auditoría
  ya no eran ciertas** ✓ (las había corregido el #133 ✓) ✓.
- **Contrato revisado** ✓: `Candil.Llm` sale de la API ✓ (su `@moduledoc` ya
  decía que era interno ✓), `Devices.processes/0` entra ✓ (sin él, el CLI
  extraído dependería de un módulo no contractual ✓), y los helpers `@doc
  false` quedan clasificados uno a uno ✓.

### 2.5 · Lo que ya está hecho y no hay que reabrir

- `Candil.StoreCase` existe y está cableado en varios tests. No es deuda
  pendiente; solo hay que usarlo en cualquier test nuevo que toque el `Store`
  global.
- `Candil.Preflight` ya vive en el núcleo, no en el CLI.
- `Candil.Doctor` ya tiene checks y `render/1` en el núcleo; el CLI solo pinta.
- `Candil.Telemetry` ya tiene las métricas de decisiones y calidad; el CLI solo
  formatea.
- `Candil.Gateway`, `Candil.Router`, `Candil.Source`, `Candil.Installer`,
  `Candil.Store` y `Candil.Engine` son núcleo y se quedan.
- `Candil.Engine.start_placed/2` es el camino único de arranque en la rama de
  #129; al mergear, queda en `main`.

---

## 3 · Qué significa «terminar Candil»

El plan de `docs/02-orden` tiene doce fases. El estado real es:

| Fase | Qué | Estado |
|---|---|---|
| 0 | Probar lo que existe | ✅ |
| 1 | Behaviours | ✅ |
| 2 | `Arrea.Resource` | ✅ |
| 3 | Enrutado | ✅ |
| 4 | Política | ✅ |
| 5 | Refusal | ✅ (`:degrade` declarado y no alcanzable; P-1) |
| 6 | RAG | ⬜ |
| 7 | MCP | ⬜ |
| 8 | Gateway | ✅ |
| 9 | Mesa camilla | ⬜ |
| 10 | Agentes | 🟡 piezas construidas; fase no cerrada |
| 11 | `candil stats` | ✅ |
| 12 | CLI | 🔄 **cambia de forma: contrato + extracción** |

**Decisión que falta:** si «terminado» significa el plan completo, hay que
cerrar 6, 7, 9 y 10 antes de extraer. Si se decide un corte 1.0, hay que
escribir explícitamente qué queda fuera y por qué. Lo que no vale es dejar la
fase 12 como «el CLI entero» y descubrir al final que el CLI dependía de piezas
que no existen.

### 3.1 · Criterio de cierre de Candil

Un corte de Candil está terminado cuando:

- `main` tiene CI verde con format, compile `--warnings-as-errors`, credo,
  tests con semillas 0 y 1, dialyzer y docs.
- La puerta de máquina con GPU real pasa, y el camino CPU también.
- No quedan P0/P1 sin decisión; las deudas P-6, P-9, P-10 y P-12 están cerradas
  o marcadas como fuera de alcance con motivo.
- `mix hex.build`/paquete y documentación de consumo están al día.
- No hay comandos nuevos dentro del CLI de Candil: lo que falte de CLI se anota
  para el proyecto nuevo.

---

## 4 · Lo que falta, en orden

### 4.1 · Cerrar la tanda actual (dueño)

1. Revisar y mergear **#129** con squash + delete-branch.
2. Verificar CI verde en `main` después del merge.
3. Revisar y mergear **#130** con squash + delete-branch.
4. Verificar CI verde en `main` otra vez.
5. Decidir qué hacer con `chore/limpiar-comentarios-corruptos`: PR propio o
   absorber en el PR de deuda.

El orden es recomendado, no una dependencia: #130 es independiente y puede
mergearse antes si el dueño lo prefiere.

**No** apilar #130 sobre #129. **No** abrir el PR de backends antes de #129:
tocan los mismos ficheros.

### 4.2 · Backends genéricos (P-12 y D-28)

Va **después** de #129, en PR propio. Toca `engine/server.ex`,
`engine/fit_params.ex`, `engine/resource.ex`, `scheduler.ex` y
`detector/devices.ex`.

Lo que falta:

1. **Nombre del device desde el engine.** Hoy se escribe `CUDA#{device}` a
   mano. `llama-server --list-devices` ya publica
   `CUDA0: NVIDIA GeForce RTX 5080 Laptop GPU (15933 MiB, 15683 MiB free)`.
2. **Lista de devices desde el engine.** Hoy sale de `nvidia-smi`; en
   ROCm/SYCL/Vulkan eso deja `devices: []` y Candil no ve el acelerador.
3. **Overhead por backend.** 370 MiB es el overhead de CUDA; 16303 − 370 =
   15933, que es exactamente lo que ve llama-server. Para otros backends hay
   que medirlo, no heredarlo.
4. **`:foreign` por backend.** En `nvidia-smi` el `memory.free` es por device;
   en memoria unificada de macOS es del sistema. La fórmula cambia.
5. **Bug `unified_memory/0`.** Pone `free_mb` igual al total (`hw.memsize`) y
   marca `usable: true`; el scheduler cree que hay memoria que no hay.
6. **D-28.** La decisión de qué significa «device» en cada backend la tiene que
   escribir el consejero. Sin ella, el PR no debe empezar.

Cierre: tests con `Candil.FakeGPU`, un caso por backend simulado y una puerta
de máquina con GPU real; `usable: false` cuando no se sabe, nunca 0 inventado.

### 4.3 · Deuda del scheduler y colocación

No bloquea la extracción del CLI, pero sí bloquea llamar «terminado» al motor
local si el objetivo incluye varias GPUs.

- **P-6:** colocación en varias GPUs, reintento en otro device. Depende de P-4.
- **P-10:** cableado completo del scheduler. En `main`, `Candil.Scheduler.Signal`
  y `Candil.Scheduler.Devices` siguen sin llamadores en `lib/` (medido
  2026-10-19); #129 puede cambiar parte de eso.
- **P-9:** agentes sin nombre y crash que no es cuelgue; D-25 propone identidad
  derivada.
- **P-1:** `:degrade` sigue declarado y no alcanzable; no bloquea, pero no
  cuentes con él como si existiera.

### 4.4 · Fases de producto que quedan

Si el corte es el plan completo:

- **6 · RAG:** `Candil.RAG.Store` está cableado, pero la fase no está cerrada.
- **7 · MCP:** `Candil.MCP.Server` está cableado en el nivel 1; falta el resto.
- **9 · Mesa camilla:** depende de 6 y de la política.
- **10 · Agentes:** hay `SimpleReflex`, `ModelBasedReflex`, breakers, snapshots
  y presupuesto de crashes; la fase no está cerrada.

Si el corte es 1.0, escribe aquí qué se queda fuera. No dejes la decisión
implícita: el proyecto del CLI necesitará saber si `route`, `serve`, `doctor` y
`stats` son todo el contrato o si hay comandos para RAG/MCP/agentes.

### 4.5 · Catálogo y máquina

No es código de Candil, pero afecta a la puerta de máquina y al `doctor`:

- `embed`, `vector`, `ranker` y `vault` siguen declarados en el catálogo, sin
  fichero y fuera de las listas de consumidores. O se restauran los GGUF y se
  reañaden, o se documenta la degradación.
- `coder`, `analyst`, `verifier`, `designer`, `vision`, `gemma`, `ornith`,
  `qwopus` y `agenta1` están medidos y arrancan; el detalle está en
  `tmp/ESTADO-CANDIL.md`.
- `models remove` no edita `candil.toml`: al reiniciar, `Hydrate` vuelve a
  registrar el modelo como `missing`. Decidir si eso es «borrar ficheros» o
  «quitar del catálogo».

### 4.6 · Contrato de núcleo que falta antes de extraer el CLI

Esto es lo único que **sí** es un prerrequisito de la extracción:

1. **Descarga del draft en el núcleo.**
   - `Candil.pull/1` descarga engine + modelo, pero no `model.draft`.
   - `Installer.download_model/1` tampoco.
   - El único sitio que baja el draft es `CLI.Models.pull/1`; sin él,
     `llama-server` falla al abrir el GGUF.
   - Mover esa descarga a `Installer`/`Candil.pull` y dejar que el CLI solo
     formatee el progreso.

2. **Borrado de modelos en el núcleo.**
   - `CLI.Models.remove` hace `Store.deregister_model/1`, borra el fichero
     principal, el draft y los `.complete`.
   - El núcleo solo tiene `Store.deregister_model/1` (ETS, sin ficheros).
   - Añadir `Candil.remove/1` o equivalente, con semántica explícita sobre
     `candil.toml`.

3. **Desacoplar `Holder` de `Engine.Server.id_for/2`.**
   - `Holder` usa `Engine.Server.id_for/2` (`@doc false`) y
     `Arrea.LongRunning.stop/1`.
   - Cambiarlo a `Engine.stop/1`, que ya es público y limpia `EnginePool`.
   - Así el holder puede vivir en el CLI sin depender de una API interna.

4. **Decidir si `status`/`stop` son API de librería o solo del CLI.**
   - Hoy se componen con `EnginePool.list/0`, `Instances.read/0`,
     `Engine.healthy?/1` y `Devices.processes/0`, todos públicos.
   - No es obligatorio añadir un facade; si se añade, que sea pequeño y después
     de la extracción.

### 4.7 · Extracción del CLI (fase 12)

**No hacerlo antes de 4.6.** La secuencia:

1. Crear el proyecto nuevo (nombre pendiente) como app Elixir con Candil como
   dependencia, Alaja y escript propio.
2. Mover `lib/candil/cli/**` y sus tests. Renombrar `Candil.CLI.*` al namespace
   del proyecto nuevo.
3. Mover el escript, los alias, la decisión de terminal, el crash log y los
   códigos de salida.
4. Quitar de Candil: `escript: [main_module: Candil.CLI.Escript]`, la dependencia
   `alaja`, `batamanta`/alias `install` de empaquetado, y el gate de «help =
   dispatch table».
5. Actualizar `zaguan`: `repos.yaml`, `candil.d/candil.sh` y README. Candil pasa
   a librería; el proyecto nuevo pasa a CLI escript. El comando puede seguir
   llamándose `candil`. Ojo: hoy `repos.yaml` ya tiene una contradicción — el
   comentario de orden dice «candil (CLI escript)» y la entrada de candil dice
   «librería»; hay que dejarlo coherente.
6. Verificar el binario nuevo con `version`, `models list`, `doctor`, `run`,
   `stop`, `status`, `--detach`, `serve`, `route`, `init`, `models pull` con
   draft y `models remove`.

**Qué se queda en Candil:** engine, scheduler, VRAM, modelo, source, installer,
store, router, gateway, doctor, telemetry, config, preflight. **Qué se va:** la
declaración de comandos, Alaja, escript, colorize, renderers de doctor/stats,
workflow de run/stop/status, ports, detach/holder, serve flags/auth, init
writer y models list/info/pull/remove como presentación.

**Breaking change:** `Candil.CLI.main/1` deja de existir como API in-process.
No hay referencias de producción en el repo; si alguien lo embebe, hay que
documentarlo.

### 4.8 · Documentación y decisiones

- Actualizar `docs/README.md`, `docs/09-deuda-y-pendientes` y `COMO-RETO-MARLO`
  cuando #129/#130 mergeen; las cabeceras de docs siguen fechadas en `4d8d3e5`
  (2026-10-16) y no reflejan `main` = `398a1b9`.
- Escribir D-28 (backend/device) antes del PR de P-12.
- Decidir el alcance de «terminado» (plan completo vs 1.0).
- Decidir la semántica de `remove`.
- Decidir si el proyecto nuevo conserva Alaja o usa otra capa de CLI.

---

## 5 · El plan del CLI, en una tabla

| Pieza | Hoy | Después |
|---|---|---|
| `Candil.CLI` (declaración) | Candil | Proyecto CLI |
| `Candil.CLI.Escript` | Candil | Proyecto CLI |
| `Help`, `Version`, `Colorize` | Candil | Proyecto CLI |
| `Doctor` / `Stats` renderers | Candil | Proyecto CLI |
| `Router`, `Serve`, `Init` | Candil | Proyecto CLI |
| `Lifecycle` run/stop/status | Candil | Proyecto CLI |
| `Ports`, `Detach`, `Holder` | Candil | Proyecto CLI |
| `Models` list/info/pull/remove | Candil | Proyecto CLI, llamando al núcleo |
| `Preflight` | Candil | Candil |
| `Engine`, `EnginePool`, `Instances` | Candil | Candil |
| `Store`, `Source`, `Installer` | Candil | Candil |
| `Router` (motor), `Gateway` | Candil | Candil |
| `Doctor` (checks), `Telemetry` | Candil | Candil |
| `Config`, `Config.Template` | Candil | Candil |

La regla para decidir: **si un consumidor de Candil sin CLI lo necesita, es
núcleo; si es una forma de operarlo desde un terminal, es CLI.** `Preflight`
pasó esa prueba y ya está en el núcleo. `run`/`stop`/`status` no la pasan: son
workflow de operador sobre primitivas que ya existen.

---

## 6 · Decisiones abiertas

| # | Decisión | Quién | Impacto |
|---|---|---|---|
| 1 | ¿Dónde está la línea de «terminado»? | **Dueño — YA DECIDIDO** | **«Terminado» = el 100 % de las tareas definidas como framework para Candil, excluyendo las del CLI.** O sea: las fases 6, 7, 9 y 10 **entran**, y también P-1, P-6, P-9, P-10 y P-12. **Ojo**: el 1.0 que recomienda el consejero (encargo 1 del mensaje 24) **deja esas fases fuera**, así que **no cumple esta definición** ✓. El CLI se extrae **después**, y entonces sí: el núcleo cerrado es el que agota la definición del dueño |
| 2 | D-28: nombre de device, detección, overhead y `:foreign` por backend | Consejero | Bloquea el PR de P-12 |
| 3 | ¿`remove` borra ficheros o también sale del catálogo/config? | Dueño | Define `Candil.remove/1` |
| 4 | ¿`status`/`stop` son API pública o solo CLI? | Dueño | Define si hay facade en Candil |
| 5 | ¿El proyecto nuevo conserva Alaja? | Dueño/consejero | Define el traslado del CLI |
| 6 | ¿Se restauran `embed`, `vector`, `ranker`, `vault` o se documenta la degradación? | Dueño | Afecta a la puerta de máquina y al router |
| 7 | ¿La rama de comentarios corruptos va en PR propio o se absorbe? | Dueño | Higiene, no bloquea |

---

## 7 · Lo que no hay que hacer

- **No extraer el CLI ahora.** El núcleo todavía tiene dos operaciones que solo
  existen en el CLI (draft y remove) y un acoplamiento interno (`Holder`).
- **No añadir comandos nuevos al CLI de Candil.** Si hace falta uno, se anota
  para el proyecto nuevo.
- **No rellenar `vram_mb` en el catálogo.** La medición ya demostró que varía.
- **No apilar PRs.** #130 va aparte; P-12 va después de #129.
- **No mover lógica de inferencia, scheduling, router o gateway al CLI.** Eso
  se queda en Candil; el CLI solo compone y pinta.
- **No dar por bueno un test que no se ha ejecutado en la máquina real.** La
  puerta de GPU y el camino CPU son parte del cierre.

---

## 8 · Evidencia para verificar este corte

```bash
cd candil

git log --oneline -8
git status --short --branch

gh pr view 129 --repo Lorenzo-SF/candil \
  --json number,title,state,headRefOid,mergeStateStatus,reviewDecision
gh pr view 130 --repo Lorenzo-SF/candil \
  --json number,title,state,headRefOid,mergeStateStatus,reviewDecision

gh api repos/Lorenzo-SF/candil/commits/398a1b9/check-runs \
  --jq '.check_runs[] | {name,status,conclusion}'

# Dependencia del núcleo hacia el CLI: no debe haberla.
rg -n 'Candil\.CLI' lib --glob '!lib/candil/cli/**' --glob '!lib/candil/cli.ex'

# Los tres huecos de extracción.
rg -n 'draft|download_model' lib/candil.ex lib/candil/installer.ex lib/candil/cli/models.ex
rg -n 'deregister_model|def remove' lib/candil/store.ex lib/candil/cli/models.ex
rg -n 'id_for|LongRunning.stop' lib/candil/cli/holder.ex lib/candil/engine/server.ex
```

---

## 9 · Siguiente acción

1. El dueño revisa y mergea **#129** y **#130** (independientes); verifica `main` en verde.
2. El consejero decide el alcance de «terminado» y escribe **D-28**.
3. Se abre el PR de **P-12** (backends) después de #129.
4. Se cierran los tres prerrequisitos de **4.6**.
5. Se extrae el CLI a su proyecto y se actualiza `zaguan`.

Mientras todo eso pasa, **Candil sigue siendo la fuente de verdad** y el CLI
actual sigue siendo una aplicación suya, no un fork. La extracción no cambia
el comando `candil`; cambia quién lo construye.
