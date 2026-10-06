# Candil 4.0 — Visión, alcance real y choques

> **Qué es este documento.** No es una especificación: es lo que entendí de lo que
> quieres, escrito para poder estar en desacuerdo con puntos concretos. Si algo de
> aquí está mal entendido, se corrige con una frase y se arregla; si está bien
> entendido, sirve para decidir qué hacen las fases que quedan.
>
> **Fecha**: 2026-10-06 · **Rama**: `fase-7-router` · **Tests**: 800 + 27 doctests, 0 fallos

---

## 1. La tesis

Candil no es un cliente de LLM más o menos. Es la **capa de decisión y de servicio**
entre lo que pide un humano o un agente y los modelos que contestan.

Eso son tres cosas, y solo la primera existe:

1. **Decidir** a qué modelo va cada prompt — existe y está medida (`Candil.Router`, 800 tests).
2. **Servir** esa decisión — no existe. Nadie llama a `Candil.Router.route/2`.
3. **Aprender** de lo que ya decidió — no existe, y es lo más ambicioso de lo que describes.

**La prueba de que esto funciona no es un test.** Es: escribir los modelos en el
`candil.toml`, arrancar `candil serve`, y que el primer prompt vaya solo a donde
tiene que ir sin que nadie le diga. Eso, hoy, es imposible.

---

## 2. Los dos caminos

**El CLI** — `candil serve`, uno para todos, un OpenAI-compatible, apuntando a
opencode, claude code, codex y mcode. Es el camino de uso.

**La librería** — `Candil` como dependencia. Y aquí la visión es mucho más
ambiciosa que el CLI: gestor de proveedores y modelos, motor de decisiones,
infraestructura para RAG, para construir tus propios MCP, para construir y
gestionar tus propios agentes y automatizar tareas.

> **Los dos caminos son el mismo código.** El escript y la librería son el mismo
> build. Eso es una ventaja y una trampa: una cosa que se rompe en el CLI es un
> bug de librería que posadero va a heredar, y al revés.

---

## 3. Lo que ya existe, con nombre de módulo

| | | |
|---|---|---|
| Modelos, proveedores | `Candil.Store`, `Candil.Model` | carga del `candil.toml`, alias, gpu_layers |
| Motores (engines) | `Candil.Engine`, `Candil.EnginePool` | arrancar, parar, VRAM |
| Decisiones | `Candil.Router` + `DecisionEngine` | pin → force → rules → embeddings → LLM |
| Contexto | `Candil.Context` + `Builder` + `Summarizer` | por consumidor, TTL, LRU |
| Llamada | `Candil.Inference`, `Candil.Conversation` | `chat_local/3` con alias obligatorio |
| Diagnóstico | `Candil.Doctor` (Botica) | checks + `--fix` |
| CLI | `Candil.CLI` (Alaja) | 12 comandos, sin `ask` |

**Y el hueco, medido:** `grep -rn 'Router.route(' lib/` devuelve **cero** llamadas
fuera del CLI y sus propios tests. Hay un motor de decisiones entero y nadie lo
consulta.

---

## 4. Lo que falta

| | |
|---|---|
| `candil serve` | no existe |
| `candil ask` / chat por HTTP | no existe |
| Cola para modelos apagados | no existe |
| Línea de cajas / eviction por VRAM | no existe |
| Mesa camilla (contexto compartido entre sesiones) | no existe |
| `candil stats` | no existe |
| Logs de uso por modelo/proveedor | `Arrea` los tiene, nadie los conecta |
| MCP | solo un documento de decisión |
| RAG | solo un documento de decisión |
| Gestor de agentes | no existe |

---

## 5. Los tres choques — donde tu visión choca con lo ya construido

Aquí está lo que me cuesta decir, pero son las tres cosas que, si no se
resuelven **antes** de escribir código, se pagan después.

### 5.1 · La cola y la VX se contradicen — **esto es serio**

La fase 6, D8, decidió con medición que el reparto de tokens es **round-robin por
turno**: a la sesión que menos ha jugado le toca el siguiente turno. Nadie se
queda sin hablar nunca. Está medido y en verde: `partida` se puede starving.

Tu "línea de cajas como en el supermercado" es **exactamente lo contrario**: una
cola FIFO por orden de llegada, donde quien llega primero habla primero y quien
llega último **puede quedarse fuera** si no cabe.

Y tu pin es un **VIP que se salta la cola**.

No son dos detalles. Son tres políticas incompatibles sobre la misma pregunta:
*¿a quién le toca el motor que está ocupado?* Hoy Candil responde una. Tu visión
responde otras dos. Hay que elegir, y elegirlas bien es lo que define si Candil es
justo o si es un musical.

### 5.2 · La mesa camilla contradice el aislamiento de sesión — y va a doler

La fase 6 también **midió** que particionar por consumidor aísla de verdad: `:posadero`
y `:opencode` con la misma sesión no se pisan. Eso es lo que hace que 5 opencodes
en paralelo no se coman entre ellos.

Una mesa camilla —"contexto compartido que se va retroalimentando, con quién pide
qué y con qué pinned"— es **justo lo contrario**: que las sesiones **sí** se vean, y
a propósito.

Aquí no hay forma de tener las dos cosas sin decidir cuándo se comparte. La regla
que yo pondría: **el historial es privado, la memoria es común.** El RAG y los
patrones salen de la mesa; los mensajes, nunca.

### 5.3 · Sin eviction no hay línea de cajas, solo un OOM a los 40 minutos

Una cola solo funciona si lo que se queda detrás **se puede descargar**. Hoy los
motores se arrancan a mano y se paran a mano: no hay LRU de motor, ni bbox, ni nada
que decida que `coder` le ceda la GPU a `analyst`.

En una 5080 de 16 GB, con modelos que piden 20 GB cada uno, esto **no es un detalle
de implementación: es la condición de posibilidad.** Sin él, la línea de cajas es un
nombre bonito para "se queda sin memoria".

Y por eso la regla que propuse antes es la regla correcta: **que no arranque solo**.
Si el router elige algo que no está cargado, que lo diga con el comando al lado. Un
router que te carga veinte gigabytes sin avisar no parece magia, parece una avería.

---

## 6. Lo que cambia del plan

Fase 7 está casi cerrada y le queda un movimiento: **una decisión de consumer.** Ahora
hay dos consumidores que significan cosas distintas:

- el del **contexto** (`Context` particiona por él)
- el del **router** (`Consumer.candidates` lee sus modelos)

Y como una sesión "va a la vez a los dos", la fase 7 tiene que decidir si hay uno o
dos. Es un movimiento pequeño de código y una decisión de arquitectura.

**La fase 8 no es "el gateway".** Lo que describes son tres sistemas que comparten
una idea pero no una implementación:

- **8a — Gateway.** `candil serve`, OpenAI-compatible, api-key, url, port, flags de qué
  modelos usar y cuáles pinear.
- **8b — Scheduler.** La línea de cajas: qué motor se queda, cuál se apaga, qué
  cola, qué prioridad. **Esto incluye el eviction, que es la pieza de la que
  depende todo lo demás.**
- **8c — Mesa camilla.** El contexto compartido entre sesiones. El sistema más
  grande de los tres y el que más puede salir mal.

Después: **9 — MCP** (como herramienta, sin modelo, reutilizando 8a), **10 — RAG**,
**11 — Stats y logs**, y **12 — Agentes y automatización** para el camino de librería.

Miopinión: la 8b no es opcional ni pequeña, y es la que tiene que ir **antes** que la
8c. Una mesa camilla sobre una cola que no existe es un RAG, que ya es la fase 10.

---

## 7. Lo que necesito de ti

Cinco decisiones, en orden de urgencia. Las tres primeras cambian código; las otras
dos, solo el plan.

1. **¿Round-robin justo (lo que hay) o FIFO con VIP (lo que describes)?** Si es FIFO,
   hay que reescribir la política de reparto y sus tests. Es una decisión de la fase 8b.
2. **¿La mesa camilla comparte historial o solo memoria?** Mi propuesta es solo
   memoria. Pero es tu producto.
3. **¿Quién puede arrancar un motor automáticamente?** Mi propuesta: nadie, salvo
   `--load`. ¿O sí, y con un aviso de "esto va a tardar"?
4. **El límite por sesión, ¿sigue siendo por `consumer`?** Con 5 opencodes y un
   `consumer` cada uno, la memoria común de la mesa camilla es donde se va a
   decided. ¿Un `consumer` para todos los agentes, o uno por cliente?
5. **¿Dónde entra el camino de librería en las fases?** Hoy las 7–11 son de servidor.
   Si la librería es la ambición real, quizá el gestor de modelos y el motor de
   decisiones —que ya existen— deberían desacoplarse de "servir por HTTP" antes que
   después.

---

## 8. Una nota sobre el orden

Lo que has descrito tiene una tentación: hacerlo todo en un mega-hito de "candil
5.0 — el router inteligente". No lo recomiendo, y por una razón concreta.

La última vez que se juntó todo, la fase 6, salió con **diez bugs de arranque** que
no se veían leyendo el código. Lo que destapó la mesa camilla del router es que
**alguien ejecutó el binario en su máquina** y el binario mintió dos veces seguidas
(un pin que no existía, un `no_models_for_consumer` con siete modelos cargados). Los
tests no los encontraron; tú los encontraste corriendo.

La regla que funcionó la semana pasada es la de esta semana: **cada fase deja algo
que se puede ejecutar y ejecutar de verdad.** La mesa camilla sin cola es un
documento bonito. La cola sin eviction es un OOM delayed. Cada cosa va después de
la que la sostiene, y cada cosa se prueba en tu máquina, no en mi sandbox.
