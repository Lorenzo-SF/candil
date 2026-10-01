# Baseline de calidad — tag `4.0-work-start` (cerrado)

> Medición real, ejecutada sobre el código tal cual estaba en el tag, con la
> toolchain que fija `.tool-versions`. No es una estimación: son salidas de
> comandos.
>
> **Estado**: cerrado. Los 8 gates están en verde tras la fase -0.
>
> **Fecha**: 2026-10-01 · **Rama**: `4.0` · **Toolchain**: OTP 28.5.0.7 /
> Elixir 1.19.5-otp-28

## Antes y después

| Gate | En `4.0-work-start` | Ahora |
|---|---|---|
| `mix format --check-formatted` | FAIL | **OK** |
| `mix deps.unlock --check-unused` | OK | OK |
| `mix compile --warnings-as-errors` | OK | OK |
| `mix credo --strict --format=oneline` | FAIL, 37 issues | **OK, 0** |
| `mix test` | FAIL, 22 fallos | **OK, 279/0** |
| `mix dialyzer` | OK (a medias) | **OK, 0** |
| `mix docs --warnings-as-errors` | FAIL, 54 warnings | **OK, 0** |
| `mix hex.audit` | OK | OK |

Cobertura: 52.7 % → **54.2 %**. 279 tests, 0 fallos, estable en 10 ejecuciones
seguidas (no hay carrera pese al `async: true` con tablas ETS compartidas).

## Resultado

| Gate | Comando | Resultado |
|---|---|---|
| Deps | `mix deps.get` | ✅ las 5 deps de GitHub resuelven |
| Compilación | `mix compile --force --warnings-as-errors` | ✅ 0 warnings en candil |
| Formato | `mix format --check-formatted` | ❌ exit 1 |
| Lint | `mix credo --strict --format=oneline` | ❌ 37 issues |
| Tests | `mix test --cover` | ❌ 279 tests, 22 fallos · cobertura **52.7 %** |
| Tipos | `mix dialyzer` | ✅ 0 errores |
| Docs | `mix docs --warnings-as-errors` | ❌ warnings |
| Seguridad | `mix hex.audit` | ✅ sin avisos |
| Deps sin usar | `mix deps.unlock --check-unused` | ✅ limpio |

Cobertura: **52.7 %** (585 modulos/funciones revisados). Los módulos con 0 %
son `candil.ex`, `config_manager.ex`, `engine/launcher.ex`, `engine/server.ex`,
`health.ex`, `inference/chat.ex` e `inference/embeddings.ex` — es decir,
justamente la ruta local que H1 tiene que arreglar, que hoy nadie prueba.

## Los 22 fallos de test son dos ficheros

No son 22 problemas. Son **un** problema repetido, el B9 del documento de
diseño:

| Fichero | Causa | Tests afectados |
|---|---|---|
| `test/candil/config_test.exs:9` | `:ets.delete_all_objects(:apero_llm_engines, :undefined)` — nombre de tabla obsoleto **y** aridad inexistente | 21 |
| `test/candil/engine_test.exs` | espera `~/.apero/llm/bin`; el código devuelve `~/.candil/llm/bin` | 1 |

**En ambos casos el código tiene razón y el test está obsoleto.** Corregir el
código para satisfacerlos reintroduciría el bug.

## Los 37 issues de credo

| Categoría | Cantidad | Naturaleza |
|---|---|---|
| Falta `\n` final | ~24 | Mecánico, lo resuelve `mix format` |
| Módulos anidados sin alias | 6 | Estilo |
| `apply/2,3` con aridad conocida | 1 | `detector.ex:67` |
| `with` de una sola rama | 1 | `structured.ex:57` |
| Línea > 120 caracteres | 3 | Mecánico |
| Complejidad ciclomática > 9 | 2 | `agent.ex:112` (10), `tools.ex:145` (10) — requieren refactor real |

Es la deuda por la que el CI tenía credo comentado desde hacía tiempo. Son
~24 issues mecánicos y **3 que necesitan decisión de código**.

## Por qué el umbral de cobertura es 50 y no 70

El 70 % del documento de diseño es el objetivo de **fin de 4.0**. El número
real de hoy es 52.7 %. Poner el gate en 70 desde el primer día produce un CI
rojo que no dice nada útil; ponerlo en el valor real y forbidding que baje
sí dice algo.

## Lecciones del propio montaje

Tres cosas que costaron tiempo aquí y que conviene no repetir:

**1. `mix hex.audit` existe; `mix deps.audit` no.** El segundo da
`could not find the task`. Escrito de memoria en el CI, fallaba en el primer
run.

**2. `minimum_coverage` de excoveralls no hace lo que parece.** Solo se
comprueba en `mix coveralls.html` y `mix coveralls.cobertura`
(`ExCoveralls.Stats.ensure_minimum_coverage` se llama desde `html.ex:19` y
`cobertura.ex:21`). En un `mix test --cover` normal no se comprueba nunca.
Ponerlo en `test_coverage` habría dado un gate que pasa siempre.

**3. `mix credo --format=github` no emite anotaciones.** En credo 1.7.12 cae
silenciosamente al formato por defecto y no produce ningún `::warning`. El
diff no se anota. Por eso el CI usa `oneline`.

## Cómo reproducirlo

```bash
# toolchain
asdf install erlang 28.5.0.7
asdf install elixir 1.19.5-otp-28

# deps
mix deps.get

# los cinco gates, en orden de coste ascendente
mix format --check-formatted
mix compile --force --warnings-as-errors
mix credo --strict --format=oneline
mix test --cover
mix dialyzer
mix docs --warnings-as-errors
```
