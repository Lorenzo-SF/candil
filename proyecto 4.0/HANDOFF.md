# Candil 4.0 — Estado y traspaso

> **Este es el documento que hay que leer antes de retomar el trabajo.**
>
> `candil-4.0-final.md` dice lo que se decidió y por qué. Este dice lo que
> **está hecho, medido y verificado**, y lo que toca mañana. Cuando se
> contradigan, este tiene razón sobre el presente y aquel sobre el futuro.
>
> **Fecha**: 2026-10-01 · **Rama**: `4.0` · **Toolchain**: Erlang/OTP 28.5.0.7,
> Elixir 1.19.5-otp-28 · **Punto de partida**: tag `4.0-work-start`

---

## 1. Dónde está el proyecto

| | |
|---|---|
| Rama de trabajo | `4.0` |
| `main` | Intacta, con su CI viejo. No se ha tocado. |
| Tag de partida | `4.0-work-start` |
| Tests | **519**, 0 fallos |
| Cobertura | **63.1 %** (era 52.7 % en el tag) |
| Gates | **8 de 8 en verde** |
| Commits en `4.0` | 12 |

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

### Lo que aún es stub, y es intencionado

Doce funciones, todas con un contrato escrito y un test que lo ejerce:

```
Candil.Source.fetch/2            fase 1     Candil.RAG.index/3            fase 10
Candil.Source.progress/1         fase 1     Candil.RAG.search/3           fase 10
Candil.Build.install/2           fase 2     Candil.RAG.create_index/2     fase 10
Candil.Config.File.save/2        fase 1     Candil.RAG.drop_index/1       fase 10
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
5. **B7** (1 h) — `EnginePool` sin LRU.
6. **B8** (1 h) — checksum en streaming, no `File.read/1` de 17 GB.

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
