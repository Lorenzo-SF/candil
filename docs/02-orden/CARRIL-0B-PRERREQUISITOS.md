# CARRIL 0B · Los tres prerrequisitos del núcleo — spec

> **Estado**: **borrador** (2026-10-23) ✓, a la espera de la aprobación del
> dueño ✓. **No es una fase empezada**: es el plano ✓.
>
> **Dónde encaja**: el carril **0b** del plan de [`docs/02-orden/`](README.md)
> §5.1 ✓, y su hermano del carril **0a** ✓ —las decisiones y los documentos ✓—
> que van en el PR #137 ✓.
>
> **Qué es**: los tres prerrequisitos que la extracción del CLI necesita ✓, y
> que **son de framework** ✓ —son API del núcleo ✓—:
>
> 1. **El draft** lo baja el núcleo ✓ (`Installer.download_model/1` ✓), no el
>    CLI ✓.
> 2. **`Candil.remove/1` y `Candil.forget/1`** ✓: quitar del catálogo es del
>    núcleo ✓, no del CLI ✓.
> 3. **El `Holder`** usa `Candil.Engine.stop/1` ✓, y deja de usar
>    `Candil.Engine.Server.id_for/2` ✓.
>
> **Por qué el 0b y no el 0a**: con el contrato escrito ✓ pero el draft todavía
> en el CLI ✓, el proyecto nuevo nace dependiendo de una API que no existe ✓.

---

## 1 · Lo que hay hoy

### 1.1 · El draft

| Fichero | Qué hace | El problema |
|---|---|---|
| `lib/candil/installer.ex:68-84` | `download_model/1` baja el **principal** ✓ | El **draft no se baja nunca** ✓. Y la rama `:local` (`:72-74` ✓) devuelve la ruta **sin comprobar que el fichero exista** ✓ |
| `lib/candil.ex:140-155` | `Candil.pull/1` baja engine y modelo ✓ | Usa `:ok = Candil.Llm.download_engine(engine)` ✓ y `{:ok, _} = Candil.Llm.download_model(model_struct)` ✓: un fallo se convierte en un **`MatchError`** ✓, no en un `{:error, reason}` ✓ |
| `lib/candil/cli/models.ex:172-198` | `Candil.CLI.Models.pull/1` baja el **draft** ✓ | La lógica del draft vive **en el CLI** ✓, y por tanto **no se va con la extracción** ✓, y `Candil.pull/1` **no lo baja** ✓: quien usa la API se queda sin draft ✓ |
| `lib/candil/source.ex:261-266` | `fetch/2` con `:local` ✓ | Devuelve la ruta **sin comprobar que exista** ✓, aunque su `@doc` dice que sí ✓ |
| `lib/candil/model.ex:377-385` | `downloaded?/1` ✓ | Solo mira el **principal** ✓: un modelo con principal y sin draft se declara «descargado» ✓, y luego **no arranca** ✓ |

El daño real ✓: `models list` ✓, `Doctor` ✓ y `Preflight` ✓ dicen que un modelo
a medias está listo ✓, y el motor lo dice al arrancar ✓ —*«failed to open GGUF
file»* ✓— cuando ya es tarde ✓.

### 1.2 · `remove` y `forget`

`Candil.CLI.Models.remove/1` ✓ borra los ficheros ✓ y hace
`Store.deregister_model/1` ✓. **No existe** ninguna operación de núcleo ✓:
quitar un modelo del catálogo es cosa del CLI ✓, y por tanto **no sobrevive a
la extracción** ✓.

Y hay un detalle que pesa ✓: `Config.File.save/2` (`config/file.ex:215-222` ✓)
**reescribe el TOML entero** ✓ desde el mapa ✓ —los **comentarios se
pierden** ✓— y el propio fichero avisa de que *«`candil.toml` es la fuente de
verdad de todo el catálogo»* ✓. Reescribir ese fichero a ciegas para quitar
un modelo es perder información que no se puede recuperar ✓.

### 1.3 · El `Holder`

- `lib/candil/cli/holder.ex:152` ✓: `block(Server.id_for(model, engine))` ✓.
- `:236` ✓: `block(id)` ✓.
- `:270` y `:274` ✓: `LongRunning.stop(id)` ✓.

Es decir: el `Holder` —**que vive en el CLI** ✓— depende de
`Candil.Engine.Server.id_for/2` ✓, que es **interno** ✓, y de
`Arrea.LongRunning` ✓. `Candil.Engine.stop/1` ✓ ya existe ✓, es **público** ✓
y limpia el pool ✓.

---

## 2 · Los contratos

### 2.1 · El draft

```elixir
@spec download_model(Candil.Model.t()) ::
        {:ok, binary()}
        | {:error, term()}
        | {:error, {:draft_failed, term(), binary()}}
```

- **El principal primero** ✓, el draft después ✓.
- Si el principal falla ✓: `{:error, reason}` ✓, y **no se intenta el draft**
  ✓.
- Si el principal está bien ✓ y el draft falla ✓:
  `{:error, {:draft_failed, reason, main_path}}` ✓ — **sin borrar el
  principal** ✓, porque volver a bajarlo son 17 GB ✓, y porque **el principal
  sí sirve** ✓: un modelo sin draft arranca ✓, solo pierde la decodificación
  especulativa ✓.
- La rama `:local` ✓ **comprueba que el fichero existe y no está vacío** ✓: si
  no, `{:error, ...}` ✓, en vez de devolver una ruta que no lleva a nada ✓.
- `Candil.Model.downloaded?/1` ✓ **exige también el draft declarado** ✓. Es lo
  que hace que `models list` ✓, `Doctor` ✓ y `Preflight` ✓ dejen de mentir ✓.
- `Candil.pull/1` ✓ usa `with` ✓ y **propaga** el error ✓: nada de
  `MatchError` ✓.
- `Candil.CLI.Models.pull/1` ✓ llama a `Candil.pull/1` ✓ y **solo formatea** ✓:
  no vuelve a llamar a `Source.fetch/2` ✓ ni decide **qué** es un draft ✓.

### 2.2 · `remove` y `forget`

```elixir
@spec forget(String.t() | atom()) :: :ok | {:error, :model_not_found}
@spec remove(String.t() | atom()) :: :ok | {:error, term()}
@spec remove(String.t() | atom(), keyword()) :: :ok | {:error, term()}
```

- **`forget/1`** ✓: **solo** `Store.deregister_model/1` ✓. No borra ficheros ✓,
  no toca `candil.toml` ✓, no para el motor ✓. Es «quita esto del catálogo y
  deja los ficheros donde están» ✓.
- **`remove/1`** = `remove(alias, [])` ✓.
- **`remove/2`** ✓ admite `:stop` (por defecto `false` ✓), `:force` (por defecto
  `false` ✓) y `:config_path` (por defecto `Config.File.default_path()` ✓).
- **Con el motor vivo** ✓: `remove/1` **se niega** ✓ con
  `{:error, {:engine_running, alias}}` ✓. `remove(alias, stop: true)` ✓ lo
  **para** con `Candil.Engine.stop/1` ✓ y sigue ✓.
- **Una instancia detached** ✓: se niega **siempre** ✓, con
  `{:error, {:detached_instance, ports}}` ✓ — desde esta VM **no se puede
  parar** ✓, y el operador tiene que hacer `stop` antes ✓.
- **`candil.toml`** ✓: **no se reescribe** ✓. Si el alias está **declarado** ✓,
  `remove/1` devuelve `{:error, {:declared_in_config, path}}` ✓ y el operador
  borra el bloque ✓. `force: true` ✓ permite borrar los ficheros igualmente ✓,
  **dejando el TOML intacto** ✓ y avisando de que el modelo **volverá** al
  recargar ✓.
- **`Installer.remove_model/1`** ✓: borra el principal ✓, el draft ✓, el
  `.part` ✓ y el `.complete` ✓; **idempotente** ✓ con ficheros ausentes ✓; y si
  falla algún borrado ✓, devuelve `{:error, {:files_not_removed, fallos}}` ✓ y
  **no desregistra** del Store ✓ —así el catálogo sigue diciendo la verdad ✓.
- `Source` gana `part_path/1` y `complete_path/1` (`@doc false` ✓) ✓, para no
  repetir los sufijos en tres sitios ✓.
- **`Candil.CLI.Models.remove/1`** ✓ deja de borrar ficheros ✓ y de llamar a
  `Store.deregister_model/1` ✓: confirma ✓, llama a
  `Candil.remove(alias, stop: true)` ✓ y formatea el error ✓.

### 2.3 · El `Holder`

- `Candil.CLI.Holder.block/1` ✓ pasa de `block(id)` ✓ a **`block(alias ::
  atom())`** ✓.
- `hold/1` ✓ llama a `Candil.Engine.stop(alias)` ✓ tanto en `:stop` ✓ como en
  `{:EXIT, ...}` ✓.
- `Engine.stop/1` ✓ devuelve `:ok` ✓ o `{:error, :not_running}` ✓: los dos
  significan **que el motor ya no está** ✓.
- `Candil.Engine.Server.id_for/2` ✓ **sigue interno** ✓: solo lo usan
  `Server.init/1` ✓, `Server.terminate/2` ✓ y `Server.handle_call(:os_pid, …)` ✓.
  El `Holder` **deja de importar** `Candil.Engine.Server` ✓ y
  `Arrea.LongRunning` ✓.
- **El test** ✓: arrancar un `Engine.start/3` real ✓ con un binario falso que
  escriba su PID ✓ y duerma ✓; llamar a `Holder.block(model.alias)` ✓;
  comprobar que el proceso del sistema operativo **desaparece** ✓.

---

## 3 · El orden y el paralelismo

| Unidad | Qué | Espera a | Comparte ficheros con |
|---|---|---|---|
| **0b.1** | El draft ✓ | el 0a ✓ | `lib/candil.ex` ✓, `installer.ex` ✓, `model.ex` ✓, `source.ex` ✓ |
| **0b.2** | `remove` y `forget` ✓ | **0b.1** ✓ | `lib/candil.ex` ✓, `installer.ex` ✓ |
| **0b.3** | El `Holder` ✓ | el 0a ✓ | `lib/candil/cli/holder.ex` ✓ |

- **0b.1 y 0b.3 en paralelo** ✓: no comparten ficheros ✓.
- **0b.2 después de 0b.1** ✓: comparten `lib/candil.ex` ✓ e `installer.ex` ✓.
- **Orden de merge** ✓: `0b.1` → `0b.2` → `0b.3` ✓, o `0b.3` en cuanto esté ✓
  —no hay dependencia con `0b.2` ✓.
- **La extracción empieza después de 0b completo** ✓, no solo de 0a ✓.

---

## 4 · La extracción

### 4.1 · Qué se mueve

- `lib/candil/cli.ex` ✓ y `lib/candil/cli/**` ✓.
- `test/candil/cli/**` ✓ y `test/candil/cli_test.exs` ✓.
- El escript ✓, `Alaja` ✓, `Batamanta` ✓, los alias `generic` e `install` ✓ y
  el workflow de terminal ✓.

### 4.2 · Qué se queda

El motor ✓, el scheduler ✓, la VRAM ✓, el modelo ✓, el `Source` ✓, el
`Installer` ✓, el `Store` ✓, el router ✓, el gateway ✓, el `Doctor` ✓, la
telemetría ✓, el `Config` ✓, el `Preflight` ✓ y las `Instances` ✓.

### 4.3 · Alaja y Batamanta

**No se mueven de su repositorio** ✓: pasan a ser **dependencia del proyecto
CLI** ✓, no de Candil ✓. Candil es una librería ✓ y no arrastra un framework
de terminal ✓.

### 4.4 · zaguan

- `repos.yaml` ✓ pasa a declarar Candil como **librería** ✓ de forma coherente
  ✓: hoy la sección dice *«50: librería»* ✓ pero la leyenda de arriba dice
  *«escript (arrea, candil)»* ✓ — **se contradicen** ✓.
- Se **añade** el proyecto CLI ✓ con su propio `<cli>.d/<cli>.sh` ✓.
- `README.md` ✓ actualiza la tabla ✓ y el conteo ✓.
- `candil.d/candil.sh` ✓ queda como **instalación de librería** ✓; el proyecto
  nuevo **enlaza** el binario ✓. El comando puede seguir llamándose `candil` ✓.

### 4.5 · Lo que se deja de exponer

`Candil.CLI.main/1` ✓ deja de existir como **API in-process** ✓, y hay que
**documentarlo** ✓: es la primera cosa que se rompe para quien lo usara ✓.

---

## 5 · Los criterios de aceptación

- `Candil.pull/1` ✓ con un engine que **no** existe ✓ devuelve
  `{:error, reason}` ✓ y **no** un `MatchError` ✓.
- `Candil.pull/1` ✓ con un modelo **declarado** con draft ✓ deja los **dos**
  ficheros en disco ✓.
- `Candil.pull/1` ✓ con un draft **que falla** ✓ devuelve
  `{:error, {:draft_failed, reason, main_path}}` ✓, deja el principal ✓ y
  **no** lo vuelve a bajar ✓.
- `Model.downloaded?/1` ✓ es `false` ✓ si falta el draft declarado ✓.
- `Candil.forget/1` ✓ **no borra ficheros** ✓ ni toca el TOML ✓.
- `Candil.remove/1` ✓ con el motor vivo ✓ **se niega** ✓;
  con `stop: true` ✓ lo para ✓ y sigue ✓.
- `Candil.remove/1` ✓ con el alias **declarado en `candil.toml`** ✓ **se
  niega** ✓ y **no reescribe el TOML** ✓; con `force: true` ✓ borra los
  ficheros ✓ y **avisa** ✓.
- `Installer.remove_model/1` ✓ es **idempotente** ✓ y, si un borrado falla ✓,
  **no desregistra** ✓.
- `Holder.block/1` ✓ **para el motor** ✓, y el proceso del sistema operativo
  desaparece ✓.
- `grep` **no** encuentra `Candil.Engine.Server` ✓ ni `Arrea.LongRunning` ✓ en
  `lib/candil/cli/holder.ex` ✓.
- Las puertas de siempre ✓: tests con semillas 0 y 1 ✓, `mix credo` ✓,
  `mix dialyzer` ✓, `mix docs` ✓.

---

## 6 · Las decisiones del dueño

1. **`remove/1` con el motor vivo** ✓: se niega ✓ o lo para por defecto ✓?
2. **`candil.toml`** ✓: no reescribirlo ✓ y negarse si está declarado ✓, o
   reescribirlo ✓ y perder los comentarios ✓?
3. **Draft parcial** ✓: conservar el principal ✓ y devolver
   `{:error, {:draft_failed, reason, main_path}}` ✓, o borrarlo ✓ para no dejar
   un modelo a medias ✓?
4. **`Model.downloaded?/1`** ✓: ¿exige el draft ✓? Si no, `models list` ✓,
   `Doctor` ✓ y `Preflight` ✓ siguen mintiendo ✓.
5. **El nombre del proyecto CLI** ✓, y si conserva `Alaja` ✓.

**No forman parte de este carril** ✓: el embedder ✓, el alcance de P-6 ✓, el
contrato de `Agent.new/1` ✓, el P-1 ✓ y la aprobación del spec de la fase 9 ✓.

---

## 7 · Lo que este spec **no** decide

- **El nombre del proyecto CLI** ✓, ni su repositorio ✓, ni su lenguaje ✓.
- **Si el CLI nuevo mantiene el comando `candil`** ✓: mi voto es que sí ✓,
  pero es una decisión de producto ✓.
- **Qué pasa con `Candil.CLI.main/1`** ✓ más allá de documentarlo ✓: si
  alguien lo usaba ✓, necesita un sustituto ✓, y quién ✓.
- **La política de `candil.toml`** más allá de lo de arriba ✓.
