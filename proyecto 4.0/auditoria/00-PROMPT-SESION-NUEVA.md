# Prompt para una sesión nueva

> **Copia el bloque de abajo entero** en la sesión que retoma el trabajo.
> Está escrito para que no tengas que descubrir nada: qué es esto, qué hay que
> leer, en qué orden, y qué está prohibido.
>
> El bloque es autocontenido. No necesitas leer nada más para empezarlo.

---

```text
Retomas Candil 4.0: una librería de Elixir que es la capa de inferencia LLM del
ecosistema del dueño (gestiona modelos, los arranca, enruta, expone gateway,
MCP y RAG). El diseño ya está cerrado y hay trabajo hecho hasta la Fase 5.

Acaban de entregarte un ZIP con TODA la documentación de ese proyecto. Tu
primera instrucción es la más importante y va contra el reflejo normal:

    NO IMPLEMENTES NADA. PRIMERO MIDE EL ESTADO REAL.

================================================================================
1. DÓNDE ESTÁ TODO
================================================================================

Descomprime el zip. Contiene:

  RETOMAR.md              ← EMPIEZA AQUÍ. Los primeros 30 minutos.
  PLAN-EJECUCION.md       ← cómo se ejecuta cada fase
  fase-6-README.md        ← la primera fase que hay que hacer de verdad
  00-INFORME-AUDITORIA.md ← solo si algo no cuadra; tiene las contradicciones
  00-INDICE.md            ← el mapa completo

  v4.1/candil-4.0-DISENO-v4.1.md   ← 10 enmiendas al diseño
  v4.1/candil-4.0-FASES-v4.1.md    ← el análisis de dependencias

  fase-2..fase-11-README.md        ← las otras fases, para cuando llegues
  ORIGINAL/                         ← los documentos SIN tocar, para comparar

**Lee EXACTAMENTE estos cuatro, en este orden, y ninguno más hasta que
tengas el veredicto:**

    1. RETOMAR.md
    2. PLAN-EJECUCION.md
    3. fase-6-README.md
    4. (más adelante) el README de la fase que estés haciendo

`ORIGINAL/candil-4.0-final.md` son 3.000 líneas. **No lo leas entero.** Cada
README de fase te dice qué secciones concretas mirar y de qué línea.

================================================================================
2. EL MANDATO
================================================================================

Hay una tabla en RETOMAR.md §2 con las 10 fases y cómo se comprueba cada una.
Rellénala con la SALIDA REAL DE LOS COMANDOS. No con lo que recuerdas, no con
lo que dicen los documentos.

**Por qué esto es tan importante:** los números que están escritos en los
documentos están desactualizados a propósito. En algún momento ponían "623
tests", luego "702", luego "687", y ninguno era el número real del momento en que
se leía. Un documento que miente es peor que un documento que no existe.

Los comandos, en orden:

    cd ~/cacafuti/candil          # o donde esté el repo
    git status -sb
    git log --oneline -20
    git tag | grep candil | sort -V        # ← el mapa de fases, 5 segundos

    CANDIL_DATA_DIR=$(mktemp -d) mix deps.get
    CANDIL_DATA_DIR=$(mktemp -d) mix test --cover 2>&1 | tail -20
    mix credo --strict --format=oneline
    mix dialyzer 2>&1 | tail -5

**`git tag` es la señal más fiable de qué se ha cerrado**, porque se ponen al
mergear y no se pueden poner por descuido.

Apunta TRES números textuales: tests, fallos, cobertura.

**Luego, por fase**, el criterio de aceptación de RETOMAR.md §2.

⚠ Una cosa NO se puede verificar sin los 17 GB de GGUF: `./candil run coder
--detach` con un STATE en ON. Si no tienes modelos, el veredicto honesto es
"verificada en todo lo verificable" y se escribe así. **Escribir un veredicto
que no has medido es el único error irrecuperable de todo este trabajo.**

================================================================================
3. ENTORNO
================================================================================

Repo:   https://github.com/Lorenzo-SF/candil
Toolchain: Erlang/OTP 28.5.0.7 · Elixir 1.19.5-otp-28   (fijado en .tool-versions)

En un sandbox efímero, antes de nada:

    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    export ELIXIR_ERL_OPTIONS="+fnu"
    bash /workspace/setup-candil.sh      # idempotente: asdf, mirror, build

Si `mix deps.get` falla con econnrefused al 127.0.0.1:4000, el mirror de Hex no
está vivo. Se arranca como TAREA GESTIONADA EN BACKGROUND, nunca con nohup: un
nohup dentro de una llamada de bash muere al cerrarse la llamada.

    python3 /workspace/tools/hex_mirror.py --port 4000

**Todo test que toque disco necesita `CANDIL_DATA_DIR=$(mktemp -d)`.** Sin eso
escribes en el ~/.candil de verdad, y un test que hace eso no se ejecuta dos
veces.

TRAMPAS DE ESTE ENTORNO (las pagó el dueño, no las repitas):

  · `Config` es un módulo de Elixir. Usa `alias Candil.Config, as: CandilConfig`
    o `Config.File.load()` resuelve al de Elixir y falla con UndefinedFunctionError.
  · `System.pid/0` devuelve un BINARIO en OTP 28, una charlist en otras versiones
    y un entero en otras. Un `is_integer` funciona hoy y no mañana.
  · `Enum.filter/2` devuelve los elementos ORIGINALES cuando la función responde
    verdadero, y tira lo que devolvió. Filtrar con un constructor parece
    funcionar, cuenta bien, y entrega mapas con claves de string.
  · `Process.alive?/1` toma un pid de ERLANG, no del sistema operativo.
  · `Map.update/4` es (map, key, default, fun). El default va en tercer lugar.
    Pasarlo al revés compila y devuelve basura.
  · Los procesos en background no sobreviven a la llamada de bash que los lanza.
  · /opt, /usr y /root desaparecen en cada reinicio. Solo sobrevive /workspace.
  · Un worktree y un _build por sesión. Los ficheros de config de dos carriles
    se pisan si comparten worktree.

================================================================================
4. EL CICLO (idéntico en todas las fases)
================================================================================

    git checkout main
    git fetch origin
    git pull --ff-only origin main
    git checkout -b f6-context            # CON GUION, nunca barra

    # … implementar la fase COMPLETA, sub-tarea por sub-tarea …

    git push -u origin f6-context

    # PR contra main. MIRA EL CI antes de pedir el merge. En este repo se
    # mergeó un PR con un job en rojo porque nadie miró.
    # Merge a main, y cerrar el ciclo: HANDOFF.md §2 con números MEDIDOS,
    # CHANGELOG.md con los nombres de función reales, y el tag de la fase.

**La fase se implementa COMPLETA antes de abrir el PR.** No un PR por sub-tarea.

================================================================================
5. EL NIVEL DE RAZONAMIENTO — esto es lo que más te va a costar
================================================================================

MiniMax-M3.1-Flash-Preview tiene 5 niveles: low, medium, high, xhigh, max.

**Se cambian con `/model` en la TUI** (verificado: `/model` cambia modelo Y
effort; `/status` muestra el par activo). En headless:
`mcode exec --effort <nivel> "..."`.

⚠ **El modelo NO puede cambiar su propio effort a mitad de respuesta.** El
ajuste es ENTRE TURNOS. Por eso la unidad de trabajo es la SUB-TAREA con su
nivel declarado, no la fase.

⚠ **No dejes el nivel sin fijar.** Si no lo mandas, sale `max` — el más caro.
Y `none` no existe: devuelve error 400.

La regla que manda:

    En media hora, `max` NO produce más trabajo: produce menos.
    No hay tiempo para pensar, escribir Y verificar.

| Nivel  | Cuándo |
|--------|--------------------------------------------------|
| low    | el texto está escrito en otro sitio: transcribir, ejecutar, un mensaje literal |
| medium | una función con spec clara; un test de comportamiento existente |
| high   | una decisión con dos respuestas válidas y UNA está escrita |
| xhigh  | hay que leer 4+ ficheros para decidir |
| max    | REVISAR. Y decidir cuando la decisión NO está escrita |

**El presupuesto alto va a la VERIFICACIÓN, no a la implementación.**

Dos reglas duras:

  1. Una sub-tarea de implementación que necesite `max` NO cabe en media hora.
     Si crees que necesita `max`, es una fase: divídela.
  2. Si la decisión NO está escrita en el documento de diseño, PARA y pregunta.
     No la tomes. El diseño dice que todas están escritas; si ninguna encaja,
     eso es información que el dueño necesita, no una decisión tuya.

Al final de cada fase, SIEMPRE una sesión de revisión aparte, a `max`, leyendo el
PR SIN el diff del autor. Es la única tarea del plan donde el nivel base es
máximo, porque es la única donde el agente no puede estar calibrado por haber
escrito el módulo.

================================================================================
6. LAS 4 CAPAS DE VERIFICACIÓN
================================================================================

Ninguna sub-tarea está terminada sin L1 + L3.

  L1 estático   mix format --check-formatted
                mix compile --force --warnings-as-errors
                SIEMPRE. Un warning de compilador es un fallo, no una nota.

  L2 análisis   mix credo --strict --format=oneline
                mix dialyzer
                si toca código compartido.
                Si aparece unknown_function de una app hermana, MIRA EL PLT antes
                que tu código. Ya mordió una vez: el PLT solo tenía OTP y
                Candil, y 15 llamadas nunca se comprobaron.
                Y: un stub que hace `raise` es `none()` para dialyzer. Si
                escribes uno, devuelve
                `{:error, %Candil.Error{reason: :not_implemented}}`.

  L3 test       CANDIL_DATA_DIR=$(mktemp -d) mix test test/candil/<ruta>/
                SIEMPRE. Y nombra el caso nuevo Y el existente que sigue verde.
                Un test que no se nombra, no se ejecuta y no cuenta.

  L4 funcional  un comando con salida observable, Y QUÉ NO PUEDE OCURRIR.
                si es visible para el usuario.

**La aserción negativa es la que importa.** Un criterio que solo dice "responde"
pasa con un `[]` de respuesta. Un criterio que dice "responde Y no devuelve `[]`
sin explicación" detecta el fallo que de verdad pasa.

================================================================================
7. POR DÓNDE EMPIEZAS
================================================================================

Según el veredicto que hayas medido en §2, y **en este orden** (riesgo primero:

    F6 (Context) → F7 (Router) → F8 (Gateway) → F9 (MCP) → F10 (RAG) → F11

El orden es riesgo primero a propósito. El riesgo del plan está en F6, F7, F9 y
F10. Con el orden viejo del gantt se llegaba a la F7 —la única fase con `max` de
base y decisiones sin escribir— en el día 23 de 41, sin margen para reaccionar.

**Las F2 a F5 no se reimplementan.** Se miden, y si dan 🟡 se terminan con su
README como guía.

⚠ El caso 🟡 "parcial" es el que más engaña: la F5 tenía los siete checks
funcionando y CERO tests, y eso no se ve compilando.

Las cinco fases que empiezan ahora **arrancan todas en `max`** o en el bloqueo que
las precede. No es casualidad: son las que tienen decisiones que el documento no
contiene.

================================================================================
8. LAS DOS DECISIONES QUE BLOQUEAN F9 Y F10
================================================================================

**No arranques estas dos con la decisión abierta.** Un agente que empieza sin
ella la toma por su cuenta, y es un día de trabajo tirado.

  F9 · ¿qué revisión del protocolo MCP? Hoy la Current es `2026-07-28`, que
       ELIMINÓ el handshake `initialize` (ahora hay `server/discover` y la
       versión va en `_meta`). Los documentos hablan de `2025-11-25`, que ya es
       Legacy. Detalle en fase-9-README.md §0.

  F10 · ¿el diseño del README (SQLite FTS5 + chunking por función) o el del
       plan (memoria + chunker configurable)? Ocho divergencias. Los dos
       documentos vivos producen dos RAG distintos. Detalle en
       fase-10-README.md §0.

Caben en una mañana. Se anotan en HANDOFF.md con un párrafo cada una.

**F6, F7 y F8 no dependen de ninguna de las dos.** Se pueden hacer ya.

================================================================================
9. LO QUE NO VAS A HACER
================================================================================

  · No reimplementar las fases 2 a 5. Se miden.
  · No tocar ropero. NI UN BYTE. Sigue vivo, es la referencia, y su retirada es
    decisión del dueño. La regla es C16.
  · No hacer `git push --force`. Nunca.
  · No hacer push directo a main sin PR.
  · No usar `String.to_atom/1` con nada que venga de fuera. Ya costó dos veces:
    la tabla de átomos no crece. Usa `String.to_existing_atom/1` y, si falla,
    `{:error, :unknown_model}`.
  · No tocar `mix.exs` para `groups_for_modules`: se pide en el PR y lo aplica
    una sola vez quien lleva ese carril.
  · No añadir flags de cmake por tu cuenta. Los flags de compilación los pone
    quien tiene el hardware.
  · No decidir nada de diseño que no esté escrito. Pregunta.

================================================================================
10. EL ENTREGABLE
================================================================================

Un `deliverable.md` con:

  · Los ocho gates, con su SALIDA REAL pegada
  · El criterio de aceptación, con su SALIDA REAL pegada
  · El número de tests antes y después
  · La cobertura antes y después, con el motivo si baja
  · Los ficheros tocados
  · El hash del commit y la URL del PR

Y una regla que no es negociable:

  Si un criterio NO se ejecutó porque el entorno no lo permite, DILO.
  Escribe: "criterio ejecutado: unitario, no integración, porque no hay GGUF
  en el sandbox".

  Un deliverable.md que dice "criterio ejecutado" cuando se ejecutó la mitad es
  una mentira, y la siguiente sesión la va a dar por buena.

Si la cobertura baja más de un punto, no lo maquilles: es información.

Si te bloqueas: PARA, y escribe en el deliverable.md qué buscaste, qué
encontraste, qué opciones ves, y por qué no decides. Un bloqueo escrito son 30
segundos. Un agente que decide por su cuenta y sigue son tres días perdidos.
```

---

## Nota para quien pega esto

El bloque está pensado para una sesión que **no sabe nada**: por eso lleva el
entorno, las trampas, el ciclo y las prohibiciones dentro, en vez de remitir a
otro fichero. Si la sesión ya tiene contexto de Candil, puede empezar en
`RETOMAR.md §1`.

**Los cinco ficheros que tiene que leer, y ninguno más hasta tener veredicto:**

| # | Fichero | Por qué ese orden |
|---|---|---|
| 1 | `RETOMAR.md` | el mandato: medir antes de tocar |
| 2 | `PLAN-EJECUCION.md` | el ciclo, los niveles, las 4 capas |
| 3 | `fase-6-README.md` | la primera fase real, y el nivel de cada sub-tarea |
| 4 | `00-INFORME-AUDITORIA.md` | solo si algo no cuadra con lo que sabes |
| 5 | `v4.1/candil-4.0-DISENO-v4.1.md` | las enmiendas, al empezar F6 |

`ORIGINAL/candil-4.0-final.md` son 3.000 líneas y **no se lee entero**: cada README
de fase dice qué secciones mirar y de qué línea.
