# Prompt para implementar la Fase 3 de Candil 4.0


> **Para probar esta fase**: [`../PRUEBAS-MANUALES.md`](../PRUEBAS-MANUALES.md) — comandos, comportamiento esperado y el script `scripts/manual-check.sh`.

Copia el bloque de abajo entero en la sesión nueva. Está escrito para que no
tenga que descubrir nada: qué leer, qué ya está hecho, qué hacer, y cómo se
comprueba.

---

```text
Estoy implementando Candil 4.0, una librería de Elixir de inferencia LLM y
gestión de modelos. Las Fases -1 (contratos congelados) y 2 (Build,
EnginePool, candil.toml) están cerradas. Tu tarea es implementar la FASE 3.

════════════════════════════════════════════════════════════════════════
0. LEE ESTO PRIMERO, PORQUE CAMBIA EL ALCANCE
════════════════════════════════════════════════════════════════════════

El grafo de dependencias del PLAN-PARALELO.md §4 dice:

    F0 (bugs + H1) → F1 (Source + TOML) → F2 (Build) → F3 (CLI)

**Las cuatro anteriores están hechas.** La fase 2 se hizo por delante de la
0 y la 1 en el calendario, no en la dependencia, y ya está mergeada. La 3 es,
por fin, la primera cuyo criterio de aceptación se puede ejecutar entero.

Lo que eso cambia para ti, en concreto:

  · `Candil.Source.fetch/2` **existe** y funciona: `.part`, reanudación por
    `Range` y checksum en streaming. `Source.progress/1` da los bytes leídos
    para la barra. `candil models pull` se puede construir de verdad y
    probarse contra un servidor HTTP de mentira. **No lo dobles por costumbre.**

  · **H1 está hecho.** `Engine.auth_headers_for/1` existe y los tres call
    sites de la ruta local de inferencia lo usan: `Inference.Chat`,
    `Inference.Embeddings` y `Stream.chat`. `Engine.Server` emite `--api-key`
    y `--alias`. La ruta local puede hablar con un `llama-server` protegido.

  · `Candil.Config.File.save/2` existe y escribe atómico.

Y lo que **sigue** en pie, y es lo único que te puede parar:

  · **No existe carga de TOML a `Candil.Store`.** `Store.init/1` solo lee
    `Application.get_env(:candil, Candil.Store)`; `Store.reload/0` no existe;
    y nada en `lib/` llama a `Config.File.load/0`, ni siquiera
    `Candil.Application`. Con un `candil.toml` en su sitio,
    `Store.list_models()` devuelve `[]`. Sin el cargador, `candil models list`
    no tiene nada que enseñar. La fase 1 escribió el lector y el escritor del
    TOML, pero no el puente al registro. Está en HANDOFF.md §5-bis y es la
    primera decisión que tienes que tomar: §4.0 abajo.

  · No hay binario de `llama-server` ni GGUF en una máquina de desarrollo
    normal. El criterio de aceptación de la fase 3 pide arrancar uno de verdad.
    Construye todo y pruébalo con dobles, y deja la prueba real como un
    bloque que se pueda copiar y pegar tal cual.

Quedan **ocho stubs** en todo el repo, y ninguno es tuyo: `Gateway.Endpoint.listen/4`
(fase 8), `MCP.serve/1` y `MCP.connect/1` (fase 9), y cinco de `RAG` (fase 10).

════════════════════════════════════════════════════════════════════════
1. ENTORNO
════════════════════════════════════════════════════════════════════════

Repositorio: https://github.com/Lorenzo-SF/candil
Rama:        4.0          (NO cambies de rama; main está intacta a propósito)
Base exacta: 4.0 con las fases 0, 1 y 2 mergeadas
Token:       te lo paso yo en el mensaje, úsalo solo para push y PR

Toolchain:   Erlang/OTP 28.5.0.7  ·  Elixir 1.19.5-otp-28
             Fijado en `.tool-versions`; sincronizado con el CI.

Clonar y arrancar:

    git clone https://github.com/Lorenzo-SF/candil.git && cd candil
    git checkout 4.0
    asdf install erlang 28.5.0.7
    asdf install elixir 1.19.5-otp-28
    mix deps.get

Las cinco deps de GitHub (apero, arrea, trebejo, alaja, botica) apuntan a
`main` con `branch:` explícito y `override: true`. Si `mix deps.get` falla por
resolución de deps, es que se ha quitado el `override: true`; no lo quites.

En un sandbox efímero, `mix test` fallará con "no process: Mox.Server" en
setenta tests si `MIX_BUILD_PATH` está puesta a mano. **Usa `MIX_BUILD_ROOT`**
— es la que añade el subdirectorio de entorno. Está explicado en el tema de
memoria del agente Mavis, `candil-sandbox-toolchain`.

════════════════════════════════════════════════════════════════════════
2. LEE ESTO, EN ESTE ORDEN
════════════════════════════════════════════════════════════════════════

  (a) `proyecto 4.0/HANDOFF.md`                    <- LEELO PRIMERO, ENTERO
      Estado medido, los ocho stubs que quedan y en qué fase está cada uno,
      la §3-bis con lo que NO está probado, la §4 con la lista de errores ya
     arquitectos con su porqué, y la §5-bis con el hueco de TOML→Store.

  (b) `proyecto 4.0/fases/fase-2-README.md`              <- por el estilo y el tono
      Es el mismo formato que el que tú vas a escribir al final. Y su §7
      ("lo que no vas a hacer") es la lista de trampas de este repo.

  (c) `proyecto 4.0/original/candil-4.0-final.md`
        · Seccion 11.2 (linea ~993)  resolución de puerto, PREFLIGHT, --force
        · Seccion 11.3 (linea ~1028) supervivencia: foreground, --detach
        · Seccion 14.4 (linea ~1279) Candil.EnginePool 4.0  <- API exacta
        · Seccion 17 (linea 1419)   Candil.Doctor — el bloque entero, porque
                                      `status` va a reutilizar sus comprobaciones
                                      de binario, modelo y memoria
        · Fase 3     (linea ~2420)  el bloque entero, con los mensajes de
                                     salida que son el criterio de aceptación
      NO leas el documento entero. Son 3.000 lineas y casi todo es de fases
      que no te tocan.

  (d) `proyecto 4.0/PLAN-PARALELO.md`
        · Seccion 3  el carril B y qué ficheros son de quien
        · Seccion 5  el protocolo de trabajo por fase
        · Seccion 5.2  lo que NO puede hacer un agente
        · Seccion 9  la checklist de arranque
        · Seccion 8  qué documentación hay que mantener al dia

════════════════════════════════════════════════════════════════════════
3. QUE ESTA YA HECHO - NO LO REPITAS
════════════════════════════════════════════════════════════════════════

La Fase 2 está cerrada, mergeada pendiente, y verificada. Concretamente ya
existen, probados y con tests:

  · Candil.Build.install/2  con las DOS estrategias
      - :precompiled  -> asset por Detector, descarga a .part, reanuda con
                          Range, SHA-256 por bloques, rename, unzip, chmod
      - :source       -> git clone real, cmake real, copia los binarios
      - opciones: :asset_url, :cmake, :on_output
    Candil.Build.check/1, configure_command/1, build_command/1, jobs/1

  · Candil.EnginePool como REGISTRO DE INSTANCIAS, no LRU
      - put/5, delete/2, get/2, by_model/1, list/0, count/0, ports/0
      - claim_port/2 que conecta de verdad para saber si algo escucha
      - get/0 sigue deprecada durante un release y devuelve :empty
      - evict/0 ya no existe
    Candil.Engine.start/2 registra {model.alias, port} con el modelo y el engine

  · `proyecto 4.0/candil.toml`  (7 modelos de ropero, valida y carga)

  · `Candil.Config.File.expand/1` expande ya el `draft` junto al `source`

Tus tests están en:
  test/candil/build/  (precompiled_test, source_test, source_real_test)
  test/candil/engine_pool_test.exs
  test/candil/config/file_test.exs

`source_real_test.exs` corre un cmake DE VERDAD cuando lo encuentra en el PATH,
y dice en voz alta cuando no lo encuentra. Si tienes cmake, úsalo.

════════════════════════════════════════════════════════════════════════
4. QUE TIENES QUE HACER
════════════════════════════════════════════════════════════════════════

▓▓▓ 4.0  PRIMERO: decide lo del TOML → Store  (bloquea a `models list`) ▓▓▓

`Store.init/1` solo lee `Application.get_env(:candil, Candil.Store)`. Nada
mete los modelos del TOML en el Store. Sin esto, `candil models list` imprime
una tabla vacía y el criterio de aceptación de la Fase 3 es inalcanzable.

El diseño (§14.1) menciona un `Store.reload/0` que no llegó a congelarse.
Tienes
tres caminos y **este es un PARAR-Y-PREGUNTAR**:

  (a) Escribir el cargador. Es código nuevo en carril A (`store.ex`,
      `config/**`), y el §3.1 del plan dice que tocar un fichero de otro carril
      va en un PR separado. Puedes hacerlo, pero como PR propio.

  (b) Declararlo fuera de alcance y hacer que la CLI lo pida como
      dependencia: `candil models list` dice "no hay modelos; ejecuta
      `candil config load`" y `candil config load` no existe todavía. Eso
      convierte un bug en un mensaje honesto, y es defendible.

  (c) Preguntármelo antes de escribir nada.

Lo que NO puedes hacer es inventar un cargador en el PR de la CLI sin decirlo.
La pregunta de diseño que trae: los alias del TOML tienen que convertirse en
átomos, y `String.to_existing_atom/1` (regla dura 7 del Apéndice D) rechaza un
alias que no haya visto. En la primera carga, ninguno de los 7 existe. Un
fichero de configuración no es la red, así que `to_atom` sobre sus claves es
defendible — pero la regla está escrita sin excepción y eso se decide, no se
hereda.

▓▓▓ 4.1  Dep y escript  (0.5 d)  ▓▓▓

`alaja` YA ESTÁ en `mix.exs` (la declaró el carril A). No añadas la dep.

Falta el escript:

    escript: [main_module: Candil.CLI]

⚠ **Conflicto real, y los dos se llaman §3.1**: el §3.1 de la Fase 3 del
documento de diseño dice que esta fase añada esa línea a `mix.exs`, y el §3.1
del PLAN-PARALELO dice que `mix.exs` solo lo toca el carril H. **No lo toques.**
Deja la línea pedida en el cuerpo del PR y dilo. Lo mismo con
`groups_for_modules`: vas a añadir módulos nuevos (`Candil.CLI`,
`Candil.CLI.*`), y eso lo aplica H.

Mientras tanto, para probar:

    mix run -e 'Candil.CLI.main(["version"])'

`Candil.CLI.main/1` llama a `Application.ensure_all_started(:candil)` antes de
nada, o la CLI no ve el catálogo de ETS. **Este detalle se olvida siempre y
cuesta una hora de desconcierto.** Lo dice el diseño, ponlo en un comentario.

▓▓▓ 4.2  Comandos de modelos  (1.5 d)  ▓▓▓

`list` con tabla de Alaja, `info`, `remove` con confirmación, y `pull` con barra
de progreso leyendo el `:atomics` del `Source`.

  · `pull` usa `Source.fetch/2` y `Source.progress/1`, que ya funcionan. La
    barra se alimenta de `progress/1`. Pruébalo contra un servidor HTTP de
    mentira que responda a `Range`, no con un doble del Source entero: la
    reanudación es justo lo que se quiere vermoviendo.

  · La tabla del criterio de aceptación es esta:

        alias      type   ctx      port  usage                 size      state
        coder      local  131072   9999  chat,code,completion  17.7 GB   downloaded
        analyst    local  131072   9999  chat,reasoning        13.1 GB   downloaded
        embed      local  8192     9990  embeddings             1.6 GB   downloaded
        gpt4o      remote 128000   -     chat,completion        -        -

    El estado es `downloaded` o no, según `Model.downloaded?/1`. La columna de
    tamaño sale de `Source.size/1`. No inventes un "downloading" que nadie
    escribe todavía.

▓▓▓ 4.3  Comandos de ciclo de vida  (2 d)  ▓▓▓

`run` con el `:auto` de §11.2, el PREFLIGHT, `--force`, `--cpu`, `--detach`;
`stop`; `status` con `--json` y `--watch`.

Esto es lo importante y no es negociable:

  · `run` resuelve el puerto en este orden (§11.2): `--port N` si está,
    si no `model.port`, si no `EnginePool.claim_port(base_port, base_port+99)`.
    Después registra con `EnginePool.put/5` ANTES de arrancar, para que el
    siguiente `claim_port` no devuelva el mismo puerto.

  · El PREFLIGHT ocurre ANTES de tocar ningún puerto: ¿existe el GGUF? ¿existe
    el engine? ¿el binario es localizable? ¿el source está descargado? Si algo
    falla, error y no has tocado nada.

  · Si el puerto está ocupado por otro `model_alias`, **no se mata solo**:
    error que dice quién lo ocupa y ofrece `--force`. Con `--force`, mata,
    espera ≤5 s, y arranca. Esto es una línea del documento de diseño y se
    nota.

  · El modo foreground **engancha y colorea la salida del proceso**. Es un
    `awk` de 25 líneas que colorea por patrón: `OOM|CUDA error|segfault` → rojo,
    `tok/s|eval time` → magenta, `loaded|server listening` → color del modelo.
    Es lo que hace legible un arranque de 20 GB. Sin esto, la fase no está.

  · `stop` dice cuántas instancias paró. El criterio espera "✓ 2 instancias de
    'coder' paradas" cuando el mismo modelo está en dos puertos.

  · `status --json` tiene que poder hacer `jq -r '.[0].model'`. O sea: una
    lista, no un objeto.

▓▓▓ 4.4  Tests  ▓▓▓

La CLI se prueba con dobles, no con procesos reales. Al menos:

  test/candil/cli/models_test.exs
    · list con el Store poblado y vacío
    · remove pide confirmación y no borra sin ella
    · pull con Source.fetch/2 doblado, incluida la barra
  test/candil/cli/lifecycle_test.exs
    · run con puerto explícito, con :auto y con :auto sin puertos libres
    · PREFLIGHT falla antes de tocar un puerto (que es la parte que cuesta
      demostrar: mira que el puerto sigue libre después del error)
    · puerto ocupado por otro alias → error, no kill
    · --force → mata y arranca
    · status --json es una lista parseable
    · stop cuenta instancias
  test/candil/cli/colorizer_test.exs
    · el patrón `CUDA error` sale en rojo
    · `tok/s` sale en magenta

Cada uno de esos es una línea del criterio de aceptación de la Fase 3, o un
error que el criterio de aceptación dice explícitamente que no puede pasar.

════════════════════════════════════════════════════════════════════════
5. LOS OCHO GATES - TODOS EN VERDE ANTES DE CADA PUSH
════════════════════════════════════════════════════════════════════════

    mix format --check-formatted
    mix compile --force --warnings-as-errors
    mix credo --strict --format=oneline
    mix test --cover
    mix dialyzer
    mix docs --warnings-as-errors
    mix hex.audit
    mix deps.unlock --check-unused

Estado de partida medido con las fases 0, 1 y 2 mergeadas: los ocho
pasan. **610 tests + 24 doctests, 0 fallos, 66.4 % de cobertura.** No bajes
ninguno de los dos números.

Advertencia sobre dialyzer: su PLT tiene que incluir apero/arrea/trebejo, o las
llamadas a las libs hermanas salen como `unknown_function` y nunca se comprueba
nada. Ya está arreglado (plt_add_apps). Si al tocar algo aparece
`unknown_function` de una app hermana, mira el PLT antes que tu código.

Advertencia sobre los stubs: un stub que hace `raise` es `none()` para dialyzer.
Por eso los once que quedan devuelven `{:error, %Candil.Error{reason:
:not_implemented}}`, que cumple su propio `@spec`. Si escribes un stub nuevo,
hazlo igual, y no añadas un fichero de ignore.

════════════════════════════════════════════════════════════════════════
6. GIT
════════════════════════════════════════════════════════════════════════

Rama:      4.0-f3-cli          (creala desde 4.0)
PR:        contra 4.0, nunca contra main
main:      tiene branch protection con 1 approving review. El PAT es admin y
           se lo salta, asi que puedes pushear a main sin revision. NO lo
           hagas. Es la unica disciplina que queda en este repo.
Commits:   export GIT_AUTHOR_DATE="YYYY-MM-DDTHH:MM:SS+02:00"
           export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
           Fecha entre 20:00 y 02:00 Europe/Berlin, de lunes a viernes.
           Finde libre. Es una convencion del ecosistema, no del repo.
Push:      en cada sub-paso, no solo al final.
Tag:       candil-4.0.0-alpha.1 al mergear

⚠ El plan dice `4.0/f3-cli` y **eso es imposible**: `refs/heads/4.0` y
`refs/heads/4.0/f3-cli` no pueden coexistir, porque Git no admite un ref y un
directorio a la vez. En la Fase 2 me pasó con el push. Usa guion: `4.0-f3-cli`.

Documentos que hay que mantener al dia, en el mismo commit que el cambio:
  · CHANGELOG.md  - formato Keep a Changelog, seccion Unreleased, con los
                    nombres de funcion reales
  · README.md     - el ejemplo tiene que RUN, no parecerse plausible. Con la
                    CLI ya existe, el ejemplo de la CLI tiene que ejecutarse
  · docs/CONFIG.md  si tocas el TOML. **No existe todavia.** El §8 del plan
                    pide que lo mantenga el carril H. Si lo creas, avisa.
  · groups_for_modules en mix.exs si anades un modulo: NO lo edites. Dejalo
    apuntado en el PR.

════════════════════════════════════════════════════════════════════════
7. LO QUE NO VAS A HACER
════════════════════════════════════════════════════════════════════════

· No toques `mix.exs`. Ni una linea. Ni el escript, ni groups_for_modules.
· No toques ficheros del carril A (store.ex, build.ex, engine.ex,
  engine_pool.ex, source.ex, config/**, engine/**, inference/**). Si necesitas
  algo de ahí, es un PR separado contra el carril dueño, y se mergea antes.
· No escribas el cargador de TOML a Store sin que quede acordada §4.0.
· No reimplementes `Source.fetch/2`, ni H1, ni ninguna de las ocho cosas que
  las fases 0 y 1 trajeron. Están hechas y probadas; tu trabajo empieza en
  la CLI.
· No conviertas la ruta de modelos en fija. Es configurable (C17).
· No uses String.to_atom/1 con nada que venga de fuera. Ya ha costado dos
  veces: la tabla de atomos no crece.
· No hagas git push --force.
· No toques los structs de contrato.
· No pongas a tu CLI a matar procesos sin --force. El §11.2 lo dice: "candil
  no mata automaticamente".

════════════════════════════════════════════════════════════════════════
8. AL TERMINAR
════════════════════════════════════════════════════════════════════════

Actualiza `proyecto 4.0/HANDOFF.md` §2 (que se hizo) y §3 (que sigue), y
añade o actualiza la §3-bis con lo que siga sin poder probarse desde un
sandbox. Numeros medidos del output real de los comandos, no de memoria.
Commit, push, PR, y avisame del resultado con los ocho gates.

Y escribe `proyecto 4.0/fases/fase-4-README.md` para la siguiente sesión, con el
mismo formato. La Fase 4 (instancias.json, --detach real, Launcher.Http) es la
que hereda todo lo que dejes sin cerrar aqui.

Si te bloqueas en algo, PARA y pregunta. No improvises una decision de
diseno: estan todas escritas en el documento de diseño, y si ninguna encaja,
eso es informacion que necesito.
```

---

## Notas para ti, no para la otra sesión

**La Fase 3 está bloqueada por arriba, no por abajo.** El grafo del plan es
F0 → F1 → F2 → F3, y tú has hecho F2 saltándote F0 y F1. Eso no invalida la
F2 —la F2 no necesitaba nada de ellas— pero la F3 sí: `models pull` necesita
`Source.fetch/2`, el criterio de aceptación necesita hablar con un
`llama-server` real, y `models list` necesita un catálogo que nadie llena.

**La decisión que te toca a ti antes que al agente** es la del §4.0 del
prompt: quién carga el TOML en el `Store`. Yo no la he inventado porque no
está en ninguna fase del plan, y porque trae la pregunta de los átomos, que es
de diseño. Puedes decidirla tú en dos minutos y el prompt queda listo para
ejecutarse.

Si quieres, la secuencia que yo haría es: Fase 0 (H1) → Fase 1 (Source) → y
entonces la Fase 3, que sería la primera fase cuyo criterio de aceptación se
puede ejecutar de principio a fin. La Fase 3 tal como está escrita se puede
construir entera, pero aceptarla sin F0 y F1 es aceptar con el marcador.

Y lo que sigue pendiente de tu máquina, sin cambio: el build real de llama.cpp
con tus flags de CUDA, y el camino `:precompiled` contra la API de GitHub. El
guion está en `HANDOFF.md` §3-bis.
