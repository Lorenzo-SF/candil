# Candil 4.0 — cómo se ejecuta

> Modo: **una sesión principal, secuencial, en `mcode`**, una fase por fase.
> El nivel de razonamiento se ajusta por sub-tarea. Cada fase se cierra con
> rama → push → merge a `main` → ciclo cerrado.
>
> Fecha: 2026-10-03 · Complementa a las 8 fases de `fase-*-README.md`

---

## 1. El mecanismo, verificado

Contra la documentación de MiniMax Code (`agent.minimax.io/docs/cli/`), hoy:

| Cosa | ¿Se puede? | Cómo |
|---|---|---|
| Cambiar el effort **dentro de una sesión interactiva** | ✅ | `/model` cambia modelo **y** nivel de effort. La status line tiene el item `model-with-reasoning` |
| Ver el par modelo + effort activo | ✅ | `/status` |
| Effort para **una** ejecución, sin guardarlo | ✅ | `mcode exec --effort high "..."` (desde 0.4.9) — **run-only, no se guarda en la sesión** |
| Effort al reanudar con `--continue` | ⚠️ | Sin `--effort`, se usa el nivel original de la sesión |
| Que el modelo **cambie su propio** effort a mitad de respuesta | ❌ | El effort es un parámetro de la petición. Lo elige quien la envía |

**La última fila es la que define todo lo demás.** El auto-ajuste no puede ser
dentro de una respuesta: es **entre turnos**. Por eso la unidad de trabajo no es la
respuesta, es la **sub-tarea con su nivel declarado**.

En la TUI, el ciclo por sub-tarea es:

```
/model  →  elige modelo + nivel para esta sub-tarea
         ↓
      implementa + verifica  (un turno)
         ↓
      /model  →  cambia al nivel de la siguiente sub-tarea
```

Y en headless, lo mismo sin TUI:

```bash
mcode exec --effort medium "B-04: añade policy de contexto strict/compact/summarize ..."
mcode exec --effort high   "B-05: revisa B-04 y verifica que :summarize no degrada a :strict"
```

**No dejes el effort sin fijar.** Omitirlo = `max`, que es el nivel más caro, y en
un plan de 40 días eso se nota. Y `none` no existe: devuelve 400.

---

## 2. Dónde va el presupuesto de razonamiento

**La regla que cambia respecto a planear por fase:**

> En una sub-tarea de media hora, `max` **no produce más trabajo: produce menos**.
> No hay tiempo para pensar, escribir y verificar. El nivel alto se gasta en el
> trabajo, no en la cabeza.

| Nivel | Cuándo | Ejemplo en Candil |
|---|---|---|
| `low` | El texto está escrito en otro sitio y hay que transcribirlo o ejecutarlo | un mensaje literal del doctor · un test de algo que ya existe · corregir el `arrea` del moduledoc |
| `medium` | Una función con spec clara, o un test de comportamiento existente | implementar `candil models pull` · el check de `sources` |
| `high` | Una decisión con dos respuestas válidas y una está escrita | el orden de los `--cpu` al final · qué check entra en `--fix` |
| `xhigh` | Hay que leer 4+ ficheros para decidir | el `Normalizer` de ElPaso · el chunker |
| `max` | **Revisión**, o decisión que **no** está escrita | revisar un PR · elegir entre las dos versiones de la F10 |

**Tres reglas duras:**

1. **Una sub-tarea `max` de implementación no cabe en media hora.** Si crees que
   necesita `max`, no es una sub-tarea: es una fase. Divídela.
2. **Si la decisión no está escrita en el documento de diseño, PARA y pregunta.**
   No la tomes tú. El documento dice que todas las decisiones están escritas: si
   ninguna encaja, eso es información que necesita el dueño, no una decisión tuya.
3. **El presupuesto alto va a la verificación, no a la implementación.** Escribir
   código con un contrato congelado es `low`. Comprobar que hace lo que dice y que
   no hace lo que no debe, es `max`.

**Y el revisor siempre a `max`**, sin excepciones, en sesión aparte, leyendo el PR
**sin el diff del autor**. Es la única tarea del plan donde el nivel base es el
máximo, porque es la única donde el agente no puede estar calibrado por haber
escrito el módulo.

---

## 3. El ciclo, idéntico en todas las fases

```bash
# 1. en main, actualizado
git checkout main
git fetch origin
git pull --ff-only origin main

# 2. rama de la fase  (CON GUION, ver más abajo)
git checkout -b <rama>

# 3. implementar la fase COMPLETA, sub-tarea por sub-tarea,
#    ajustando el nivel con /model en cada una

# 4. verificar (las 4 capas de §4)

# 5. publicar
git push -u origin <rama>

# 6. PR contra main. MIRA EL CI antes de pedir el merge.

# 7. merge a main y cerrar el ciclo:
#    - HANDOFF.md §2 con números MEDIDOS
#    - CHANGELOG.md con los nombres de función reales
#    - el tag de la fase
```

⚠ **La rama lleva guion, nunca barra.** `refs/heads/main` y
`refs/heads/main/f5-doctor` no pueden coexistir: Git no admite un ref y un
directorio en el mismo sitio. Es `f5-doctor`, no `main/f5-doctor`.

⚠ **Un worktree por sesión y un `_build` por carril.** Los ficheros de config de
varios carriles se pisan si comparten worktree.

⚠ **El merge a `main` tiene una consecuencia mecánica que decides tú:** `main` tiene
branch protection con 1 approving review, y el PAT es admin. O el merge espera a
una revisión humana, o lo hace el PAT saltándose la única protección que queda. No
es una opinión: es qué pasa con el siguiente. Decide antes del primer merge, no en
el cuarto.

---

## 4. Las 4 capas de verificación

Ninguna sub-tarea está terminada sin **L1 + L3**. Las cuatro, con lo que exige cada
una:

### L1 · Estático — obligatorio siempre

```bash
mix format --check-formatted
mix compile --force --warnings-as-errors
```

Cero warnings. Un warning de compilador es un fallo, no una nota.

### L2 · Análisis — obligatorio si toca código compartido

```bash
mix credo --strict --format=oneline
mix dialyzer
```

Si aparece `unknown_function` de una app hermana, **mira el PLT antes que tu
código**. Ya mordió una vez.

Y: un stub que hace `raise` es `none()` para dialyzer. Si escribes uno, devuelve
`{:error, %Candil.Error{reason: :not_implemented}}`, que cumple su `@spec`.

### L3 · Test — obligatorio siempre, con caso nombrado

```bash
CANDIL_DATA_DIR=$(mktemp -d) mix test test/candil/<ruta>/
```

Cada sub-tarea nombra **qué caso nuevo** añade y **qué caso existente sigue
verde. Un test que no se nombra no se ejecuta y no cuenta.

`CANDIL_DATA_DIR` es obligatorio: sin él escribes en el `~/.candil` de verdad, y un
test que hace eso no se ejecuta dos veces.

### L4 · Funcional — obligatorio si es visible para el usuario

Un comando con **salida observable**, y dos cosas escritas: **qué tiene que
ocurrir** y **qué NO puede ocurrir**.

> La aserción negativa es la que importa. Un criterio que solo dice "responde"
> pasa con un `[]` de respuesta. Un criterio que dice "responde **y no devuelve
> `[]` sin explicación**" detecta el fallo que de verdad pasa.

---

## 5. El entregable de cada fase

Un `deliverable.md` con:

- Los ocho gates, **con su salida real pegada**
- El criterio de aceptación, **con su salida real pegada**
- El número de tests **antes y después**
- La cobertura antes y después, **con el motivo si baja**
- Los ficheros tocados
- El hash del commit y la URL del PR

**Y una regla que no es negociable:**

> Si un criterio **no se ejecutó** porque el entorno no lo permite, **dilo**.
> Escribe: *"criterio ejecutado: unitario, no integración, porque no hay GGUF en el
> sandbox"*.

Un `deliverable.md` que dice "criterio ejecutado" cuando se ejecutó la mitad es una
mentira, y la siguiente sesión la va a dar por buena.

Si la cobertura baja más de un punto, **no lo maquilles**: es información.

---

## 6. Si se bloqueas

**PARA.** No improvises una decisión de diseño: están todas escritas.

Escribe en el `deliverable.md`, y sigue con la siguiente sub-tarea que no dependa de
eso:

```markdown
## Bloqueo

**Tarea**: B-07
**Qué**: no encuentro cómo el diseño resuelve X.
**He comprobado**: §18, FASE 6, HANDOFF §3, y el código de Context.Builder.
**Opciones que veo**: (a) ...  (b) ...
**Por qué no decido**: las dos son válidas y el documento no dice.
**Necesito**: una línea.
```

Un bloqueo escrito es 30 segundos. Un agente que decide por su cuenta y sigue
adelante son tres días de trabajo perdido.

---

## 7. El orden, si es una sola sesión

**Riesgo primero.** El riesgo del plan está en F6, F7, F9 y F10: aislamiento de
contexto, decisión de modelo, protocolo, retrieval. F3 y F4 son lo más seguro que
vas a tener.

```
F5 (a medias, 1 d) → F6 (4 d) → F7 (6 d) → F8 (5 d) → F9 (4 d) → F10 (5 d)
                                                                        ↓
                                        F3 (6 d) → F4 (4 d) ─────────→ F11
```

Razón: **llegar a la F7 —la única fase con `max` de base y decisiones sin
escribir— en el día 23 de 41 es llegar tarde.** Con el orden viejo no queda
calendario para reaccionar a un bloqueo en la parte que más lo necesita.

**Con las enmiendas v4.1 dentro**, cada fase lleva además su propio extra:

| Fase | Enmienda | Qué añade |
|---|---|---|
| 2 *(ya cerrada)* | **D3, D7** | el `launcher` solo en el engine · la paridad con ropero como test |
| 5 | **D9** | el primer check nuevo, y es la piloto de los smoke tests |
| 6 | **D4, D8, D9** | política de desbordamiento · `Conversation` → deprecated · check de context |
| 7 | **D1, D6, D9** | `quality_class` · señal de acierto · check de router |
| 8 | **D5, D9** | `reasoning_effort` en el gateway · check de gateway |
| 9 | **D9** | check de la revisión del protocolo |
| 10 | **D9** | check de RAG |
| 11 | **D7, D10** | paridad como criterio de cierre · la issue de botica |

⚠ **F9 y F10 arrancan con la puerta de decisiones cerrada.** La revisión del
protocolo (A1) y el diseño del RAG (A2) están sin decidir, y un agente que
empieza con la decisión abierta la toma por su cuenta. Cuesta una mañana y evita
un día de trabajo tirado.

---

## 8. Lo que esto NO es

- **No son ventanas de 30 minutos con sub-agentes.** Este plan asume **una sesión,
  secuencial**. La granularidad viene de cambiar el nivel por sub-tarea, no de
  partir la fase en trocitos para varios agentes.
- **No es un cambio del diseño.** Las enmiendas v4.1 son adiciones al diseño, y el
  diseño original sigue valiendo donde no se tocan.
- **No cambia los criterios de aceptación**, que eran lo mejor del plan y siguen
  siendo ejecutables y concretos.
- **No automatiza la verificación.** La capa L4 sigue siendo una persona mirando
  una salida. Lo que hay es un contrato de qué mirar, no un script que lo mire.
