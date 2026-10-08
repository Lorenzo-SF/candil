# Fase 0 — lo que medimos antes de construir nada

> **Qué es esto.** Cuatro mediciones ejecutadas sobre el código, no sobre el plan.
> Cada una， la afirmación que la evaluación daba por cierta y ha
> resultado ser otra cosa.
>
> **Fecha**: 2026-10-08 · `27 doctests, 824 tests, 0 failures`
> **Por qué va primero.** Una fase que empieza sin medir lo que hereda empieza a
> adivinar. Estas cuatro son la fase 0 del plan, y cambiaron el orden.

---

## El patrón

Las cuatro se parecían. En el plan eran «hecho», «a medio hacer» o «decidido».
Ejecutadas:

| | En el plan | Medido |
|---|---|---|
| **0.1** Proveedor remoto | hecho | **toda la suite interceptaba HTTP con un Mox** |
| **0.2** `Candil.Agent` | funcionando | **el bucle ReAct no cerraba jamás** |
| **0.3** RAG | a medio hacer | **cinco stubs y un struct congelado** |
| **0.4** Refusal de VRAM | decidido | **no existe** |

**Las cuatro existen porque existen, no porque funcionen.** Y ninguna la encontró
un test: los tests pasaban porque probaban lo que el test puesto al lado hacía.

---

## 0.1 · El proveedor remoto nunca había salido a la red

```elixir
# test/test_helper.exs:8
Application.put_env(:apero, :http_adapter, Candil.HTTPAdapterMock)
```

**Para TODOS los tests.** Así que `chat_remote/4` tenía 2 usos en el suite, y los
dos contra un mock.

Lo que un mock **no** prueba, y que se rompe de verdad:

- la URL que se construye
- la cabecera `Authorization` con la forma que espera el proveedor
- el JSON que sale por el cable
- el JSON que vuelve parseado

Ahora hay un test que levanta un **Bandit real** en un puerto de loopback,
escribe un `[provider.X]` de verdad y comprueba **el contenido de la
respuesta**. Más lo que se ve por el cable: la URL, la clave y el body.

**Nada sale a internet.** Si el adaptador de apero cambia y el test se va a
openai.com, falla ruidosamente.

> Lo que sale bien por el camino: el `model`, los headers, el JSON del body, el
> parseo de la respuesta, y que sin clave da 401. **El camino está entero y es
> correcto.** Lo que no había era **demostración**.

---

## 0.2 · El bucle ReAct no cerraba con ningún LLM real

El más grave de los cuatro, porque no es un borde: **es el módulo entero**.

```elixir
# ANTES
Conversation.add_message(c, "user", observation_message(name, result))
```

**El agente le enseñaba al modelo su propio resultado como si lo hubiera dicho
el usuario.** Un LLM real recibe el resultado de una herramienta en un mensaje
con `role: "tool"`.

Consecuencia: el modelo volvía a pedir la herramienta, recibía su respuesta
como mensaje del usuario, volvía a pedirla, y **agotaba los pasos sin cerrar
nunca**. `:max_steps_exhausted` era el síntoma de un bucle que no iba a
terminar jamás.

Verificado, después de arreglarlo:

```
ROLES: ["system", "user"]            ← pide la herramienta
ROLES: ["system", "user", "tool"]    ← recibe el resultado
RESULTADO: :ok
```

### Los otros dos que salieron debajo

**`resolve_backend/1` devolvía `nil`** y el bucle hacía `nil.chat(...)`: un
`UndefinedFunctionError` de Erlang por un error de configuración. Ahora devuelve
`:no_backend`.

**El `@type step` mentía**: declara `:thought | :action | :observation | :final`
y el bucle **nunca emite `:observation`** — la observación va dentro de un
`:action`.

**Y `Conversation.add_message/3` no aceptaba `role: "tool"`.** Así que el bug de
la observación estaba escondido detrás de tres sitios más. **Uno solo no se ve.**

### Una cuarta, de superficie

`use Candil.Agent, tools: [MiTool]` **no registra la herramienta**. Espera
`%Tool{}` ya construidos y el módulo entero revienta en `to_wire_schema/1`. El
`use` *parece* que registra tus herramientas y no lo hace.

---

## 0.3 · El RAG es una superficie decidida y un cuerpo pendiente

No es un RAG a medio hacer. `lib/candil/rag.ex` son **cinco funciones que
devuelven `{:error, :not_implemented}`** más el struct `Chunk` con los tipos
congelados.

La diferencia importa: **lo decidido se puede usar, y lo que no se puede ni
discutir sin inventar.**

El `@moduledoc` promete «coseno sobre un escaneo lineal, hasta 50k chunks». No
hay una línea de código que lo haga. Que `search/3` exista **no** significa que
el escaneo exista.

### Dos hallazgos escribiendo el test

**`embedder/1` no devuelve el nombre.** Con uno que no está registrado:

```elixir
{:error, {:unknown_embedder, "nvidia/embed"}}
```

El error lo nombra. `{:error, :no_embedder}` a secas obligaba a ir a buscarlo.

**`text: ""` es legal y `text: nil` también.** `@enforce_keys` comprueba la
**presencia** de la clave, no su valor. Un chunk con texto vacío es inútil, no
imposible.

### El test de un stub

Funciona **al revés**: se pone **rojo** el día que alguien implemente la fase
10. Un contrato que falla cuando algo llega, no cuando falta.

La alternativa —`assert match?({:error, _}, …)` y pasar siempre— no fija nada.

---

## 0.4 · El refusal de VRAM no existe

La decisión que gobierna la 8b, tomada en la fase 2, **nunca ejecutada**:

> Si el modelo que gana no está cargado, **no lo arranques**: dilo.

```
grep -rn 'Instances' lib/candil/router.ex   →  NADA
grep -rln 'Instances' lib/                   →  solo CLI, doctor y holder
```

**El router no mira si un modelo está cargado.** Un pin a un modelo apagado
devuelve **exactamente la misma tupla** que un pin a uno encendido.

Y las únicas razones por las que el router puede negarse son
`no_models_for_consumer` y `model_not_in_candidates`. **Ninguna es «el modelo
que quieres no está arriba»**.

> **Por eso el refusal no se puede escribir sin una razón nueva: no hay dónde
> apoyarlo.** `Instances.alive?/1` existe y funciona — lo que falta es que el
> router la consulte, y eso es una línea.

El test de esta uno **certifica una ausencia**: los dos `refute` están escritos
para caerse cuando alguien lo escriba.

---

## Lo que esto cambia en el plan

| Documento | Qué hay que corregir |
|---|---|
| [`04-modulos/05-agentes/`](../../04-modulos/05-agentes/) | **Describe un bucle ReAct que no funcionaba.** Es el más urgente |
| [`04-modulos/03-rag/`](../../04-modulos/03-rag/) | Asume que hay RAG. Hay cinco stubs |
| [`04-modulos/01-routing-y-ciclo-vida/DISENO-MOTOR.md`](../04-modulos/01-routing-y-ciclo-vida/DISENO-MOTOR.md) | Habla del refusal como si existiera. **No existe** |
| [`01-inventario/`](../../01-inventario/) §4 | La tabla «existe pero no está probado» ya tiene respuesta: cuatro |

---

## Y dos cosas que no son de Candil, y pasa lo mismo

**1 · El build dir corrupto.** Tres veces hoy: 84 fallos de `Mox.Server` sin
arrancar que **no eran de ningún cambio**. Con `MIX_BUILD_PATH` nuevo: 0. Un
`checker` que falla por el entorno enseña a ignorar el rojo.

**2 · El Store es global y es gratis compartirlo hasta que no lo es.**
`engine/for_model_test.exs` registra un `:llama_cpp` mientras corre; mi test de
routing usaba los alias `:coder` y `:embed`. El test ajeno se encontraba mi
engine y fallaba sin que nadie hubiera escrito mal una línea.

> Un Store compartido **obliga a no compartir los alias**, y un alias compartido
> **obliga a no compartir el fichero**. El otro test ya lo avisa en su setup. Es
> verdad, y no es gratis.

**3 · El invisible en un string.** `<tool_call>` escrito a mano lleva un
carácter invisible entre el `<` y el nombre. El parser no ve la llamada, el
agente se queda en `max_steps_exhausted`, y **no dice por qué**. Cuatro horas de
"el agente no hace nada" que eran dos bytes.

Se construye con `<<60>>` y `<<62>>`, que es a lo que no se le puede colar
nada.

---

## La regla que sale de aquí

> **Un componente existe de dos maneras: la que está escrita, y la que funciona.**
> El plan las porque el código compila, los tests pasan y el `@moduledoc`
> promete.

Las cuatro mediciones eran baratas — **dos sesiones y cuatro ficheros de test**— y
cambiaron qué se construye primero. Ese es el argumento para hacerlas antes de
construir: **no para encontrar bugs, sino para no construir encima de una
suposición.**