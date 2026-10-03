# Auditoría · ¿están realmente integrados los repos hermanos?

> **Fecha**: 2026-10-03 · **Medido sobre** `candil` @ `f6-context` (main + D8) y los
> seis repos clonados a `main`.
> **Método**: `grep` de cada símbolo en `lib/` de Candil, y lectura del código de los
> hermanos. Nada de lo de aquí sale de leer el `mix.exs`: es lo que el `mix.exs` dice
> contrasted con lo que el código hace.

# Auditoría · ¿están realmente integrados los repos hermanos?

> **Fecha**: 2026-10-03 · **Medido sobre** `candil` @ `f6-context` y los seis repos
> clonados a `main`.
> **Método**: `grep` de cada símbolo en `lib/` de Candil, y lectura del código de los
> hermanos. Nada de lo de aquí sale de leer el `mix.exs`: es lo que el `mix.exs` dice
> contrasted con lo que el código hace.

---

## 0. Estado tras la integración (lo que se hizo con esta auditoría)

La tabla de la §1 midió el **antes**. Esto es el **después**, medido igual:

| Dep | Antes | Ahora | Qué cambió |
|---|---|---|---|
| **alaja** | 2 símbolos en 2 de 9 ficheros del CLI | **el CLI entero**, con `use Alaja.CLI.Definition` | El parseo, el help, el despacho, los errores de uso y el color son de Alaja. Candil queda con la *declaración* y nada más. |
| **botica** | 1 símbolo (`Batteries.Memory`) | **2** (`Memory` + `Batteries.Disk`) | El octavo check de `doctor` es `Botica.Batteries.Disk.check_disk/3`. |
| **arrea** | 9 símbolos / 5 ficheros | **9 + telemetría + sin duplicados** | `Candil.RateLimiter` (67 líneas, duplicado) sustituido por `Arrea.RateLimiter`; todos los eventos de Candil se reflejan por `Arrea.Telemetry`. |
| **apero** | 7 símbolos / 10 ficheros | **9 símbolos**, escrituras atómicas | `Apero.Atomic.File` en `Config.File` y en `Instances`, que reimplementaban a mano el temp + rename. |
| **trebejo** | 1 símbolo | igual, y es todo lo que hay | Revisado símbolo por símbolo: `OS.arch/0` es todo lo que Candil necesita. Ver abajo. |

### El CLI, al DSL

`Candil.CLI` pasó de ser una tabla `@commands` con un parser propio en cada módulo a
ser una **declaración** con `use Alaja.CLI.Definition`. Eso no es cosmético: el
`@switches` de `Lifecycle` llevaba cuatro flags que el parser aceptaba (`--force`,
`--cpu`, `--yes` y los cortos `-p/-f/-d/-y`) y que el help nunca mencionó. El DSL
obligó a declararlos, y con ellos su descripción y sus alias, en el mismo sitio.

Dos cosas se quedan en Candil a propósito, en `Candil.CLI.Escript`:

- **Los alias de nombre** (`-v`, `--version`, `model`). `command/3` del DSL no tiene
  `aliases:`; declararlos como comandos extra habría metido cinco fantasmas en el help.
- **La decisión de terminal.** `Alaja.CLI.NoColor.sync/1` solo cubre `--no-color`; el
  resto cae en `IO.ANSI.enabled?/0`, que mira `ansi_enabled` y **no** si stdout es un
  tty. En un escript eso es `true`, y `candil doctor > report.txt` escribía escapes en
  el fichero. El límite toma la decisión una vez y se la pasa a Alaja.

### El bump de Alaja que hizo falta

`candil run --help` no imprimía nada: `unknown flag '--help'`. No era un bug de
Candil. El lock fijaba `alaja` en `d8c733e`, y ese SHA **no contiene** ninguna
traza de `command_help` / `help_exit_block` — la ayuda por comando llega en
`f755938` ("Feat/cli dsl v2"). El lock se movió a ese SHA.

Corolario para el futuro: `Alaja.CLI.Help.full/1` **no** es un renderizador genérico,
es el help del propio Alaja (título "Alaja CLI", su cookbook, sus typed messages).
Para un host externo está `render_host_help/2`, que Alaja aplica a quien no sea ella
— y nombra a `candil` en el comentario de esa rama.

### Lo que sigue pendiente

- `candil models list --help` imprime el help **y luego ejecuta el comando**. Es un
  bug de Alaja (la rama de subcomando devuelve antes de cortar el despacho), no de
  Candil. Está anotado aquí y no se ha tocado el repo del hermano.
- El uso de los booleanos en la línea `USAGE` (`candil run  --detach  ... <model>`)
  muestra los que tienen `default: false` como si fueran obligatorios. Cosmético, y
  también del renderizador de Alaja.

---

### Segunda ronda: Arrea, Apero y Trebejo

**`Candil.RateLimiter` fuera.** Eran 67 líneas de ventana deslizante sobre ETS
contra las 269 de `Arrea.RateLimiter`, que además se apoya en Apero. Se usaba en
un solo sitio, `Candil.HTTP.Retry`, y **no tenía un solo test** — que es
exactamente cómo un duplicado sobrevive un año de CI en verde. Ahora es
`Candil.HTTP.RateLimit`, con sus tests.

El algoritmo no es el mismo y conviene decirlo: la ventana deslizante de "N por
segundo" deja pasar 2N en la frontera entre dos segundos; un cubo de tokens con
`capacity: N, refill_per_second: N` no. Para una API de LLM el comportamiento
estricto es el correcto.

Cuando Apero no está, `Arrea.RateLimiter` contesta `:apero_unavailable` y Candil
degrada a "sin límite", con un log. degrading y no fallar es lo que evita que
una dependencia opcional ausente convierta un rate limit en una caída.

**Telemetría reflejada.** Todos los eventos de `Candil.Telemetry` se emiten dos
veces desde un único `execute/3` privado: en `[:candil, ...]` como siempre, y en
`[:arrea, :candil_*]` a través de `Arrea.Telemetry.emit/3`. Un host que ya tiene
handlers de Arrea ve a Candil sin adjuntar nada. Se añadieron los eventos que no
existían: `:candil_engine_start/stop` y `:candil_http_request/response`.

Deliberadamente **no** se usa `Arrea.Telemetry.measure/2`: rescata excepciones y
devuelve `{:ok, result}`, así que envolver con él una llamada de inferencia
cambiaría su tipo de retorno.

**Apero: escrituras atómicas.** `Candil.Config.File` y `Candil.Instances`
reimplementaban "escribe a un temporal y renombra". Ahora es
`Apero.Atomic.File.write/3`, que además limpia el temporal si falla y reintenta
`:eagain`. El de `Instances` además tenía un bug: si el `rename` fallaba, el
temporal se quedaba ahí para siempre.

### Trebejo: no hay nada más que integrar

Revisado símbolo por símbolo, y la respuesta es que `OS.arch/0` es todo lo que
Candil necesita:

- `Trebejo.Git` es de credenciales y de disponibilidad del CLI de GitHub.
  Candil no hace operaciones git.
- `Trebejo.File` es un *watcher* de ficheros, no una utilidad de filesystem.
  Candil no vigila ficheros.
- `Trebejo.Proc` ya está, y cubierto por `Apero.Proc`.

Añadir integraciones de Trebejo que nadie va a usar sería peor que no
tenerlas. Este es el caso en el que la respuesta correcta es "no".

### Lo que queda sin integrar, y por qué

`Arrea.Parallel`, `Arrea.Bulkhead`, `Arrea.Pool` y `Arrea.Monitor` no se usan, y
es a propósito: **no hay ningún `Task.async` en `lib/`**. No existe un fan-out
que migrar, y `doctor` paralelizaría ocho checks cuyo orden es parte del
resultado. Cuando F6 traiga el fan-out de retrieval y las llamadas MCP, ahí sí.

Sobre el doc de `Candil.Engine.Server`: afirmaba que el aislamiento de caídas
venía de `Arrea.WorkerSupervisor`. Es verdad a medias, y la mitad falsa importaba
— el proceso OS cuelga de Arrea, pero ese GenServer cuelga de
`Candil.EngineSupervisor`. Un host leyendo el doc buscaría esos procesos en el
árbol de Arrea y no los encontraría. Corregido el doc; el código no se movió
porque unificar los dos supervisores haría más difícil, no más fácil, saber qué
proceso es de quién.

---

## 1. Respuesta corta

**No, no de forma consistente.** Tres de los cinco hermanos están integrados de verdad.
**Alaja está a un 20 % de lo que su comentario dice**, y **Botica a la mitad**.

| Dep | Símbolos usados en `lib/` | Ficheros | Estado real |
|---|---|---|---|
| **apero** | 7 (`Http`, `Http.Finch`, `OS.type`, `Proc`, `Retry`…) | 10 | ✅ **integrado**, y de forma transversal |
| **arrea** | 9 (`CircuitBreaker`, `LongRunning`, `Registry`, `Telemetry`…) | 5 | ✅ **integrado** |
| **trebejo** | 1 (`OS.arch/0`) | 1 | ⚠ **mínimo**, y es lo que dice el diseño: es `optional` y `runtime: false` |
| **alaja** | **2** (`Components.Table`, `Printer`) | **2 de 9** del CLI | ❌ **parcial** |
| **botica** | **1** real (`Batteries.Memory`) | 1 | ❌ **la mitad**: no hay check de disco |
| **pote** | 0 | 0 | — no es dep directo de Candil, llega transitivo |

**Sobre `pote`**: no aparece en el `mix.exs` de Candil. Está en `mix.lock` como
`{:hex, :pote, "3.0.0"}` porque otro hermano lo arrastra. No hay nada que integrar
ni que quitar.

---

## 2. Alaja, que es la pregunta

### Lo que dice el `mix.exs`

> Alaja: CLI definition, tables, colour. Used only by `lib/candil/cli/**` and
> `lib/candil/doctor.ex`.

### Lo que hace el código

| Fichero del CLI | Alaja / `Say` | `IO.puts` / `IO.write` |
|---|---|---|
| `models.ex` | 17 | 0 |
| `lifecycle.ex` | 16 | 2 |
| `doctor.ex` | **0** | 3 |
| `help.ex` | **0** | 4 |
| `version.ex` | **0** | 1 |
| `colorize.ex` | 0 | 1 (justificado, abajo) |
| `ports.ex` | 0 | 0 |
| `preflight.ex` | 0 | 0 |

**Alaja se usa en 2 de los 9 ficheros del CLI. Los otros 7 imprimen con `IO.puts`.**

Y el comentario **miente en la parte concreta**: dice que Alaja se usa en
`cli/**` **y en `doctor.ex`**, y `doctor.ex` **no usa Alaja ni una vez**. Los tres
`IO.puts` de ahí son `IO.puts(Jason.encode!(...))`, `IO.puts(Check.render(...))` y
`IO.puts(unsolved(...))`: el informe del doctor se renderiza **a mano**, con un
`render/1` propio, teniendo Alaja con `Components.Table` y `Printer` a mano.

### Lo que Alaja ofrece y Candil ignora

Alaja **no es solo una librería de tablas y color**. Tiene un framework de CLI
completo, y su último commit es justamente *"Feat/cli dsl v2"*:

```
lib/alaja/cli.ex                    el punto de entrada, definido con su propio DSL
lib/alaja/cli/definition.ex         el DSL: command/2, halt_on_error, command_help…
lib/alaja/cli/help.ex               summary/1, full/1, command/1
lib/alaja/cli/color.ex              parse/1, parse_list/1, formats/0
lib/alaja/cli/no_color.ex           la política de color
lib/alaja/cli/action_error.ex
lib/alaja/config.ex                 color_enabled?/0
```

Tres cosas que Candil **reimplementa** sin saber que ya existen:

1. **`Candil.CLI.Help`** (63 líneas) construye la tabla de comandos y la pinta a
   mano. `Alaja.CLI.Help` tiene `summary/1`, `full/1` y `command/1` para eso.
2. **`Candil.CLI.Colorize.enabled?/0`** decide el color mirando `NO_COLOR` y `TERM`
   a mano. `Alaja.Config.color_enabled?/0` lo hace con una prioridad documentada en
   tres niveles — *flag de CLI > `NO_COLOR` > `IO.ANSI.enabled?`* — y además
   contempla un caso que Candil no contempla: dentro de un daemon `Batamanta`,
   `IO.ANSI.enabled?/0` es **siempre `false`**, así que el criterio de Candil
   desactivaría el color en un contexto donde sí funciona.
3. **El render del doctor** podría usar `Components.Table`, que Candil ya usa en
   `models.ex` para los modelos. O sea: la misma librería se usa en un comando y no
   en el hermano de al lado.

### Lo que Candil **no** duplica (y conviene no tocar)

**`Candil.CLI.Colorize` no es un clon de Alaja.** No colorea texto: colorea la
**línea de salida de `llama-server` según un regex**, y su moduledoc razona el
criterio — *"anything unrecognised is passed through untouched. A colouriser that
swallows or rewrites unknown output is a colouriser that will eventually hide the
very error it was added to surface."* Eso es dominio de Candil y está bien como
está. Lo único discutible de ese fichero es `enabled?/0`, y por lo que he contado
arriba.

---

## 3. Botica: el otro comentario que no cuadra

El `mix.exs` dice que Botica se usa *"only by `candil doctor` for the generic
memory/disk checks"*. La realidad:

- `Botica.Batteries.Memory` → **sí**, en `lib/candil/doctor.ex:40`.
- `Botica.Batteries.Disk` → **no existe**. Aparece **solo dentro del moduledoc** de
  `doctor.ex`, que dice: *"Those two go to `BoticaMemory` and
  `Botica.Batteries.Disk`"*.
- `Botica.Doctor` → solo en un comentario de `lib/candil/health.ex`.

**No hay check de disco.** Los siete checks son `config`, `binary`, `sources`,
`ports`, `auth`, `gpu`, `memory`. El disco no está, y el moduledoc afirma que sí.

---

## 4. La afirmación que **sí** es cierta

El bloque sobre `batamanta` acierta: la dep es `optional: true, runtime: false` y
Alaja **no la referencia en código**. Las 5 apariciones de "Batamanta" en
`alaja/lib/` están **todas en comentarios o en un `@doc`**, explicando el efecto del
daemon sobre la detección de color. La afirmación se sostiene.

---

## 5. Qué sigue, y qué no decido yo

**Barato y obvious** (si quieres que lo haga):
- corregir los dos comentarios que mienten, en `mix.exs` y en el moduledoc del
  doctor. Son la causa de que esto fuera invisible.
- decidir si el check de disco entra, y si entra, que use `Botica.Batteries.Disk`
  de verdad. El diseño lo contempla; el código no.

** Caro, y es decisión de dueño:**
- **migrar el CLI de Candil al DSL de Alaja**. No es un cambio de imports: es
  redefinir `Candil.CLI` con `Alaja.CLI.Definition`, y eso toca el despacho, el
  `--help`, los errores y los tests del CLI. Es trabajo de un día, y **cambia el
  contrato del binario**, que es justo lo que la F3 dio por cerrado.
- **qué hacer con `Colorize.enabled?/0`**: delegar en `Alaja.Config.color_enabled?/0`
  (menos código, más correcto) o dejarlo (independiente, y Candil no depende de la
  config de Alaja para decidir si escribe ANSI).

**No lo he tocado.** Ninguno de los dos es un bug, y los dos cambian un contrato
público. La auditoría es la respuesta; la decisión es tuya.
