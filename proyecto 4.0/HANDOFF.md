# Candil 4.0 — Estado y traspaso

> **Este es el documento que hay que leer antes de retomar el trabajo.**
>
> `candil-4.0-final.md` dice lo que se decidió y por qué. Este dice lo que
> **está hecho, medido y verificado**, y lo que toca mañana. Cuando se
> contradigan, este tiene razón sobre el presente y aquel sobre el futuro.
>
> **Fecha**: 2026-10-02 · **Rama**: `4.0-f2-build` (base `4.0`) ·
> **Toolchain**: Erlang/OTP 28.5.0.7, Elixir 1.19.5-otp-28 ·
> **Punto de partida**: tag `4.0-contracts-frozen`
>
> **Las fases 0 y 1 están cerradas** (PR #21 y #22, ambos con el CI en
> verde). Este documento se actualizó con lo medido, no con lo previsto.

---

## 1. Dónde está el proyecto

| | |
|---|---|
| Rama de trabajo | `4.0-f2-build` (base `4.0`, con `main` mergeado dentro) |
| `main` | Intacta. No se ha tocado desde el merge. |
| Tag de partida | `4.0-contracts-frozen` |
| Tests | **623 tests + 25 doctests**, 0 fallos |
| Cobertura | **66.8 %** (64.6 % en `main` sin la fase 2) |
| Gates | **8 de 8 en verde** |
| Fases cerradas | −1 contratos · −0 gates · **0 los ocho bugs** · 1 Source y TOML · **2 Build y EnginePool** |

### Ramas y PRs

```
main        28f09ec   fases −1, −0, 0 y 1, mergeados
 4.0-f2-build          PR #18, fase 2, con main mergeado dentro
```

La fase 2 se hizo por delante de la 0 y la 1 en el calendario, no en la
dependencia: `Build.install/2` y el rewrite de `EnginePool` no tocan la
ruta local de inferencia. Al integrar, `EnginePool` aparece en los dos
lados y se queda la versión de la fase 2, que además trae `claim_port/2`.

Lo que sí hubo que reconstruir a mano, porque Git no lo detecta:

- `engine.ex`: hacen falta **las dos** cosas. La fase 2 registró
  `{model.alias, port}` en el `EnginePool`; las fases 0 y 1 añadieron los
  cinco métodos de H1. Auto-mergeó bien, y está comprobado que están los
  diez.
- `config/file.ex`: la fase 1 reescribió el escritor de TOML sobre una
  versión vieja de la función que la fase 2 había tocado. Auto-mergeó, y
  están las dos mitades: el arreglo de `expand/1` y el `save/2` nuevo.

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

### Lo que aún es stub, y en qué fase

Nueve. Todos con contrato escrito, spec y tests. Ninguno lanza: devuelven
`{:error, %Candil.Error{reason: :not_implemented}}`, que cumple su propio
`@spec`. Un stub que hace `raise` es `none()` para dialyzer.

```
Candil.Build.install/2            fase 2
Candil.Gateway.Endpoint.listen/4  fase 8
Candil.MCP.serve/1                fase 9
Candil.MCP.connect/1              fase 9
Candil.RAG.create_index/2         fase 10
Candil.RAG.index/3                fase 10
Candil.RAG.search/3               fase 10
Candil.RAG.drop_index/1           fase 10
Candil.RAG.list_indexes/0         fase 10
```

---

## 3. Lo siguiente

La **fase 0** (los ocho bugs) y la **fase 1** (Source y el TOML) están
hechas, y la **fase 2** está mergeada en esta rama. El grafo del §4 del
PLAN-PARALELO queda así: **−1, −0, 0, 1 y 2 cerradas.** La siguiente es la 3,
la CLI con Alaja, y `PROMPT-FASE-3.md` la trae ya escrita.

Quedan **ocho stubs**, todos de fases posteriores:

```
Candil.Gateway.Endpoint.listen/4  fase 8    Candil.RAG.index/3         fase 10
Candil.MCP.serve/1                fase 9    Candil.RAG.search/3        fase 10
Candil.MCP.connect/1              fase 9    Candil.RAG.create_index/2  fase 10
Candil.RAG.drop_index/1           fase 10   Candil.RAG.list_indexes/0  fase 10
```

Y sigue en pie el aviso de la §5-bis: **no hay carga de TOML a
`Candil.Store`**, y eso es lo que bloquea `candil models list`. La fase 1
escribió el lector y el escritor del TOML, pero no el puente al registro.

Lo que ya no falta: `Source.fetch/2` baja solo con `.part`, reanudación por
`Range` y checksum en streaming; `Source.progress/1` da los bytes para una
barra; y H1 está hecho — los tres call sites de la ruta local usan
`Engine.auth_headers_for/1` y el servidor recibe `--api-key` y `--alias`. Para
hablar con un `llama-server` protegido ya no falta código: falta un binario y
un GGUF.

## 3-quater. B6, cerrado (2026-10-02)

El §1 decía "0 los ocho bugs" y eran siete de ocho. B6 era el que faltaba.
Medido ahora, con los ocho:

```
B1  LlamaCpp.chat/3           ✅ cuerpo
B2  LlamaCpp.chat_stream/3    ✅ cuerpo
B3  OpenAICompat.chat_stream  ✅
B4  OpenAICompat.embed        ✅ una request por texto, no un batch
     borrar build_chunk_stream/1  ✅ borrado
H1  auth en la ruta local      ✅ los tres call sites
B5  api_key string plano      ✅
B6  Detector.safe_arch/0      ✅ avisa; :arch conserva su forma, el motivo viaja en :arch_error
B7  EnginePool sin LRU        ✅
B8  checksum en streaming     ✅ Installer ya hashea por bloques
```

Lo que el diseño pide para B6 es
`Trebejo.OS.arch/0 → {:ok, arch} | {:error, :trebejo_not_available}`, y eso es
justo lo que hace ahora `Detector.safe_arch/0`, que es público para que quien
vaya a descargar pueda preguntar antes. `detect/0` no cambia de forma —sus
llamadas dependen de ella— pero lleva el motivo en `:arch_error` y avisa por
log.

El comentario que había al lado ya lo sabía:

> apply/3 here was only there to silence the compiler and hid the fact that a
> missing Trebejo silently degraded to `:unknown` instead of saying so.

Se quitó el `apply/3`, que era la ofuscación, y se dejó el `:unknown`, que
era el defecto. El síntoma sigue siendo el mismo: la descarga del binario
falla más tarde y sin decir por qué. Es media hora de código.

## 3-quinquies. La estrategia `:precompiled` no puede funcionar en Linux

Esto salió al verificar **contra la API real de GitHub**, no leyendo el código.
El TLS roto del sandbox lo tenía escondido; con un proxy propio que termina
TLS, Candil habla con GitHub de verdad y la respuesta es que la estrategia
`:precompiled` está construida sobre una suposición que no se cumple.

**llama.cpp no publica binarios de Linux en sus releases.** Medido sobre 20
releases, 271 assets `.zip`:

```
linux / ubuntu / debian     0
win                        252
macos / xcframework         19
```

Y `Detector.Models.build_asset_pattern/4` genera para Linux exactamente
`bin-ubuntu-x64`, `bin-linux-cuda-...`, `bin-linux-rocm-...`, `bin-linux-vulkan-...`
— patrones que no casan con nada que exista. Los `.zip` de Linux no se publican
ahí; se reparten por Homebrew y por otros canales.

Encima, `releases/latest` de llama.cpp apunta a `v0.5.0`, que **no trae
binarios**: solo un `nightly-tag.txt`. Los binarios van en tags rodantes
`b11327`, `b11326`, … Así que `version: :latest`, el valor por defecto de
`Build`, nunca resolvió a nada.

### Lo que tapaba todo: el fallback

`find_matching_asset/2` tenía un fallback: si nada casaba, cogía el primer
`.zip` que no fuera sources ni sha256 y lo ofrecía igual. Puesto contra la API
real, en esta máquina (linux x64) devolvía

```
cudart-llama-bin-win-cuda-12.4-x64.zip
```

Un bundle de Windows con CUDA, que **se descarga bien, se descomprime bien y
falla al ejecutarlo**. Y como el fallbackrespondía, el error de `:latest`
quedaba escondido detrás de un binario equivocado.

**Arreglado**: si no hay asset para esta plataforma, se dice. Ahora
`:latest` da `:no_matching_asset` y una plataforma sin publicar da
`{:no_such_platform, "bin-ubuntu-x64"}`. Un binario equivocado es peor que
ninguno.

### Lo que sigue sin resolver, y no es código

Que la estrategia `:precompiled` tenga un sentido en Linux es una **decisión
de diseño**, no un bug. Y la respuesta parece ser que no: para Linux, la ruta
es `:source`, que es exactamente lo que hace ropero con sus flags. El camino
rápido existe para Windows y macOS.

Esto **no bloquea** el merge. Lo que hace es cambiar lo que el §4.1 del prompt
promete: ":precompiled es el camino rápido" solo es cierto donde hay binario
publicado.

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
| El callback del stream devolvía `{:cont, acc}` | `Finch.stream/5` **envuelve** el callback: su retorno *es* el acumulador. La tupla se anidaba en cada chunk |
| Reanudar abría con `[:read, :write]` | El `read_write` de Erlang **trunca** sin `:no_truncate`. Media descarga se pisaba y quedaba un fichero de la mitad del tamaño |
| El writer TOML emitía `## header` | `##` es un comentario. El documento entero hacía round-trip a una tabla plana |
| `Enum.split_with/2` leído al revés | Devuelve `{coincidentes, no_coincidentes}`. Todos los escalares acababan como sub-tablas |

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

**No hay carga de TOML a `Candil.Store`, y la fase 1 no lo arregló.**
Revalidado sobre el árbol ya integrado: `Store.init/1` sigue llamando solo a
`load_from_app_config/0`, que lee `Application.get_env(:candil, Candil.Store)`;
`Store.reload/0` no existe; y **nada en `lib/` llama a `Config.File.load/0`**,
ni siquiera `Candil.Application`. La fase 1 escribió el lector y el escritor
del TOML — `Config.File.load/1` y `save/2` ya no son stubs — pero no el puente
entre el documento y el registro.

Los 7 modelos de `candil.toml` se construyen y validan; eso se comprobó a
mano, construyendo los structs y registrándolos uno a uno. El Store, al
arrancar, sigue vacío.

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
