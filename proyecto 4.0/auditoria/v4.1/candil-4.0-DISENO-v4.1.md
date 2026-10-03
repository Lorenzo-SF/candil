# Candil 4.0 — enmiendas al diseño

> **Addenda a `candil-4.0-final.md`.** No lo reescriben: lo amplían. Cada
> enmienda dice qué añade, por qué, el cambio concreto, y en qué fase cae.
> Si una enmienda contradice al documento original, **manda esta**, y hay que
> actualizar el original para que los dos digan lo mismo.
>
> Fecha: 2026-10-03 · Origen: auditoría de las 8 fases + revisión del diseño

---

## El resumen

| # | Qué | Tipo | Fase |
|---|---|---|---|
| **D1** | `quality_class` en `Model`: las reglas apuntan a clases, no a modelos | API + config | 7 |
| **D2** | `EnginePool` deja de ser API pública: el fichero es la verdad | API | 4 |
| **D3** | El `launcher` vive en el Engine, no en el Model | **defecto** | 2 |
| **D4** | Política de desbordamiento de contexto, `strict` por defecto | config + API | 6 |
| **D5** | El Gateway acepta `reasoning_effort` y lo traduce por modelo | API | 8 |
| **D6** | El router recibe una señal de si acertó | API | 7 |
| **D7** | La paridad con ropero pasa de `pgrep` manual a test | test | 2 |
| **D8** | `Conversation` → `@deprecated`: dos maneras de guardar una conversación | limpieza | 6 |
| **D9** | El doctor crece con cada subsistema, o no sirve de release gate | feature | 5, 7, 8, 10 |
| **D10** | La retirada de `Batteries.LlamaServer` es una issue, no una nota | acción | 11 |

**D3 es un defecto, no una mejora.** El resto son mejoras. D7 y D9 son las que más
rendimiento dan por línea escrita.

---

## D1 · `quality_class`: las reglas apuntan a clases, no a modelos

### El problema

§19.2 define el router con un score por modelo: `coder 0.80`, `verifier 0.20`. Eso
 ata la tabla de reglas a los nombres de los modelos. Dos consecuencias:

1. **Añadir un modelo es reescribir la tabla de reglas.** En un sistema cuyo
   propósito es ser la librería de IA de un ecosistema que ya tiene 12 modelos, eso
   no escala.
2. **No hay forma de decir "esto es rápido"** sin escribir una regla por modelo.

El propio diseño ya tiene la tubería para arreglarlo: `task_categories` existe, y
`Model` ya lleva `usage` y `tags`. Lo que ata es el **peso por modelo**.

### El cambio

Un campo más en el struct, y el peso vive en el modelo:

```elixir
@type quality_class :: :fast | :balanced | :deep
defstruct [..., quality_class: :balanced]
```

```toml
[model.coder]
quality_class = "deep"

[model.coder_lite]
quality_class = "balanced"

[router.affinity.deep]
prefer    = ["coder", "verifier"]
fallback  = ["designer"]
[router.affinity.balanced]
prefer    = ["coder_lite"]
[router.affinity.fast]
prefer    = ["gpt4o_mini"]
```

El flujo del router pasa a ser de **tres pasos** en vez de una tabla de pesos:

```
categoría de la tarea  →  quality_class  →  tabla de afinidad  →  modelo
   (ya existe:            (nuevo)            (nuevo)             (ya existe:
    task_categories)                                             Store)
```

`Model.validate/1` acepta `:balanced` por defecto, así que **no rompe ningún TOML
existente** y no obliga a tocar el Apéndice A. Q10 ya preguntaba si los consumers
pueden tener afinidades distintas: con esto, sí, y es una línea por consumer.

### Por qué `high` para implementarlo

Es un cambio pequeño de superficie (`Model` + una tabla nueva + el `DecisionEngine`
que lee la afinidad), pero obliga a **reencontrar todos los sitios donde el router
habla de un modelo por su nombre**. Ese grep es el trabajo real.

---

## D2 · `EnginePool` deja de ser API pública

### El problema

Hay dos verdades sobre qué está corriendo: `instances.json` en disco y `EnginePool`
en ETS. La nota de la F5 dice que "`stop` lee el fichero **además del** del pool".
Eso es una frase, no una especificación: no dice cuál gana cuando discrepan.

### El cambio

No escribir una regla de conflicto. **Eliminar el conflicto:**

- **`instances.json` es la verdad entre procesos.** Es lo único que un CLI recién
  arrancado puede confiar.
- **`EnginePool` deja de ser API pública.** Pasa a estado interno de
  `Candil.Instances`. Se renombra a `Candil.Instances.Pool` y deja de estar
  exportado.
- **Todo lo que consulta estado de instancias pasa por `Candil.Instances`.** Nadie
  lee el pool directamente, y un `grep -rn "EnginePool" lib/` → 0 fuera de
  `instances.ex`.
- `Instances.prune/0` reconcilia al arrancar: lee el fichero, poda las entradas
  cuyo pid está muerto, y el pool se queda con lo que sobrevive.

`EnginePool` ya está reescrito por la F2 como registro `{alias, port} => %{...}`,
así que el coste es renombrar y cerrar el módulo, no reescribirlo.

### Por qué `medium`

Mecánico una vez decidido. Lo caro es decidir, y está decidido.

---

## D3 · El `launcher` vive en el Engine — defecto

### El problema

§8 dice que `:external` exige `engine` + `base_url` + `launcher`. Y §10.3 pone
`launcher` en **los dos sitios**:

```toml
[engine.vllm_box]
launcher   = "Candil.Engine.Launcher.Http"     # ← aquí

[model.tgi]
engine     = "tgi_box"
launcher   = "Candil.Engine.Launcher.Http"     # ← y aquí
base_url   = "http://10.0.0.5:8080"
```

Un launcher describe **cómo se habla con un tipo de motor**, no una instancia
concreta. Ponerlo en el modelo abre dos fallos:

- Dos modelos en el mismo engine pueden declarar launchers distintos, y entonces
  Candil habla de dos maneras con el mismo servidor.
- `Model.validate/1` puede validar dos modelos que declaran el mismo engine con
  `launcher` distinto, y **ninguno de los dos está mal según el validador**.

### El cambio

**El launcher es del engine. Punto.**

```toml
[engine.vllm_box]
launcher   = "Candil.Engine.Launcher.Http"    # aquí, y solo aquí
host       = "10.0.0.5"

[model.tgi]
type      = "external"
engine    = "vllm_box"
base_url  = "http://10.0.0.5:8080"            # el modelo solo aporta la URL
```

`Model.validate/1` para `:external` exige `engine` + `base_url`, y **nada de
`launcher`**. El engine lo resuelve. Con eso, "vLLM, TGI, LM Studio, Ollama,
airllm, tensorrt-llm y mlx-lm quedan cubiertos sin una línea cada uno" sigue
siendo cierto, y además es imposible que un modelo se salga del launcher de su
engine.

### Por qué `high`, y por qué en la F2

Es una **`Model.validate/1` que hay que endurecer y un TOML que hay que editar**, y
el TOML del Apéndice A es el artefacto que la F2.4 escribe a mano. Si se deja para
más tarde, el Apéndice A queda con el error dentro y se copia a `MIGRATION.md` en
la F11.

---

## D4 · La política de desbordamiento de contexto es una decisión de seguridad

### El problema

§18 define el `Builder` y la F6 exige `{:error, :context_exceeded}`. Pero **qué
pasa cuando te acercas al límite** no está decidido, y hoy está repartido entre
`Context.PrefixManager` y `Context.Summarizer`.

No es una pregunta de UX. La F6 mete **una API key en el contexto** como criterio
de aceptación. Si truncar en silencio es el default, el contexto resultante parece
completo y no lo está, y una key que "ya no está" en un resumen truncado sigue
estando en una sesión de otro consumer.

### El cambio

Una escalera explícita, y el consumer elige. `strict` por defecto:

```toml
[consumer.posadero]
context_policy = "strict"      # → [:ok, msj] | {:error, :context_exceeded}
[consumer.opencode]
context_policy = "summarize"   # → resumir, y si falla, degradar a :compact
```

```
:strict     →  {:error, :context_exceeded}          nunca descarta nada
:compact    →  descarta los mensajes más viejos
:summarize  →  resume los más viejos; si el modelo está caído, degrada a :compact
```

Y una condición que hoy no existe: **`:summarize` nunca degrada a `:strict`**. Si el
modelo está caído y no queda sitio, sale `:context_exceeded`, no una lista truncada
sin avisar. Degradar a error es honesto; degradar a silencio, no.

`[consumer.X] context_policy` se lee en `Context.Store` al crear la sesión, y
`Builder` lo recibe. El default `:strict` no cambia el comportamiento ya escrito
en la F6, que es correcto.

### Por qué `max`, y en la F6

Es una decisión con consecuencia de seguridad, y es de las pocas cosas del plan
que **no se pueden recuperar una vez deployed**: un contexto truncado en silencio
es un bug que no se manifiesta, y su síntoma aparece semanas después en el sitio
equivocado.

---

## D5 · El Gateway tiene que aceptar `reasoning_effort`

### El problema

El gateway es **OpenAI-compatible**. El API de OpenAI acepta `reasoning_effort` en
`chat/completions`, y hay clientes que lo mandan. El diseño no dice qué hace Candil
con ese campo, y no todos los modelos lo soportan: los `gptoss_*` de ropero lo
soportan vía `chat-template-kwargs`, `coder` no lo soporta en absoluto.

Hoy el `Normalizer` de ElPaso se trae tal cual y casi con seguro se come el
campo. Un cliente que manda `reasoning_effort: "high"` y recibe una respuesta sin
pensar **no tiene forma de saberlo**.

### El cambio

```elixir
# en Model
defstruct [..., supports_reasoning_effort: false]

# en Gateway.Normalizer
reasoning_effort ∈ ["low", "medium", "high"]   # se acepta siempre
```

Tres casos, y ninguno es un 400:

| Modelo | Qué hace el gateway |
|---|---|
| `supports_reasoning_effort: true` | lo mete en `chat-template-kwargs`, sustituyendo el valor por defecto del modelo |
| `false`, el cliente no manda nada | el valor por defecto del modelo, sin tocar |
| `false`, el cliente manda algo | **lo ignora y lo dice**: cabecera de respuesta `X-Candil-Reasoning-Ignored: high` |

El modelo que no puede tenetslo **no rompe la petición**. Un 400 por un campo
opcional de un cliente que funciona es una regresión para todos los clientes.

Y hay una razón de peso para soportarlo de verdad: `gptoss_high` / `_medium` /
`_low` son **tres level del mismo GGUF con distinto `reasoning_effort`**, y son
alias distintos en el catálogo (`verifier`, `designer`). Con D5, un cliente puede
pedir profundidad en vez de modelo, y eso es lo que un endpoint compatible
debería poder hacer.

### Por qué `high`, y en la F8

El `Normalizer` es `xhigh` de por sí (§ del diseño) y esto se suma en la misma
capa. Pero es `high` y no `xhigh` porque el cambio es acotado: un campo más en el
struct, un `case` en el normalizer, una cabecera de respuesta.

---

## D6 · El router necesita saber si acertó

### El problema

`router stats` da `p50`, `p95` y `errors`. Eso es **operación**: si va lento o
falla, se ve. No dice si el modelo elegido era el bueno, y sin eso el
`auto_tuner` del §19.2 no tiene insumo.

El resultado: el router es una apostura informed y bienintencionada, y se queda
ahí para siempre. En un sistema cuyo propósito es "decidir qué modelo responde",
decidir sin saber si se acertó es la mitad del trabajo.

### El cambio

Una tabla `Candil.Router.Outcome` y dos fuentes, la segunda gratis:

```bash
# 1. Explícita: un humano dice qué debería haber pasado
candil pin coder --ttl 1h
```

```elixir
# 2. Implícita y gratis: el usuario launchó un modelo a mano
#    cuando el router no estaba en el camino
Candil.Instances.started_by_user(model, consumer)  # → negative signal
```

`router stats` gana una columna `correct`, y `AutoTuner` la consume para mover
pesos. La fuente 1 es la que vale; la 2 es ruido con volumen.

**El mínimo imprescindible es la 1**, y es un comando. Sin ella, `auto_tuner` es
código muerto y hay que decirlo en el documento para que nadie lo dé por hecho.

### Por qué `medium`, y en la F7

No es un algoritmo difícil: una tabla, un comando y una columna. Es `medium`
porque hay que decidir **cuánto dura un pin** y **qué pasa si el pin contradice a
la regla** — y eso es política, no código.

---

## D7 · La paridad con ropero, de `pgrep` manual a test permanente

### El problema

Este proyecto **es** absorber ropero. ropero está vivo y es la verdad. Y el plan
tiene **una sola** comprobación de equivalencia: el `pgrep | diff` manual de la
F2.4, que se ejecuta una vez y se queda en un chat.

Mientras tanto, el Apéndice A — que es **justo el argv conocido como bueno de
ropero, escrito a mano** — está en un documento de Markdown que nadie comprueba
contra nada.

### El cambio

El Apéndice A baja a un fichero de datos que se puede testear:

```
priv/ropero_argv.json     # argv conocido como bueno, por alias, transcrito
                          # a mano de ropero.d/*.sh el <fecha>. NO regenerar
                          # sin revisar: es el ground truth.
```

Una tarea nueva, y un test:

```bash
mix candil.config.resolve --model coder --format shell
# → --host 127.0.0.1 --port 9999 --api-key *** --alias coder --ctx-size 131072
#   -fa on --n-gpu-layers -1 --n-cpu-moe 30 ...
```

```elixir
@tag :parity     # excluido del CI, se corre a mano
test "coder produce el mismo argv que ropero, salvo los flags del engine" do
  ours    = Candil.Config.resolve(:coder) -- engine_owned()
  ropero  = RoperoArgv.fixture("coder")   -- engine_owned()
  assert ours == ropero                  # lista, no set: el ORDEN importa
end
```

Dos detalles que hacen que esto funcione:

- **Compara como lista, no como conjunto.** El diseño insiste en que el `--cpu` va
  al final porque llama-server usa la última aparición de un flag. Un `MapSet`
  pierde el orden y el test pasa sobre un bug que el diseño dice explícitamente que
  importa.
- **`engine_owned()`** quita `--host`, `--port`, `--alias` y `--api-key`, que los
  pone el engine y son legítimamente distintos.

### Por qué `high`, y en la F2

Es trabajo de transcripción más un test, y la transcripción es `low`. Pero
descubrir qué flags se desvían de verdad requiere comparar con ropero corriendo, y
eso es lectura cuidadosa de dos líneas de 30 flags. `high` por el comparar, no por
el escribir.

**Rendimiento:** con esto, un typo en `--n-gpu-l` deja de ser un flag que
llama-server ignora en silencio. Y la F11 gana un criterio de cierre que no
requiere 17 GB: comparar el TOML contra el ground truth.

---

## D8 · `Conversation` → `@deprecated`

### El problema

§2 lista `Conversation`, `Conversation.Context` y `Conversation.TokenEstimator` como
✅, y §2.1 los describe como "guarda el historial en el proceso que llama". La F6
crea `Candil.Context`, que guarda el historial en ETS, particionado por consumer.

**No dice qué pasa con `Conversation`.** Si sigue, hay dos maneras de guardar una
conversación en la misma librería, y la nueva es la que hay que particionar. Si
desaparece, hay que quitarlo de `lib/`, de los tests y de las deps.

### El cambio

Decidir, y escribirlo:

```elixir
@deprecated "Usa Candil.chat_with_context/4. Se elimina en 4.1.0"
defdelegate chat(messages, opts), to: Candil.Context
```

`Conversation` **se queda en 4.0** como fachada, porque hay consumidores fuera del
ecosistema. `Conversation.TokenEstimator` **pasa a `Context.TokenEstimator`**,
porque la F6 lo necesita y duplicarlo es peor. `Conversation.Context` —que es lo
que §2 llama `context`— se elimina en la F6, sin deprecación, porque no ha salido
de casa.

### Por qué `low`, y en la F6

Es borrar un módulo, delegar tres funciones y actualizar una lista de deps. Lo
único que hay que pensar es qué es público y qué no, y eso está dicho arriba.

---

## D9 · El doctor crece con cada subsistema, o no sirve de release gate

### El problema

La F5 define siete checks: config, binario, sources, puertos, auth, gpu, memoria.
Ninguno mira el router, el gateway, el context, el MCP ni el RAG.

Y la F11 pone `./candil doctor` con **0 errores** como condición de publicar 4.0.0:
*"Si el doctor falla, no hay 4.0.0"*.

Un doctor que no sabe que el router existe no puede ser el gate de release de un
4.0 que **incluye** un router. Los siete checks se escribieron en la F5, cuando el
router todavía no existía; el problema es que la F11 los usa sin haberlos
actualizado.

### El cambio

**Un check por subsistema, en la fase donde el subsistema llega:**

| Check | Qué mira | Fase |
|---|---|---|
| `router` | hay modelos para el `default`; el clasificador está como debe | 7 |
| `context` | la tabla de ETS existe; el TTL corre; el `Summarizer` tiene modelo | 6 |
| `gateway` | si está arrancado: `/health` y el router detrás responden | 8 |
| `mcp` | la revisión del protocolo es la esperada; los transports están declarados | 9 |
| `rag` | hay índice; el embedder está; el chunker responde | 10 |

Cada uno en `:warning` si el subsistema está apagado a propósito, y `:error` solo
si debería estar activo y no lo está. La diferencia importa: un doctor que marca
error por un RAG que el usuario no ha configurado es un doctor que nadie lee.

### Por qué `low` por check, en 5 fases distintas

Un check son treinta líneas: un check, un mensaje accionable y tres casos de test.
El trabajo difícil —qué mirar y qué decir— se hace una vez por subsistema, y es
`medium`. Lo caro del cambio es **acordar el mensaje**, y por eso el formato de la
F5 (`"engine failed"` no es accionable) es el que hay que replicar.

---

## D10 · La retirada de `Batteries.LlamaServer` es una issue, no una nota

### El problema

C11 dice: *"Botica se usa solo en `candil doctor`... **Nota de retirada en su repo,
no aquí.**"*

Y la F5 lo repite: *"**NO** borres `Batteries.LlamaServer` del repo de botica. Está
fuera de su dominio y su sitio es aquí, pero borrar cosas del repo de otro es
decisión del dueño. Déjalo anotado."*

Un plan **no puede** producir una acción en otro repositorio. "Déjalo anotado" es
una intención, y las intenciones en planes adyacentes las ejecuta el 0 % de las
veces.
Dentro de un año hay dos implementaciones de "arrancar un llama-server" en el
ecosistema y **ninguna marcada**.

### El cambio

Sustituir la nota por un entregable con dueño:

```markdown
### 11.5 — Issue en botica

- [ ] Issue abierta en `Lorenzo-SF/botica`: "Candil 4.0 supersede
      Batteries.LlamaServer". Con la fecha, y con el enlace a C11.
- [ ] Anotada en el README de botica (NO se borra el módulo).
- [ ] En la definición de done de la 11, no en una nota.
```

`Botica.Batteries.LlamaServer` se queda. Lo que cambia es que botica **sabe**
que Candil 4.0 lo sustituye, con fecha, y quien llegue a ese módulo en 2027 no
pierde tres días intentando mantenerlo.

### Por qué `low`, y en la F11

Es abrir una issue. La parte difícil es aceptar que **no** se borra, que es
justo lo que el plan ya dice.

---

## Lo que NO cambia

- **Los 8 bugs y H1.** Verificados uno a uno contra el código, y el criterio de
  la H1 sigue siendo el que valida el diseño entero. No hay nada que mejorar.
- **La estructura de capas** (§9) ni la regla de una sola dirección. Es correcta y
  la excepción documentada de `Stream ← Router` está bien justificada: es el caso
  del re-entry del router dentro de un agent loop. Lo que falta es **decirlo**, no
  el mecanismo.
- **La regla 4** (ETS siempre, Postgres no). Sigue siendo correcta y la F10 debe
  respetarla.
- **La regla 7** (nada de `String.to_atom/1` con input externo). Con D5 se refuerza,
  porque el gateway recibe más campos de la red.
- **La estrategia de los tres `reasoning_effort` de ropero.** Con D5 pasan de ser tres
  alias a ser además un parámetro del endpoint. Es una mejora gratis de un dato que
  ya estaba en el catálogo.
- **El resto del diseño.** Los hallazgos H1-H5, las decisiones C1-C21, las reglas
  duras del Apéndice D y las preguntas abiertas E: todo eso aguanta.

---

## Cuánto cuesta esto

| Enmienda | Superficie | Fase |
|---|---|---|
| D1 `quality_class` | `Model` + `DecisionEngine` + grep de reglas | 7 |
| D2 `EnginePool` interno | renombrar + cerrar el módulo | 4 |
| D3 launcher del engine | `Model.validate/1` + Apéndice A | 2 |
| D4 política de contexto | `Config` + `Builder` + `Store` | 6 |
| D5 `reasoning_effort` | `Model` + `Normalizer` | 8 |
| D6 señal del router | tabla + comando + columna | 7 |
| D7 paridad ropero | transcripción + tarea + test | 2 |
| D8 `Conversation` | borrar + delegar | 6 |
| D9 checks del doctor | 5 checks repartidos | 5,6,7,8,10 |
| D10 issue de botica | una issue | 11 |

**Ninguna añade una fase.** Todas caen dentro de trabajo que ya existe, salvo D7
(medio día) y D10 (una issue). El coste real de la tabla entera es de **un día**,
y lo que compra es que el router deje de estar atado a una lista de nombres, que
el desbordamiento de contexto deje de ser un accidente, y que la paridad con
ropero deje de depender de que alguien se acuerde del `pgrep`.
