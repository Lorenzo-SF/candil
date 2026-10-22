# El contrato público de Candil

> Qué puede llamar un consumidor de Candil **sin el CLI**, y qué no.
>
> Medido el 2026-10-22 sobre `main` (`2c517b2`).

---

## Por qué existe este documento

Candil va a tener **dos consumidores**: el CLI (que se extrae a su propio
proyecto al final) y **cualquiera que incruste Candil como librería** ✓. La
pregunta «¿qué es núcleo y qué es CLI?» decide dónde vive cada cosa, y
responderla por partes es lo que hace que la extracción no duela ✓.

**El criterio**, que no es nuevo:

> Si un consumidor de Candil **sin CLI** lo necesita, es núcleo ✓. Si es una
> forma de **operarlo desde un terminal**, es CLI ✓.

Y su corolario, que es la regla que más cuesta:

> **No se marca `@doc false` una función solo porque el CLI nuevo la
> necesite** ✓. O es API con sus docs ✓, o el CLI no la usa ✓. Exponer
> «a escondidas» una función que otro proyecto va a llamar es hacer una API
> pública que no parece pública ✓.

`Candil.Preflight` ya pasó esta prueba ✓ (vive en el núcleo ✓). `run`, `stop` y
`status` no la pasan ✓: son workflow de operador sobre primitivas que ya
existen ✓.

---

## 1 · API estable del núcleo (1.0)

Lo que un consumidor puede llamar y **no se rompe sin un cambio mayor** ✓.

### La fachada

| Función | Para qué |
|---|---|
| `Candil.chat/3` | una inferencia, con el modelo resuelto por alias ✓ |
| `Candil.pull/1` | descargar un modelo al catálogo ✓ |
| `Candil.serve/1` | exponer la API OpenAI-compatible ✓ |

### Inferencia

| Módulo | Qué |
|---|---|
| `Candil.Llm` | chat local y remoto, y el estado de los motores ✓ |
| `Candil.Inference` | el camino de inferencia: `chat_local/3`, `chat_remote/4`, embeddings ✓ |

### Motores

| Módulo | Qué |
|---|---|
| `Candil.Engine` | `start/3`, `start_placed/2` (el camino único ✓), `stop/1`, `healthy?/1`, `for_model/3` ✓ |
| `Candil.EnginePool` | `list/0`, `put/5`, `delete/2`, `claim_port/2` ✓ |
| `Candil.Instances` | `read/0`, `find/1`, `put/2`, `delete/1`: el registro de instancias, en disco ✓ |

### Catálogo y configuración

| Módulo | Qué |
|---|---|
| `Candil.Store` | el catálogo: modelos, engines, providers ✓ |
| `Candil.Source` | de dónde sale un fichero (HuggingFace, URL, local ✓) |
| `Candil.Installer` | descargar e instalar ✓ |
| `Candil.Model` | el struct del modelo y su `file_path/1` ✓ |
| `Candil.Provider` | un destino remoto ✓ |
| `Candil.Config` / `Candil.Config.Template` | leer la configuración y escribir la plantilla ✓ |

### Enrutado y servicio

| Módulo | Qué |
|---|---|
| `Candil.Router` | a qué modelo va cada prompt ✓ |
| `Candil.Gateway` | servir la API a otros procesos ✓ |
| `Candil.Scheduler` | la **decisión** de colocación ✓ |
| `Candil.Detector.Devices` | **`processes/0`** sí ✓: la VRAM que usa cada proceso ✓. `detect/0` es interno ✓ |

### Observabilidad

| Módulo | Qué |
|---|---|
| `Candil.Doctor` | los checks de la máquina ✓ (el CLI solo los pinta ✓) |
| `Candil.Telemetry` | las métricas de decisiones y calidad ✓ |
| `Candil.Preflight` | las comprobaciones previas a arrancar ✓ |

---

## 2 · Lo que NO es contrato

| Módulo | Por qué |
|---|---|
| `Candil.Engine.Resource` | la contabilidad interna de la VRAM ✓ |
| `Candil.Engine.Resource.Placement` | el semáforo de colocaciones ✓ |
| `Candil.Engine.Server.id_for/2` | una identidad interna del motor ✓ |
| `Candil.Engine.holder/2` | la identidad interna de una reserva ✓ |
| `Candil.Router.DecisionEngine` | la fachada pública es `Candil.Router` ✓ |
| `Candil.Scheduler.Devices` | la traducción de hardware a scheduler ✓ |
| `Candil.CLI.*` | **no es núcleo**: se va a su proyecto ✓ |

**Y los helpers `@doc false`**, clasificados uno a uno ✓ (segunda lectura
del consejero ✓):

| Helper | Decisión |
|---|---|
| `Candil.resolve_model_alias/1` | **interno** ✓ — lo usan la fachada y `Agent` ✓; el CLI no lo llama ✓ |
| `Candil.ensure_engine_running/2` | **interno** ✓ — es el camino de `Candil.chat/3` y `serve/1` ✓; el CLI usa `Candil.chat` ✓, `Candil.serve` ✓ o `Engine.start_placed/2` ✓ |
| `Candil.EnginePool.get/0` | **retirado** ✓ — está deprecado ✓, devuelve `:empty` ✓ y no es API ✓ |
| `Candil.Store.start_link/1` | **interno** ✓ — es el arranque de un GenServer ✓, no la API del catálogo ✓ |
| `Candil.Engine.Server.id_for/2` | **interno** ✓ (ya en §2 ✓) |
| `Candil.Engine.holder/2` | **interno** ✓ (ya en §2 ✓) |
| `Candil.Scheduler.instances/0` | **interno** ✓ — es una vista para tests ✓; el scheduler decide con `plan/1` ✓ |
| `Candil.Engine.Resource.device_name/1` | **interno** ✓ — `Resource` es interno ✓; que sea público para los tests ✓ no lo convierte en contrato ✓ |

**Y `Candil.Llm` deja de ser API** ✓: su `@moduledoc` dice que es la
implementación interna ✓ y el contrato decía lo contrario ✓. La corrección
tiene una consecuencia de código ✓: `Engine.start_placed/2` llama a
`Candil.Llm.stop_engine/1` ✓ (`engine.ex:439` ✓) → debe llamar a
`Candil.Engine.stop/1` ✓, que ya es público ✓, para que **el núcleo no
dependa de un módulo que declara interno** ✓.

**No se expone ninguno «porque el CLI lo necesita»** ✓. O es API con sus
docs ✓, o el CLI no lo usa ✓.

---

## 3 · `status` y `stop`: dos decisiones distintas

**`status` es CLI-only** ✓. Es una **vista de operador**: mezcla
`EnginePool.list/0` ✓, `Instances.read/0` ✓, `Engine.healthy?/1` ✓ y
`Devices.processes/0` ✓ → cuatro lecturas públicas ✓ (y `Devices.processes/0`
está en §1 ✓ **por eso** ✓: si no, el CLI extraído dependería de un módulo no
contractual ✓). **No añadir
`Candil.status/0`** ✓: congelaría la presentación en el núcleo ✓ — y la
presentación es justo lo que se va al otro proyecto ✓. La composición se
documenta aquí ✓ y el CLI nuevo la implementa ✓.

**`stop` es primitivo de núcleo, el comando es CLI** ✓. El primitivo es
**`Candil.Engine.stop/1`** ✓ — y solo ese ✓: `Llm.stop_engine/1` deja de ser API
✓ (§1 ✓), porque `Candil.Llm` es interno ✓. Lo que **no** es núcleo es
la parte de operador: parar todas ✓, las instancias detached ✓ y el TERM del
grupo de procesos ✓. **No hace falta un `Candil.stop/1`** mientras ningún
consumidor de librería lo pida ✓.

### El acoplamiento que bloquea la extracción

`Candil.CLI.Holder` usa `Engine.Server.id_for/2` ✓ y `Arrea.LongRunning.stop/1`
✓ — dos APIs internas ✓. Mientras eso siga así, el CLI depende del interior
del núcleo ✓ y **no se puede extraer** ✓. El arreglo: que el holder use
`Candil.Engine.stop/1` ✓, que ya es público ✓ y limpia el `EnginePool` ✓.

---

## 4 · Lo que este documento NO decide

- **Si `status`/`stop` necesitan un facade** ✓. Mi voto: no ✓, hasta que un
  consumidor de librería lo pida ✓.
- **Qué módulos exactos son públicos** ✓: la lista de arriba es la que usan el
  CLI y el núcleo de verdad ✓; falta la pasada completa por todos los
  `@moduledoc` y `@doc` ✓.
- **El alcance del 1.0** ✓: si entra la fase 6, 7, 9 y 10 ✓ o quedan fuera ✓
  (decisión del dueño ✓, en el
  [`CHECKPOINT-2026-10-22`](../CHECKPOINT-2026-10-22.md) ✓).
- **Qué se mueve al proyecto del CLI** ✓: la lista de módulos del §2 ✓, más el
  escript ✓, Alaja ✓, los renderers ✓ y el workflow de terminal ✓.
