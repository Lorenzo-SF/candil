# Fase 6 — Context compartido

> Estado: **CERRADA** (2026-10-05). La 4 y la 5 también.
>
> D8, §3.4+D4 y §3.6 cerradas. El criterio de cierre pasa — dos consumidores
> con la misma `session_id` no se ven — y el estado medido es **786 tests +
> 27 doctests, 0 fallos**, con los 8 gates en verde.
>
> Antes de tocar el arranque, lee
> [`2026-10-05-bugs-de-arranque.md`](../auditoria/2026-10-05-bugs-de-arranque.md):
> siete bugs del arranque que ningún smoke vio porque todos miraban exit codes.
> Original: `candil-4.0-final.md` §18 y la Fase 6.
> Effort: 4 d.
>
> **Nivel de razonamiento de la fase: `high` — sube a `max` en §3.1 y §3.4.**
> Razón: el particionado es una propiedad de aislamiento y el `Builder` decide
> entre un error honesto y pérdida de contexto en silencio.

---

## 1. Antes de empezar

- [ ] **La fase 4 está mergeada en `main`.** Si no lo está, **para**: la
      integración necesita `candil run --detach` y el registro de instancias.
- [ ] La base de `main` está actualizada (`git pull --ff-only origin main`).
- [ ] **Anota el número real de tests en `main`** y ponlo en `HANDOFF.md`. Las
      referencias "702" y "687 + 26" de este documento **estaban mal**: la base
      real medida en `main` es **705 + 26 doctests**, 0 fallos, 66.2 % (2026-10-03, `7fc0920`).
      **Mídela otra vez al abrir la rama**: es un hecho de `main`, no una
      constante escrita en este documento.
- [ ] Recuerda `CANDIL_DATA_DIR=<tmp>` para todo test que toque disco.

---

## 2. Qué es y por qué

Hoy `Candil.Conversation` guarda el historial **en el proceso que llama**. Si
posadero y opencode están en la misma VM, cada uno tiene el suyo, y no se puede
compartir, resumir ni mover entre modelos. `ElPaso` lo resolvió con Postgres y
schemas Ecto; aquí es **ETS**.

Una sesión se identifica por `{consumer, session_id}`. El consumer particiona:
el contexto de `opencode` nunca se mezcla con el de `posadero`, **aunque usen el
mismo `session_id`**. Esa es toda la fase, y es más pequeña de lo que parece.

Está en la ruta crítica porque el router de la 7 y la RAG de la 10 leen contexto,
y las dos llegan tarde sin él. La 7 se retiene un día a propósito: un router que
reparte sin contexto reparte bien, y uno que reparte con el contexto equivocado
reparte peor.

---

## 3. Dónde

| Qué | Dónde |
|---|---|
| Módulos | `lib/candil/context.ex` y `lib/candil/context/**` |
| Tests | `test/candil/context*_test.exs` |
| Ya existe | `Context`, `Context.Builder`, `Context.Session`, `Context.Summarizer`, `Context.PrefixManager` — **congelados en la fase −1, con cuerpo** |

**Carril C.** No toques `router.ex`, `gateway.ex`, `mcp.ex` ni `rag.ex`: son las
fases 7, 8, 9 y 10, y pueden estar en marcha a la vez.

---

## 4. Qué hay que hacer

### 3.1 Particionar por consumer · `max`

`create(:posadero, "s1")` y `create(:opencode, "s1")` son **dos sesiones
distintas**.

Es el `max` de la fase porque lo que lo valida es una prueba de integración con
**dos modelos reales**: posadero escribe una API key, opencode pregunta qué sabe
sobre el usuario. Si el segundo la sabe, el particionado está roto aunque los
unitarios pasen.

**La forma de probarlo sin depender de un LLM, que es la que hay que escribir:**

```elixir
test "el mismo session_id bajo distintos consumers no filtra contenido" do
  p = Context.create(:posadero, "s1")
  o = Context.create(:opencode, "s1")

  refute p.id == o.id
  assert p.consumer == :posadero
  assert o.consumer == :opencode

  Context.append(p, [%{role: :user, content: "API_KEY=sk-abc123"}])

  refute Enum.any?(o.messages, &String.contains?(&1.content, "sk-abc123"))
end
```

El último `refute` es el que realmente prueba el aislamiento. Los tres
anteriores solo comprueban que los identificadores son distintos, y un bug de
partición en la tabla ETS los superaría.

### 3.2 TTL · `high`

`gc/0` recoge la sesión vieja. El reloj es **monotónico**; comparar reloj de
pared contra reloj monotónico es un bug que ya se cometió una vez y no recogía
nunca.

### 3.3 LRU · `high`

Con `max_sessions: 2`, la tercera desaloja la más antigua. El desalojo tiene que
funcionar: un `max(0, len - max)` mal colocado nunca desaloja nada.

### 3.4 Builder · `max`

Con `context_size` pequeño: `{:error, :context_exceeded}`, **no una lista
truncada en silencio**. Una lista truncada parece un contexto corto; el error dice
que no cupo.

Es `max` porque es la diferencia entre un error accionable y pérdida de contexto
que parece funcionar. Un consumidor que trunca en silencio no se queja nunca, y
descubrirlo es en producción.

**El `reason` debería duplicar la causa, no solo el síntoma:**

```elixir
@type reason ::
  :context_exceeded
  | {:context_exceeded, :no_room_to_truncate | :budget_exhausted | :no_room_for_system}
```

El plan solo dice `:context_exceeded`. Si el consumidor necesita distinguir por
qué no cupo, el error tiene que poder decirlo sin parsear texto.

### 3.5 Summarizer · `high`

Con el modelo caído, **la sesión queda intacta**. Un resumen fallido que deja la
sesión vacía destruye trabajo del usuario.

### 3.6 El facade · `medium`

`Candil.chat_with_context/4` cableado. Mecánico.

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

> **Si el número de tests baja respecto a la base que anotaste, para.** No es una
> cifra decorativa: si baja, alguien borró cobertura para hacer verde el gate.

---

## 6. Capa 2 — Qué tiene que pasar al ejecutar

```bash
mix test test/candil/context_test.exs test/candil/context_builder_test.exs
```

| Test | Qué tiene que ocurrir | Qué NO puede ocurrir |
|---|---|---|
| aislamiento | dos sesiones distintas, contenidos separados | que el `session_id` solo baste para encontrar una |
| TTL | `gc/0` recoge la sesión vieja, la nueva no | que `gc/0` recoja la nueva por reloj de pared |
| LRU | con `max_sessions: 2` la tercera desaloja la más antigua | que `gc/0` recollection se lleve la que se acaba de crear |
| Builder | `{:error, :context_exceeded}` con `context_size` pequeño | una lista truncada que parece un contexto corto |
| Summarizer | con el modelo caído la sesión queda **intacta** | una sesión vacía o a medio resumir |

---

## 7. Capa 3 — Revisión manual del código

- [ ] ¿La clave de la tabla ETS incluye el `consumer`? Léelo, no lo supongas.
- [ ] ¿El reloj del TTL es `System.monotonic_time/0`? Busca `System.os_time/0` en
      `context/**` y si aparece, es un bug.
- [ ] ¿El LRU desaloja de verdad, o solo calcula un número y no borra?
- [ ] ¿El Builder **devuelve un error** o **avisa por log y sigue**? Un
      `Logger.warning` en vez de un `{:error, ...}` es el fallo silencioso.
- [ ] ¿El `Summarizer` escribe el resultado en la sesión solo **después** de
      tener el resumen completo? Un `append` por chunk deja la sesión a medias si
      falla el segundo.
- [ ] ¿Los mensajes de `:error` llevan el `reason` duplicado o solo el string?

---

## 8. Capa 4 — La prueba funcional

```bash
$ ./candil run verifier --detach
$ mix run -e '
  Candil.chat_with_context(:verifier, "s1",
    [%{role: "user", content: "recuerda: mi API key está en $CANDIL_KEY"}],
    consumer: :posadero)
  Candil.chat_with_context(:coder, "s1",
    [%{role: "user", content: "¿qué sabes de mí?"}],
    consumer: :opencode)
  # el segundo NO debe saber nada del primero'
```

**Ese último bloque es el criterio.** Si el segundo responde sabiendo la API key,
el particionado no funciona aunque todos los tests unitarios pasen.

**Qué NO tiene que ocurrir:**

- ❌ que el segundo consumer mencione `$CANDIL_KEY` de cualquier forma
- ❌ que la sesión de opencode haya crecido al escribir posadero
- ❌ que un `gc/0` entre las dos llamadas vacíe la sesión que acabas de crear

**Y en sandbox, sin modelos:** la parte del LLM no se puede ejecutar. Entonces
**el test unitario del §3.1 es el criterio**, y hay que decirlo en el
`deliverable.md`: "criterio ejecutado: unitario, no integración, porque no hay
GGUF en el sandbox". No digas que has ejecutado la integración si no la has
ejecutado.

---

## 9. Por qué NO

- **No Postgres.** Regla 4 del Apéndice D: ETS siempre. La 6 es sesiones en
  memoria, y `Q9` dice que en v4 no se persisten.
- **No un GenServer de dos responsabilidades.** `Context` ya existe; la fase le
  pone cuerpo, no le añade una responsabilidad.

---

## 10. Definición de done

- [ ] Los cinco casos de `mix test test/candil/context_test.exs test/candil/context_builder_test.exs` en verde
- [ ] El bloque de integración ejecutado **o** su sustituto unitario, declarado
- [ ] Los ocho gates verdes
- [ ] El número de tests no ha bajado de la base real anotada
- [ ] `CHANGELOG.md` con los nombres de función reales
- [ ] `HANDOFF.md` §2 actualizado con números medidos
- [ ] PR contra `main`, CI verde
- [ ] Tag `candil-4.0.0-alpha.4`

---


## 11. Cómo se ejecuta esta fase

**Una sesión principal, secuencial, en `mcode`.** El nivel se cambia **por
sub-tarea** con `/model` (verificado: `/model` cambia modelo **y** effort, y
`/status` muestra el par). El modelo no puede cambiar su propio effort a mitad de
respuesta: el ajuste es **entre turnos**, y por eso la unidad es la sub-tarea.

### El ciclo

```bash
# 1. en main, actualizado
git checkout main && git fetch origin && git pull --ff-only origin main

# 2. rama de la fase  (CON GUION, nunca barra)
git checkout -b f6-context

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    cambiando el nivel con /model en cada frontera

# 4. verificar las 4 capas (abajo)

# 5. publicar
git push -u origin f6-context

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    HANDOFF.md §2 con números MEDIDOS · CHANGELOG.md · el tag
```

Un worktree por sesión, un `_build` por carril.

### El nivel, sub-tarea por sub-tarea

| Sub-tarea | Nivel | Verificación |
|---|---|---|
| 3.1 Particionar por consumer | `max` | L3: aislamiento; L4: opencode no ve la key de posadero |
| 3.2 TTL con reloj monotónico | `high` | L3: `gc/0` recoge la vieja; `grep System.os_time` → 0 |
| 3.3 LRU que desaloja de verdad | `high` | L3: con `max_sessions: 2` la tercera desaloja |
| 3.4 Builder: `context_exceeded`, no truncado | `max` | L3: error con `context_size` pequeño |
| 3.5 Summarizer con el modelo caído | `high` | L3: la sesión queda intacta |
| 3.6 El facade `chat_with_context/4` | `medium` | L3+L4: la integración de los dos consumers |
| D4 Política `:strict`/`:compact`/`:summarize` | `max` | L3: `:summarize` NO degrada a `:strict` |
| D8 `Conversation` → `@deprecated` | `low` | L1+L2: compila; los consumidores externos siguen |
| Revisión de la fase (sesión aparte) | `max` | L4: el segundo consumer NO recuerda nada |

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
