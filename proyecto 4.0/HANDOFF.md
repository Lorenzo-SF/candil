# Candil 4.0 — Estado y traspaso

> **Este es el documento que hay que leer antes de retomar el trabajo.**
>
> `candil-4.0-final.md` dice lo que se decidió y por qué. Este dice lo que
> **está hecho, medido y verificado**, y lo que toca mañana. Cuando se
> contradigan, este tiene razón sobre el presente y aquel sobre el futuro.
>
> **Fecha**: 2026-10-01 · **Rama**: `4.0/f2-build` (base `4.0`) ·
> **Toolchain**: Erlang/OTP 28.5.0.7, Elixir 1.19.5-otp-28 ·
> **Punto de partida de esta fase**: `4.0-work-start`

---

## 1. Dónde está el proyecto

| | |
|---|---|
| Rama de trabajo | `4.0` |
| `main` | Intacta, con su CI viejo. No se ha tocado. |
| Tag de partida | `4.0-work-start` |
| Tests | **571 tests + 24 doctests**, 0 fallos |
| Cobertura | **65.2 %** (63.1 % al entrar; oscila una décima con la semilla async) |
| Gates | **8 de 8 en verde** |
| Rama de trabajo | `4.0/f2-build` — tres commits, `4.0` sin tocar |

### Los ocho gates, y los comandos exactos

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

Los tres últimos no se ejecutaban de verdad antes: `mix deps.audit` no existe
(`mix hex.audit`), `minimum_coverage` de excoveralls no se comprueba en un
`mix test --cover` normal, y `mix docs` sale con 0 aunque imprima warnings.

---

## 2. Lo que está hecho

### Fase -0 — el gate fiable (cerrada)

Partía de 4 gates rojos. Los ocho están verdes.

- `mix format` sobre 24 ficheros.
- `mix credo --strict` de 37 issues a **0**, dos con refactor real:
  `Agent.loop/7` tenía tres niveles de anidamiento y
  `Tools.parse_openai_tool_calls/1` estaba sobre el límite de complejidad.
- **Los 22 fallos de test eran dos ficheros**, no 22 problemas:
  `config_test.exs` borraba `:apero_llm_engines` y `engine_test.exs` esperaba
  `~/.apero/llm/bin`. El código tenía razón en ambos casos; corregirlo habría
  reintroducido el bug.
- 54 warnings de `mix docs` a 0. La causa era casi toda una: `Candil.Llm` es
  `@moduledoc false` y los `defdelegate` de `Candil` heredaban sus `@doc`, así
  que el facade público entero se renderizaba con referencias irresolubles.

### Fase -1 — congelado de contratos (cerrada)

Ocho rebanadas, cada una con sus propios errores encontrados por sus propios
tests.

| Rebanada | Qué congeló |
|---|---|
| 1 | `Candil.Source`, `Candil.Build` |
| 2 | `Candil.Model` y `Candil.Engine` v4 — **incluye H1** |
| 3 | `Candil.Store` (antes `Config`), `Config.Schema`, `Config.File` |
| 4 | `Candil.Context`, `Context.Session` |
| 5 | `Candil.Router` y sus cinco módulos |
| 6 | `Candil.Gateway`, `Gateway.Auth`, `Gateway.Endpoint` |
| 7 | `Context.Builder`, `Summarizer`, `PrefixManager` |
| 8 | `Candil.MCP`, `MCP.Protocol`, `Candil.RAG`, `RAG.Chunk` |

**H1 está arreglado.** `Engine.auth_headers/1` y
`Engine.base_url_and_headers/2` resuelven la API key, y
`Engine.Server.build_args/2` emite `--api-key` y `--alias` en la línea de
comandos. El camino local ya puede hablar con un `llama-server` protegido.

### Fase 2 — Build, EnginePool y el TOML de ropero (cerrada en 4.0/f2-build)

Tres commits, uno por sub-paso, con los ocho gates en verde en cada push.

| Sub-paso | Qué |
|---|---|
| 4.1 | `Candil.Build.install/2` con las dos estrategias, y `check/1`. Más `configure_command/1`, `build_command/1` y `jobs/1`, públicos para que un test pueda comprobar el argv sin compilar nada |
| 4.2 | `Candil.EnginePool` como registro de instancias, con `claim_port/2` |
| 4.3 | `proyecto 4.0/candil.toml`, y un bug de `Config.File.expand/1` que aparecía al usarlo |

**4.1, lo que no era lo que parecía.** Un puerto pertenece a la VM, no al
proceso que lo abrió: matar al dueño dejaba el `cmake` corriendo, y
`Port.close/1` también. `run/3` monitoriza al dueño y mata el `os_pid`. El
límite está escrito en el código: un `kill -9` a la VM entera no deja ningún
proceso BEAM vivo que pueda matar nada. Y `spawn_executable` **no** busca en el
`PATH`: `git` salía como `:enoent` en una máquina que tiene git.

**4.1, verificado además contra un cmake de verdad.** La suite usa un doble
de cmake, que es lo que le permite comprobar el argv exacto que recibió un
proceso y nada más. `test/candil/build/source_real_test.exs` cubre el hueco
que un doble no cubre: cmake 3.25.1 y ninja 1.11.1 de verdad, `git clone`
real, los dos generadores, los binarios compilados **y ejecutados**, y el error
de un compilador real llegando por su stderr. Sin cmake en el PATH lo dice en
vez de pasar en silencio. Cinco tests, dos segundos.

Descubierto al escribirlo, y ahora en el moduledoc: **cmake cachea su
configuración en `build_dir`**, así que volver a lanzar `install/2` ahí con
otros `cmake_args` no los aplica. Es comportamiento de cmake, y borrar un
directorio de build en silencio es justo cómo se pierden veinte minutos de
compilación, así que está documentado en vez de disimulado.

`install/2` **no** delega en `Candil.Installer.download_engine/1`, y es una
decisión: el installer escribe en `engine.binary_dir` y no en el `dir` del
plan, no lee `sha256`, no tiene reanudación por `Range`, ni `.part`, ni rename,
y hashea el fichero entero con `File.read/1` — que es B8, y B8 es de la Fase 0.
Delegar habría sido arreglar un bug de la Fase 0 desde una fase que no puede
tocarlo.

**4.3, medido, no supuesto.** `Candil.Config.File.load/1` sobre el TOML
devuelve `{:ok, _}`: 1 engine, 1 provider, 3 consumers, 7 modelos. Los 7
construyen y se registran en `Candil.Store` con su puerto, contexto, usage y
fichero correctos.

**El fallo que salió al usarlo**: `Config.File.expand/1` nunca expandía el
`draft` de un modelo que tuviera también `source`. Dos cláusulas, un patrón
cada una. El único modelo con draft es el único que también tiene `source`, así
que su `--model-draft` conservaba un `~` literal — el C22 de manual. El test
que decía cubrirlo usaba un modelo con draft y sin source, que es justo la
forma que ya funcionaba.

### Lo que aún es stub, y es intencionado

Once funciones, todas con un contrato escrito y un test que lo ejerce.
`Candil.Build.install/2` sale de la lista: la Fase 2 le ha puesto cuerpo.

```
Candil.Source.fetch/2            fase 1     Candil.RAG.index/3            fase 10
Candil.Source.progress/1         fase 1     Candil.RAG.search/3           fase 10
Candil.Config.File.save/2        fase 1     Candil.RAG.create_index/2     fase 10
Candil.MCP.serve/1               fase 9     Candil.RAG.drop_index/1       fase 10
Candil.MCP.serve/1               fase 9     Candil.RAG.list_indexes/0     fase 10
Candil.MCP.connect/1             fase 9
Candil.Gateway.Endpoint.listen/4 fase 8
```

Ninguna lanza una excepción: devuelven
`{:error, %Candil.Error{reason: :not_implemented}}`, que cumple su propio
`@spec`. Un stub que hace `raise` es `none()` para dialyzer, así que un
freeze de contratos basado en raise necesita un fichero de ignore — y un
fichero de ignore es justo lo que luego oculta un `no_return` real.

---

## 3. Lo siguiente: Fase 0, los bugs y H1

**Es la fase que desbloquea todo lo demás.** Sin H1 implemented no se puede
arrancar nada contra ropero.

Orden recomendado, tal cual está en el documento de diseño:

1. **Los 4 stubs de backend** (2 h) — `LlamaCpp.chat/3`, `chat_stream/3`,
   `OpenAICompat.chat_stream/3` (borrar `build_chunk_stream/1`: un stream de
   un chunk con `Process.sleep(50)` no es una feature a arreglar, es
   eliminación), `OpenAICompat.embed/3` (batch en una request).
2. **H1, la cabecera** (3 h) — el diseño ya está escrito y probado en
   `test/candil/engine_auth_test.exs`; falta **usarlo** en
   `Inference.Chat.do_chat_local/3`, `Inference.Embeddings.do_embed_local/3`
   y `Stream.chat/4`. La prueba de aceptación es un `llama-server` real con
   `--api-key`, y el mismo test con la key quitada esperando 401.
3. **B5** (15 min) — `api_key` acepta un string plano. Ya está hecho en
   `Store.register_provider/1`; queda propagarlo a `Provider` y su doc.
4. **B6** (30 min) — `trebejo` ya está declarada; queda comprobar que
   `Detector.safe_arch/0` ya no degrada en silencio.
5. ~~**B7**~~ — **hecho en la Fase 2**: `EnginePool` es un registro de
   instancias. Sigue vivo el detalle: `Candil.Engine.Server` sigue enlazando a
   `engine.port`, así que `Model.port == :auto` todavía no significa nada.
   Eso lo resuelve el CLI de la Fase 3.
6. **B8** (1 h) — checksum en streaming, no `File.read/1` de 17 GB. Ahora
   también es lo que queda en `Candil.Installer.verify_checksum/2`; la Fase 2
   lo hizo bien en su propio camino en vez de heredarlo.

### La prueba que decide si la absorción es viable

```bash
llama-server --model ~/.candil/models/jina-code-embeddings-1.5b-Q8_0.gguf \
  --port 39999 --api-key sk-test-key -fa on --embedding &

iex> engine = %Candil.Engine{alias: :t, binary: "llama-server",
           host: "127.0.0.1", port: 39999, api_key: "sk-test-key"}
iex> Candil.Engine.start(engine, model)
iex> Candil.embed(:embed_test, ["hola", "adios"])
```

Si eso devuelve vectores, todo lo demás es mecánico. Si devuelve 401, el
problema no era H1.

---

## 3-bis. Lo que NO está probado, y por qué

Todo lo de aquí está **escrito y en verde**, y no se ha podido ejecutar. No es
un bug: es trabajo que necesita tu máquina. La distinction importa, porque
"en verde" sin esto dice menos de lo que parece.

| # | Qué falta probar | Por qué no se ha probado aquí | Dónde |
|---|---|---|---|
| 1 | **Compilar `llama.cpp` de verdad con CUDA** | No hay GPU, ni `nvcc`, ni 20-40 min que permitamos | §2.2 del diseño, bloque `CANDIL_CONFIG=/tmp/build-test.toml` |
| 2 | **Los flags de tu RTX 5080** | `-DCMAKE_CUDA_ARCHITECTURES=120a` + MXFP4/NVFP4 solo tienen sentido en tu hardware | §2.2 |
| 3 | **`:precompiled` contra la API real de GitHub** | El TLS de OTP está roto en el sandbox (`asn1 bad_range` con el proxy), así que no hay HTTPS desde Erlang | `Candil.Detector.asset_url/1` |
| 4 | **Reanudación por `Range` contra un servidor real** | Probado por el mock de Mox, que es donde vive la lógica, pero no contra un servidor de verdad | `Build.download/2` |
| 5 | **Arrancar un `llama-server` real y hablar con él** | Necesita 1, y las Fases 0 y 1 no están hechas | §3 |
| 6 | **Cualquier cosa end-to-end contra ropero** | Depende de 5 | §3 |

**Lo que sí está verificado con herramientas de verdad**, para que no suene a
menos de lo que es: `git clone` real, **cmake 3.25.1 real**, **ninja 1.11.1
real**, `Unix Makefiles` real, los binarios compilados **y ejecutados**, y el
error de un compilador real llegando por su stderr sin resumir. Está en
`test/candil/build/source_real_test.exs`.

### El guion que falta

Esto es lo que hay que ejecutar en tu máquina, en este orden. El primero es el
que bloquea todo lo demás.

```bash
# 1. ¿Compila llama.cpp con TUS flags?   20-40 min
cat > /tmp/build-test.toml <<'EOF'
[engine.llama_cpp.install]
strategy  = "source"
repo      = "https://github.com/ggml-org/llama.cpp"
ref       = "b4561"
src_dir   = "/tmp/llama.cpp"
build_dir = "/tmp/llama.cpp/build"
generator = "ninja"
dir       = "/tmp/llama-bin"
binaries  = ["llama-server", "llama-cli"]
cmake_args = [
  "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_CUDA_ARCHITECTURES=120a",
  "-DGGML_CUDA=ON", "-DGGML_CUDA_FA=ON", "-DGGML_CUDA_MMQ_MXFP4=ON",
  "-DGGML_CUDA_MMQ_NVFP4=ON", "-DGGML_CUDA_NO_VMM=ON",
  "-DGGML_CUDA_COMPRESSION_MODE=speed", "-DGGML_NATIVE=ON",
  "-DGGML_AVX512=ON", "-DBUILD_SHARED_LIBS=OFF",
  "-DLLAMA_BUILD_SERVER=ON", "-DLLAMA_BUILD_TOOLS=ON"
]
EOF

CANDIL_CONFIG=/tmp/build-test.toml mix run -e 'Candil.Build.install(:llama_cpp)'
/tmp/llama-bin/llama-server --version      # tiene que funcionar
```

⚠ **`build_dir` cachea.** Si repites con otros `cmake_args`, cmake reutiliza la
configuración del build anterior y los flags nuevos no se aplican. Borra
`/tmp/llama.cpp/build` antes de cambiar flags. Está documentado en el moduledoc
de `Build` porque no es culpa nuestra y sí es una sorpresa.

```bash
# 2. El camino precompiled, sin GPU:     1-2 min
#    Apunta a un asset real de llama.cpp
mix run -e '
{:ok, url} = Candil.Detector.asset_url(:latest)
IO.puts(url)
{:ok, b} = Candil.Build.new(strategy: :precompiled, dir: "/tmp/pre", binaries: ["llama-server"])
Candil.Build.install(b, asset_url: url)
|> IO.inspect(label: "install")
|> then(fn _ -> Candil.Build.check(b) |> IO.inspect(label: "check") end)
'

# 3. La reanudación por Range contra algo real:   2 min
#    corta la descarga a mitad, relanza, y mira que el fichero final
#    tiene el tamaño correcto y el checksum pasa
```

Si algo falla, el mensaje es texto del programa que falló. Pégalo tal cual en
el PR: un resumen sería justo lo que estamos intentando evitar.

## 3-ter. La Fase 0, medida punto por punto (2026-10-01)

Alguien merged main y creyó que eso era "la Fase 1". No lo es: lo que hay en
main es el **congelado de contratos** (Fase -1 del plan) más el **gate
fiable**, y nada de eso implementa Source. Los stubs siguen vivos:

```
lib/candil/source.ex:211   Source.fetch/2     {:error, ...not_implemented}, phase: 1
lib/candil/source.ex:219   Source.progress/1  {:error, ...not_implemented}, phase: 1
lib/candil/config/file.ex  File.save/2        {:error, ...not_implemented}, phase: 1
```

Y no existe carga de TOML a `Candil.Store`: `Store.init/1` solo lee
`Application.get_env`. Verificado.

**La Fase 0 NO está hecha, pero está más que a medias.** Medido sobre el árbol
integrado:

| # | Ítem | Estado |
|---|---|---|
| 1a | `LlamaCpp.chat/3` | **stub**, `{:error, %Error{reason: :backend_unavailable}}` |
| 1b | `LlamaCpp.chat_stream/3` | **stub**, idem |
| 1c | `OpenAICompat.chat_stream/3` | **hecho**, cuerpo real con telemetria |
| 1d | `OpenAICompat.embed/3` | hecho, pero **una request por texto**, no un batch |
| 1e | borrar `build_chunk_stream/1` | **sigue vivo** (openai_compat.ex:246) |
| 2 | **H1** | **NO hecho.** Los tres sitios que nombra el diseño mandan `[]` como cabeceras |
| 3 | B5 `api_key` string plano | **hecho** (store.ex:142) |
| 4 | B6 `Detector.safe_arch/0` | **mitad**: `trebejo` sí está declarado, pero sigue devolviendo `:unknown` en silencio |
| 5 | B7 `EnginePool` sin LRU | **hecho**, en la Fase 2 de este mismo PR |
| 6 | B8 checksum en streaming | **NO hecho** en `Installer.verify_checksum/2`, que sigue con `File.read/1` |

### H1 en detalle, porque es la que bloquea todo lo demás

La pieza que resuelve la clave existe, tiene sus tests, y **no está conectada
a nada**:

```
lib/candil/engine.ex:166  base_url_and_headers/2   ← escrita y probada
lib/candil/inference/chat.ex:20         HTTP.post_json(url, body, [], opts)          ← []
lib/candil/inference/embeddings.ex:14   HTTP.post_json(url, body, [], [])            ← []
lib/candil/stream.ex:58                 do_stream(url, body, [], ...)                 ← []
```

`test/candil/engine_auth_test.exs` tiene 0 referencias a `do_chat_local`,
`do_embed_local` ni `Stream.chat`: prueba el **resolutor**, no el sitio donde
el resolutor debería usarse. Es exactamente el patrón de la §4 de este
documento — una línea plausible que no puede fallar en el test que la ejerce,
porque el camino que falla no está en el test.

Hasta que H1 no esté, **no se puede arrancar nada contra un `llama-server`
protegido**, y por tanto la Fase 3 no tiene criterio de aceptación ejecutable.
Es el primer trabajo que toca.

## 4. Lo que se rompió por el camino, y conviene no repetirlo

Todo esto está en el CHANGELOG con su porqué, pero aquí la lista corta porque
cada uno costó tiempo:

| Error | Por qué costó |
|---|---|
| `String.to_atom/1` sobre el nombre de consumer de una URL | Tabla de átomos finita. Fuga a un byte por petición |
| Clave de caché del router **sin** el consumer | El que ruteara primero decidía por todos |
| `Context.gc/1` comparaba reloj de pared contra reloj monotónico | Dos épocas distintas. No recogía nunca |
| `max(-(len - max), 0)` para el exceso del LRU | Negar antes de `max/2` siempre da 0. Recogía nunca |
| `Builder.build/3` no añadía los mensajes nuevos | **Descartaba la pregunta que se acababa de hacer** |
| `RAG.embedder/1` devolvía el string del TOML | `Store` está indexado por átomos. Todo fallo, siempre |
| `expand/1` casaba claves como átomos con un mapa de TOML | Compilaba, pasaba el test vacío, no hacía nada en real |
| El rename de `Config` arrastró a `ConfigManager` | Un reemplazo de cadena no es un rename |

El patrón común: **una línea plausible que no puede fallar en el test que la
ejerce**. O porque el test construye el dato con el mismo error, o porque el
camino que falla no está en el test.

---

## 5. Cómo retomar

```bash
git clone https://github.com/Lorenzo-SF/candil.git && cd candil
git checkout 4.0

# toolchain
asdf install erlang 28.5.0.7
asdf install elixir 1.19.5-otp-28

mix deps.get
bash /workspace/setup-candil.sh   # en el sandbox: mirror de Hex, dirs de build
```

**Antes de escribir código, lee el plan de carriles**:
[`PLAN-PARALELO.md`](PLAN-PARALELO.md). Los contratos están congelados y son
propiedad del carril A; ningún otro carril los edita. Es la única cosa que
mantiene el trabajo en paralelo de que nadie pise a nadie.

Ventanas paralelas, en cuanto la Fase 0 esté:

```
Fase 0 ──► F1 ──► F2 ──┬─► F3 ─► F4 ─┬─► F6 ─► F7 ─► F8 ─┐
                        ├─► F5        │                   ├─► F11 ─► 4.0.0
                        ├─► F9        │                   │
                        └─► F10        ┘                   ┘
```

F5 (doctor), F9 (MCP) y F10 (RAG) no están en la ruta crítica: dependen sólo
del carril A y del store, así que pueden arrancar en cuanto F2 cierre.

---

## 5-bis. Un hueco que la Fase 2 no ha tapado

**No hay carga de TOML a `Candil.Store`.** `Store.init/1` solo lee
`Application.get_env(:candil, Candil.Store)`; nada más. `Config.File.load/1`
devuelve el mapa, y ahí se acaba. Los 7 modelos de §4.3 se contaron a mano
para poder decir que construyen y validan — no hay código de librería detrás
de esa frase.

El cargador no está asignado a ninguna fase del plan, y trae una pregunta que
no es de este carril: `String.to_existing_atom/1` (regla dura 7) rechaza un
alias que no haya visto antes, y en la primera carga **ninguno** de los 7
alias existe. Un fichero de configuración no es la red, así que `to_atom`
sobre sus claves es defendible, pero la regla está escrita sin excepción y eso
es una decisión de diseño, no una que se tome de paso.

## 6. Decisiones que siguen abiertas

Del Apéndice E del documento de diseño, sin cambios:

| # | Pregunta | Bloquea | Recomendación |
|---|---|---|---|
| Q1 | ¿Los modelos de `fired/` de ropero entran en el TOML? | F2.4 | no |
| Q3 | ¿Gateway en LAN o sólo loopback? | F8 | loopback; `host` configurable |
| Q4 | ¿JWT en el gateway? | v5 | no en v4 |
| Q6 | ¿Candil en Hex? | F11 | git. Las deps ya van por GitHub |
| Q9 | ¿El context persiste entre reinicios? | F6 | no en v4, es ETS |
| Q10 | ¿Affinity distinta por consumer? | F7 | sí, `[consumer.X] affinity` |

**Q3 es la única que ha cambiado de carácter**: el gateway ya tiene
`Auth` escrito con `api_key` en tiempo constante, así que la pregunta ya
tiene respuesta parcial.
