# Fase 11 — Consumidores, docs y 4.0.0

> **Para probar esta fase**: [`../PRUEBAS-MANUALES.md`](../PRUEBAS-MANUALES.md) — comandos, comportamiento esperado y el script `scripts/manual-check.sh`.

> Estado: **pendiente**. Depende de todas. Carril H.
> Original: `../original/candil-4.0-final.md`, Fase 11 (~línea 2730).
> Effort: 4 d. **Fin del plan: 57-67 días.**

## Qué es

Cablear los consumidores reales, escribir la documentación de usuario, y
publicar 4.0.0. Hasta aquí Candil es una librería; a partir de aquí lo usan
posadero, gunter y opencode.

## Por qué es una fase y no el final

Porque toca **repositorios ajenos**. 11.1 y 11.2 no se pueden hacer desde el
repo de Candil, y por eso es la única fase que no se cierra con un PR a `4.0`.

## Dónde

| Sub-fase               | Dónde                                     | Effort |
| ---------------------- | ----------------------------------------- | ------ |
| 11.1 Posadero          | `~/workspace/github/lasaca/posadero`      | 1.5 d  |
| 11.2 gunter / opencode | `~/bin/gunter` · `opencode.jsonc`         | 0.5 d  |
| 11.3 Docs              | `README.md`, `docs/` en el repo de Candil | 1 d    |
| 11.4 Cierre            | el repo de Candil                         | 1 d    |

**Carril H. El único que puede tocar `mix.exs`.**

## Qué hay que hacer

### 11.1 — Posadero

`Posadero.LLM.Ropero` **se puede borrar**: son 250 líneas que existen solo
para sortear H1. Se sustituye por `Candil.Store.get_model/1` +
`Candil.embed/3`.

```bash
cd ~/workspace/github/lasaca/posadero
git rm lib/posadero/llm/ropero.ex
mix test                    # 0 failures
grep -r "LLM.Ropero" lib/   # 0
```

El `grep` a 0 es el criterio. Si queda una referencia, el borrado no está.

### 11.2 — gunter / opencode

Los aliases (`coder`, `analyst`, `verifier`, `designer`, `embed`) ya existen en
Candil con los mismos puertos. Se cambia `ropero <alias> --background` por
`candil run <alias> --detach` en `_shunt-lib.sh`, y el `base_url` de
`opencode.jsonc` al gateway si se quiere.

⚠ `ropero <alias> --background` **no sobrevive**: `nohup` no sobrevive en
este entorno. `--detach` sí.

### 11.3 — Docs

`README.md`, `docs/CONFIG.md` (el TOML comentado), `docs/ENGINES.md` (las dos
estrategias con ejemplos reales de CUDA y Metal), `docs/MIGRATION.md` (copia el
Apéndice A, ajusta rutas, **valida**), `docs/DESIGN.md`, `docs/CONSUMERS.md`
(c cómo se aíslan opencode y posadero).

⚠ `MIGRATION.md` no es un copypaste: si no se valida, es una promesa.

### 11.4 — Cierre

```bash
$ mix compile --warnings-as-errors
$ mix test && mix test --cover          # ≥ 70%
$ mix credo --strict
$ mix dialyzer
$ mix docs                              # 0 warnings
$ mix hex.audit
$ mix deps.unlock --check-unused
$ ./candil doctor                       # 0 errores

$ git tag candil-4.0.0 && git push --tags
```

## `groups_for_modules`, que le toca a este carril

Lleva retraso desde la 4 y sigue pendiente. Este carril tiene que añadir los
módulos que las fases anteriores dejaron fuera:

```elixir
# H tiene que añadir, como mínimo
Candil.Doctor, Candil.CLI.Doctor        # fase 5
Candil.CLI, Candil.CLI.Models            # fase 3
Candil.CLI.Run, Candil.CLI.Stop,
Candil.CLI.Status                        # fase 4
Candil.Instances, Candil.Engine.Launcher.Http
Candil.Config.Hydrate, Candil.Source     # fases 3 y 4
Candil.Context, Candil.Router, Candil.Gateway, Candil.MCP, Candil.RAG
```

## Por qué NO

- **No tocar `Botica.Batteries.LlamaServer` desde Candil.** Está fuera de su
  dominio. Queda anotado en el handoff, no se arregla aquí.
- **No publicar 4.0.0 con el doctor en rojo.** El cierre incluye
  `./candil doctor` con **0 errores**. Si el doctor falla, no hay 4.0.0.
- **No `git push --force` en ningún punto.**

## Definición de done

- [ ] `grep -r "LLM.Ropero" lib/` → 0 en posadero, y sus tests en verde
- [ ] gunter usa `candil run --detach`, y sobrevive a un reinicio de shell
- [ ] Los seis documentos escritos y **MIGRATION validado**
- [ ] `groups_for_modules` al día, y el dialyzer lo confirma
- [ ] Los ocho gates verdes
- [ ] Cobertura **≥ 70%**
- [ ] `./candil doctor` con 0 errores
- [ ] `git tag candil-4.0.0` publicado
- [ ] `HANDOFF.md` dice "4.0.0 publicada", no "4.0.0 pendiente"

## La rama

```
git fetch origin
# antes: sincroniza, para que 4.0 no se vaya atrasando de main
# git checkout 4.0 && git merge origin/main && git push origin 4.0
git checkout -b 4.0-f11-cierre origin/4.0
```

## El aviso de `HANDOFF.md`

Cuando la 11 cierre, ese fichero pasa de ser un documento vivo a ser un
histórico. **No lo borres**: es lo que explica por qué cada fase es como es.
Actualiza su §2 con el estado real de 4.0.0 y déjalo ahí.
