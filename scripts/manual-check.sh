#!/usr/bin/env bash
# Everything worth checking by hand, in phases, with markers you can copy.
#
#   ./scripts/manual-check.sh            # all phases
#   ./scripts/manual-check.sh 1 3        # only phases 1 and 3
#   CANDIL=./candil ./scripts/manual-check.sh
#
# It does NOT stop at the first failure. That is the point: a phase that dies
# takes the four after it with it, and the interesting failures are usually the
# ones in a later phase. Every command's exit status is recorded and summarised
# at the end.
#
# Nothing here writes to your model files, kills a running engine, or removes
# anything. `doctor --fix` does create `data_dir` and `log_dir` — that is the
# thing it is for, and phase 2 says so before doing it.

set -uo pipefail

# ── which candil ────────────────────────────────────────────────────────────
if [[ -n "${CANDIL:-}" ]]; then
  CANDIL_BIN="$CANDIL"
elif command -v candil >/dev/null 2>&1; then
  CANDIL_BIN="$(command -v candil)"
elif [[ -x ./candil ]]; then
  CANDIL_BIN="./candil"
else
  cat >&2 <<'EOF'
No encuentro `candil`.

  CANDIL=/ruta/al/candil ./scripts/manual-check.sh
  o bien, desde el repo:  mix escript.build && CANDIL=./candil ./scripts/manual-check.sh
EOF
  exit 127
fi

# ── plumbing ────────────────────────────────────────────────────────────────
RESULTS=()          # "phase|check|exit|note"
# `$*` and not `${*:}`: the latter is not bash, and it fails the whole script
# before the first line of output. With no arguments `$*` is empty, which is
# what "run every phase" means.
PHASES="$*"
CURRENT_PHASE=0
CURRENT_LABEL=""

# ── el log ────────────────────────────────────────────────────────────────
#
# La queja original era "no puedo dartelo": el script se colgaba, se.cancelaba
# con Ctrl-C y lo unico que se llevaba por delante era lo que ya habia
# spooteado por el terminal, que se puede perder al copiar. Ademas todo lo
# que va despues del cuelgue —que es justo lo que hay que mirar— no existia.
#
# Asi que ademas de imprimir, se escribe. Y si lo matan a mitad, el log dice
# EN QUE IBA y el resumen de lo que llego a completarse.
LOG_FILE="${LOG_FILE:-manual-check.log}"
: > "$LOG_FILE"

# Lo que va ahora, para que una muerte envie un "aqui estaba" en vez de un
# "se ha parado".
NOW_RUNNING="(nada)"

# exec > >(tee -a "$LOG_FILE") 2>&1  deja stdout y stderr en el log. Con exec
# no hace falta acordarse de redirigir en cada sitio, y lo que se ve y lo que
# se guarda no pueden separarse sin querer.
exec > >(tee -a "$LOG_FILE") 2>&1

cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    printf '\n\033[1;33m[interrumpido]\033[0m iba por: %s\n' "$NOW_RUNNING"
    printf 'Lo que llego a completarse:\n'
    for r in "${RESULTS[@]:-}"; do
      [[ -n "$r" ]] && printf '  %s\n' "$r"
    done
  fi
  printf '\nLog completo en: %s (%s comprobaciones)\n' \
    "$LOG_FILE" "$((${#RESULTS[@]}))"
  exit $rc
}
trap cleanup EXIT
trap 'printf "\n[Ctrl-C]\n"; exit 130' INT

want() { # want <phase>
  [[ -z "$PHASES" ]] && return 0
  for p in $PHASES; do [[ "$p" == "$1" ]] && return 0; done
  return 1
}

banner() {
  printf '\n\033[1m═══ %s ═══\033[0m\n' "$1"
}

phase() { # phase <n> <title>
  banner "FASE $1 · $2"
  CURRENT_PHASE="$1"
  CURRENT_LABEL="$2"
}

# candil_run <command...> — la unica forma de llamar a candil en este script.
#
# POR QUE EXISTE: este script se pega en un chat, y un smoke que se cuelga es
# un smoke que no llega a nadie. Con la salida de `models list --help` se
# quedaba esperando a un TTY y habia que matarlo con Ctrl-C: todo lo que venia
# detras se perdia, que es justo lo contrario de lo que sirve este fichero.
#
# Tres cortafuegos, porque hay tres maneras de colgarse:
#   timeout -k -> algo espera algo que no llega
#   </dev/null -> algo pregunta por stdin y nadie contesta
#   PAGER=cat  -> un paginador --less---- esperando a que pulses una tecla
#
# EL -K NO ES COSMETICO, y costaria un cuelgue entero encontrarlo. `timeout 30`
# manda SIGTERM y, si el proceso no se muere, se queda ESPERANDO a que se
# muera para siempre: no es un plazo, es una peticion. Detras de un escript hay
# un BEAM entero, y hay procesos que se tragan el TERM —comprobado con un
# `trap` de shell: 300s de espera en vez de 30. `-k 5` manda SIGKILL cinco
# segundos despues, que no se puede ignorar. 124 = timeout, 137 = hubo que
# matarlo a la fuerza; los dos salen en el resumen.
candil_run() {
  timeout -k 5 "${CANDIL_TIMEOUT:-30}" env PAGER=cat LESS=cat GIT_PAGER=cat "$@" < /dev/null
}

# run <description> <command...>
# Runs it, shows stdout+stderr, records the exit status.
run() {
  local desc="$1"; shift
  NOW_RUNNING="$desc"
  printf '\n--- %s\n' "$desc"
  printf '$ %s\n\n' "$*"

  local out rc
  out="$(candil_run "$@" 2>&1)"; rc=$?

  printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g'
  printf '\n[exit=%s]\n' "$rc"
  RESULTS+=("${CURRENT_PHASE}|${desc}|${rc}|")
  NOW_RUNNING="(nada, esperando)"
  return 0
}

# run_json <description> <command...> — same, but keeps stdout separate from
# stderr, because a --json consumer cares about the difference and so should
# the person checking it.
run_json() {
  local desc="$1"; shift
  NOW_RUNNING="$desc"
  printf '\n--- %s\n' "$desc"
  printf '$ %s\n\n' "$*"

  # stdout a fichero, NUNCA a un sed que lea de <&0.
  #
  # `sed ... <&0` leia el stdin del SCRIPT, que desde una terminal es la
  # terminal: se quedaba esperando a un Ctrl-D indefinidamente, justo despues
  # de imprimir el JSON. El comentario de al lado decia que habia un
  # `</dev/null` que hacia justo eso, y el codigo no lo tenia. Un comentario
  # que describe una proteccion que no existe es peor que no tener comentario,
  # porque el siguiente lo lee, lo da por cierto, y no lo vuelve a mirar.
  local err out rc
  err="$(mktemp)"
  out="$(mktemp)"
  candil_run "$@" >"$out" 2>"$err"; rc=$?

  local escapes
  escapes=$(grep -c $'\033' "$out" || true)

  printf '[stdout]\n'; sed 's/\x1b\[[0-9;]*m//g' "$out"
  printf '\n[stderr]\n'; sed 's/\x1b\[[0-9;]*m//g' "$err"
  rm -f "$err" "$out"
  printf '\n[exit=%s]  [escapes ANSI en stdout: %s]\n' "$rc" "$escapes"
  RESULTS+=("${CURRENT_PHASE}|${desc}|${rc}|ansi=${escapes}")
  NOW_RUNNING="(nada, esperando)"
  return 0
}

# expect <what> <actual> — for the few things that are pass/fail by eye
check() { # check <description> <got> <want>
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  OK    %s = %s\n' "$desc" "$got"
    RESULTS+=("${CURRENT_PHASE}|${desc}|0|ok")
  else
    printf '  AVISO %s = %s (esperaba %s)\n' "$desc" "$got" "$want"
    RESULTS+=("${CURRENT_PHASE}|${desc}|0|esperaba ${want}, dio ${got}")
  fi
}

# El script dice que version es. Se ha perdido una hora enteraDiagnosticando
# un cuelgue con un script VIEJO en disco: el pull habia fallado por un
# cambio local, el script de al lado era el de antes, y todo el sintoma
# parecia un bug nuevo. Un numero que se lee de un vistazo convierte "esta
# cosa se cuelga" en "no tengo el script que creo".
SELF_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'sin-repo')"
SELF_SHA="$(git log -1 --format='%h' -- "$0" 2>/dev/null || echo "$SELF_SHA")"

printf '\033[1mcandil manual check\033[0m\n'
printf 'script  : %s @ %s\n' "$(basename "$0")" "$SELF_SHA"
printf 'binario: %s\n' "$CANDIL_BIN"
candil_run "$CANDIL_BIN" version 2>&1 | head -1 | sed 's/^/version: /'
printf 'cwd    : %s\n' "$PWD"
printf 'atencion: esto corre doctor --fix en la fase 2, que crea data_dir y log_dir.\n'

# ── FASE 1 · el binario ───────────────────────────────────────────────────────────────────────────────────
if want 1; then
  # ── FASE 1: el binario. SIN help, a proposito. ─────────────────────────
  #
  # No se prueba el help porque CUELGA, y no por culpa del script: el help de
  # Alaja es una vista a pantalla completa que espera a que pulses "q" para
  # salir. `</dev/null` no lo para porque no lee de stdin, lee de /dev/tty,
  # y ahi no hay nada que redirigir. Un timeout solo convierte un cuelgue
  # infinito en 30s perdidos por cada help que se prueba, y son seis.
  #
  # El help se mira a ojo, en un terminal, una vez. Un smoke que se cuelga no
  # es un smoke: es un script que no termina nunca.
  phase 1 "el binario"

  run "version" "$CANDIL_BIN" version
  run "--version (debe coincidir con version)" "$CANDIL_BIN" --version
  run "-v" "$CANDIL_BIN" -v
  run "sin argumentos (debe listar los comandos)" "$CANDIL_BIN"

  phase 2 "doctor"
  run "sin --fix" "$CANDIL_BIN" doctor
  run_json "con --json" "$CANDIL_BIN" doctor --json
  printf '\n--- miralo tu: si hay un check en :error, el exit tiene que ser 1\n'
  run "solo los niveles, para pegar en un issue" \
    bash -c "\"$CANDIL_BIN\" doctor --json 2>/dev/null | jq -r '.[] | \"\(.level)\t\(.name)\"'"

  printf '\n--- ESTO CREA data_dir y log_dir\n'
  run "--fix" "$CANDIL_BIN" doctor --fix
  run "doctor otra vez, ya arreglado (esta vez compara con el de arriba)" \
    "$CANDIL_BIN" doctor
fi

# ── ¿ha arrancado DE VERDAD? ───────────────────────────────────────────────
#
# Por que esto existe y por que mira la VRAM. Durante meses
# `candil run <modelo>` imprimia "arrancado en :9999", salia con codigo 0 y no
# arrancaba NADA: `EnginePool.put/5` contestaba :ok sin hacer nada y la CLI
# nunca llegaba a llamar a `Engine.start/2`. Todos los smokes miraban exit
# codes, y `candil run` sale 0 haya modelo o no — un codigo de salida no es una
# comprobacion de que algo funcione.
#
# Un modelo cargado mueve la VRAM de golpe. Si no se mueve, no ha arrancado,
# por muy bonito que sea el codigo de salida. Y si el puerto no escucha, tampoco.
# Las dos cosas se miran, porque fallan por motivos distintos.

# Megabytes de VRAM usados ahora mismo. Vacio si no hay NVIDIA o no hay
# `nvidia-smi`: entonces el smoke lo dice y salta ESTA comprobacion, en vez de
# darla por buena.
vram_used_mb() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  local line
  line=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
  [[ "$line" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$line"
}

# Hay algo escuchando en ese puerto. `ss` no esta en todas partes; se cae a
# /proc/net/tcp, que siempre lo esta en Linux.
port_listening() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :$port" 2>/dev/null | tail -n +2 | grep -q . && return 0
    return 1
  fi
  local hex
  printf -v hex '%04X' "$port" 2>/dev/null
  grep -qiE ":[[:space:]]*${hex} " /proc/net/tcp 2>/dev/null && return 0
  grep -qiE ":[[:space:]]*${hex} " /proc/net/tcp6 2>/dev/null && return 0
  return 1
}

# La comprobacion de verdad. Imprime lo que ha visto y decide.
#
# `vram_before` es lo que habia ANTES del arranque. Sin esa cifra no se puede
# decir "ha subido": decir "hay 14000 MB" no demuestra nada, porque puede que ya
# los hubiera.
check_real_launch() {
  local alias="$1" port="$2" before="$3"
  local after listening state vram_note

  if listening=$(port_listening "$port"); then :; fi

  if [[ "$listening" == "0" ]]; then
    listening="si"
  else
    listening="no"
  fi

  if after=$(vram_used_mb); then
    if [[ -n "$before" && "$after" -gt "$before" ]]; then
      vram_note="+$((after - before)) MB (de $before a $after)"
    else
      vram_note="sin cambio (de ${before:-?} a $after)"
    fi
  else
    vram_note="no disponible (sin nvidia-smi)"
  fi

  state=$("$CANDIL_BIN" status 2>/dev/null | grep -c "$alias" || true)

  printf '  puerto %-6s %s\n' "$port" "$listening"
  printf '  vram             %s\n' "$vram_note"
  printf '  status dice      %s mencion(es) de %s\n' "$state" "$alias"

  # La condicion de cierre: el puerto escucha Y la VRAM ha subido. Con las dos
  # cosas, un codigo de salida 0 deja de ser la unica prueba.
  if [[ "$listening" == "si" && "$vram_note" == +* ]]; then
    printf '  VEREDICTO         HA ARRANCADO\n'
    RESULTS+=("3|$alias arranca de verdad (puerto + vram)|0|")
    return 0
  fi

  printf '  VEREDICTO         NO HA ARRANCADO, aunque el exit code fuera 0\n'
  RESULTS+=("3|$alias arranca de verdad (puerto + vram)|1|puerto=$listening vram=$vram_note")
  return 1
}

# ── FASE 3 · flows reales ───────────────────────────────────────────────────
if want 3; then
  phase 3 "flows reales (solo si tienes modelos)"
  run "models list" "$CANDIL_BIN" models list

  # Modelo a probar. `MODEL=... ./scripts/manual-check.sh 3` lo fija; si no,
  # se saca de la primera columna de `models list`. Sin sustitucion anidada:
  # un `$(` sin cerrar hace que bash se coma el resto del script buscando el
  # parentesis, y el fallo aparece doscientas lineas mas abajo.
  ALIAS="${MODEL:-}"
  if [[ -z "$ALIAS" ]]; then
    # Estrategia 1: la tabla. El separador de columnas es U+2502, el guion
    # vertical de las cajas, NO una barra ASCII. Con `awk -F'|'` no se parte
    # NADA, $2 sale vacio en todas las lineas, y el script se conviction de que
    # no tienes modelos mientras te enseña los siete en la tabla. Se traduce
    # el separador antes de partir.
    # El separador va DIRECTO como -F, y no pasa por `tr`: `tr` no sabe de
    # UTF-8 y convierte cada uno de los TRES bytes de U+2502 en una barra, de
    # modo que un separador se convierte en "|||" y la tabla se rompe peor que
    # antes. awk si lo trata como un caracter.
    ALIAS=$("$CANDIL_BIN" models list 2>/dev/null \
      | awk -F'│' '{gsub(/^ +| +$/, "", $2); if ($2 != "" && $2 != "alias" && $2 != "-") {print $2; exit}}')
  fi
  if [[ -z "${ALIAS:-}" ]]; then
    # Estrategia 2: el fichero de configuracion. No depende de como se
    # imprima la tabla, asi que si Alaja cambia el formato un dia, esta fase
    # sigue funcionando en vez de saltarse en silencio. Que es lo que mas
    # molesta: un smoke que se salta lo importante sin decir por que.
    CFG="${CANDIL_CONFIG:-$HOME/.config/candil/candil.toml}"
    if [[ -f "$CFG" ]]; then
      ALIAS=$(sed -n 's/^\[model\.\([^]]*\)\].*/\1/p' "$CFG" | head -1)
    fi
  fi

  MODEL_PORT="${MODEL_PORT:-$("$CANDIL_BIN" models list 2>/dev/null \
    | awk -F'│' -v a="$ALIAS" '$2 ~ a {gsub(/^ +| +$/, "", $4); print $4; exit}')}"
  MODEL_PORT="${MODEL_PORT:-9999}"

  if [[ -n "${ALIAS:-}" ]]; then
    printf '\n(modelo detectado: %s)\n' "$ALIAS"
    run "models info $ALIAS" "$CANDIL_BIN" models info "$ALIAS"
    run "status antes de arrancar" "$CANDIL_BIN" status
    # La VRAM de ANTES. Sin esta cifra, "ahora hay 14000 MB" no demuestra nada:
    # puede que ya los hubiera. Y `run --detach` se mide con `check_real_launch`,
    # no con su exit code — que es exactamente lo que dejo pasar al bug de los
    # meses.
    VRAM_BEFORE="$(vram_used_mb || true)"

    run "run $ALIAS --detach" "$CANDIL_BIN" run "$ALIAS" --detach
    run "status con el engine detached" "$CANDIL_BIN" status

    NOW_RUNNING="$ALIAS arranca de verdad"
    printf '\n--- %s: puerto + vram, NO el exit code\n' "$ALIAS"
    printf '$ (el modelo deberia subir la VRAM y dejar el puerto escuchando)\n\n'
    check_real_launch "$ALIAS" "$MODEL_PORT" "$VRAM_BEFORE" || true

    run_json "stop" "$CANDIL_BIN" stop
    printf '\n--- y tras el stop, el puerto tiene que quedar libre\n'
    printf '$ (si sigue escuchando, algo se ha quedado sin dueño)\n\n'
    if port_listening "$MODEL_PORT"; then
      printf '  VEREDICTO         SIGUE ESCUCHANDO tras el stop — huerfano\n'
      RESULTS+=("3|$ALIAS se para de verdad|1|el puerto sigue escuchando")
    else
      printf '  VEREDICTO         el puerto queda libre\n'
      RESULTS+=("3|$ALIAS se para de verdad|0|")
    fi
    NOW_RUNNING="(nada, esperando)"
  else
    printf '\nNo he detectado ningun modelo, me salto la parte de run.\n'
    printf '(ni por la tabla ni por %s)\n' "${CANDIL_CONFIG:-$HOME/.config/candil/candil.toml}"
    printf 'Si tienes uno configurado, corre esto a mano:\n'
    printf '  %s models list\n  %s run <alias>\n  %s status\n  %s stop\n' \
      "$CANDIL_BIN" "$CANDIL_BIN" "$CANDIL_BIN" "$CANDIL_BIN"
    RESULTS+=("3|run/stop reales|0|no hay modelo configurado; skipped")
  fi
fi

# ── FASE 4 · lo que se rompio en esta rama ─────────────────────────────────
if want 4; then
  phase 4 "regresiones concretas de la rama"
  run "un comando inexistente (no debe reventar con stack trace)" \
    bash -c "\"$CANDIL_BIN\" frobnicate 2>&1"
  run "models con subcomando inexistente" bash -c "\"$CANDIL_BIN\" models frobnicate 2>&1"
  run "status --json (debe salir sin escapes)" bash -c "\"$CANDIL_BIN\" status --json 2>&1"
  run "un flag que ese comando no tiene" bash -c "\"$CANDIL_BIN\" doctor --nada 2>&1"
fi

# ── resumen ─────────────────────────────────────────────────────────────────
banner "RESUMEN  (${SECONDS}s)"

printf '%-6s %-52s %-6s %s\n' FASE QUÉ EXIT NOTAS
printf '%-6s %-52s %-6s %s\n' "----" "----" "----" "-----"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r p d rc n <<<"$r"
  printf '%-6s %-52s %-6s %s\n' "$p" "${d:0:52}" "$rc" "$n"
done

BAD=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r _p _d rc _n <<<"$r"
  [[ "$rc" != "0" ]] && BAD=$((BAD + 1))
done

printf '\n'
if [[ "$BAD" -eq 0 ]]; then
  printf '\033[1mtodos los comandos salieron con 0\033[0m\n'
  printf 'Ojo: eso NO significa que todo este bien. El punto 1 de la fase 2 dice\n'
  printf 'que doctor puede imprimir errores y salir con 0 si algo se rompio.\n'
else
  printf '\033[1m%s comando(s) con exit distinto de 0\033[0m\n' "$BAD"
  printf 'Mira la tabla de arriba y pega el bloque del que falla.\n'
fi

cat <<'EOF'

Para pegar en un issue:

  1. la salida entera de este script, y
  2. para lo que falle, la salida de UNA fase concreta, con su exit:
       ./scripts/manual-check.sh 2 2>&1 | tail -n 40
EOF
