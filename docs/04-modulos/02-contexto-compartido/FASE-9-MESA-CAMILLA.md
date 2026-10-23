# FASE 9 · La mesa camilla — spec

> **Estado**: **borrador escrito por el consejero** (2026-10-23) ✓, a la espera
> de la aprobación del dueño ✓. **No es una fase empezada**: es el plano ✓.
>
> **Dónde encaja**: la mesa camilla es la fase **9** de [`docs/02-orden/`](../../02-orden/README.md) ✓
> y vive en el módulo **02 · Contexto compartido** ✓, junto a
> `Candil.Context.SharedMemory` (F2.4 ✓). No es un módulo nuevo ✓: el índice de
> módulos dice «los cinco» ✓ y sigue siendo cinco ✓.
>
> **Qué resuelve**: la contradicción entre **F2.4** (§5.4 del módulo 02 ✓) y
> **D-22** ✓. Gana **D-22** ✓: `SharedMemory` es un mapa clave → valor ✓ y **no**
> depende del RAG ✓ ni de un embedder ✓. La recuperación semántica es un
> enriquecimiento futuro ✓, con su propia decisión ✓, y **no** un
> prerrequisito ✓.

---

## 1 · La decisión que cambia el plan: la fase 9 no depende de la fase 6

**F2.4** decía ✓: *«no se puede terminar hasta que el RAG (fase 7) tenga un
`Embedder` que no sea un stub»* ✓.

**D-22** dice ✓: `SharedMemory` **no** depende del RAG ✓.

Gana D-22 ✓. Y la consecuencia es concreta ✓:

- La fila **9** de [`docs/02-orden/`](../../02-orden/README.md) deja de depender
  de la fase **6** ✓, y se queda con la **4** ✓.
- **F9.1** (`SharedMemory`) **puede empezar ya** ✓, sin embedder ✓ y sin RAG ✓.
- Lo que sí espera al RAG ✓ es el **enriquecimiento semántico** ✓ —el scrap, la
  búsqueda por significado—, que es una decisión aparte ✓.

---

## 2 · `Candil.Context.SharedMemory`

Un `GenServer` con su **propia tabla ETS** ✓, **sin embeddings** ✓ y **sin
historial** ✓.

### 2.1 · La entrada

| Campo | Tipo | Qué es |
|---|---|---|
| `key` | `String.t()` | La clave: `mem:proyecto_42`, `mem:decision:usar-postgres` |
| `value` | `term()` | Lo que se sabe. Un término, no un string |
| `author` | `atom()` | **Obligatorio**. Sin autor no hay memoria, hay un archivo anónimo |
| `inserted_at` | `DateTime.t()` | Cuándo se escribió |
| `updated_at` | `DateTime.t()` | Cuándo se volvió a escribir |
| `expires_at` | `DateTime.t() \| nil` | Cuándo caduca. `nil` = no caduca |
| `superseded_by` | `String.t() \| nil` | La clave que la desmentió, si la hubo |
| `version` | `pos_integer()` | Para el compare-and-swap |
| `meta` | `map()` | Lo que quiera el que escribe |

### 2.2 · La API

| Función | Qué hace | Qué devuelve |
|---|---|---|
| `put(key, value, opts)` | Escribe. `:author` **obligatorio**, `:expires_at` y `:supersedes` opcionales | `{:ok, entry}` \| `{:error, :author_required}` \| `{:error, :version_conflict}` |
| `put_new(key, value, opts)` | Escribe **solo si no existe**. Atómico | `{:ok, entry}` \| `{:error, :exists}` |
| `get(key)` | Lee | `{:ok, entry}` \| `{:error, :not_found}` \| `{:error, :expired}` |
| `delete(key)` | Borra | `:ok` \| `{:error, :not_found}` |
| `supersede(key, new_key, value, opts)` | Escribe la nueva y marca la vieja con `superseded_by` | `{:ok, entry}` \| error |
| `list(prefix)` | Las claves que empiezan por el prefijo | `[entry]` |
| `prune(now)` | Caducadas y viejas. Devuelve **conteos** | `%{expired: n, superseded: n}` |

- `put/3` sin `:author` devuelve `{:error, :author_required}` ✓: **quien escribe,
  se sabe** ✓.
- `SharedMemory` **es un hijo de la `Application`** ✓, con su tabla ETS propia ✓
  —el `GenServer` que la posee es quien la vigila ✓. Va **después** de
  `Candil.Context` ✓ y de `Candil.Context.PrefixManager` ✓, porque escribe en
  el Store ✓ y en el prefijo ✓.
- `put/3` con `:expected_version` hace **compare-and-swap** ✓: si la versión no
  es la que el que escribe vio, no escribe ✓. Es lo que permite que cinco
  procesos escriban a la vez sin pisarse ✓.
- **Las escrituras devuelven `{:ok, entry}` y no `:ok`** ✓. Con compare-and-swap,
  quien escribe necesita **la versión que se ha escrito** ✓: saber que se
  escribió la v3 y no la v2 es la diferencia entre un CAS y una carrera
  silenciosa ✓. Un `:ok` no dice qué versión quedó ✓, y quien escribe no puede
  encadenar la siguiente escritura sobre ella ✓.
- **No hay `append`** ✓, **no hay historial** ✓ y **no hay embedding** ✓.

### 2.3 · Los tests

`put`/`get` ✓ · `put_new` ✓ · compare-and-swap ✓ · `supersede` ✓ · caducidad ✓ ·
`prune` ✓ · el autor es obligatorio ✓ · **y que no depende de RAG ni de
embedder** ✓ — ese último es un test de dependencias, no de comportamiento ✓,
y es el que hace cumplir D-22 ✓.

---

## 3 · `Candil.Mesa`

| Función | Qué hace |
|---|---|
| `Candil.Mesa.estimate(request, opts)` | **Cero** llamadas a modelos. Devuelve `{:ok, %Estimate{}}` |
| `Candil.Mesa.run(request, opts)` | Ejecuta la mesa: `{:ok, %Result{}}` \| `{:error, reason}` |

- `run/2` **sin `confirm`** devuelve `{:error, {:confirmation_required, estimate}}` ✓:
  quien llama ve lo que va a costar **antes** de que cueste ✓.
- `%Voice{model, role, instruction, timeout_ms, enabled}` ✓.
- **Roles acotados** ✓: `:critic`, `:analyst`, `:coder`, `:verifier`, `:creative`,
  `:planner` ✓. Con instrucción por defecto ✓ y sobrescribible ✓.
- `%Result{round_1, round_2, oracle, unanswered, usage, started_at, finished_at}` ✓.

### 3.1 · Los behaviours, con sus `@callback`

Un behaviour sin `@callback` es un `@behaviour` que no dice nada ✓ — y el repo ya
tiene esa regla escrita ✓ (§D-10 ✓: *«una pieza interna sin llamadores es
trabajo sin empezar»* ✓). Los dos van con su firma ✓:

```elixir
defmodule Candil.Mesa.Strategy do
  @callback run(request :: map(), voices :: [Candil.Mesa.Voice.t()], opts :: keyword()) ::
              {:ok, %{round_1: [map()], round_2: [map()]}} | {:error, term()}
end

defmodule Candil.Mesa.Oracle do
  @callback synthesize(request :: map(), answers :: [map()], opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
end
```

- `Candil.Mesa.Strategy` ✓, con `Candil.Mesa.TwoRounds` por defecto ✓.
- `Candil.Mesa.Oracle` ✓, con `Candil.Mesa.Oracle.Model` por defecto ✓, que
  llama al modelo configurado ✓.

**Una estrategia o un oráculo de un tercero** ✓ —los criterios de aceptación lo
piden ✓— solo se puede escribir si **la firma está escrita** ✓. Por eso los
`@callback` no son burocracia ✓: son lo que hace posible el criterio ✓.

### 3.2 · El `Estimate`

```elixir
%Estimate{
  voices: non_neg_integer(),        # cuántas voces responden
  rounds: pos_integer(),            # 2: el original, y el original + las atribuidas
  inferences: pos_integer(),        # voices * rounds + 1 (el oráculo)
  input_tokens: non_neg_integer(),  # el prompt, medido con el estimador
  output_tokens: non_neg_integer(), # lo que puede pedir cada voz
  max_output_tokens: non_neg_integer(),
  provider: :local | :remote,
  cost_eur: float() | nil           # nil si es local: no hay precio
}
```

**El cálculo** ✓ —y todo lo que se puede contar, se cuenta ✓, sin gastar un
token ✓:

- `voices` = las voces **habilitadas** de la configuración ✓.
- `rounds` = 2 ✓.
- `inferences` = `voices * rounds + 1` ✓ — el `+ 1` es el oráculo ✓. No es una
  estimación: es la cuenta ✓.
- `input_tokens` = lo que mida el estimador ✓ sobre el prompt ✓.
- `output_tokens` = el `max_tokens` del modelo de cada voz ✓, y
  `max_output_tokens` = la suma ✓.
- `provider` = `:local` o `:remote` ✓, según el modelo de la voz ✓.
- `cost_eur` = `nil` si es local ✓ —no hay precio, y un 0 sería un precio
  falso ✓— o el coste estimado ✓ si es remoto ✓.

**Cero llamadas a modelos** ✓: el `Estimate` sale de la configuración ✓ y del
estimador ✓. Si un día hiciera falta llamar a un modelo para saber lo que va a
costar, esa llamada **sería** el coste ✓, y entonces `estimate/2` dejaría de
ser gratis ✓ y su nombre Mentiría ✓.

### 3.3 · Las dos rondas

1. El original va a **cada voz** ✓.
2. Después, el original **más** las respuestas atribuidas a cada voz ✓.
3. Después, el **oráculo** sintetiza ✓.

Una voz que falla o expira va a `unanswered` ✓ y **no tumba la mesa** ✓: la
respuesta parcial es una respuesta ✓.

`usage.inferences = N + N + 1` ✓, o el número **real** de voces que
respondieron ✓ si algunas no lo hicieron ✓.

**El formato de la atribución** ✓ —cada respuesta lleva **quién la dijo** ✓,
que es lo que hace que una segunda ronda no sea la misma pregunta repetida ✓:

```elixir
%{voice: "critica", role: :critic, text: "el TTL no está en el esquema", round: 1}
```

El `voice` es el **nombre de la configuración** ✓ (`[mesa.voice.critica]` ✓), no
el modelo ✓: quien configura las voces es quien las reconoce ✓, y el modelo
puede cambiarse sin que cambie el nombre ✓.

### 3.4 · Si el oráculo falla

`{:error, {:oracle_failed, reason}}` ✓.

El oráculo es **la última inferencia** ✓, y si falla, la mesa **no tiene
respuesta** ✓: devolver las rondas sin sintetizar sería devolver media
respuesta ✓ sin decirlo ✓, y quien llama creería que la mesa terminó ✓.

La razón va **dentro** ✓, y no de vuelta: `{:oracle_failed, :timeout}` y
`{:oracle_failed, {:http, 503}}` son cosas distintas ✓, y quien llama decide
qué hacer con cada una ✓.

### 3.5 · La telemetría

Dos eventos, con la convención del repo ✓ (`[:candil, ...]` ✓, como
`[:candil, :llm, :chat, :start]` ✓ o `[:candil, :router, :decision]` ✓):

```elixir
:telemetry.execute([:candil, :mesa, :run, :start], %{}, %{voices: names, provider: p})
:telemetry.execute([:candil, :mesa, :run, :stop], %{duration: ms, inferences: n},
                   %{voices: names, unanswered: u, provider: p})
```

- `duration` ✓ en milisegundos ✓.
- `inferences` ✓ = las que **pasaron** ✓, no las que se pidieron ✓: la
  diferencia es exactamente lo que se perdió ✓.
- `unanswered` ✓ = cuántas voces no respondieron ✓.
- `voices` ✓ = los nombres ✓, no los modelos ✓.

Y **el evento tiene que tener a alguien suscrito** ✓: el repo ya lo escribió
✓ —*«un evento al que nadie está suscrito es un contador que nadie mira»* ✓.

### 3.6 · La frontera de D-12

**D-12** ✓: *«Candil manda la pregunta; la respuesta no es suya»* ✓.

La mesa **no dice si la respuesta del usuario es correcta** ✓. Lo que hace es
**preguntar lo mismo a varias voces** ✓ y **sintetizar lo que dijeron** ✓ —que
es lo que el usuario pidió ✓—, no **dictaminar** ✓.

La diferencia no es de estilo ✓, es de contrato ✓:

- Si la mesa **juzgara** la respuesta del usuario ✓, tendría que saber si es
  correcta ✓, y no lo sabe ✓ → `{:error, :not_a_judge}` ✓.
- Si la mesa **sintetiza** ✓, hace lo que se le pidió ✓ y quien lee decide ✓.

El **oráculo** sintetiza ✓; no evalúa ✓. Si un día se le pide que evalúe ✓,
eso es **otra** mesa ✓, con su propia decisión ✓ — y con D-12 escrita otra vez ✓.

### 3.7 · La configuración

```toml
[mesa]
oracle = "analyst"           # el modelo que sintetiza
default_timeout_ms = 120000
max_voices = 4

[mesa.voice.critica]
model = "verifier"
role = "critic"
instruction = "Ataca la respuesta del original"
enabled = true
```

### 3.8 · Lo que la mesa **no** hace

- **No decide VRAM ni carga modelos** ✓: llama a `Candil.chat/2` ✓ y respeta al
  scheduler ✓. Para voces locales, **concurrencia 1** por defecto ✓; para
  remotas, configurable ✓.
- **No depende de `Candil.RAG`** ✓.
- **No toca `Candil.CLI`** ✓.

## 4 · Las fases

| Fase | Qué | Prerrequisito |
|---|---|---|
| **F9.1** | `SharedMemory` + tests | ninguno |
| **F9.2** | `Voice`, roles, `[mesa]` en el esquema y la plantilla | F9.1 |
| **F9.3** | `TwoRounds` + `Oracle.Model` con backend falso | F9.2 |
| **F9.4** | Timeout, parciales, telemetría | F9.3 |
| **F9.5** | `estimate/2` + la confirmación | F9.3 |
| **F9.6** | Aceptación de framework: estrategia y oráculo **de un tercero**, sin tocar Candil | F9.3–F9.5 |

---

## 5 · Los criterios de aceptación

- `SharedMemory` funciona **sin RAG ni embedder** ✓, y sus tests están en
  verde ✓.
- `Mesa.run/2` con **dos voces falsas** devuelve 2 respuestas de la ronda 1 ✓, 2
  de la ronda 2 ✓ y 1 del oráculo ✓, con `usage.inferences == 5` ✓.
- Una voz que **expira** aparece en `unanswered` ✓ y la mesa devuelve
  `{:ok, result}` ✓.
- `estimate/2` hace **cero** llamadas ✓; `run/2` sin confirmar devuelve
  `{:error, {:confirmation_required, estimate}}` ✓, y con `confirm` ejecuta ✓.
- `put/3` devuelve **`{:ok, entry}`** ✓ con la **versión** que se ha escrito ✓, y
  con `:expected_version` equivocado **no escribe** ✓ y dice
  `{:error, :version_conflict}` ✓.
- Un oráculo que **falla** devuelve `{:error, {:oracle_failed, reason}}` ✓, y no
  media respuesta sin decirlo ✓.
- La telemetría emite **`[:candil, :mesa, :run, :start]`** ✓ y
  **`[:candil, :mesa, :run, :stop]`** ✓, con `duration` ✓, `inferences` ✓ y
  `unanswered` ✓ —y **alguien está suscrito** ✓.
- La mesa **no juzga** la respuesta del usuario ✓ (D-12 ✓): sintetiza lo que
  dijeron las voces ✓ y no dictamina ✓.
- `[mesa]` y `[mesa.voice.*]` **validan** ✓, y un rol o un modelo inválido
  **nombra la clave exacta** ✓.
- Un tercero define `Strategy` y `Oracle` **en un test** ✓ y funciona sin tocar
  `lib/` ✓ — que es el criterio de framework del repo ✓.
- `grep` **no** encuentra `Candil.CLI` ni `Candil.RAG` en
  `lib/candil/mesa/**` ni en `shared_memory.ex` ✓.
- Las puertas: tests con semillas 0 y 1 ✓, `mix credo` ✓, `mix dialyzer` ✓,
  `mix docs` ✓.

---

## 6 · Lo que este spec **no** decide

- **El modelo del oráculo por defecto** ✓: se configura, y el valor por defecto
  sale de lo que haya en el catálogo ✓.
- **Si la mesa tiene memoria persistente entre reinicios** ✓: `SharedMemory`
  es ETS ✓ y se pierde al parar ✓. Persistirla es otra decisión ✓.
- **El número máximo de voces por defecto** ✓: `max_voices` lo dice ✓, pero el
  valor de fábrica es de este spec ✓ y se puede cambiar ✓.
