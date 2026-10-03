# Fase 2 — Engine/Model v2 y Build

> Estado: **CERRADA.** Mergeada antes de la rama de contratos congelados.
> Carril A. Original: `candil-4.0-final.md` §13, §14.3, §14.4, §11 y Fase 2.
> Effort: 7 d.
>
> **Este documento se archiva.** Se conserva porque explica por qué
> `Candil.Build` es como es, y porque su §4.1 contiene la única decisión del
> proyecto que sigue sin tomar por escrito (ver §6).
>
> **Nivel de razonamiento de la fase: `high` — `max` en §4.1.**
> Razón: 2.1 y 2.3 las hizo el freeze de contratos. Lo que queda es 2.2, y la
> parte pesada es decidir.

---

## 1. ⚠ Correcciones de esta auditoría

Este documento tenía **tres errores** que ya están corregidos aquí:

| Error | Corrección |
|---|---|
| Rama `f2/build` | **Imposible.** Es `f2-build`, con guion. `refs/heads/f2` y `refs/heads/f2/build` no pueden coexistir. |
| No menciona el mirror de Hex | `mix deps.get` falla con `econnrefused` al `127.0.0.1:4000` si el mirror no corre. La fase 5 lo documenta bien; aquí faltaba. |
| Ruta de setup divergente | Aquí decía `/workspace/setup-candil.sh`; la fase 5 dice `/workspace/tools/setup.sh`. **Usa la de la 5**, que es la que está probada. |

Y una cosa que **no** era error sino estado: el §8 de las notas decía "Fase 0
sigue pendiente". Ya no: la 0 está mergeada. El documento refleja un momento
anterior.

---

## 2. Entorno *(por si hay que reconstruirla)*

```
Repositorio: https://github.com/Lorenzo-SF/candil
Toolchain:   Erlang/OTP 28.5.0.7  ·  Elixir 1.19.5-otp-28
             Fijado en `.tool-versions`; sincronizado con el CI.

    git clone https://github.com/Lorenzo-SF/candil.git && cd candil
    git checkout 4.0
    asdf install erlang 28.5.0.7
    asdf install elixir 1.19.5-otp-28
    mix deps.get
```

Las cinco deps de GitHub (apero, arrea, trebejo, alaja, botica) apuntan a `main`
con `branch:` explícito y `override: true`. Si `mix deps.get` falla por
resolución de deps, es que se ha quitado el `override: true`; no lo quites.

En sandbox efímero:

```bash
bash /workspace/tools/setup.sh              # Hex + deps + compilación
python3 /workspace/tools/hex_mirror.py --port 4000   # como tarea gestionada
```

---

## 3. Lo que ya hizo el freeze de contratos

La Fase −1 (congelado de contratos) ya está cerrada y verificada. La **2.1 de
esta fase ya la hizo entera**:

- `Candil.Model` 4.0 — el struct entero con `port`, `source`, `draft`, `tags`,
  `enabled`, `launcher`, `base_url` y `type: :external`
- `Candil.Engine` 4.0 — `binary`, `base_port`, `api_key`, `auth_headers`,
  `install`; y las funciones `api_key/1`, `auth_headers/1`,
  `base_url_and_headers/2`, `validate/1`
- `Candil.Build` — el struct, y `new/1`, `validate/1`, `dir/1`,
  `binary_path/2`, `cmake_command/1`, `generator_flag/1`
- `Candil.Source` — el struct, y `validate/1`, `url/1`, `filename/1`,
  `dest_path/1`, `present?/1`, `size/1`
- `Candil.Store` — el registro, con validación en la entrada (antes `Candil.Config`)
- `Candil.Config.Schema` y `Candil.Config.File`

Tests: `test/candil/source_test.exs`, `build_test.exs`, `model_v4_test.exs`,
`engine_auth_test.exs`, `store_test.exs`, `config/schema_test.exs`,
`config/file_test.exs`

**Estos ficheros son propiedad del carril A.** Eran tuyos; puedes editarlos, pero
nadie más los toca.

---

## 4. Qué había que hacer

### 3.1 `Candil.Build.install/2` y `check/1` · `high` — **`max` en la decisión**

Eran stubs que devuelven `{:error, %Candil.Error{reason: :not_implemented}}`.

**`:precompiled`** — detectar SO, arch y GPU (`Candil.Detector` ya existe con
`Detector.GPU`, `Detector.Models`, `Detector.Release`); resolver el asset del
release de llama.cpp; descargar con reanudación por `Range`, checksum en
streaming, escribir a `.part` y renombrar; descomprimir y `chmod +x`.

> ⚠ **`Candil.Installer.download_engine/1` YA HACE CASI TODO ESTO** para el caso
> simple. **La decisión es tuya y no está escrita en ningún sitio** (ver §6).

**`:source`** — `git clone -b ref`; `cmake -B build_dir -S src_dir` con los
`cmake_args` del usuario; `cmake --build -j` (con `jobs`, donde `0` significa
`nproc`); copiar los `binaries` declarados y `chmod +x`.

**Las reglas que no son negociables:**

- `cmake_args` se pasa a cmake **VERBATIM**. Candil no añade ningún flag de
  arquitectura ni de GPU, y no debe empezar a hacerlo. Una RTX 5080 (Blackwell)
  necesita `-DCMAKE_CUDA_ARCHITECTURES=120a` junto con los interruptores MXFP4
  y NVFP4, y un binario genérico publicado no está ajustado a eso. **Quien sabe
  el hardware es quien escribe el TOML.**
- Candil solo añade `-S`, `-B` y `-DCMAKE_BUILD_TYPE=Release`, y solo si el
  usuario no los puso ya. `cmake_command/1` ya lo hace.
- El proceso hijo debe ser cancelable y morir con el padre. Si el usuario cierra
  el CLI a mitad de compilación, el cmake se mata.
- El error de cmake se propaga **textualmente**. Si no compila, es que los flags
  están mal, y el error de cmake lo dice.
- **Nada se enlaza al PATH.** Ni a `~/.local/bin`. Un montaje anterior enlazó un
  venv entero y tumbó el `python3` del sistema para todos los procesos de la
  máquina.

`check/1` — que los `binaries` declarados estén y sean ejecutables.
Devuelve `:ok | {:error, [nombres que faltan]}`.

### 3.2 `EnginePool` como registro de instancias · `high`

El registro pasa a ser `{alias, port} => %{pid, model, engine, started_at, healthy}`.

Esto es el bug B7, y el motivo no es estético: cuatro modelos de 20 GB no caben,
y un LRU de 4 entradas tampoco resuelve eso. **Un LRU finge estar resolviendo una
presión de memoria que no existe.** Lo que hace falta es un registro de lo que
está vivo.

Desaparecen `get/0` y `evict/0`. Es un cambio de API público y es deliberado: la
versión mayor de semver ya está en marcha (C13). Deja `get/0` con `@deprecated`
durante un release.

`claim_port/2` reserva un puerto de `base_port..+99` y comprueba con
`:gen_tcp.connect/4` que no hay nadie escuchando. Eso es lo que distingue un
puerto libre de uno con un ropero muerto encima, que es exactamente el caso aquí.

### 3.3 El `candil.toml` de ropero, a mano · `low`

**Aquí no hay nada que automatizar, y es una decisión (C15).** Los ficheros
`ropero.d/*.sh` tienen `case` anidados, variables indirectas y `source` entre
ellos. No se puede parsear fiablemente, y un parser que funciona el 80 % es peor
que nada: parece fiable y falla en silencio.

El análisis ya está hecho y está en el Apéndice A. Tu trabajo es traducirlo:

```bash
mkdir -p ~/.config/candil
$EDITOR ~/.config/candil/candil.toml
mix run -e 'IO.inspect(Candil.Config.File.load())'
```

> El CLI no existía todavía (es la fase 3). Valida con `mix run -e` mientras
> tanto.

**ropero NO se toca.** Sigue vivo, y su retirada es decisión tuya (C16).

---

## 5. Los ocho gates

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

**Advertencia sobre dialyzer, que ya mordió una vez:** su PLT tenía solo OTP y
Candil, así que las 15 llamadas a apero/arrea/trebejo salían como
`unknown_function` y nunca se comprobó ninguna. Ya está arreglado (`plt_add_apps`).
Si al tocar algo aparece `unknown_function` de una app hermana, **mira primero el
PLT antes que tu código**.

**Sobre los stubs:** un stub que hace `raise` es `none()` para dialyzer. Por eso
los doce existentes devuelven `{:error, %Candil.Error{reason: :not_implemented}}`,
que cumple su propio `@spec`. Si escribes un stub nuevo, hazlo igual.

---

## 6. Qué tenía que pasar

| Qué | Qué tenía que ocurrir | Qué NO podía ocurrir |
|---|---|---|
| `:precompiled` | descarga, unzip, `chmod +x`, `llama-server --version` funciona | un `.zip` a medias que se considera instalado |
| `:source` | 20-40 min de compilación, el binario funciona | un `--watch` que se mira mientras compila |
| `cmake_args` | se pasan **verbatim**, con un test que lo blinda | que Candil añada un flag de su cuenta |
| cancelación | cerrar el CLI mata el cmake **y sus hijos** | que quede un `ninja` huérfano consumiendo CPU |
| error de cmake | `{:error, texto}` con el stderr | un "build failed" genérico |
| `claim_port/2` | un puerto libre **o** uno con ropero muerto se distingue | que reserve un puerto que está en `TIME_WAIT` |
| el TOML | carga, y los modelos aparecen en `Store` | un TOML que carga pero con `model_args` como mapa |

**La prueba manual de `:source` es la que importa**, porque los tests usan un
repo fixture:

```bash
CANDIL_CONFIG=/tmp/build-test.toml mix run -e 'Candil.Build.install(:llama_cpp)'
# → 20-40 min, acompañado con `candil engine install --watch`
/tmp/llama-bin/llama-server --version     # debe funcionar
```

Y la equivalencia con ropero, que **no es un test**:

```bash
# con ropero parado y candil gestionando coder:
./candil run coder &
sleep 40
pgrep -a llama-server | grep -- --model
# La línea debe coincidir con la de `ropero coder`, salvo en
# --host, --port, --alias y --api-key (los pone el engine).
# Si algo no cuadra, la diferencia va al TOML, no al código.
```

---

## 7. La decisión que sigue abierta

> **¿`Candil.Build` delega en `Candil.Installer`, o lo reescribe?**

`Installer.download_engine/1` ya hace casi todo el caso simple de `:precompiled`.
Delegar son unas pocas líneas. Reescribir son ~200 líneas duplicadas, con la
ventaja de que el camino nuevo puede ramificar por engine y la desventaja de que
hay dos descargadores que se desincronizan.

El prompt decía "decide, y si lo reescribes explica por qué en el commit". **La
decisión no está en el documento de diseño.** Es la única del proyecto en esa
situación, y por eso es el `max` de esta fase.

**Mi lectura:** si la fase 2 está cerrada y el criterio de aceptación pasó, la
decisión ya se tomó de facto. **Anótala en `HANDOFF.md` con el porqué**, porque
dentro de seis meses la única forma de saber si fue deliberada es que esté
escrito.

---

## 8. Lo que no se iba a hacer

- No tocar ropero. Ni un byte.
- No escribir el comando de migración de ropero. C15: no existe.
- No añadir flags de cmake por tu cuenta.
- No convertir la ruta de modelos en fija. Es configurable (C17).
- No usar `String.to_atom/1` con nada que venga de fuera.
- No `git push --force`.

---


## 9. Cómo se ejecuta esta fase

**Una sesión principal, secuencial, en `mcode`.** El nivel se cambia **por
sub-tarea** con `/model` (verificado: `/model` cambia modelo **y** effort, y
`/status` muestra el par). El modelo no puede cambiar su propio effort a mitad de
respuesta: el ajuste es **entre turnos**, y por eso la unidad es la sub-tarea.

### El ciclo

```bash
# 1. en main, actualizado
git checkout main && git fetch origin && git pull --ff-only origin main

# 2. rama de la fase  (CON GUION, nunca barra)
git checkout -b f2-build

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    cambiando el nivel con /model en cada frontera

# 4. verificar las 4 capas (abajo)

# 5. publicar
git push -u origin f2-build

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    HANDOFF.md §2 con números MEDIDOS · CHANGELOG.md · el tag
```

Un worktree por sesión, un `_build` por carril.

### El nivel, sub-tarea por sub-tarea

| Sub-tarea | Nivel | Verificación |
|---|---|---|
| 4.1 `Build.install/2` — la **decisión** Installer vs reescritura | `max` | L3: el test de `cmake_args` verbatim pasa |
| 4.1 `Build.install/2` — `:precompiled` | `high` | L3: `build/precompiled_test.exs`; L4: `llama-server --version` |
| 4.1 `Build.install/2` — `:source` | `high` | L3: `build/source_test.exs`; L4: compila 20-40 min |
| 4.1 `Build.install/2` — cancelación del proceso hijo | `xhigh` | L3: cerrar el CLI mata cmake y sus hijos |
| 4.2 `EnginePool` → registro de instancias | `high` | L3: `engine_pool_test.exs`; `claim_port/2` distingue libre de ocupado |
| 4.3 El `candil.toml` de ropero a mano | `low` | L4: `mix run -e` carga el TOML; el `pgrep` coincide con ropero |

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
