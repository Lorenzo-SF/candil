# Candil 4.0 — auditoría de fases

> Los 8 README de fase, corregidos, con **nivel de razonamiento por sub-tarea**
> y **capa de verificación en 4 capas** en cada uno.
>
> Fecha: 2026-10-03 · Revisión en `max`

---

## ⚠ Lo primero: tres cosas bloquean

| | Qué | Dónde |
|---|---|---|
| **A1** | La fase 9 implementa `2025-11-25`, que ya es **Legacy**. La revisión `Current` es `2026-07-28` y **eliminó el handshake `initialize`**, que es lo que la fase 9 llama "obligatorio". | `fase-9-README.md` §0 |
| **A2** | La fase 10 tiene **dos versiones incompatibles**: SQLite FTS5 + chunking por función, frente a memoria + chunker configurable. Ocho divergencias. | `fase-10-README.md` §0 |
| **A4** | "Cerrado a `main`" estaba en 6 documentos, contradiciendo la única disciplina del repo. | los 6 README, eliminada |

**A2 es el más grave**: un agente que lee el README y otro que lee el prompt
producen software distinto, y el que mergea primero bloquea al otro.

El detalle de los nueve hallazgos está en `00-INFORME-AUDITORIA.md`.

---

## Los ficheros

| Fichero | Fase | Estado | Nivel base |
|---|---|---|---|
| [`00-PROMPT-SESION-NUEVA.md`](00-PROMPT-SESION-NUEVA.md) | — | **prompt para pegar en la sesión nueva** | — |
| [`RETOMAR.md`](RETOMAR.md) | — | entrada de la sesión nueva | — |
| [`PLAN-EJECUCION.md`](PLAN-EJECUCION.md) | — | cómo se ejecuta cada fase | — |
| [`00-INFORME-AUDITORIA.md`](00-INFORME-AUDITORIA.md) | — | — | — |
| [`fase-2-README.md`](fase-2-README.md) | 2 — Engine/Model v2 + Build | **cerrada**, archivada | `high` |
| [`fase-5-README.md`](fase-5-README.md) | 5 — Doctor | **a medias** | `low` → `high` |
| [`fase-6-README.md`](fase-6-README.md) | 6 — Context compartido | pendiente | `high` → `max` |
| [`fase-7-README.md`](fase-7-README.md) | 7 — Router | pendiente | **`max`** |
| [`fase-8-README.md`](fase-8-README.md) | 8 — Gateway | pendiente | `high` → `max` |
| [`fase-9-README.md`](fase-9-README.md) | 9 — MCP | 🛑 **bloqueada** | `xhigh` → `max` |
| [`fase-10-README.md`](fase-10-README.md) | 10 — RAG | 🛑 **bloqueada** | `xhigh` → `max` |
| [`fase-11-README.md`](fase-11-README.md) | 11 — Consumidores + 4.0.0 | pendiente | `medium` → `max` |

---

## El mapa de razonamiento

```
F0  medium  │ max en H1 (valida el diseño entero)          [cerrada]
F1  medium  │ max en reanudación y checksum                [cerrada]
F2  high    │ max en decidir Installer vs reescribir        [cerrada]
F3  low     │ high en preflight y orden de flags            [cerrada]
F4  max     │ ─                                             [cerrada]
F5  low     │ high en --fix y en los tests                  [a medias]
F6  high    │ max en particionado y Builder
F7  max     │ ─
F8  high    │ max en auth + model de la red
F9  xhigh   │ max en la revisión del protocolo              🛑 bloqueada
F10 xhigh   │ max en RRF, chunker y resolver el diseño      🛑 bloqueada
F11 medium  │ max en borrar Posadero.LLM.Ropero
```

**Los `max` sin escalón** — donde la fase entera es el punto difícil: **F4** (matar
al dueño correcto), **F7** (decidir qué modelo responde), **F2.2** (la única
decisión no escrita del proyecto) y **F11.1** (la condición de posibilidad de
borrar el módulo).

**Las más baratas:** **F3** y **F5** tienen los mensajes literales en el documento
de diseño, y **11.3** son docs. Ahí un `max` es dinero tirado.

**El revisor siempre a `max`**, sin excepciones. Es la única tarea donde el nivel
base es el máximo, porque es la única donde el agente no puede estar calibrado
por haber escrito el módulo.

---

## Qué tiene cada README que no tenía

### 1. Nivel de razonamiento por sub-tarea

No un nivel por fase: **un nivel por sub-tarea, con el porqué**. Y la regla de
escalada de cada una.

El razonamiento de fondo: el freeze de contratos de la fase −1 bajó todos los
niveles. El agente no diseña, implementa contra un contrato verificado. **Diseñar
costaría `max`; implementar lo diseñado cuesta `medium`.** Los `max` que quedan
son los que el freeze no pudo congelar porque no son código.

### 2. Verificación en 4 capas

En todas las fases:

| Capa | Qué es |
|---|---|
| **1 · Los ocho gates** | compilación, formato, credo strict, tests, dialyzer, docs, hex.audit, deps.unlock |
| **2 · Qué tiene que pasar al ejecutar** | tabla de test por test: **qué tiene que ocurrir** y **qué NO puede ocurrir** |
| **3 · Revisión manual del código** | lo que no hay linter que detecte. El `grep` que hay que correr, la línea que hay que leer |
| **4 · La prueba funcional** | el comportamiento de verdad, contra el criterio de aceptación |

La capa 2 es la que faltaba: los documentos tenían "estos tests tienen que pasar",
que es el *qué*, sin el **qué no puede pasar** que es donde están los fallos que
se cuelan.

La capa 3 es la que más valor da. Ejemplos de lo que ahora hay que mirar a mano:

- fase 6: `grep System.os_time lib/candil/context/` → si aparece, es un bug de TTL
- fase 8: `grep "String.to_atom" lib/candil/gateway/` → 0
- fase 9: la revisión se compara como **cadena**, no como tupla
- fase 10: el RRF **combina ranks**, no suma scores

### 3. Las trampas del entorno

La fase 5 tenía ocho, y son las que más tiempo ahorran. Ahora **las tienen todas**
las que las necesitan, porque todas corren en el mismo sandbox:

- `Config` es un módulo de Elixir → `UndefinedFunctionError`
- `System.pid/0` devuelve tres tipos distintos según la versión de OTP
- `Enum.filter/2` devuelve los elementos **originales**, no lo que devolvió la función
- `Map.update/4` es (map, key, default, fun) — el default va en tercer lugar
- `Process.alive?/1` toma un pid de ERLANG, no del SO
- Los procesos en background no sobreviven a la llamada de bash
- `/opt`, `/usr` y `/root` desaparecen en cada reinicio; solo sobrevive `/workspace`
- `CANDIL_DATA_DIR=<tmp>` para todo test que toque disco

### 4. Qué hacer si el bloqueante no está resuelto

Ninguna fase lo decía. Ahora cada una tiene su sección §0: qué tiene que estar
mergeado antes de abrir la rama, y qué hacer si no lo está (**para**).

Y la instrucción de honestidad: **si el criterio no se ejecutó porque el sandbox
no lo permite, dilo en el `deliverable.md`.** Un `deliverable.md` que dice
"criterio ejecutado" cuando se ejecutó el unitario con un embedder falso está
mintiendo, y el siguiente agente lo va a dar por bueno.

---

## Lo que no he tocado

**El plan de diseño.** `candil-4.0-final.md` es un documento excelente: los ocho
bugs verificados uno a uno, los hallazgos que cambian el diseño con su
consecuencia, los criterios de aceptación ejecutables, y las reglas duras con su
número. No hay nada que arreglar ahí.

**La fase 5.** Es el mejor documento del conjunto y el que usé de plantilla para
los otros siete. Solo se le corrigieron la referencia de tests desactualizada y
se le añadió `CANDIL_DATA_DIR`.

Y tres cosas que no había visto en ningún sitio y que están bien:

- El criterio de la fase 8 con un cliente OpenAI **de PyPI**, no un test propio.
- La fase 9 razonando sobre por qué **NO** las cosas, y explica que es "la
  razón de ser del atom factory".
- La nota operativa de las fases 9 y 10: *"Esta fase con 4 equipos no cabe en 30
  minutos. Ya se intentó y el plan no entregó."* Reconocer un intento fallido en el
  propio documento es raro y ahorra repetirlo.

---

## Cómo se ejecuta (añadido el 2026-10-03)

El modelo de ejecución es **una sesión principal, secuencial, en `mcode`**, una
fase por fase. Ver [`PLAN-EJECUCION.md`](PLAN-EJECUCION.md).

- El nivel de razonamiento se cambia **por sub-tarea** con `/model`, que verificado
  cambia modelo **y** effort. El modelo **no** puede autoajustarse a mitad de
  respuesta: el ajuste es entre turnos, y por eso la unidad es la sub-tarea.
- Cada fase lleva su tabla de sub-tarea → nivel → verificación, y el ciclo
  completo: `main` → `pull --ff-only` → rama → implementar la fase entera →
  verificar → push → PR → **merge a `main`** → cerrar el ciclo.
- Las 4 capas de verificación (L1 estático, L2 análisis, L3 test, L4 funcional) y
  la regla de que **la aserción negativa es la que importa**.

Cada `fase-*-README.md` tiene su sección **"Cómo se ejecuta esta fase"** al final
con su tabla propia.

> **Para retomar:** pega el bloque de
> [`00-PROMPT-SESION-NUEVA.md`](00-PROMPT-SESION-NUEVA.md) en la sesión nueva.
> Los demás son referencia.

---

## Contenido del paquete

| Carpeta | Qué |
|---|---|
| *(raíz)* | el prompt de entrada, el protocolo de ejecución, el informe de auditoría, y los 8 README de fase corregidos |
| `v4.1/` | las 10 enmiendas al diseño y el análisis de dependencias |
| `ORIGINAL/` | **los documentos sin tocar**, para comparar. Incluye el diseño de 3.000 líneas, el plan de ventana paralela, y los 8 README en su estado previo |

`ORIGINAL/` está para que puedas ver qué cambió. **El diseño de Candil 4.0 está
cerrado y no se toca**: las enmiendas de `v4.1/` son adiciones, y solo dos tocan
fases ya cerradas (F2 y F4), como verificación.
