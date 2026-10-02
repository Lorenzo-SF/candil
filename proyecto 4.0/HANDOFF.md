# Candil 4.0 — Estado y traspaso

> **Este es el documento que hay que leer antes de retomar el trabajo.**
>
> `candil-4.0-final.md` dice lo que se decidió y por qué. Este dice lo que
> **está hecho, medido y verificado**, y lo que toca mañana. Cuando se
> contradigan, este tiene razón sobre el presente y aquel sobre el futuro.
>
> **Fecha**: 2026-10-02 · **Rama**: `4.0` · **Toolchain**: Erlang/OTP 28.5.0.7,
> Elixir 1.19.5-otp-28 · **Punto de partida**: tag `4.0-contracts-frozen`
>
> **Las fases 0 y 1 están cerradas** (PR #21 y #22, ambos con el CI en
> verde). Este documento se actualizó con lo medido, no con lo previsto.

---

## 1. Dónde está el proyecto

| | |
|---|---|
| Rama de trabajo | `4.0` |
| `main` | Intacta, con su CI viejo. No se ha tocado. |
| Tag de partida | `4.0-contracts-frozen` |
| Tests | **549 tests + 24 doctests**, 0 fallos |
| Cobertura | **64.6 %** (era 52.7 % en el tag de partida) |
| Gates | **8 de 8 en verde** |
| PRs abiertos | #21 fase 0 · #22 fase 1 · #18 fase 2 (otra sesión) |

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
hechas. La **fase 2** la lleva otra sesión en el PR #18.

Lo que sigue en este carril, en orden:

- **Conectar el resto de H1.** La ruta local ya manda cabeceras de
  autenticación y el servidor ya recibe `--api-key`. Falta el test de
  aceptación contra un `llama-server` real, que es el que decide si la
  absorción de ropero es viable.
- **Fase 2** si el PR #18 no lo cierra del todo.
- **Fase 3** (CLI) — `PROMPT-FASE-3.md` lo trae la otra sesión.

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
