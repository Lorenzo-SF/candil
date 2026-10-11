# 07 · El trabajo local, aparcado

> **Esto no está cancelado. Está aparcado, con lo que hay medido y lo que
> falta.** Se conserva para que la decisión se tome con el dato delante y no
> desde el olvido.
>
> Estado a 2026-10-11 · `main` de Candil `e6c4367` · Arrea `4.0.0`

---

## 1 · Por qué se aparca

No porque el trabajo local sea malo, sino porque **el plan lo puso delante sin
decir que era opcional**, y arrastró cuatro fases enteras. La frase que faltaba
está en [`06-capacidad-y-politica`](../06-capacidad-y-politica/README.md) §1:
*el centro de gravedad es el enrutado; la inferencia local es un backend más*.

Un usuario que solo llama a APIs **no se salta el enrutado, y sí se salta
todo esto.** Que se lo salte es correcto; que el plan no lo dijera, no.

---

## 2 · Lo que ya está hecho y medido

Nada de esto se tira. Es real, está en `main` y en Hex.

| Pieza | Dónde | Qué es |
|---|---|---|
| `Arrea.Resource` | Arrea 4.0.0 | capacidad, identidad por titular, motivo con números, dos ejes (`capacity` entera, `quota` decimal) |
| `Arrea.Worker.request/4` | Arrea 4.0.0 | RPC dirigido sobre la cola, que es lo que necesita la fase de agentes |
| Orden de prioridad de la cola | Arrea 4.0.0 | **corregido**: antes servía la prioridad más baja y el `@moduledoc` decía lo contrario |
| `Candil.Detector.Devices` | Candil `e6c4367` | **cuántas GPUs hay y cuánta VRAM cada una** |
| `Arrea.Bulkhead` ponderado | Arrea 3.1.0 | capacidad con peso, con un ejemplo de GPU en su `@moduledoc` |
| Motores, arranque, descarga | Candil | `Engine`, `Engine.Server`, launcher, `Holder` — 2.327 líneas |

### Y dos bugs que encontró este trabajo, que no eran de la fase 2

- **La cola servía la prioridad del revés.** `:gb_trees` ordena ascendente y la
  clave era `{priority, sequence}`. El `@moduledoc` decía "Higher runs first"
  dos veces. **El test que lo tapaba se llamaba "la prioridad manda" y no
  comprobaba la prioridad**: reclamaba tres entradas a una variable que no
  volvía a mirar.
- **La suite escribía en el `~/.candil` del developer.** `Candil.Instances`
  escribe un `instances.json` en disco y varios tests no ponían
  `CANDIL_DATA_DIR`. En CI, donde no hay un home previo, eso puso cuatro tests
  de `cli_test.exs` en rojo con una instancia que nadie había creado.

Ninguno de los dos era de GPU. Los dos eran de **cola** y de **aislamiento**, y
los dos valen para todo el mundo. Eso es parte de la razón de que este trabajo
no se haya perdido: la parte que salió de aquí no es local.

---

## 3 · Lo que falta, y por qué no se ha hecho

La fase que se aparcó se llamaba **8b · Scheduler**: cola, eviction, VRAM en GB.

Y aquí está lo que se sabe de ella, con lo que ya se sabe:

### El scheduler tiene dos capas, y solo se había planeado una

- **Colocación**: dado un conjunto de dispositivos libres, ¿dónde va este
  modelo? Con dos GPUs es un problema de **empaquetado**, no de expulsión: 12 GB
  + 12 GB en 16 + 16 es que **cabe entero y no se expulsa nada**.
- **Expulsión**: cuando no cabe en ninguna, ¿qué sale?

El plan de la 8b hablaba casi solo de expulsión. Y con una sola GPU la
expulsión es constante; con dos es rara. **La política depende de la topología,
así que no puede ser una constante.**

### La capacidad no era 16 GB

Era un supuesto mío, y era falso. **La capacidad es lo que diga el hardware
que haya.** Eso es lo que resuelve `Detector.Devices`, y por eso va antes que
cualquier política: sin ella, "qué motor se queda" no tiene respuesta.

### Y la regla que queda escrita, porque no se puede decidir aquí

1. **Si cabe, no se toca nada.** Nunca expulsar por tener sitio libre.
2. **Si no cabe, la víctima más barata** — la que menos se usa y, a igualdad de
   antigüedad, **la más pequeña que haga falta** para dejar hueco. Un embedder de
   1,8 GB se repone en segundos; un coder de 12 GB, no.
3. **Nunca expulsar lo que está en uso ni lo que tiene un pin.**

Y **`rest_for_one` está descartado** para el caso local, por una razón concreta:
expulsa cuando toca, no cuando hace falta, y con 16 GB y esos tamaños
descargaría el coder mientras el embedder todavía cabía. Es la política correcta
para un pool de workers iguales; no para memoria con costes dispares.

---

## 4 · Lo que haría falta para retomarlo

En orden, y con lo que ya está hecho marcado:

1. ~~Saber qué hardware hay~~ → **hecho** (`Detector.Devices`).
2. **Un `Resource` por dispositivo.** El módulo ya lo soporta: es un pool
   *por nombre*, así que son `:cuda0`, `:cuda1`, con su capacidad cada uno.
3. **La colocación**, que es lo que falta de verdad. Al revés que la expulsión.
4. **La capa de señales**: para `:local`, *bytes y segundos de arranque*; para
   `:remote`, *euros y rpm*. La misma forma, distintas unidades.
5. **El eviction** según las tres reglas de arriba.
6. **Un `candil status` que deje de fingir.** Hoy deduce la GPU del puerto.

---

## 5 · Y el trabajo que sí está fuera de aquí, en Arrea

Lo que **no** depende de Candil y ya está hecho y publicado en Arrea 4.0.0:

- `Arrea.Resource`, que es la forma de una capacidad y **no sabe qué es una
  GPU** (§2 de [`06-capacidad-y-politica`](../06-capacidad-y-politica/README.md)).
- `Arrea.Worker.request/4`, que es el RPC dirigido que necesitan los agentes.
- La cola con el orden de prioridad corregido.

**Esos tres no son trabajo local.** Son la infraestructura de la que usa
*cualquier* política, local o remota, y eso es exactamente por lo que se
sacaron de aquí en lugar de descartarse.

---

## 6 · La regla de este documento

Un componente aparcado **no es un componente borrado**, y tampoco es un componente
que se retoma por inercia.

Si vuelve al plan, vuelve **medido**: con lo que hay, lo que falta, y una razón
—no porque quede en el hueco de una fase que se movió.
