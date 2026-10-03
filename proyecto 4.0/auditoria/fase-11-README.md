# Fase 11 — Consumidores, docs y 4.0.0

> Estado: **pendiente**. Depende de todas. Carril H.
> Original: `candil-4.0-final.md` Fase 11.
> Effort: 4 d. **Fin del plan: 57-67 días.**
>
> **Nivel de razonamiento de la fase: `medium` — sube a `max` en §3.1.**
> Razón: borrar 250 líneas de otro repo que existen para sortear un bug, y
> publicarlo.

---

## 1. Antes de empezar

- [ ] **Todas las fases anteriores están mergeadas en `main`.** Esta fase además
      toca repositorios ajenos (posadero, gunter), así que su PR cierra contra
      `main` en Candil y lleva sus propios commits en los otros repos.
- [ ] **El `groups_for_modules` está al día.** Lleva retraso desde la 4 y este
      carril es el único que puede tocar `mix.exs`. Ver §5.
- [ ] Anota el número real de tests y la cobertura real en `main`.
- [ ] `HANDOFF.md` al día. Es el documento que esta fase actualiza por última vez.

---

## 2. Qué es

Cablear los consumidores reales, escribir la documentación de usuario, y
publicar 4.0.0. Hasta aquí Candil es una librería; a partir de aquí lo usan
posadero, gunter y opencode.

Es una fase y no el final porque toca **repositorios ajenos**. 11.1 y 11.2 no se
pueden hacer desde el repo de Candil.

---

## 3. Dónde

| Sub-fase | Dónde | Effort |
|---|---|---|
| 11.1 Posadero | `~/cacafuti/lasaca/posadero` | 1.5 d |
| 11.2 gunter / opencode | `~/bin/gunter` · `opencode.jsonc` | 0.5 d |
| 11.3 Docs | `README.md`, `docs/` en el repo de Candil | 1 d |
| 11.4 Cierre | el repo de Candil | 1 d |

**Carril H. El único que puede tocar `mix.exs`.**

---

## 4. Qué hay que hacer

### 3.1 Posadero — borrar `Posadero.LLM.Ropero` · `max`

Son 250 líneas que existen **solo** para sortear H1, el bug de que Candil no
puede hablar con los servidores de ropero. Se sustituye por
`Candil.Store.get_model/1` + `Candil.embed/3`.

```bash
cd ~/cacafuti/lasaca/posadero
git rm lib/posadero/llm/ropero.ex
mix test                    # 0 failures
grep -r "LLM.Ropero" lib/   # 0
```

**El `grep` a 0 es el criterio.** Si queda una referencia, el borrado no está.

Es `max` por la condición de posibilidad: **si H1 (fase 0) no está arreglado,
esto no se puede hacer**, y posadero se queda con dos clientes de LLM para
siempre. Antes de empezar, verifica que el test de H1 pasa:

```bash
# en el repo de candil, con un llama-server con api-key
Candil.embed(:test, ["hola"])   # → {:ok, [[...], [...]]}, no 401
```

**El riesgo real:** el `mix test` de posadero pasa, pero el RAG deja de funcionar
en silencio porque el camino nuevo no está arrancado. Por eso el criterio no es
solo "0 failures" sino "0 failures **y** el RAG responde".

**Y la nota del Apéndice B:** el plan dice 1.5 d, el Apéndice B dice media hora.
La diferencia es que en los 30 minutos la fase 0 ya está hecha y probada. Si
H1 está en duda, son días, no minutos. Mídelo, no lo asumas.

### 3.2 gunter / opencode · `medium`

Los aliases (`coder`, `analyst`, `verifier`, `designer`, `embed`) ya existen en
Candil con los mismos puertos. Se cambia `ropero <alias> --background` por
`candil run <alias> --detach` en `_shunt-lib.sh`, y el `base_url` de
`opencode.jsonc` al gateway **si se quiere**.

⚠ `ropero <alias> --background` **no sobrevive**: `nohup` no sobrevive en este
entorno. `--detach` sí.

**El `base_url` al gateway es opcional y cambia el comportamiento**: apuntaba
`opencode` a un gateway que enruta, no a un modelo concreto. Decidirlo es tuyo,
y si lo haces, `model: "auto"` tiene que resolver bien para el consumer
`opencode` — que es el `[consumer.opencode]` del TOML.

### 3.3 Docs · `low`

`README.md`, `docs/CONFIG.md` (el TOML comentado), `docs/ENGINES.md` (las dos
estrategias con ejemplos reales de CUDA y Metal), `docs/MIGRATION.md` (copia el
Apéndice A, ajusta rutas, **valida**), `docs/DESIGN.md`, `docs/CONSUMERS.md`
(cómo se aíslan opencode y posadero).

⚠ `MIGRATION.md` no es un copypaste: si no se valida, es una promesa.

**`README.md` tiene que RUN, no parecer plausible.** Es la regla del repo y la
razón por la que el ejemplo del README es un comando copiable.

### 3.4 Cierre · `high` para leer, `low` para correr

```bash
$ mix compile --warnings-as-errors
$ mix test && mix test --cover          # ≥ 70 %
$ mix credo --strict
$ mix dialyzer
$ mix docs                              # 0 warnings
$ mix deps.audit
$ mix deps.unlock --check-unused
$ ./candil doctor                       # 0 errores

$ git tag candil-4.0.0 && git push --tags
```

Correr los comandos es `low`. **Entender por qué la cobertura baja es `high`.**
La cobertura medida va del 66,8 % (fases 0-2) al 64,9 % con la CLI, y el objetivo
es ≥ 70 %. **Ese salto de 5 puntos no está planificado en ninguna parte.** O
está, y hay que localizarlo, o es un objetivo nuevo que hay que dimensionar antes
de prometerlo.

> **No maquilles la cobertura.** Si baja, es información, y la definición de done
> dice ≥ 70 %. Si no llegas, la fase no está cerrada, o el objetivo se revisa
> explícitamente. Lo que no puede es decir "casi 70".

---

## 5. `groups_for_modules`, que le toca a este carril

Lleva retraso desde la 4. Este carril tiene que añadir los módulos que las fases
anteriores dejaron fuera:

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

**Lo que faltaba en el documento y hay que tener claro:** ¿y si la fase 5 no ha
mergeado cuando empieza la 11? `Candil.Doctor` no existe y el `mix.exs` no puede
referenciarlo. **El orden de merge es una dependencia de esta fase**, no una
casualidad.

**Y el dialyzer lo confirma:** un módulo en `groups_for_modules` que no existe da
un fallo de compilación, no un warning silencioso. Si `mix compile` pasa, están
todos.

---

## 6. Capa 1 — Los ocho gates

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

Más, propios de esta fase:

```bash
./candil doctor          # 0 errores
mix test --cover         # ≥ 70 %
```

**Los ocho gates de posadero también**, porque 11.1 los toca:

```bash
cd ~/cacafuti/lasaca/posadero && mix test && mix credo --strict
```

---

## 7. Capa 2 — Qué tiene que pasar al ejecutar

| Qué | Qué tiene que ocurrir | Qué NO puede ocurrir |
|---|---|---|
| `mix test` en Candil | 0 fallos, cobertura ≥ 70 % | un `:skip` para hacer verde |
| `mix test` en posadero | 0 fallos | que el borrado se "salte" el módulo y sus tests |
| `grep -r "LLM.Ropero" lib/` en posadero | **0 resultados** | una referencia en un `.exs` o un `.ex` que no se borró |
| `candil doctor` | **0 errores** | advertencias sin comando de arreglo |
| `mix compile` con `groups_for_modules` | compila | un módulo en la lista que no existe |
| `MIGRATION.md` | el bloque de código **se ejecuta** | que se documente una ruta que no funciona |
| `README.md` | el ejemplo **se ejecuta** | que "parezca plausible" |
| el tag | `candil-4.0.0` publicado | un tag con los gates en rojo |

---

## 8. Capa 3 — Revisión manual del código

- [ ] `grep -rn "LLM.Ropero" ~/cacafuti/lasaca/posadero/` → **0 en todo el
      repo**, no solo en `lib/`. Incluye tests, docs y moduledocs.
- [ ] ¿Queda algún cliente HTTP a mano en posadero que debería ser
      `Candil.embed/3`?
- [ ] ¿`docs/CONSUMERS.md` explica el aislamiento con el ejemplo de la fase 6
      (posadero y opencode con el mismo `session_id`)? Es el único sitio donde se
      documenta, y es la propiedad que más cuesta recuperar después.
- [ ] ¿`docs/MIGRATION.md` tiene el Apéndice A **ajustado a las rutas reales**?
- [ ] ¿`README.md` es el mismo `README.md` que el `mix docs` genera, o el manual?
- [ ] ¿La cobertura del 70 % está justificada en el `deliverable.md`, o es un
      número copiado?
- [ ] `git log --oneline` de posadero: ¿el borrado es un commit propio, o va
      mezclado con otra cosa? Va a ser más fácil de revertir solo.

---

## 9. Capa 4 — La prueba funcional

Las cuatro, en orden, porque cada una depende de la anterior.

### 8.1 El borrado de posadero

```bash
cd ~/cacafuti/lasaca/posadero
git rm lib/posadero/llm/ropero.ex
mix test
grep -r "LLM.Ropero" lib/   # → 0
```

**Lo que tiene que pasar:** los tests en verde y el RAG de posadero respondiendo
igual que antes del borrado.

**Lo que NO:** que los tests pasen porque el RAG tiene su propio mock y el
camino real no se ejercita. **Prueba el RAG de verdad**, no solo `mix test`.

### 8.2 gunter con `--detach`

```bash
candil run coder --detach
# y después, en otra shell:
candil status
```

**Lo que tiene que pasar:** gunter arranca el modelo con `candil run --detach` y
**sobrevive a un reinicio de shell**. Ese es el criterio: cerrar la terminal y
volver.

**Lo que NO:** que funcione en la sesión donde se arrancó y muera al cerrar. Eso
es exactamente lo que pasaba con `ropero --background`.

### 8.3 El `MIGRATION.md`

```bash
# sigue los pasos del documento, en una máquina limpia
```

Cada bloque de código del documento se ejecuta. Si un paso no se puede ejecutar
en el sandbox, **dilo en el documento**: "esto requiere 20 GB de disco y una
GPU" es honesto y útil. Un paso que parece ejecutable y no lo es, es una trampa.

### 8.4 El cierre

```bash
./candil doctor
```

**Lo que tiene que pasar: 0 errores.** En una máquina con los modelos
descargados, el doctor da todo en verde. En un sandbox con 0 modelos, dará
errores legítimos: **eso no es un fallo de la fase, es un criterio que depende
del entorno.** Hay que decirlo explícitamente en el `deliverable.md` en vez de
reportar "0 errores" sin haberlos tenido.

---

## 10. Por qué NO

- **No tocar `Botica.Batteries.LlamaServer` desde Candil.** Está fuera de su
  dominio. Queda anotado en el handoff, no se arregla aquí.
- **No publicar 4.0.0 con el doctor en rojo.** El cierre incluye
  `./candil doctor` con **0 errores**. Si el doctor falla, no hay 4.0.0.
- **No `git push --force` en ningún punto.**

---

## 11. Definición de done

- [ ] `grep -r "LLM.Ropero" lib/` → 0 en posadero, y sus tests en verde
- [ ] **El RAG de posadero responde de verdad**, no solo `mix test`
- [ ] gunter usa `candil run --detach`, y sobrevive a un reinicio de shell
- [ ] Los seis documentos escritos y **MIGRATION validado**
- [ ] `groups_for_modules` al día, y el dialyzer lo confirma
- [ ] Los ocho gates verdes
- [ ] Cobertura **≥ 70 %**, o el objetivo revisado **por escrito**
- [ ] `./candil doctor` con 0 errores, o el criterio del entorno documentado
- [ ] `git tag candil-4.0.0` publicado
- [ ] `HANDOFF.md` dice "4.0.0 publicada", no "4.0.0 pendiente"

---


## 12. El aviso de `HANDOFF.md`

Cuando la 11 cierre, ese fichero pasa de ser un documento vivo a ser un
histórico. **No lo borres**: es lo que explica por qué cada fase es como es.
Actualiza su §2 con el estado real de 4.0.0 y déjalo ahí.


## 13. Cómo se ejecuta esta fase

**Una sesión principal, secuencial, en `mcode`.** El nivel se cambia **por
sub-tarea** con `/model` (verificado: `/model` cambia modelo **y** effort, y
`/status` muestra el par). El modelo no puede cambiar su propio effort a mitad de
respuesta: el ajuste es **entre turnos**, y por eso la unidad es la sub-tarea.

### El ciclo

```bash
# 1. en main, actualizado
git checkout main && git fetch origin && git pull --ff-only origin main

# 2. rama de la fase  (CON GUION, nunca barra)
git checkout -b f11-cierre

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    cambiando el nivel con /model en cada frontera

# 4. verificar las 4 capas (abajo)

# 5. publicar
git push -u origin f11-cierre

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    HANDOFF.md §2 con números MEDIDOS · CHANGELOG.md · el tag
```

Un worktree por sesión, un `_build` por carril.

### El nivel, sub-tarea por sub-tarea

| Sub-tarea | Nivel | Verificación |
|---|---|---|
| 3.1 Cablear posadero y borrar `LLM.Ropero` | `max` | L4: `grep` a 0 y **el RAG responde** |
| 3.2 gunter con `candil run --detach` | `medium` | L4: sobrevive a reiniciar la shell |
| 3.3 Los seis documentos | `low` | L4: el README y el MIGRATION **se ejecutan** |
| 3.4 Cierre: gates + doctor + tag | `low correr / high leer` | L4: `doctor` 0 errores; cobertura ≥70% o revisado |
| D10 Issue en botica | `low` | Una issue abierta, con fecha y enlace a C11 |
| Revisión final (sesión aparte) | `max` | Todo lo anterior, mirando sin el diff |

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
