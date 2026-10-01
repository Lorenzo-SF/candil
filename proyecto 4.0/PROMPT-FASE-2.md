# Prompt para implementar la Fase 2 de Candil 4.0

Copia el bloque de abajo entero en la sesión nueva. Está escrito para que no
tenga que descubrir nada: qué leer, qué ya está hecho, qué hacer, y cómo se
comprueba.

---

```text
Estoy implementando Candil 4.0, una librería de Elixir de inferencia LLM y
gestión de modelos. Ya hay un plan completo y 16 commits de contratos
congelados. Tu tarea es implementar la FASE 2.

════════════════════════════════════════════════════════════════════════
1. ENTORNO
════════════════════════════════════════════════════════════════════════

Repositorio: https://github.com/Lorenzo-SF/candil
Rama:        4.0          (NO cambies de rama; main está intacta a propósito)
Tag de partida de esta fase: 4.0-contracts-frozen
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

Si trabajas en un sandbox efímero donde /opt se borra entre sesiones, hay un
script de recuperación en /workspace/setup-candil.sh que reconstruye el
entorno entero (asdf, mirror de Hex, directorios de build) en un comando.

════════════════════════════════════════════════════════════════════════
2. LEE ESTO, EN ESTE ORDEN
════════════════════════════════════════════════════════════════════════

Los tres documentos están en `proyecto 4.0/`. El orden importa: el primero
te da el estado real, el segundo el diseño, el tercero cómo trabajar.

  (a) `proyecto 4.0/HANDOFF.md`                    <- LEELO PRIMERO, ENTERO
      Estado medido, los ocho gates, los doce stubs que quedan y en qué
      fase está cada uno, el orden de trabajo, y la lista de errores ya
      cometidos con su porqué. La sección 4 es importante.

  (b) `proyecto 4.0/candil-4.0-final.md`
      Solo estas partes, indicadas por número de línea:
        · Seccion 13  (linea ~1152)  Candil.Build, las dos estrategias
        · Seccion 14.3 (linea ~1253) Candil.Engine 4.0
        · Seccion 14.4 (linea ~1279) Candil.EnginePool 4.0  <- API exacta
        · Seccion 11  (linea 977)   Puertos, instancias y supervivencia  Puertos, instancias y supervivencia
        · Apendice A  (linea ~2779)  el candil.toml de ropero
        · Fase 2      (linea ~2334)  el bloque de la fase, con el criterio
                                      de aceptacion ejecutable
      NO leas el documento entero. Son 3.000 lineas y casi todo es de fases
      que no te tocan.

  (c) `proyecto 4.0/PLAN-PARALELO.md`
        · Seccion 3  los ocho carriles y que ficheros son de quien
        · Seccion 5  el protocolo de trabajo por fase
        · Seccion 9  la checklist de arranque de cada agente
        · Seccion 2  por que existen los contratos congelados (2.2, la regla)

  Ademas, `docs/BASELINE-4.0.md` tiene el punto de partida medido.

════════════════════════════════════════════════════════════════════════
3. QUE ESTA YA HECHO - NO LO REPITAS
════════════════════════════════════════════════════════════════════════

La Fase -1 (congelado de contratos) ya esta cerrada y verificada. La
Fase 2 del plan empieza por 2.1, y 2.1 YA ESTA HECHO. Concretamente ya
existen, probados y con tests:

  · Candil.Model 4.0   - el struct entero con port, source, draft, tags,
                         enabled, launcher, base_url y type: :external
  · Candil.Engine 4.0  - binary, base_port, api_key, auth_headers, install;
                         y las funciones api_key/1, auth_headers/1,
                         base_url_and_headers/2, validate/1
  · Candil.Build       - el struct, y new/1, validate/1, dir/1,
                         binary_path/2, cmake_command/1, generator_flag/1
  · Candil.Source      - el struct, y validate/1, url/1, filename/1,
                         dest_path/1, present?/1, size/1
  · Candil.Store       - el registro, con validacion en la entrada
                         (antes se llamaba Candil.Config)
  · Candil.Config.Schema y Candil.Config.File - el TOML

Estos ficheros son PROPIEDAD DEL CARRIL A. Son tuyos, puedes editarlos, pero
nadie mas los toca.

Sus tests estan en:
  test/candil/source_test.exs, build_test.exs, model_v4_test.exs,
  engine_auth_test.exs, store_test.exs, config/schema_test.exs,
  config/file_test.exs

════════════════════════════════════════════════════════════════════════
4. QUE TIENES QUE HACER - TRES COSAS
════════════════════════════════════════════════════════════════════════

▓▓▓ 4.1  Candil.Build.install/2 y check/1  (lo mas grande, ~3 dias) ▓▓▓

Hoy son stubs: devuelven {:error, %Candil.Error{reason: :not_implemented}}.
Hay que escribirles el cuerpo.

install/2 tiene dos estrategias, y las dos se ejecutan.

  :precompiled
    Detectar SO, arquitectura y GPU (ya existe Candil.Detector, con
    Detector.GPU, Detector.Models y Detector.Release). Resolver el asset del
    release de llama.cpp que encaje. Descargar con reanudacion por Range,
    checksum en streaming, escribir a .part y renombrar. Descomprimir a dir
    y chmod +x.

    Ojo: Candil.Installer.download_engine/1 YA HACE CASI TODO ESTO para el
    caso simple. Decide si Build delega en Installer o lo reescribes, y si
    lo reescribes explica por que en el commit. No dupliques 200 lineas sin
    motivo.

  :source
    git clone -b ref
    cmake -B build_dir -S src_dir con los cmake_args del usuario
    cmake --build -j (jobs, donde 0 significa nproc)
    copiar los binaries declarados a dir, chmod +x

    ESTA ES LA PARTE QUE IMPORTA. Reglas que no son negociables:

    · cmake_args se pasa a cmake VERBATIM. Candil no anade ningun flag de
      arquitectura ni de GPU, y no debe empezar a hacerlo. La razon esta
      escrita en el moduledoc de Build: una RTX 5080 (Blackwell) necesita
      -DCMAKE_CUDA_ARCHITECTURES=120a junto con los interruptores MXFP4 y
      NVFP4, y un binario generico publicado no esta ajustado a eso. Quien
      sabe el hardware es quien escribe el TOML.
    · Candil solo anade -S, -B y -DCMAKE_BUILD_TYPE=Release, y solo si el
      usuario no los puso ya. cmake_command/1 ya lo hace: usalo.
    · El proceso hijo debe ser cancelable y debe morir con el padre. Si el
      usuario cierra el CLI a mitad de compilacion, el cmake se mata.
    · El error de cmake se propaga TEXTUALMENTE. Si no compila, es que los
      flags estan mal, y el error de cmake lo dice.
    · Nada se enlaza al PATH. Ni a ~/.local/bin ni a ningun sitio. Un
      montaje anterior enlazo un venv entero y tumbo el python3 del sistema
      para todos los procesos de la maquina.

check/1
    Que los binaries declarados esten y sean ejecutables.
    Devuelve :ok | {:error, [nombres que faltan]}.

Tests que deben existir y pasar:
  test/candil/build/precompiled_test.exs
  test/candil/build/source_test.exs
    · git clone de un repo fixture
    · cmake_args se pasan VERBATIM   <- blinda la regla de arriba
    · --build usa el generator declarado (ninja/make)
    · jobs=0 significa nproc
    · binaries se copian a dir y quedan ejecutables
    · error de cmake -> {:error, texto} con el stderr
    · cancelacion mata el proceso hijo

Y una prueba manual, fuera del CI, contra llama.cpp de verdad: el bloque
bash de la seccion 2.2 de la Fase 2 en el documento de diseno trae el TOML
completo con los flags reales de CachyOS/CUDA. Son 20-40 minutos de
compilacion. Al terminar, /ruta/llama-server --version tiene que funcionar.

▓▓▓ 4.2  EnginePool como registro de instancias  (~1.5 dias) ▓▓▓

Hoy es un LRU de una sola entrada que nadie vacia. Se reescribe segun la
API exacta de la seccion 14.4 del documento de diseno: el registro pasa a
ser {alias, port} => %{pid, model, engine, started_at, healthy}.

Esto es el bug B7, y el motivo no es estetico: cuatro modelos de 20 GB no
caben, y un LRU de 4 entradas tampoco resuelve eso. Un LRU finge estar
resolviendo una presion de memoria que no existe. Lo que hace falta es un
registro de lo que esta vivo.

Lo que desaparece: get/0 y evict/0. Es un cambio de API publico, y es
deliberado: la version mayor de semver ya esta en marcha (C13). Deja
get/0 con @deprecated durante un release.

claim_port/2 es la pieza nueva y merece atencion: reserva un puerto del
rango base_port..+99 y comprueba con :gen_tcp.connect/4 que no hay nadie
escuchando. Eso es lo que distingue un puerto libre de uno con un ropero
muerto encima, que es exactamente el caso aqui.

▓▓▓ 4.3  El candil.toml de ropero, a mano  (~medio dia) ▓▓▓

Aqui NO hay nada que automatizar, y es una decision (C15).

Los ficheros ropero.d/*.sh tienen case anidados, variables indirectas y
source entre ellos. No se puede parsear fiablemente, y un parser que
funciona el 80 por ciento es peor que nada: parece fiable y falla en
silencio. El analisis ya esta hecho y esta escrito en el Apendice A del
documento de diseno. Tu trabajo es traducirlo a un fichero de verdad:

    mkdir -p ~/.config/candil
    $EDITOR ~/.config/candil/candil.toml
    mix run -e 'IO.inspect(Candil.Config.File.load())'

Comprueba que el TOML carga y que los modelos aparecen en Candil.Store.

Ojo: el CLI no existe todavia (es la Fase 3). Valida con mix run -e
mientras tanto.

ropero NO se toca. Sigue vivo, y su retirada es decision tuya (C16).

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

Estado de partida: los ocho pasan. 515 tests y 24 doctests, 0 fallos, 63.1
por ciento de cobertura. No bajes ninguno de los dos numeros.

Advertencia sobre dialyzer, que ya mordio una vez: su PLT tenia solo OTP y
Candil, asi que las 15 llamadas a apero/arrea/trebejo salian como
unknown_function y nunca se comprobo ninguna. Ya esta arreglado
(plt_add_apps). Si al tocar algo aparece unknown_function de una app
hermana, mira primero el PLT antes que tu codigo.

Advertencia sobre los stubs: un stub que hace raise es none() para dialyzer.
Por eso los doce existentes devuelven {:error, %Candil.Error{reason:
:not_implemented}}, que cumple su propio @spec. Si escribes un stub nuevo,
hazlo igual. No hace falta fichero de ignore y dialyzer queda limpio.

════════════════════════════════════════════════════════════════════════
6. GIT
════════════════════════════════════════════════════════════════════════

Rama:      4.0/f2-build            (creala desde 4.0)
PR:        contra 4.0, nunca contra main
main:      tiene branch protection con 1 approving review. El PAT es admin y
           se lo salta, asi que puedes pushear a main sin revision. NO lo
           hagas. Es la unica disciplina que queda en este repo.
Commits:   export GIT_AUTHOR_DATE="YYYY-MM-DDTHH:MM:SS+02:00"
           export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
           Fecha entre 20:00 y 02:00 Europe/Berlin, de lunes a viernes.
           Finde libre. Es una convencion del ecosistema, no del repo.
Push:      en cada sub-paso (4.1, 4.2, 4.3), no solo al final.
Tag:       candil-4.0.0-alpha.2 al mergear

Documentos que hay que mantener al dia, en el mismo commit que el cambio:
  · CHANGELOG.md  - formato Keep a Changelog, seccion Unreleased, con los
                    nombres de funcion reales
  · README.md     - el ejemplo tiene que RUN, no parecerse plausible
  · docs/CONFIG.md si tocas el TOML
  · groups_for_modules en mix.exs si anades o renembras un modulo.
    SOLO lo edita el carril H (docs/CI): si anades un modulo, dejalo
    apuntado en el PR y lo anade quien lleve ese carril.
  · El moduledoc de lo que toques. mix docs corre con --warnings-as-errors,
    asi que una referencia rota a un modulo que no existe es un build rojo.

════════════════════════════════════════════════════════════════════════
7. LO QUE NO VAS A HACER
════════════════════════════════════════════════════════════════════════

· No toques ropero. Ni un byte.
· No escribas el comando de migracion de ropero. C15: no existe.
· No anadas flags de cmake por tu cuenta.
· No conviertas la ruta de modelos en fija. Es configurable (C17).
· No uses String.to_atom/1 con nada que venga de fuera. Ya ha costado dos
  veces: la tabla de atomos no crece.
· No hagas git push --force.
· No toques los structs de contrato de otro carril.

════════════════════════════════════════════════════════════════════════
8. AL TERMINAR
════════════════════════════════════════════════════════════════════════

Actualiza `proyecto 4.0/HANDOFF.md` seccion 2 (que se hizo) y seccion 3
(que sigue), con numeros medidos del output real de los comandos, no de
memoria. Commit, push, PR, y avisame del resultado con los ocho gates.

Si te bloqueas en algo, PARA y pregunta. No improvises una decision de
diseno: estan todas escritas en el documento de diseno, y si ninguna encaja,
eso es informacion que necesito.
```

---

## Notas para ti, no para la otra sesión

**La 2.1 de la Fase 2 ya está hecha.** El freeze de contratos la ejecutó
entera: `Model` y `Engine` v4, el struct de `Build` y todas sus funciones
puras. El prompt lo dice explícitamente para que no la repita.

**Fase 0 sigue pendiente y no es lo mismo.** En `HANDOFF.md` §3 está el
trabajo de H1: usar `auth_headers/1` en la ruta local de inferencia, que ya
está escrito y probado pero no conectado. La Fase 2 no lo necesita para
completarse, pero **sin Fase 0 no se puede arrancar nada contra ropero**,
que es el objetivo de todo esto. Si quieres que la otra sesión lo haga
primero, dímelo y lo añado al prompt.

**Los nombres de rama y tag** (`4.0/f2-build`, `candil-4.0.0-alpha.2`) son
los que dicta el §6 del plan paralelo.
