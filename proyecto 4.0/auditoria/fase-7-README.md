# Fase 7 — Router

> Estado: **pendiente**. Depende de la 6. Carril D.
> Original: `candil-4.0-final.md` §19 y la Fase 7.
> Effort: 6 d.
>
> **Nivel de razonamiento de la fase: `max`.**
> Razón: es la única fase donde el freeze de contratos congeló la **API** pero no
> el **comportamiento**. Hay que decidir cómo se degradan las capas entre sí, y
> esa decisión no está escrita en ningún sitio.

---

## 1. Antes de empezar

- [ ] **La fase 6 está mergeada en `main`.** Sin contexto, el router reparte bien;
      con el contexto equivocado, reparte peor. Si la 6 no está, **para**.
- [ ] **Anota el número real de tests en `main`** en `HANDOFF.md`. Las
      referencias "702" y "687 + 26" de aquí **estaban mal**: la base real
      medida es **705 + 26 doctests**, 0 fallos, 66.2 % (2026-10-03, `7fc0920`).
      Mídela al abrir la rama; este número envejece como los otros.

---

## 2. Qué es

Las cuatro capas de la §19.2, con el motor arrancado si hace falta. El router
decide **qué modelo responde** a una petición: no es un balanceador, es una
decisión con criterio y razones.

Está en la ruta crítica porque es lo que hace que `model: "auto"` signifique
algo. Sin él, el gateway de la 8 no puede enrutar.

---

## 3. Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/router.ex` y `lib/candil/router/**` |
| Tests | `test/candil/router*_test.exs` |
| Ya existe | `Router`, `Router.Cache`, `Router.Consumer`, `Router.DecisionEngine`, `Router.Scorer` — congelados en la −1, con cuerpo |

**Carril D.** No toques `context/**`, `gateway/**`, `mcp/**` ni `rag/**`.

---

## 4. Qué hay que hacer

### 3.1 `pin/2` · `max`

Un modelo fijado **gana a cualquier regla**. La precedencia es explícita: se
comprueba antes de que corra nada más, incluso antes de la capa de reglas.

### 3.2 Reglas · `high`

Patrones sobre la entrada, `score` por modelo. Es la única capa cuyo output es
determinista sin modelo, y por eso es la que corre siempre.

**Por qué `high` y no `max`:** el criterio de puntuación está en el plan
(`rule, score 0.80`), pero los patrones concretos y sus pesos no están escritos.
Hay que inventarlos, y eso es diseño.

### 3.3 Embeddings · `max`

Similitud con la descripción del modelo. **No corre sin un modelo de
embeddings**: si no lo hay, la capa se salta, no falla.

La decisión que no está escrita: qué pasa con el score cuando la capa se salta.
¿Los otros modelos heredan el score? ¿se renormalizan? ¿la decisión sale marcada
con menos confianza? Eso cambia el comportamiento observable y hay que
decidirlo explícitamente, no dejarlo en un `Enum.reduce` que se come un `nil`.

### 3.4 Clasificador LLM · `max`

Una llamada a un modelo pequeño. **Opt-in**: `enable_llm_classifier: false` por
defecto. Una petición en la ruta caliente no puede depender de otra llamada a un
LLM por defecto.

La decisión que falta: si está activo y el modelo está caído, ¿el router sigue
con las capas anteriores o falla? Sin respuesta, lo natural es que reviente, y
eso es lo que no debe pasar.

### 3.5 `Router.Cache` por consumidor · `max`

La clave de caché **incluye el consumer**: la entry que ruteara primero decidía
por todos. Ese bug ya se cometió una vez.

`max` porque la clave de caché es donde un error es invisible: el router
"funciona", devuelve decisiones rápidas, y son las decisiones de otro.

---

## 5. Capa 1 — Los ocho gates

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

Todos en verde. **La base se mira en `main` al abrir la rama.** Si el número de
tests baja, **para**.

---

## 6. Capa 2 — Qué tiene que pasar al ejecutar

```bash
mix test test/candil/router_test.exs
```

| Test | Qué tiene que ocurrir | Qué NO puede ocurrir |
|---|---|---|
| property | misma entrada + misma caché → misma decisión, **siempre** | que sea un ejemplo con nombre de test |
| `pin/2` | gana a las reglas, siempre | que una regla con score 1.0 gane a un `pin` |
| sin candidatos | `{:error, :no_models_for_consumer}` | un `nil` o una lista vacía |
| capa 2 sin embedder | **se salta**, el router decide con las demás | que devuelva `:no_embedder` o que tumbe la decisión |
| capa 3 desactivada | **no corre**, misma decisión que sin ella | que se llame al LLM con `enable_llm_classifier: false` |
| caché con 2 consumers | decisiones **distintas** para la misma entrada en consumers distintos | que el segundo reciba la decisión cacheada del primero |

**El caso de la caché con dos consumers es el que más se cuela**, porque es un
bug ya vivido. El test tiene que ser explícito sobre ello, no incidental.

---

## 7. Capa 3 — Revisión manual del código

- [ ] ¿`enable_llm_classifier` está en `false` **por defecto**? Un `true` mete un
      LLM en la ruta caliente.
- [ ] ¿La clave de `Router.Cache` incluye el `consumer`? Léelo, no lo supongas.
- [ ] ¿`pin/2` se comprueba **antes** de la capa de reglas?
- [ ] ¿La capa de embeddings devuelve un skip explícito, o un `nil` que se
      propaga y se pierde en un `Enum.reduce`?
- [ ] ¿El property test genera entradas variadas? Con una sola entrada es un
      ejemplo disfrazado.
- [ ] ¿El router es un balanceador de carga por accidente? Elige por **qué modelo
      toca**, no por cuál está menos ocupado.
- [ ] `grep -rn "classif" lib/` y mira en qué ramas aparece. Cualquier llamada en
      un camino por defecto es un bug de latencia.

---

## 8. Capa 4 — La prueba funcional

```bash
$ ./candil router test "refactoriza este módulo de Elixir"
→ coder (rule, score 0.80)
  alternativas: verifier 0.20, gpt4o 0.00

$ ./candil router test "explícame por qué esto es O(n log n)"
→ verifier (rule, score 0.60)

$ ./candil router stats
consumer    model      calls   p50      p95      errors
opencode    coder      128     820ms    3.1s     2
posadero    embed      47      12ms     40ms     0
```

**Qué tiene que ocurrir:**

- `router test` imprime **modelo, score y alternativas**. Los tres. Un score sin
  alternativas no permite entender la decisión.
- `router stats` imprime **p50, p95 y errores**. Sin p95 el router no se puede
  operar.
- La misma entrada dos veces seguidas da la misma salida.

**Qué NO tiene que ocurrir:**

- ❌ que tarde más de un segundo en la ruta caliente: con reglas y caché es `low`
- ❌ que el clasificador LLM se active sin `enable_llm_classifier: true`
- ❌ que `router stats` esté vacío después de `router test`: si `test` no cuenta
  la llamada, `stats` miente
- ❌ que el resultado dependa del orden en que se registran los modelos

**La prueba de los dos consumers, que no estaba en el documento y es la
importante:**

```bash
./candil router test "qué sabes de mi API key" --consumer posadero
./candil router test "qué sabes de mi API key" --consumer opencode
```

Si salen **idénticos byte a byte** y uno debería tener contexto distinto, tienes
el bug de la fase 6 detrás.

---

## 9. Por qué NO

- **No un LLM que decida siempre.** Por defecto son reglas y caché. Un LLM en la
  ruta caliente multiplica la latencia y el coste por una decisión que cuatro
  patrones resuelven.
- **No balanceo de carga.** Son preguntas distintas.

---

## 10. Lo que NO vas a hacer

- No toques `context/**`, `gateway/**`, `mcp/**`, `rag/**`.
- No toques ficheros del carril A: `model.ex`, `engine.ex`, `engine_pool.ex`,
  `build.ex`, `source.ex`, `store.ex`, `config/**`, `inference/**`, `engine/**`.
- No toques `mix.exs`. `groups_for_modules` se pide en el PR y lo aplica el carril H.
- No pongas `enable_llm_classifier: true` por defecto.
- No uses `String.to_atom/1` con nada que venga de fuera.
- No hagas `git push --force`.

---

## 11. Definición de done

- [ ] Los cinco casos de `mix test test/candil/router_test.exs` en verde
- [ ] `./candil router test` imprime modelo, score **y alternativas**
- [ ] `./candil router stats` imprime p50, p95 y errores
- [ ] El property test corre de verdad, no es un ejemplo con nombre de test
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de la base real anotada
- [ ] `CHANGELOG.md` y `HANDOFF.md` al día
- [ ] PR contra `main`, CI verde
- [ ] Tag `candil-4.0.0-beta.1`

---


## 12. Cómo se ejecuta esta fase

**Una sesión principal, secuencial, en `mcode`.** El nivel se cambia **por
sub-tarea** con `/model` (verificado: `/model` cambia modelo **y** effort, y
`/status` muestra el par). El modelo no puede cambiar su propio effort a mitad de
respuesta: el ajuste es **entre turnos**, y por eso la unidad es la sub-tarea.

### El ciclo

```bash
# 1. en main, actualizado
git checkout main && git fetch origin && git pull --ff-only origin main

# 2. rama de la fase  (CON GUION, nunca barra)
git checkout -b f7-router

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    cambiando el nivel con /model en cada frontera

# 4. verificar las 4 capas (abajo)

# 5. publicar
git push -u origin f7-router

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    HANDOFF.md §2 con números MEDIDOS · CHANGELOG.md · el tag
```

Un worktree por sesión, un `_build` por carril.

### El nivel, sub-tarea por sub-tarea

| Sub-tarea | Nivel | Verificación |
|---|---|---|
| 3.1 `pin/2` gana a las reglas | `max` | L3: un pin gana a una regla de score 1.0 |
| 3.2 Capa de reglas | `high` | L3: property test, misma entrada → misma decisión |
| 3.3 Capa de embeddings (se salta si no hay) | `max` | L3: sin embedder se salta, no falla |
| 3.4 Clasificador LLM opt-in | `max` | L3: `enable_llm_classifier: false` → no llama al LLM |
| 3.5 `Router.Cache` con el consumer en la clave | `max` | L3: 2 consumers, 2 decisiones distintas |
| D1 `quality_class` en `Model` + afinidad | `high` | L3: añadir un modelo NO toca el router |
| D6 Señal de acierto (`pin` + outcome) | `medium` | L4: `router stats` gana la columna `correct` |
| Revisión de la fase (sesión aparte) | `max` | L4: `router test` y `router stats` con la salida del diseño |

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
