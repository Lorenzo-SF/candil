# 02 · Orden — la secuencia y sus dependencias

> Este bloque es la bisagra. Los otros cinco explican **qué** se construye; este
> explica **en qué orden** y **por qué en ese orden**.
>
> **Medido el**: 2026-10-07 · rama `docs-v2`

---

## 1 · La regla del orden

No se ordena por dificultad. Se ordena por **lo que tiene que existir antes que
lo demás**.

Un componente cuyo prerrequisito no existe no es «una fase difícil»: es una fase
que **no se puede empezar**. Esto pasó esta semana con `Arrea.Agent`: no es
difícil, es imposible, porque el behaviour está en el repo hermano.

## 2 · La dependencia que lo ordena todo

```
   ┌──────────────────────────────────────────────┐
   │  8b · Scheduler: cola, eviction, VRAM en GB │
   │  ¿qué motor se queda? ¿qué se descarga?     │
   └──────────────────────────────────────────────┘
            ▲                          ▲
            │ necesita saber           │ necesita saber
            │ cuánto pesa              │ quién lo llama
            │ cada modelo              │
   ┌────────┴────────┐        ┌────────┴────────┐
   │ 8a · Gateway    │        │ Agentes         │
   │ candil serve    │        │ Arrea.Agent     │
   └────────┬────────┘        └────────┬────────┘
            │                          │
            └────────┬─────────────────┘
                     ▼
              MCP · RAG · mesa camilla
                     │
                     ▼
                 El CLI entero
```

**La 8b va primero porque todo lo demás se apoya en ella o la comparte.**

- El **gateway** sin scheduler enruta a un modelo que puede no estar arriba.
- Los **agentes** multi-modelo sin scheduler piden algo que no cabe en la GPU y
  nadie se lo dice.

## 3 · Las fases, y qué bloquea a qué

| # | Fase | Prerrequisito | Qué desbloquea |
|---|---|---|---|
| **0** | Probar lo que existe sin probar | — | **Todo.** Convierte afirmaciones en hechos |
| **1** | Los behaviours que faltan | 0 | RAG, provider, router configurable |
| **2** | `Arrea.Resource` (VRAM en GB) | — | La 8b |
| **3** | **8b · Scheduler** | 1, 2 | Gateway y agentes |
| **4** | **8a · Gateway** `candil serve` | 3 | MCP, y el mundo entero |
| **5** | `Arrea.Agent` (en Arrea) | 3 | Agentes |
| **6** | MCP | 1, 4 | Herramientas para cualquier agente |
| **7** | RAG | 1 | La mesa camilla |
| **8** | Mesa camilla | 3, 7 | Agentes con memoria compartida |
| **9** | `candil stats` | 3 | Saber si está funcionando |
| **10** | El CLI entero | 4 | — |

### Las dos reglas que no se negocian

**El CLI va el último.** Una fase no se cierra por `./candil algo`. Se cierra por
`mix run -e '…'`. El CLI es la **confirmación** de que todo cuelga, no el sitio
donde vive la lógica.

**La fase 0 va primero, y es la más barata.** Dos sesiones, y convierte
«proveedor externo: hecho» en «hecho **y comprobado**».

## 4 · Por qué la 0 va primero, y no es obvio

Porque **cambia el orden de todo lo demás**.

Ahora se dice «el RAG tiene los tipos y cinco stubs». Con la fase 0 hecha sabemos
**cuántos** son y si el camino que existe devuelve algo útil. Una fase que empieza
sin medir lo que hereda empieza a adivinar.

Y hay un motivo más fuerte: **la fase 0 es donde se descubre si `Candil.Agent`
funciona.** Si el `use Candil.Agent` no corre contra un modelo de verdad, el
módulo de agentes entero cambia de forma **antes** de haber escrito nada. Hoy
tiene cero usos fuera de sus propios tests.

## 5 · La fase 0, tarea a tarea

Cada una cabe en dos sesiones o menos. Y cada una tiene un criterio que **no es
un exit code**.

| | Qué | Criterio de verdad |
|---|---|---|
| **0.1** | **Proveedor externo** | Un `[provider.X]` del toml, un `chat_remote/4`, y una aserción sobre **el contenido de la respuesta**. Hoy tiene 2 usos en todo el suite |
| **0.2** | **`Candil.Agent` real** | Un agente con una herramienta de verdad, un modelo mockeado, y aserciones sobre el resultado. **Cero usos fuera de sus tests ahora** |
| **0.3** | **RAG mínimo** | Indexar un fichero real, recuperar, y comprobar que el chunk sale. Hoy hay tipos y cinco stubs |
| **0.4** | **Motores, encendidos** | El refusal de VRAM, con `mix run` y un modelo pequeño. **No es un test unitario: es una medición** |

> **0.4 es la que más información da y la más fácil de saltarse.** El refusal de
> VRAM es la decisión central de la 8b, y se decidió sin ejecutarla nunca.

### Y 0.1 es la más urgente

Porque toca el camino que **más se va a usar**. Un proveedor externo mal probado
es el fallo que aparece cuando alguien ya tiene Candil en producción.

## 6 · Qué se puede hacer en paralelo, y qué no

| Se puede en paralelo | No se puede en paralelo |
|---|---|
| Fase 0 con la fase 2 (`Arrea.Resource`, que es en Arrea) | La 8b y la 8a: la 8a depende de la 8b |
| Los documentos de los módulos 3, 4 y 5 | La 8b y los agentes: comparten el mismo `Arrea.Agent` |
| MCP y RAG, una vez hechos los behaviours | El CLI y cualquier otra cosa |

**Un carril de código, varios de documentación.** La documentación de los cinco
módulos se escribe en paralelo porque no se tocan; el código, no, porque casi
todo acaba tocando el mismo `Store` y el mismo `Router`.

## 7 · La decisión que rompe este orden

**El reparto del presupuesto entre sesiones.** Hoy es round-robin justo, medido,
en verde. La línea de cajas es FIFO con VIP. Son **tres** políticas incompatibles
sobre la misma pregunta: *¿a quién le toca el motor que está ocupado?*

Y esa decisión es la que hace que la 8b pueda empezar. **Sin ella, la 8b es una
cola sin criterio de orden**, y se construye y se tira.

## 8 · Lo que este documento NO decide

| | |
|---|---|
| **Cuánto cuesta cada fase** | En sesiones, no en días. El calendario depende del paralelismo, que es tuyo |
| **La política de reparto** | Es decisión del dueño del producto. Está marcada, no resuelta |
| **El orden dentro de un módulo** | Lo dice cada módulo en su bloque. Este dice el orden **entre** módulos |

Y hay una cosa que este documento no puede resolver y conviene decir: **el plan
anterior estimaba 57-67 días de contenido.** Eso era para once fases de «Candil
tiene X». Las fases de aquí incluyen una librería de agentes y una mesa de
contexto compartido, y **el número no aplica**. Prefiero no reestimar sin haber
medido la fase 0, porque una estimación hecha sin ella es una suposición con
decimales.
