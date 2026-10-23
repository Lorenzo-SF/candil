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
| `put(key, value, opts)` | Escribe. `:author` **obligatorio**, `:expires_at` y `:supersedes` opcionales | `:ok` \| `{:error, :author_required}` \| `{:error, :version_conflict}` |
| `put_new(key, value, opts)` | Escribe **solo si no existe**. Atómico | `:ok` \| `{:error, :exists}` |
| `get(key)` | Lee | `{:ok, entry}` \| `{:error, :not_found}` \| `{:error, :expired}` |
| `delete(key)` | Borra | `:ok` \| `{:error, :not_found}` |
| `supersede(key, new_key, value, opts)` | Escribe la nueva y marca la vieja con `superseded_by` | `:ok` \| error |
| `list(prefix)` | Las claves que empiezan por el prefijo | `[entry]` |
| `prune(now)` | Caducadas y viejas. Devuelve **conteos** | `%{expired: n, superseded: n}` |

- `put/3` sin `:author` devuelve `{:error, :author_required}` ✓: **quien escribe,
  se sabe** ✓.
- `put/3` con `:expected_version` hace **compare-and-swap** ✓: si la versión no
  es la que el que escribe vio, no escribe ✓. Es lo que permite que cinco
  procesos escriban a la vez sin pisarse ✓.
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
- `Candil.Mesa.Strategy` es un **behaviour** ✓, con `Candil.Mesa.TwoRounds` por
  defecto ✓.
- `Candil.Mesa.Oracle` es un **behaviour** ✓, con `Candil.Mesa.Oracle.Model` por
  defecto ✓, que llama al modelo configurado ✓.

### 3.1 · Las dos rondas

1. El original va a **cada voz** ✓.
2. Después, el original **más** las respuestas atribuidas a cada voz ✓.
3. Después, el **oráculo** sintetiza ✓.

Una voz que falla o expira va a `unanswered` ✓ y **no tumba la mesa** ✓: la
respuesta parcial es una respuesta ✓.

`usage.inferences = N + N + 1` ✓, o el número **real** de voces que
respondieron ✓ si algunas no lo hicieron ✓.

### 3.2 · La configuración

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

### 3.3 · Lo que la mesa **no** hace

- **No decide VRAM ni carga modelos** ✓: llama a `Candil.chat/2` ✓ y respeta al
  scheduler ✓. Para voces locales, **concurrencia 1** por defecto ✓; para
  remotas, configurable ✓.
- **No depende de `Candil.RAG`** ✓.
- **No toca `Candil.CLI`** ✓.

---

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
