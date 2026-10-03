# Fase 5 — Doctor

> Estado: **a medias**. Fases −1 a 4 mergeadas en `main`; commit base `6c73b28`.
> Carril A. Original: `candil-4.0-final.md` §17 y Fase 5.
> Effort: 3 d.
>
> **Nivel de razonamiento de la fase: `low` — sube a `high` en §3.2 y `medium` en §3.1.**
> Razón: los siete checks y sus mensajes están escritos literalmente en el
> documento de diseño. Es transcripción con verificación.

---

## 1. Dónde estamos exactamente

Rama `main`, último commit `6c73b28`.

**Ya hecho y commiteado en esta fase — no lo rehagas, no lo borres, y si algo
te parece mal dilo en vez de tocarlo:**

- `lib/candil/doctor.ex` — los siete checks de la §17
- `lib/candil/cli/doctor.ex` — el comando, con `--fix` y `--json`
- `"doctor"` añadido a la tabla de comandos de `lib/candil/cli.ex`
- `Candil.Application` hidrata el Store desde el TOML al arrancar

**Y así funciona de verdad:**

```
$ candil doctor
✓ config       válido · 7 modelos · 1 engine(s) · 1 provider(s)
✗ binary       /root/.candil/llm/bin/llama-server is not built
⚠ sources      0/6 descargados (faltan coder, analyst, embed, ...)
✓ ports        :10000-10099 libres
✗ auth         api_key_env=LLAMA_API_KEY pero LLAMA_API_KEY NO esta puesta
✓ gpu          sin GPU: los modelos iran por CPU, mas lento pero funciona
✓ memory       Memory usage normal: 6% used

2 errores · 1 advertencias.

Para arreglar:
  binary: candil engine install  (estrategia source)
  sources: candil models pull
  auth: export LLAMA_API_KEY=... en el shell que arranca el engine
```

**Gates en `6c73b28`: 8/8 · 687 tests + 26 doctests · 0 fallos.**
Esa es la base. Si el número de tests baja de 687, para.

---

## 2. Entorno

```
Repo:       https://github.com/Lorenzo-SF/candil
Rama:       f5-doctor  (créala desde main)
PR:         contra main
Toolchain:  Erlang/OTP 28.5.0.7 · Elixir 1.19.5-otp-28

    git clone https://github.com/Lorenzo-SF/candil.git && cd candil
    git checkout main && git pull --ff-only origin main
    git checkout -b f5-doctor
    bash /workspace/tools/setup.sh          # Hex + deps + compilación
    mix deps.get
```

⚠ **La rama NO puede llamarse `f5/doctor`.** `refs/heads/f5` y
`refs/heads/f5/doctor` no pueden coexistir: Git no admite un ref y un directorio
en el mismo sitio. El guion es obligatorio.

**El mirror de Hex tiene que estar vivo** o `mix deps.get` falla con
`econnrefused` al `127.0.0.1:4000`:

```bash
python3 /workspace/tools/hex_mirror.py --port 4000
```

como **tarea de background gestionada**, NO con `nohup`: un `nohup` dentro de una
llamada de bash muere al cerrarse la llamada.

**Para todo test que toque disco, `CANDIL_DATA_DIR=<tmp>`.** Sin eso estás
escribiendo en el `~/.candil` de verdad, y un test que hace eso no se ejecuta
dos veces.

---

## 3. Lee esto

1. `PLAN-VENTANA-PARALELA.md` → sección de la fase 5
2. `candil-4.0-final.md` → **solo** la §17 y la Fase 5. No lo entero: son 3.000 líneas
3. `HANDOFF.md` §2 y §3

---

## 4. Qué falta — el trabajo de verdad

### 3.1 Los tests del doctor · `medium`

**NO hay ni un test de `Candil.Doctor`.** Es lo primero y es el entregable de
primera clase de esta fase. `test/candil/doctor_test.exs` con, como mínimo:

- cada check con su `:ok`, su `:warning` y su `:error`
- cada warning y cada error **nombra el comando que lo arregla** — assert sobre
  el texto, no "que tenga un fix"
- `--fix` arregla lo que puede y lista lo que no
- un check que **lanza** no tumba el doctor: sale `:error`, no crash
- la salida `--json` es una **lista**, no un objeto
- un doctor con la config vacía **no dice "todo bien" mintiendo**
- el informe de memoria viene de botica, no de una cuenta propia

> El caso del que LANZA es el que más se cuela. Para provocarlo, mete un engine
> con un `binary` que sea una Struct: `Engine.binary_path/1` reventaría y el
> resto de los seis checks tienen que salir igual.

**Por qué `medium` y no `low`:** los casos son literales, pero el de "un check
que lanza" requiere entender cómo un GenServer de checks captura excepción sin
tragarse el error, y eso tiene tres implementaciones posibles con consecuencias
distintas.

### 3.2 `--fix` que arregla de verdad · `high`

Ahora mismo `--fix` solo crea el directorio de datos. El criterio dice "arregla
lo que puede, y lista lo que no con el comando exacto". Lo segundo ya está; lo
primero es un placeholder honesto pero poco.

**Lo que sí se puede arreglar sin riesgo:**

- el directorio de datos, si falta
- el directorio de logs
- el directorio de modelos, si `model_dir` está declarado y no existe

**Lo que NO se arregla, y hay que listar con su comando:**

- un binario sin construir → `candil engine install`
- un modelo sin descargar → `candil models pull <alias>`
- una variable de entorno sin poner → `export VAR=...`
- un TOML que no valida → la ruta del fichero

> Un `--fix` que **se traga** un fallo es PEOR que no tener `--fix`: el usuario
> cree que arreglaste algo.

**Por qué `high`:** hay que decidir la frontera entre "esto lo arregla botica" y
"esto solo te lo digo", y esa frontera cambia según si el arreglo es reversible.
Un `--fix` que crea un directorio y no dice nada de los otros seis, o un `--fix`
que intenta arreglar un binario y falla a medias, son los dos fallos.

### 3.3 La limpieza de deuda de la §5.2 · `low`

- `Candil.Cost` lleva precios de 2024 embebidos en una tabla. Sácalos a un
  fichero de datos, deja la tabla con `@deprecated`, y haz que los locales valan `0.0`.
- El moduledoc de `Candil.Application` dice `{:arrea, "~> 2.1.0"}` y arrea está
  en 3.0.0. Corrígelo. Es la clase de error que hace que alguien lea el moduledoc
  y tome decisiones de diseño sobre una versión que no es la real.
- No hay TODOs en `lib/`. Los `Process.sleep` que quedan están en un comentario
  de `openai_compat.ex`; revísalo y decide si se va.

---

## 5. Capa 1 — Los ocho gates

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict --format=oneline
mix test --cover
mix dialyzer
mix docs --warnings-as-errors
mix hex.audit
mix deps.unlock --check-unused
```

Todos en verde. Base: **8/8, 687 tests + 26 doctests, 0 fallos.**

**Sobre dialyzer:** un stub que hace `raise` es `none()`, y eso rompe el `@spec`.
Si escribes un stub nuevo devuelve `{:error, %Candil.Error{reason: :not_implemented}}`,
que cumple su propio `@spec`. No hace falta fichero de ignore.

**Si el número de tests baja de 687, para.** No es una cifra decorativa: si baja,
alguien borró cobertura para que el gate pasara.

---

## 6. Capa 2 — Qué tiene que pasar al ejecutar

| Qué ejecutas | Qué tiene que ocurrir | Qué NO puede ocurrir |
|---|---|---|
| `mix test` | 687+ tests, 0 fallos | ningún test en `:skip` para hacer verde |
| `mix credo --strict` | 0 issues | ni un `# credo:disable` añadido |
| `mix dialyzer` | 0 errores | ni un `unknown_function` de una app hermana — si aparece, mira el PLT antes que tu código |
| `candil doctor` | los 7 checks, cada uno con su mensaje | que un check salga `:ok` sin haber comprobado nada |
| `candil doctor --fix` | arregla los 3 directorios, lista los 4 casos con comando | que se trague un fallo o que finja haber arreglado algo |
| `candil doctor --json` | una **lista** | un objeto con `{checks: [...]}` |
| un check que lanza | `:error` en ese check, los otros 6 salen igual | que tumbe el doctor entero |

**La prueba del `:json`:** `candil doctor --json | jq 'type'` tiene que imprimir
`array`, no `object`.

---

## 7. Capa 3 — Revisión manual del código

Antes de abrir el PR, lee esto a mano. No hay linter que lo detecte.

- [ ] ¿Cada `:warning` y cada `:error` **nombra un comando ejecutable**? No vale
      "engine failed". Vale "llama-server no está en /root/.candil/llm/bin; ejecuta
      `candil engine install`".
- [ ] ¿Los checks genéricos (memoria, disco) **salen de botica** y no hay una
      segunda cuenta de memoria en Candil?
- [ ] ¿`--fix` distingue lo arreglado de lo listado, y lo listado **se lista**?
- [ ] ¿Un check que lanza produce `:error` con el nombre del check y el motivo, y
      no un `nil` silencioso?
- [ ] ¿La config vacía produce `:warning` o `:error`, y no `:ok` por defecto?
- [ ] ¿Los precios de `Cost` están en un fichero de datos y la tabla embebida
      tiene `@deprecated`? ¿Los locales valen `0.0`?
- [ ] ¿El moduledoc de `Application` dice la versión **real** de arrea?

---

## 8. Capa 4 — La prueba funcional

La que de verdad importa, y la que no la Automatizas:

```bash
# 1. Contra el TOML de ropero, el de verdad
candil doctor
```

**Qué tiene que ocurrir:**

- los 7 checks salen, en orden, con `✓` `⚠` o `✗`
- los 2 errores que son errores de verdad (binario sin construir, auth sin
  poner) son `:error`, no `:warning`
- el bloque "Para arreglar" lista **un comando por problema**
- la última línea cuenta: `2 errores · 1 advertencias`

**Qué NO tiene que ocurrir:**

- ❌ que diga "todo bien" — no hay binario ni modelos ni GPU
- ❌ un `:error` sin comando de arreglo debajo
- ❌ un check que aparezca `✓` cuando el fichero no existe
- ❌ que el `--fix` haya "arreglado" el binario o los modelos
- ❌ que la salida cambie de forma al ejecutarla dos veces seguidas

```bash
# 2. El idempotente: dos veces seguidas, mismo resultado
candil doctor > /tmp/d1.txt; candil doctor > /tmp/d2.txt; diff /tmp/d1.txt /tmp/d2.txt
```

`diff` tiene que salir 0. Si sale distinto, hay un check con estado oculto o un
`:atomics` que se consume al leerse.

```bash
# 3. El que casi nadie prueba
CANDIL_DATA_DIR=/tmp/vacio candil doctor
```

Con el directorio vacío tiene que dar `:warning` o `:error` con qué ejecutar —
**no** `:ok`.

---

## 9. Lo que NO vas a hacer

- **NO** toques `mcp.ex`, `rag.ex` ni sus tests. Las fases 9 y 10 son otras y se
  pueden estar haciendo en paralelo.
- **NO** toques `build.ex`, `engine_pool.ex`, `source.ex`, `instances.ex`. Son de
  las fases 2 y 4, ya certificadas.
- **NO** toques `mix.exs`. `groups_for_modules` necesita `Candil.Doctor` y
  `Candil.CLI.Doctor`: lo pides en el PR y lo aplica el carril H.
- **NO** borres `Batteries.LlamaServer` del repo de botica. Está fuera de su
  dominio y su sitio es aquí, pero borrar cosas del repo de otro es decisión
  del dueño. Déjalo anotado.
- **NO** reimplementes la memoria ni el disco. Son de botica, y reimplementarlos
  aquí sería un `free` peor en otra máquina.
- **NO** hagas `git push --force`. Ni push directo a `main` sin PR.

---

## 10. Definición de done

- [ ] Los siete checks existen y cada uno dice algo accionable
- [ ] `test/candil/doctor_test.exs` existe y cubre los ocho casos de §3.1
- [ ] `--fix` arregla lo arreglable y lista lo que no, con comando
- [ ] La limpieza de §5.2 está hecha
- [ ] `candil doctor` corre con el TOML de ropero y su salida coincide con la §17
- [ ] Los ocho gates verdes
- [ ] El número de tests **no ha bajado de 687**
- [ ] `CHANGELOG.md` actualizado con los nombres de función reales
- [ ] `HANDOFF.md` §2 actualizado con números **medidos** del output real
- [ ] PR abierto contra `main`, con el CI en verde
- [ ] Tag `candil-4.0.0-alpha.3` al mergear

---

## 11. Trampas de este entorno

Las he pagado todas esta semana; no las repitas.

- **`Config` es un módulo de Elixir.** Usa `alias Candil.Config, as: CandilConfig`
  o `Config.File.load()` resuelve al de Elixir y falla con `UndefinedFunctionError`.
- **`System.pid/0` devuelve un BINARIO en OTP 28**, una charlist en otras
  versiones y un entero en otras. Un `is_integer` sobre lo que devuelve funciona
  hoy y no mañana.
- **`Enum.filter/2` devuelve los elementos ORIGINALES** cuando la función
  responde con algo verdadero, y tira lo que devolvió. Filtrar con un constructor
  parece funcionar, cuenta bien, y entrega mapas con claves de string.
- **`Process.alive?/1` toma un pid de ERLANG**, no del sistema operativo. Con un
  entero responde sobre otra cosa y la línea parece correcta.
- **`mix format` reexpande `{_, 0} == {status, 0}`** y rompe el fichero. Usa
  `edit`, o escribe la comparación sin `_`.
- **`Map.update/4` es (map, key, default, fun).** El default va en tercer lugar.
  Pasarlo al revés compila y devuelve basura.
- **Los procesos en background no sobreviven a la llamada de bash** que los
  lanza. Usa tareas gestionadas o `setsid` con las tres fd redirigidas.
- **`/opt`, `/usr` y `/root` desaparecen en cada reinicio.** Solo sobrevive
  `/workspace`. cmake y ninja viven en `/workspace/tools/cmake-root` y `env.sh`
  los pone en el PATH.
- **Los ficheros de configuración de varios carriles se pisan si comparten
  worktree.** Un worktree y un `_build` por carril.

---

## 12. Al terminar

`deliverable.md` con: los ocho gates y su salida, el criterio de aceptación con
su salida **REAL**, el número de tests antes y después, la cobertura antes y
después **con el motivo si baja**, los ficheros tocados, el hash del commit y la
URL del PR.

Si la cobertura baja más de un punto, **no lo maquilles**: es información.

Si te bloqueas en una decisión de diseño que no esté en el documento, PARA y
escribe la pregunta en `deliverable.md`.


## 13. Cómo se ejecuta esta fase

**Una sesión principal, secuencial, en `mcode`.** El nivel se cambia **por
sub-tarea** con `/model` (verificado: `/model` cambia modelo **y** effort, y
`/status` muestra el par). El modelo no puede cambiar su propio effort a mitad de
respuesta: el ajuste es **entre turnos**, y por eso la unidad es la sub-tarea.

### El ciclo

```bash
# 1. en main, actualizado
git checkout main && git fetch origin && git pull --ff-only origin main

# 2. rama de la fase  (CON GUION, nunca barra)
git checkout -b f5-doctor

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    cambiando el nivel con /model en cada frontera

# 4. verificar las 4 capas (abajo)

# 5. publicar
git push -u origin f5-doctor

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    HANDOFF.md §2 con números MEDIDOS · CHANGELOG.md · el tag
```

Un worktree por sesión, un `_build` por carril.

### El nivel, sub-tarea por sub-tarea

| Sub-tarea | Nivel | Verificación |
|---|---|---|
| 3.1 Los tests del doctor | `medium` | L3: `doctor_test.exs`, 8 casos; el `:json` es una lista |
| 3.2 `--fix` que arregla de verdad | `high` | L3: `--fix` lista lo no arreglable con comando |
| 3.3 Limpieza de deuda §5.2 | `low` | L1+L2: `Cost` a fichero, arrea 2.1.0→3.0.0 |
| Revisión de la fase (sesión aparte) | `max` | L4: `candil doctor` da 0 errores y cada warning nombra comando |

**Y al final, siempre:** una sesión de revisión aparte, a `max`, leyendo el PR
**sin el diff del autor**. Es la única tarea del plan donde el nivel base es el
máximo, porque es la única donde el agente no puede estar calibrado por haber
escrito el módulo.

### Las 4 capas, en cada sub-tarea

| Capa | Qué | Obligatoria |
|---|---|---|
| **L1** | `mix format --check-formatted` + `mix compile --force --warnings-as-errors` | siempre |
| **L2** | `mix credo --strict` + `mix dialyzer` | si toca código compartido |
| **L3** | `CANDIL_DATA_DIR=$(mktemp -d) mix test <ruta>/` con el caso nombrado | siempre |
| **L4** | un comando con salida observable, **y qué NO puede ocurrir** | si es visible para el usuario |

La **aserción negativa** es la que importa: un criterio que solo dice "responde"
pasa con un `[]` de respuesta.

### Si se bloqueas

**PARA.** No improvises una decisión de diseño: están todas escritas. Anótala en
`deliverable.md` y sigue con la siguiente sub-tarea que no dependa de eso.

**Y si un criterio no se ejecutó porque el entorno no lo permite, dilo.** Escribe
*"criterio ejecutado: unitario, no integración"*. Un `deliverable.md` que dice
"criterio ejecutado" cuando se ejecutó la mitad es una mentira, y la siguiente
sesión la da por buena.
