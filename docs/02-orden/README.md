# 02 · Orden — la secuencia y sus dependencias

> Este bloque es la bisagra. Los otros explican **qué** se construye; este
> explica **en qué orden** y **por qué en ese orden**.
>
> **Medido el**: 2026-10-11 · `main` `e6c4367`
>
> ⚠️ **Renumerado el 2026-10-11.** El orden anterior ponía la 8b · Scheduler
> como fase 3 y el Gateway como fase 4, y eso dragaba cuatro fases hacia el
> trabajo local sin decirlo. El motivo del cambio, con las mediciones que lo
> sostienen, está en [`06-capacidad-y-politica`](../06-capacidad-y-politica/README.md) §1.
> Lo que se aparca está en [`07-local-aparcado`](../07-local-aparcado/).

---

## 1 · La regla del orden

No se ordena por dificultad. Se ordena por **lo que tiene que existir antes que
lo demás**.

Un componente cuyo prerrequisito no existe no es «una fase difícil»: es una fase
que **no se puede empezar**. Esto pasó con `Arrea.Agent`: no era difícil, era
**imposible** —el behaviour estaba en el repo hermano— y por eso **D-13 lo trajo a
Candil** (2026-10-16): ya no hay repo hermano de por medio.

Y pasó otra vez, y esa con más consecuencias: **el scheduler se puso antes que
la política**, cuando la política es la que decide qué hace el scheduler. Y la
capacidad se dio por 16 GB cuando en realidad es **lo que diga el hardware que
haya**, que es justo lo que nadie preguntaba.

---

## 2 · La dependencia que lo ordena todo

```
   ┌──────────────────────────────────────────────┐
   │ El ENRUTADO: qué modelo, y con qué certeza   │
   │ Scorer :rule escrito · :embedding y :llm no  │
   └──────────────────────────────────────────────┘
            ▲
            │ necesita saber                     │ necesita
            │ cuánto pesa cada destino            │ quién va primero
   ┌────────┴─────────┐        ┌──────────────────┴─────────┐
   │ La CAPACIDAD      │        │ La POLÍTICA                │
   │ ¿cabe? ¿en qué   │        │ one_for_all / rest_for_one │
   │ unidad?           │        │ one_for_one (defecto)      │
   └────────┬─────────┘        └──────────────────────────┘
            │                          │
            └────────┬─────────────────┘
                     ▼
              El REFUSAL: por qué no
              tres tipos · tres unidades
                     │
            ┌────────┴─────────┐
            ▼                  ▼
       MCP · RAG            El GATEWAY
       mesa camilla         `candil serve`
```

**El enrutado va primero porque es el producto**, y porque las dos capas de
debajo son las que hoy están a medias. Un enrutado que solo sabe rules y caché
—que es exactamente el estado medido— no tiene nada que ordenar.

---

## 3 · Las fases, y qué bloquea a qué

| # | Fase | Prerrequisito | Qué desbloquea | |
|---|---|---|---|---|
| **0** | Probar lo que existe sin probar | — | **Todo.** Convierte afirmaciones en hechos | ✅ |
| **1** | Los behaviours que faltan | 0 | RAG, provider, router configurable | ✅ |
| **2** | `Arrea.Resource` (la forma de una capacidad) | — | La política; y es lo que usa la scheduler | ✅ |
| **3** | **El enrutado: las capas que faltan** | 1, 2 | Que el enrutado elija por significado y no solo por regla | ✅ |
| **4** | **La política: quién va primero** | 3 | Que varios compitan por un destino y no se estorben | ✅ **mergeada y medida** (§2.1 de la deuda); `rest_for_one` no está, a propósito (P-3) |
| **5** | **El refusal, en los tres tipos** | 4 | Que un "no" diga qué corregir | 🟡 |
| **6** | RAG | 1 | La mesa camilla | ⬜ |
| **7** | MCP | 1, 4 | Herramientas para cualquier agente | ⬜ |
| **8** | **Gateway** `candil serve` | 3, 5 | Que otro proceso use Candil sin escribir Elixir | ✅ **cerrada el 2026-10-16**: el comando existe y sirve, medido con `curl` |
| **9** | Mesa camilla | 4, 6 | Agentes con memoria compartida | ⬜ |
| **10** | **Agentes** — el behaviour y el bucle, en Candil (D-13) | 4 | Agentes | ⬜ |
| **11** | `candil stats` | 4 | Saber si está funcionando | ✅ |
| **12** | El CLI entero | 8 | — | ⬜ |

> **Lo que dicen los amarillos, medido el 2026-10-16** (ver
> [`09-deuda-y-pendientes`](../09-deuda-y-pendientes/README.md) §5): la **5**
> tiene `:fail` (el defecto, con `Retry-After`) y `:wait` escritos, y `:degrade`
> no es alcanzable y no bloquea nada. La **8** ya no es un amarillo: existía
> todo menos el comando, el comando se escribió, y por el camino salió que **la
> auth no estaba enchufada al pipeline** —un `auth = api_key` contestaba 200 sin
> credencial— y se arregló. La **11** existe y corre, pero hasta ayer reventaba
> al invocarlo: existía en el papel y no en el terminal.

**La 8b · Scheduler no está en esta tabla.** Está aparcada, con lo que hay
medido y lo que falta, en [`07-local-aparcado`](../07-local-aparcado/). Volvería
cuando el enrutado y la política estén, porque **para entonces ya no es lo
siguiente: es una extensión.**

**La 10 cambió de sitio con D-13 (2026-10-16)**: el behaviour nace en Candil — a
Arrea solo sube lo que Arrea usa para sí o lo que piden dos consumidores. Lo que
en la tabla era «`Arrea.Agent` (en Arrea)» ya no es una fase con dos repositorios:
se cierra aquí.

### Qué cambió y por qué, en una línea

| Antes | Ahora | Por qué |
|---|---|---|
| 3 · 8b Scheduler (local) | **3 · el enrutado** | la scheduler es una extensión; el enrutado es el producto |
| 4 · 8a Gateway | **8 · Gateway** | un gateway sin enrutado expone una respuesta que siempre es la misma |
| — | **+ 3, 4 y 5: enrutado, política, refusal** | no estaban, y son el producto |

### El gateway se mueve al 8 y no es un castigo

El módulo **ya está escrito** —`gateway.ex`, `gateway/endpoint.ex`,
`gateway/auth.ex`—, y desde el 2026-10-16 también el comando que lo arranca
(`candil serve`); el control de concurrencia es `Policy.run/3`, que ya estaba y
es por donde pasa el chat. Se movió al 8 porque **va justo detrás de lo que
tiene que servir**: un gateway montado antes del enrutado expone una respuesta
que no cambia, y eso no se nota hasta que alguien lo usa y se queja.

---

## 4 · Por qué la 0 va primero, y sigue siendo la más barata

Porque **cambia el orden de todo lo demás**, y de eso hay tres ejemplos ya
medidos, todos de la última semana:

1. El refusal de VRAM **no existía** y nadie se había dado cuenta.
2. La cola **servía la prioridad del revés** y su `@moduledoc` decía lo
   contrario — y el test que lo tapaba **no comprobaba la prioridad**.
3. `candil status` **no sabe qué GPUs hay**: la columna `SLOT` se deduce del
   número de puerto.

Ninguno de los tres lo habría visto un test unitario. Los tres salieron de
mirar el código con lo que el `@doc` prometía al lado.

---

## 5 · Qué se puede hacer en paralelo, y qué no

| Se puede en paralelo | No se puede en paralelo |
|---|---|
| Fase 0 con la documentación de módulos | El enrutado y la política: la política decide para el enrutado |
| Los documentos de los módulos 3, 4 y 5 | El refusal y la política: uno define las razones del otro |
| RAG (6) con la política (4) | El CLI y cualquier otra cosa |
| Todo lo local aparcado, si algún día vuelve | El Gateway y el CLI: el CLI lo usa |

**Un carril de código, varios de documentación.** La documentación se escribe
en paralelo porque no se toca; el código, no, porque casi todo acaba tocando el
mismo `Store` y el mismo `Router`.

---

## 6 · La decisión que estaba abierta, y ya está escrita

**Cuando algo está ocupado y no cabe de ninguna manera, ¿qué hace Candil?**
Falla, espera, o degrada.

Estaba sin escribir a propósito, y era del dueño — y el dueño la decidió: **D-09
(2026-10-11)**, configurable, y las tres son válidas. El defecto es **`:fail`**,
y no por gusto: medido el 2026-10-14, con `wait` la suite del router tardaba
60,3 s y con `fail` 0,3 s, porque esperar no hace aparecer un modelo que no
está. Lo que **no** vale sigue siendo un default silencioso, y no lo hay: la
decisión, sus números y su porqué están en `Candil.Refusal`.

---

## 7 · Lo que este documento NO decide

| | |
|---|---|
| **Cuánto cuesta cada fase** | En sesiones, no en días. El calendario depende del paralelismo, que es tuyo |
| **La política de reparto** | Está escrita en `06-capacidad-y-politica`, y su *defecto* está decidido: el aburrido |
| **El refusal** | **Ya no**: D-09 lo decidió el 2026-10-11 (`fail` por defecto, configurable) y `Candil.Refusal` lo tiene escrito |
| **La frontera con Arrea** | **Ya no**: D-13 (2026-10-16) la escribe — a Arrea sube lo que Arrea usa o lo que piden dos; el behaviour de agentes nace en Candil |

> Y una cosa que este documento no puede resolver y conviene decir: el plan
> anterior estimaba 57-67 días de contenido. Eso era para once fases de
> «Candil tiene X». Este plan tiene doce, con una política y un refusal que no
> estaban. **Preferimos no reestimar sin haber medido la fase 3**, porque una
> estimación hecha sin ella es una suposición con decimales.
