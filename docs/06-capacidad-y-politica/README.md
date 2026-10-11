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

## 4 · Lo que NO está decidido, y por qué no lo decido

**Cuando algo está ocupado y no cabe de ninguna manera, ¿qué hace Candil?**

Tres salidas, las tres defendibles:

1. **Falla**, con el motivo con números que ya sabe dar.
2. **Espera** — y el pinado se queda esperando para siempre, bloqueando a los
   demás.
3. **Degrada** — suelta lo ocupado y prueba con el siguiente candidato que quepa.

Y la misma pregunta tiene **dos respuestas distintas según el backend**, que es
justo lo que impide cerrarla:

- contra **una API remota**, fallar es lo único razonable: el proveedor no te
  va a guardar el sitio, y esperar solo multiplica la factura.
- contra **una GPU**, degradar es lo soñado y cuesta segundos de arranque.

> **Es una decisión del dueño, no una decisión de diseño.** Se deja escrita y
> abierta a propósito. Lo que **no** vale es un default silencioso: si no está
> escrito, cada sitio del código inventará su respuesta y acabaremos con
> cuatro comportamientos distintos.

Donde se escribirá, cuando se escriba, es en `Gateway.error_body/1` — que **ya sabe**
emitir `:no_models_for_consumer`, `:unknown_model`, `:unknown_engine` y
`:unknown_provider`, y hoy no tiene ninguna razón de escasez. El sitio existe y
está vacío.

---

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
