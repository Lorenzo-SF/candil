# 06 · La capacidad, y quién va primero

> Este bloque responde a una sola pregunta, y es la que el plan anterior daba
> por resuelta sin haberla escrito: **cuando dos peticiones quieren lo mismo y
> solo cabe una, ¿qué pasa?**
>
> Se ha escrito después de medir cuatro cosas el 2026-10-10, y las cuatro
> importan.

---

## 1 · El centro de gravedad, en una frase

> **El centro de gravedad de Candil es el enrutado. La inferencia local es un
> backend más.**

Y no es una frase de adorno: está medido.

| Medición | Resultado |
|---|---|
| `DISENO-MOTOR.md` — el diseño del motor de decisión — menciones de `vram`/`gpu`/`cuda`/`device`/`engine` | **0** |
| …menciones de `provider`/`remote`/`latency`/`precio` | 2 |
| Tipos de destino que el router ya distingue | `:local`, `:remote`, `:external` (`Model.model_type/0`) |
| Módulos que deciden, y que no saben qué es una GPU | `DecisionEngine`, `Scorer`, `Classifier`, `Consumer`, `Cache` |

**El cerebro no tiene conceptos de GPU. Cero.** La GPU entra por debajo, en los
backends, que es donde tiene que estar.

### Por qué hay que decirlo

Porque el orden de fases anterior lo contradecía sin decirlo. Las cuatro
primeras fases eran, todas, *que mi máquina funcione bien*. Un usuario que solo
llama a APIs se salta motores, builds, VRAM, scheduler y descubrimiento de
dispositivos: **justo lo que más esfuerzo había costado.**

Y hay un dato que no se puede mirar de otra forma: la **columna `SLOT` de
`candil status` no viene del hardware.**

```elixir
# lib/candil/cli/lifecycle.ex
defp slot(port), do: if(rem(port, 100) >= 90, do: "dGPU", else: "CPU")
```

Sale del **número de puerto**. Cualquier puerto acabado en `9x` es `dGPU` por
definición. No hay ningún campo `device` en el modelo. Y
`Candil.Detector.GPU` devuelve un átomo de backend y la versión del driver:
**no cuenta dispositivos ni pregunta por la VRAM** (esto se arregló el
2026-10-10, §4).

---

## 2 · La misma pregunta, tres respuestas distintas

Aquí está la tensión real, y por eso esto **no** puede ser "la política de la
GPU". Los tres tipos de destino hacen la misma pregunta y se contestan con
unidades distintas:

| | `:local` (embutido) | `:remote` (API) | `:external` |
|---|---|---|---|
| **lo que cuesta** | bytes de VRAM | euros y rpm | lo que diga quien lo expone |
| **cuánto tarda** | segundos al arrancar | milisegundos | depende |
| **cómo dice "no"** | no cabe | 429 | lo que diga |
| **se puede parar a mitad** | sí, se descarga | no | no |
| **quién es exclusivo** | la GPU | la cuota | lo que sea |

Misma **forma**, distintas **unidades**. Y esa forma es la que hay que diseñar
una vez, no tres.

### La forma, que ya está escrita

`Arrea.Resource` (Arrea 4.0.0) es exactamente esa forma, y su `@moduledoc`
**no dice GPU ni una vez**:

- **capacidad** — en *units*. No en bytes. El byte es una unidad, no *la*
  unidad.
- **identidad por titular** — `release/2` devuelve la reserva de *ese* titular,
  con `===` y no `==` (en Erlang `1 == 1.0` es verdad).
- **un motivo con números** — `requested`, `available`, `capacity`. Un átomo
  pelado no le dice a un router qué tiene que arreglar.

Y es **exactamente lo que necesita un proveedor remoto**, con las unidades
cambiadas: la cuota es una capacidad, la identidad es el `api_key`, y el motivo
sigue siendo un motivo con números.

### La lección del `N/A`, que aplica aquí

NVIDIA imprime `N/A` cuando un atributo no está soportado. Las dos salidas
fáciles son las dos peores:

- si `N/A` se convierte en `0`, el planificador cree que hay 0 libres y dice
  *«no cabe»* **con un número inventado**;
- si se convierte en el total, cree que hay sitio y **lanza un modelo que no
  entra**.

Un `0` y un `total` son los dos extremos del mismo fallo: **decir con seguridad
algo que no se sabe.** Por eso `Candil.Detector.Devices` devuelve un
dispositivo con `usable: false` y las cifras a `nil`, y por eso esa diferencia
está **en el tipo**: un planificador tiene que poder distinguir *«no hay sitio»*
de *«no lo sé»*, y eso no puede depender de la cabeza de quien lee el mapa.

---

## 3 · Los modos, con nombre de supervisor

La pregunta es: *entre los que esperan, ¿quién sigue?* Y hay **tres** respuestas
que merecen nombre propio. Se llaman como los estrategias de un supervisor
porque Candil lo usa quien escribe Elixir, y porque son disjuntas: nadie tiene
que elegir entre "FIFO" y "FIFO pero pinado".

| Modo | Qué garantiza | Cuándo |
|---|---|---|
| **`one_for_all`** | el que entra entra **para todos**: nadie más hasta que sale | el destino es exclusivo y caro (una GPU) |
| **`rest_for_one`** | el que entra, al salir, **vuelve al final**: primero pasan todos los que quedan | varios compiten y nadie debe monopolizar |
| **`one_for_one`** | el que entra **no molesta a nadie**: no hay turno | el destino no es exclusivo (una API) |

### El defecto tiene que ser el aburrido

**`one_for_one`.** Sin cola.

Y esto no es solo que sea lo más seguro: es que **el camino caliente no pasa por
el planificador**. El usuario que solo llama a APIs —y el que llama a un modelo
local cuando la GPU está libre— nunca ve una cola. La política existe, pero es
una extensión para cuando el recurso **sí** es exclusivo.

Un defecto "inteligente" rompe a alguien el primer día y no lo vuelve a tocar.

### El pin es una excepción por petición, no un modo

`model: "coder"` en una petición, o `--model` en la CLI, es un **override** que
funciona por encima de los tres modos. Si se metiera como un cuarto modo,
tendríamos cuatro opciones donde tres se contradicen, que es exactamente la
trampa de los *settings* que nadie entiende.

> Ya está escrito, además, en el `@moduledoc` del gateway: *"a router you
> cannot bypass is a router whose mistakes you cannot work around"*. Una
> petición que nombra un modelo se salta el router entero.

### Y un eje que no es un eje

`Candil.Router` ya tiene siete estrategias de elección —`:cache`, `:rule`,
`:embedding`, `:llm`, `:default`, `:pinned`, `:forced`— y eso es **otro eje**:
*cómo elijo modelo*. El de este documento es *en qué orden atiende el destino*.

Son ortogonales y no deben mezclarse. `one_for_all` no dice a qué modelo vas;
dice quién entra primero cuando todos quieren el mismo.

---

## 4 · El refusal, y la decisión que lo cierra

> **DECIDIDO por el dueno el 2026-10-11.** Antes estaba abierto; ya no.

### Lo que NO era esta pregunta

No era *"¿qué pasa si no hay candidato?"*, porque **eso ya esta resuelto**:

- `Router.Consumer` tiene tres niveles de busqueda, y el tercero es
  **`model_default`**. El **schema lo exige**: un `[consumer.X]` sin
  `model_default` **no valida**, y el TOML falla al arrancar.
- Sin candidatos, `{:error, :no_models_for_consumer}`.

Esa parte estaba hecha y funcionando desde antes. Se(documento aqui porque
esta escrito en otro sitio y asi se lee.

### La pregunta de verdad

Cuando el destino **existe y esta ocupado**, y no cabe de ninguna manera —la
GPU llena, la cuota del proveedor agotada, el limite de concurrencia— **que
hace Candil?**

> **Es una decision del desarrollador, y las tres son validas.** No se elige
> una sola para todos: se configura.

| Valor | Que hace | Cuando |
|---|---|---|
| **`fail`** | contesta el motivo con numeros, sin esperar | cuando esperar cuesta mas que fallar: un proveedor remoto cobra igual |
| **`wait`** | encola, con la politica de turno de §3 | cuando el recurso se libera solo y vale la pena esperar |
| **`degrade`** | suelta lo ocupado y prueba con el siguiente candidato que quepa | cuando hay candidatos alternativos y la espera no cabe en el timeout del cliente |

**Todas son factibles y las tres estan probadas mentalmente contra el mismo
caso**, asi que la eleccion no es tecnica: es de política del proyecto de quien
lo usa. Un desarrollador que factura por rpm quiere `fail`; uno con una GPU local
quiere `degrade`; un servicio con varios consumidores identicos quiere `wait`.

> **Estado (fase 5, cerrada el 2026-10-17):** `fail` y `wait` están
> construidos, probados **y entregados al cliente HTTP** (503 + `Retry-After`,
> ver abajo). **`degrade` no es alcanzable todavía**: servir con otro modelo
> «que cubra lo mismo» exige saber qué pide la pregunta (enrutado por
> cobertura) y hoy no existe. Configurarlo revienta con un `ArgumentError` que
> lo dice con esas palabras. El porqué completo, y con qué condiciones se
> retomaría, está en [`09-deuda-y-pendientes`](../09-deuda-y-pendientes/README.md)
> §5 (P-1).

### Y dos reglas que el valor no puede cambiar

1. **Ninguna puede devolver un modelo vetado.** Un rechazo de recursos que
   devuelve un modelo que no debe recibir eso es un fallo de seguridad, no una
   politica.
2. **`fail` nunca miente con numeros.** O sale el motivo con `requested`,
   `available` y `capacity`, o sale la razon de que **no se sabe** — que es lo
   que hace `Detector.Devices` con un `usable: false`. Un `-1` que significa
   "no lo sé" y un `0` que significa "no hay" son el mismo bug.

### Donde se comprueba

**Hecho en la fase 5 (cerrada el 2026-10-17).** El refusal lo construye
`Candil.Refusal` —con la estrategia decidida y el `retry_after` dentro del
error— y el gateway lo entrega con los números que ese contexto ya traía:

| Pieza | Donde | Qué |
|---|---|---|
| El motivo y el número | `Candil.Refusal.apply/5` | `{:error, %Candil.Error{reason: :no_capacity, context: %{reason_origen, retry_after, message}}}` |
| El status | `Candil.Gateway.Handlers.status_for/1` | **503** — el propio `Error.no_capacity/2` decía «esto es un 503», y hasta la fase 5 caía en el 500 genérico |
| El `Retry-After` | `Candil.Gateway.Handlers.reason/2` | en **segundos** (RFC 9110), redondeando hacia arriba |
| `:no_capacity` | `@type reason` de `Candil.Error` | estaba fuera del tipo y se añadió aquí |

Y la puerta se prueba de verdad, por HTTP: en
`test/candil/gateway/end_to_end_test.exs` hay un gateway **sin candidatos** y
su petición recibe **503 + `Retry-After: 30`** con el motivo de escasez dentro.
Lo que queda **sin solución** —`:degrade`— no se esconde: ver arriba y P-1.

## 5 · El sitio donde se comprueba

El `Gateway` **ya está escrito** (`lib/candil/gateway.ex`, `gateway/endpoint.ex`,
`gateway/auth.ex`): un servidor compatible con la API de OpenAI. Su `@moduledoc`
dice para qué sirve —*"esto es lo que hace que Candil sea usable sin escribir
Elixir"*.

**No tiene ningún control de concurrencia.** Cero referencias a cola, a
semáforo, a `Bulkhead`, a nada.

Y eso es lo que hace que esta fase y la del gateway sean la misma: **un
cliente HTTP que recibe un rechazo no se rinde, reintenta**, y cinco rechazos
seguidos son una tormenta de reintentos. En local te dice "no" y ya está. Por
eso un gateway necesita cola, y por eso la necesita **antes de abrir el
puerto**.

---

## 6 · Lo que este bloque NO hace

- **No conoce GPUs.** Ni de nombre. `Arrea.Resource` no dice GPU; esto tampoco.
- **No conoce proveedores.** Cuesta euros y rpm, no bytes. La misma forma.
- **No decide qué modelo.** Eso es el enrutado ([`04-modulos/01-routing-y-ciclo-vida/`](../04-modulos/01-routing-y-ciclo-vida/)).
- **No persiste nada.** `instances.json` es de Candil, no de Arrea, y aquí no.
