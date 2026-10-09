# El motor de decisiones · el diseño cerrado

> Documento de diseño. Va **antes** de escribir código, y es la referencia de
> la fase que rehace el motor de decisiones.
>
> **Fecha**: 2026-10-07 · rama `docs-v2` · Arrea ya tiene `Queue` y el
> bulkhead con peso (`ffd1314`)
>
> Este es el diseño que cerramos. Lo que hay hoy en `lib/candil/router/` es un
> `Scorer` con un mapa de palabras clave en un `@rules` de módulo. Esto lo
> sustituye. No es un plan: es la forma.
---

## 1 · Qué lo hace tener tres entradas

Hoy el motor decide con **dos**: los mensajes del prompt, y a quién se le
atribuye. Y de ahí sale un modelo.

Un sistema al que le pasa eso se rompe en cuanto hay un catálogo de modelos
real. Y el catálogo de este proyecto son siete, en una RTX 5080 de 16 GB, con
sus `.gguf`, sus motores y sus puertos. Las piezas que un motor de decisiones
necesita y que **hoy no existen** en `Candil.Router`:

| Falta | Por qué |
|---|---|
| Un **filtro** (veto) antes de puntuar | Hoy nada impide que un prompt con una imagen acabe en un modelo de solo texto. Hoy `force_model` gana a todo, incluso a lo que no tiene sentido |
| **`no_encaja` y `no_cabe` separados** | Hoy solo hay `:miss`, que no distingue «nadie sirve» de «nadie cabe» |
| **`:unknown` de primera clase** | Un motor estático que solo sabe decir sí o no está obligado a mentir en el caso normal |
| **Las clases de calidad** | Está decidido (D1) y **nunca implementado**. Es lo que hace que el routing searesiliente a cambiar el hardware |
| **Política configurable** | Hoy las reglas son código. Nadie puede tocar el routing sin compilar Candil |

**Y un hueco más grande que el motor:** hoy **nadie consulta al motor**. `grep -rn 'Router.route(' lib/` da cero llamadas fuera del CLI y sus tests. Hay un motor de decisiones entero, y ningún consumidor. Esa es la fase 8a: ponerlo en el camino.

---

## 1.5 · ⚠️ MEDIDO · cuánto cuesta decidir

> Antes este documento decía «un motor estático tiene que resolver la mayoría en
> **menos de 1 ms**». Eso estaba escrito desde la fase 7 y **nunca se había
> medido**. Ahora sí.
>
> `mix bench router`, OTP 28.5.0.7 / Elixir 1.19.5, Xeon 8163 @ 2.50 GHz,
> **un solo core**.

| | media | mediana | 99th % |
|---|---|---|---|
| **decision completa (3 prompts)** | 422 μs | 324 μs | 662 μs |
| **decision por prompt** | ~135 μs | ~102 μs | ~170 μs |
| **scoring por reglas** (sin la decisión) | **2.9 μs** | 2.1 μs | 8.6 μs |

### Lo que dice

**El scoring es 2,9 μs. La decisión son 135 μs.** Casi todo el coste de decidir
está **fuera** del scoring: en resolver candidatos, leer el TOML, cachear. Eso
dice **dónde** optimizar, no que haya que optimizar.

**Y el margen es de sobra.** El diseño pedía 1 ms; se está en 135 μs. **Con tres
decisiones por milisegundo de CPU**, la decisión no va a ser el cuello de botella
de la línea de cajas: lo serán la GPU y el tiempo de generación.

> Consecuencia para la 8b: **la caja no necesita cola de decisiones**, necesita
> cola de **generaciones**. Y eso es una decisión más fácil de la que se pensaba.

### Y lo que NO dice

El ±300-600% de desviación es **esta máquina con un core y ruido de sandbox**.
El 99th % es el número que importa, y 170 μs de cola contra segundos de modelo
sigue siendo ruido. En la máquina del dueño habrá que volver a medirlo antes de
decidir nada con estos números.

El catálogo de `bench/support.exs` tiene seis modelos con capacidades distintas
a propósito: un catálogo donde todos hacen lo mismo mide un caso que no existe,
porque el filtro nunca tiene nada que descartar.

---

## 2 · El motor, en una frase

> **Señales → requisitos → filtro → afinidad → una decisión.**
> Con tres salidas: un modelo, `:no_encaja`, `:no_cabe`. Y `:unknown` como una
> salida más, no como un error.

Ese último es el que no se ve venir: un sistema que **tiene** que poder decir
«no lo sé» es un sistema que puede mezclarse con un LLM más adelante sin que
el LLM lo replaced. Un sistema que solo sabe decir «sí» o «no», no se puede
mezclar con nada.

---

## 3 · Las seis piezas

| # | Pieza | Qué hace |
|---|---|---|
| **1** | **Señal** | un hecho medible del prompt o del consumer |
| **2** | **Requisito** | lo que hace falta, derivado de señales |
| **3** | **Capacidad** | lo que ofrece cada modelo |
| **4** | **Filtro** | veto duro. **No es una puntuación** |
| **5** | **Afinidad** | puntuación entre los que pasan el filtro |
| **6** | **Decisión** | un modelo, o `:no_encaja`, o `:no_cabe` |

Filtro y afinidad **no son lo mismo** y esa distinción es lo que separa esto de
un árbol de reglas. Un filtro es un **hecho**: este modelo no tiene visión, este
prompt sí la tiene. Una afinidad es una **opinión**: creo que este modelo es
mejor para este prompt. **El filtro no se puntúa, se aplica. La afinidad no
excluye, ordena.**

---

## 4 · Las señales, y el dominio de señal

Una señal es un hecho medible del prompt o del consumer. **Un dominio de señal es
un conjunto de ellas que viajan juntas y que se pueden activar y silenciar
juntas.**

**¿Por qué agruparlas?** Un developer que escribe un chatbot para una biblioteca
municipal no quiere aprender cinco señales de código, y si las aprende tiene que
apagarlas. Con dominios:

```toml
[router]
dominios_activos = ["longitud", "documento", "modalidad", "idioma"]
```

Y las de `codigo` ni se miran.

**Los dominios iniciales:**

| Dominio | Señales |
|---|---|
| `longitud` | `tokens`, `turnos` |
| `codigo` | `bloque_codigo`, `diff`, `fichero_mencionado`, `stacktrace` |
| `documento` | `adjunto`, `en_contexto`, `paginas` |
| `modalidad` | `texto`, `vision`, `audio` |
| `idioma` | `es`, `en`, `otro` |
| `privacidad` | **del consumer, no del prompt** |

**El de `privacidad` es el que no se le ocurriría a nadie**: una biblioteca
municipal no manda nada fuera de la máquina, y eso **no es una propiedad del
prompt**, es una propiedad de quién pregunta.

### La regla que lo sostiene

> **Los tipos son código, los valores son datos.** Candil aporta las señales; el
> toml dice cuáles se miran y qué significan.

El developer **no puede inventarse una señal desde el toml**. Puede elegir
dominios, poner umbrales, y escribir reglas que combinen las señales que
existen. Si le hace falta «menciona número de socio», eso es **una fase de
Candil**, no una línea de política. Y esa es la línea entre «personalizable» y
«un DSL que hay que mantener».

---

## 5 · Requisitos

Un requisito es lo que **hace falta**, no lo que se quiere. La primera versión
de campos:

| Requisito | Tipo | Qué dice |
|---|---|---|
| `calidad` | `:básica \| :normal \| :alta` | el nivel de razonamiento |
| `modalidad` | lista de `:texto \| :vision \| :audio` | qué tiene que leer el modelo |
| `contexto_minimo` | `number()` | cuántos tokens necesita |
| `sin_datos_fuera` | `boolean()` | privacidad |
| `coste_maximo` | `number()` | presupuesto |

El nombre del requisito es el de la **calidad**, y no el del modelo. **Eso es lo
que hace que la política sobreviva a que cambies el hardware.** El `toql` dice
qué modelo es `alta` hoy. Mañana dices que `otro` es el nuevo `alta`, cambias una
línea, y ninguna regla se toca.

---

## 6 · `no_encaja` y `no_cabe` · la parte que más se subestima

Son dos salidas distintas, y la diferencia es operativa, no teórica:

| | qué ha pasado | qué hago yo |
|---|---|---|
| **`:no_encaja`** | ningún modelo cumple: no hay visión, no llega a 200k | config: añade un modelo, o baja el requisito |
| **`:no_cabe`** | alguno cumpliría pero ahora mismo no hay VRAM | esperar, o descargar otro |

**Con esto la cola deja de ser decorativa.** Un `no_cabe` es una entrada que se
puede encolar de verdad —«vuelve a intentarlo cuando hay hueco»— y esa es la
línea de cajas.

Y de paso, **`:no_cabe` es donde se ve la diferencia entre este motor y el de
Elasticsearch**: ES ordena documentos que ya están en un índice. Este decide
quién **se carga**, y cargarse cuesta GB. **Nada en ES tiene este problema,
porque en ES nada tiene peso.**

---

## 7 · El filtro

El filtro es un veto. Nada de lo que se decida arriba lo salta. Ejemplos:

- un modelo sin visión no pasa un prompt con visión
- un modelo sin `contexto_minimo` suficiente no pasa
- **el circuit breaker abierto no pasa** (ver más abajo)

Y un filtro que deja la lista vacía **no es un error**, es un `:no_encaja` con
la razón.

---

## 7.5 · ⚠️ El refusal NO está escrito

> **Antes de leer §8: la política que ese capítulo describe todavía no existe.**

```
grep -rn 'Instances' lib/candil/router.ex   →  NADA
grep -rln 'Instances' lib/                   →  solo CLI, doctor y holder
```

**El router no mira si un modelo está cargado.** Un pin a un modelo apagado
devuelve exactamente la misma tupla que un pin a uno encendido. Y las únicas
razones por las que puede negarse son `no_models_for_consumer` y
`model_not_in_candidates` — **ninguna es «el modelo que quieres no está
arriba»**.

Por eso **esta fase no puede empezar por §6**: sin una razón nueva de error, el
refusal no tiene dónde apoyarse. `Instances.alive?/1` existe y funciona; lo que
falta es que el router la consulte.

Medido en la [fase 0.4](../../01-inventario/HALLAZGOS-FASE-0.md), con un test
que **certifica la ausencia**: se pondrá rojo el día que alguien lo escriba, y
eso es lo que tiene que pasar.

## 8 · El circuito breaker va en el filtro, no en la puntuación

Esto lo dijo el usuario y es lo más importante que se ha decidido aquí:

> `Candil.HTTP.Retry` usa el breaker. `Scorer` y `DecisionEngine` no lo miran.
> Cero.

Un modelo que lleva cinco minutos fallando sigue recibiendo puntuación normal.
Eso está mal por una razón concreta: **si el breaker abierto resta puntos en vez
de excluir, y no hay nadie mejor, gana igual, y entonces te enteras por una
excepción en vez de por una respuesta.**

El breaker abierto **excluye** del filtro. Y si era el único:

```
no_encaja: vision → ningún modelo lo soporta
           coder  → el breaker está abierto (5 fallos)
```

Y ojo con el **solapamiento de ejes**, que no es una colisión sino una
composición: el estado del worker (`waiting`, `working`, `failed`, `died`) es
**qué hace el proceso**; el circuit breaker es **si le damos más trabajo**. Un
worker puede estar `working` con el breaker `open`: está vivo pero sin trabajo
porque no nos fiamos del modelo de detrás.

**El rescate**, cuando un worker muere, ya lo hace el DynamicSupervisor de Arrea.
Lo que le falta hoy es una cola de la que volver a coger. **Ya existe:**
`Arrea.Queue` es precisamente eso.

---

## 9 · La afinidad

**Aquí sí que inventamos.** No hay nadie de quien copiarlo.

Y hay un uso de prueba para saber si la hemos acertado, y no es bonito: **si
algún día el LLM entra, ¿lo pondría para elegir de entre los que pasan el
filtro?** Si la afinidad es «opinión razonada», un LLM es mejor que unas
palabras clave. Si la afinida no es más que un producto cartesiano, el LLM
sobra y lo que hay que arreglar son las señales.

**Por eso el LLM no es una fase del motor, es el tribunal del motor.** Si lo
pasa, las reglas estaban bien. Si no, la forma de las reglas estaba mal.

La primera versión será: `calidad` + `modalidad` + `idioma` + `domicilio`
(`cargado` suma, `local` suma). Cuatro factores. Si con eso no se resuelve el
90% en la máquina real, se añaden señales, no un modelo.

---

## 10 · El LLM, si algún día

No sustituye. **Se añade.** Y solo en dos papeles:

| Papel | Cuándo | Qué **no** puede |
|---|---|---|
| **Fallback** | la política dice `:unknown` | elegir un modelo vetado |
| **Reranker** | dentro de los ya elegibles | ampliar la lista |

Y **nunca `:no_cabe`**: «no cabe» es una decisión de recursos, y un modelo de
lenguaje no tiene nada que decir sobre VRAM.

**Y un tribunal que hay que_passar antes de meterlo:** se mide qué fracción de
decisiones resolvió la política. Si es el 97%, el LLM se llama el 3% y es ruido
caro. Si es el 60%, **el motor estático está mal hecho** y hay que arreglarlo
antes de meter un modelo. Esa métrica sale de `Candil.Telemetry`, que ya emite
y ya está conectado.

---

## 11 · Los tres fallos de este motor que hay que evitar

**1 · Que dos“No hay ningún modelo para este prompt” sin decir cuál.**
La versión vaga es indistinguible de Candil roto, y el developer se va a
probar cosas a ciegas. Con la versión con datos (`el mayor disponible es
131072, querías 200000`), es un cambio de número.

**2 · Que el motor estático se quede en 97% y nadie lo mire.**
Si se queda en 97%, la afinidad está bien y no hace falta un LLM. Si se queda en
60%, la culpa es de las señales. **Sin esa métrica, añadir el LLM es una
apuesta.**

**3 · Que el motor decida un modelo que no está cargado y «lo arregle luego».**
No hay «luego». O el filtro comprueba la carga, o la petición va a fallar, y
entonces el fault filter lo cuenta como `no_cabe` y no como error.

---

## 12 · Las entradas

`route/2` recibe mensajes, opts. Y una decisión de routing depende de **tres**
cosas:

1. **Los mensajes** — el prompt
2. **El consumer** — quién pregunta, y sus restricciones
3. **El catálogo** — qué modelos hay, y ahora mismo cuál está cargado

Los tres son datos y ninguno se adivina. El catalogue es un `:`list` de alias y
se resuelve una vez, antes de puntuar, **no dentro del bucle de afinidad** (que
por eso puede ser una reducción simple y no un doble bucle).

---

## 13 · Lo que este motor NO va a tener

- **LLM en el camino caliente**, hasta que la métrica de cobertura lo pida
- **Overriding del filtro.** El `--model` de una persona puede saltarse la
  afinidad, pero **no un filtro**: si le mandas una imagen a un modelo sin visión
  y lo sabe, no lo hace, y **te lo dice**.
- **Normalización de la confianza.** La fase 7 la vetó, y el sitio donde se
  arregla es la afinidad, no la confianza.
- **Preferencias globales.** Un modelo puede ser peor en general y mejor para un
  consumer. Eso va en el policy.toml, no en el motor.

---

## 14 · Un test antes que diez

La forma, en un test literal:

```elixir
test "un prompt de 200k no encuentra modelo, y lo dice con el numero" do
  # el motor tiene solo un modelo de 131072
  assert {:no_encaja, %{motivo: :contexto_insuficiente,
                        detalle: "necesitas 200000, el mayor es 131072 (coder)"}} =
           Router.decide(mensajes_de_200k, catalog: [coder_131072])
end
```

Un test que dice **lo que la decisión tiene que decir cuando se bloquea**.
Porque el día que ese mensaje cambie de forma sin que nadie se entere, el
developer pierde la única pista que tenía de por qué su prompt no salía.

Y el que decide si el motor es un framework o un programa:

```elixir
defmodule MiPropioEmbedder do
  # define signals, define policy… sin tocar Candil
end
test "una politica de un tercero funciona sin tocar Candil" do
  # ✓  Candil es un framework
end
```

Ese es el que decide. Y hoy **fallaría**, porque `Scorer` tiene las reglas
escritas en un `@rules`. **Ese es el fallo, y por eso esta fase no es
incremental.**

---

## 15 · Lo que tiene que leer el siguiente

1. `docs/01-inventario/README.md` §2 — los cuatro puntos de extensión que hay, y
   por qué este motor necesita más
2. `docs/00-arrea/README.md` §5 — lo que Arrea **no** tiene, y por qué
3. Este documento, entero
> sustituye. No es un plan: es la forma.