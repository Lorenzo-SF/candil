# Prompt de traspaso — Fase 5, Doctor

> **La Fase 4 está CERRADA y certificada.** No la rehagas. Está en `4.0`, commit
> `8918492`, con los cuatro jobs del CI en verde. Lo que sigue es la Fase 5,
> que es la siguiente del plan y la que está a medias ahora mismo.
>
> Si venías buscando el prompt de la Fase 4, ya no hace falta: lo que hay que
> continuar es esto.

Copia el bloque de abajo entero en la sesión nueva.

---

```text
Estoy implementando Candil 4.0. Las fases -1, 0, 1, 2, 3 y 4 están
mergeadas en la rama 4.0. Tu tarea es TERMINAR la FASE 5: `candil doctor`.

════════════════════════════════════════════════════════════════════════
0. DÓNDE ESTAMOS EXACTAMENTE
════════════════════════════════════════════════════════════════════════

Rama: 4.0, último commit 6c73b28.

Lo que YA está hecho y commiteado en la fase 5 (no lo rehagas, no lo
borres, y si algo te parece mal dilo en vez de tocarlo):

  · lib/candil/doctor.ex           los siete checks de la §17
  · lib/candil/cli/doctor.ex       el comando, con --fix y --json
  · "doctor" añadido a la tabla de comandos de lib/candil/cli.ex
  · Candil.Application hidrata el Store desde el TOML al arrancar

Y así funciona de verdad, contra el proyecto 4.0/candil.toml de ropero:

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

Gates en 6c73b28: 8/8, 687 tests + 26 doctests, 0 fallos.

════════════════════════════════════════════════════════════════════════
1. ENTORNO
════════════════════════════════════════════════════════════════════════

Repo:       https://github.com/Lorenzo-SF/candil
Rama:       4.0-f5-doctor  (créala desde origin/4.0)
PR:         contra 4.0. NUNCA contra main, y NUNCA push directo a 4.0
Toolchain:  Erlang/OTP 28.5.0.7 · Elixir 1.19.5-otp-28

    git clone https://github.com/Lorenzo-SF/candil.git && cd candil
    git checkout 4.0 && git pull
    git checkout -b 4.0-f5-doctor
    bash /workspace/tools/setup.sh          # Hex + deps + compilación
    mix deps.get

El mirror de Hex tiene que estar vivo o `mix deps.get` falla con econnrefused
al 127.0.0.1:4000. Si falta:

    python3 /workspace/tools/hex_mirror.py --port 4000

como tarea de background gestionada, NO con nohup: un nohup dentro de una
llamada de bash muere al cerrarse la llamada.

Para los tests que tocan disco, usa CANDIL_DATA_DIR=<tmp>. Sin eso estás
escribiendo en el ~/.candil de verdad, y un test que hace eso no se ejecuta
dos veces.

════════════════════════════════════════════════════════════════════════
2. LEE ESTO
════════════════════════════════════════════════════════════════════════

  1. proyecto 4.0/PLAN-F5-F9-F10.md → sección de la fase 5
  2. proyecto 4.0/candil-4.0-final.md → SOLO la §17 (línea ~1419) y la
     Fase 5 (línea ~2552). NO leas el documento entero: son 3.000 líneas
  3. proyecto 4.0/HANDOFF.md §2 y §3

════════════════════════════════════════════════════════════════════════
3. QUÉ FALTA — el trabajo de verdad
════════════════════════════════════════════════════════════════════════

▓▓▓ 3.1  Los tests del doctor  (lo que más falta)  ▓▓▓

NO hay ni un test de Candil.Doctor. Es lo primero, y es el entregable de
primera clase de esta fase. test/candil/doctor_test.exs con, como mínimo:

  · cada check con su :ok, su :warning y su :error
  · cada warning y cada error NOMBRA EL COMANDO QUE LO ARREGLA
    (assert sobre el texto, no "que tenga un fix")
  · --fix arregla lo que puede y lista lo que no
  · un check que LANZA no tumba el doctor: sale :error, no crash
  · la salida --json es una LISTA, no un objeto
  · un doctor con la config vacía no dice "todo bien" mintiendo
  · el informe de memoria viene de botica, no de una cuenta propia

  El caso del que LANZA es el que más se cuela. Para provocarlo, mete un
  engine con un `binary` que sea una Struct: `Engine.binary_path/1` reventaría
  y el resto de los seis checks tienen que salir igual.

▓▓▓ 3.2  `--fix` que arregla de verdad  ▓▓▓

Ahora mismo `--fix` solo crea el directorio de datos. El criterio de
aceptación dice "arregla lo que puede, y lista lo que no con el comando
exacto". Lo segundo ya está; lo primero es un placeholder honesto pero poco.

Lo que sí se puede arreglar sin riesgo:
  · el directorio de datos, si falta
  · el directorio de logs
  · el directorio de modelos, si `model_dir` está declarado y no existe

Lo que NO se arregla, y hay que listar con su comando:
  · un binario sin construir → `candil engine install`
  · un modelo sin descargar → `candil models pull <alias>`
  · una variable de entorno sin poner → `export VAR=...`
  · un TOML que no valida → la ruta del fichero

Un `--fix` que se traga un fallo es PEOR que no tener `--fix`: el usuario cree
que arreglaste algo.

▓▓▓ 3.3  La limpieza de deuda de la §5.2  ▓▓▓

  · `Candil.Cost` lleva precios de 2024 embebidos en una tabla. Sácalos a un
    fichero de datos, deja la tabla con `@deprecated`, y haz que los locales
    valan 0.0.
  · El moduledoc de `Candil.Application` dice `{:arrea, "~> 2.1.0"}` y arrea
    está en 3.0.0. Corrígelo. Es la clase de error que hace que alguien lea
    el moduledoc y tome decisiones de diseño sobre una versión que no es la
    real.
  · No hay TODOs en lib/. Los `Process.sleep` que quedan están en un
    comentario de openai_compat.ex; revísalo y decide si se va.

════════════════════════════════════════════════════════════════════════
4. LO QUE NO VAS A HACER
════════════════════════════════════════════════════════════════════════

· NO toques mcp.ex, rag.ex ni sus tests. Las fases 9 y 10 son otras y se
  pueden estar haciendo en paralelo.
· NO toques build.ex, engine_pool.ex, source.ex, instances.ex. Son de las
  fases 2 y 4, ya certificadas.
· NO toques mix.exs. `groups_for_modules` necesita `Candil.Doctor` y
  `Candil.CLI.Doctor`: lo pides en el PR y lo aplica el carril H.
· NO borres `Batteries.LlamaServer` del repo de botica. Está fuera de su
  dominio y su sitio es aquí, pero borrar cosas del repo de otro es
  decisión del dueño. Déjalo anotado.
· NO reimplementes la memoria ni el disco. Son de botica, y reimplementarlos
  aquí sería un `free` peor en otra máquina.
· NO hagas git push --force. Ni push directo a 4.0.

════════════════════════════════════════════════════════════════════════
5. DEFINICIÓN DE DONE
════════════════════════════════════════════════════════════════════════

La fase está terminada cuando TODO esto es verdad:

  □ Los siete checks existen y cada uno dice algo accionable
  □ test/candil/doctor_test.exs existe y cubre los ocho casos de §3.1
  □ `--fix` arregla lo arreglable y lista lo que no, con comando
  □ La limpieza de §5.2 está hecha
  □ `candil doctor` corre con el TOML de ropero y su salida coincide con
    la §17 del documento de diseño
  □ Los ocho gates verdes:

        mix format --check-formatted
        mix compile --force --warnings-as-errors
        mix credo --strict --format=oneline
        mix test --cover
        mix dialyzer
        mix docs --warnings-as-errors
        mix hex.audit
        mix deps.unlock --check-unused

  □ El número de tests NO ha bajado de 687
  □ CHANGELOG.md actualizado con los nombres de función reales
  □ HANDOFF.md §2 actualizado con números MEDIDOS del output real
  □ PR abierto contra 4.0, con el CI en verde

════════════════════════════════════════════════════════════════════════
6. TRAMPAS DE ESTE ENTORNO
════════════════════════════════════════════════════════════════════════

Las he pagado todas esta semana; no las repitas.

· `Config` es un módulo de Elixir. Usa `alias Candil.Config, as: CandilConfig`
  o `Config.File.load()` resuelve al de Elixir y falla con
  UndefinedFunctionError.

· `System.pid/0` devuelve un BINARIO en OTP 28, una charlist en otras
  versiones y un entero en otras. Un `is_integer` sobre lo que devuelve
  funciona hoy y no mañana.

· `Enum.filter/2` devuelve los elementos ORIGINALES cuando la función
  responde con algo verdadero, y tira lo que devolvió. Filtrar con un
  constructor parece funcionar, cuenta bien, y entrega mapas con claves de
  string.

· `Process.alive?/1` toma un pid de ERLANG, no del sistema operativo. Con un
  entero responde sobre otra cosa y la línea parece correcta.

· `mix format` reexpande `{_, 0} == {status, 0}` y rompe el fichero. Usa
  `edit`, o escribe la comparación sin `_`.

· `Map.update/4` es (map, key, default, fun). El default va en tercer
  lugar. Pasarlo al revés compila y devuelve basura.

· Los procesos en background no sobreviven a la llamada de bash que los
  lanza. Usa tareas gestionadas o `setsid` con las tres fd redirigidas.

· `/opt`, `/usr` y `/root` desaparecen en cada reinicio. Solo sobrevive
  `/workspace`. cmake y ninja viven en /workspace/tools/cmake-root y env.sh
  los pone en el PATH.

· Los ficheros de configuración de varios carriles se pisan si comparten
  worktree. Un worktree y un _build por carril.

════════════════════════════════════════════════════════════════════════
7. AL TERMINAR
════════════════════════════════════════════════════════════════════════

deliverable.md con: los ocho gates y su salida, el criterio de aceptación con
su salida REAL, el número de tests antes y después, la cobertura antes y
después con el motivo si baja, los ficheros tocados, el hash del commit y la
URL del PR.

Si la cobertura baja más de un punto, no lo maquilles: es información.

Si te bloqueas en una decisión de diseño que no esté en el documento, PARA y
escribe la pregunta en deliverable.md. Todas están escritas; si ninguna
encaja, eso es información que necesito.
```

---

## Nota sobre la Fase 4, para quien lea esto después

Está **cerrada y certificada**, en `4.0` commit `8918492`, con el CI en verde.

| | |
|---|---|
| `Candil.Instances` | `instances.json` con escritura atómica, lecturas que podan los dueños muertos, y `ad-hoc-ports`. El `owner` es una tupla etiquetada con una variante hoy y la de daemon escrita y no compilada |
| `Launcher.Http` | vLLM, TGI, LM Studio, Ollama, airllm, tensorrt-llm y mlx-lm sin una línea cada uno. `pid: nil` es la garantía, no un descuido |
| `run --detach` | registra con el PID del SO de este proceso como dueño, que es lo que hace que **matar al dueño se lleve el engine con él** |
| `stop` | lee el fichero además del pool, y manda TERM en vez de KILL |
| `status` | `STATE` lo dice el health poller, no "hay fila" |

**Lo único que no se pudo verificar** es el criterio completo de la fase, que
pide `./candil run coder --detach` con modelos de verdad y un `STATE` en `ON`.
No hay GPU ni GGUF en el sandbox. El mecanismo entero sí está probado con
procesos reales: el fichero se escribe con el dueño correcto, un segundo proceso
lo lee, `stop` lo mata, la entrada desaparece, y matar al dueño hace que el
registro se poda solo.
