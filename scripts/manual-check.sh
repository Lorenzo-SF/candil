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
  printf '\n--- %s\n' "$desc"
  printf '$ %s\n\n' "$*"

  local err rc
  err="$(mktemp)"
  candil_run "$@" 2>"$err"; rc=$?
  local escapes
  escapes=$(grep -c $'\033' || true)

  # `</dev/null` on the sed: without it, sed reads the script's own stdin and
  # swallows whatever was piped into this script, which is how a run that looks
  # fine turns into a run that quietly checked nothing.
  printf '[stdout]\n'; sed 's/\x1b\[[0-9;]*m//g' <&0
  printf '\n[stderr]\n'; sed 's/\x1b\[[0-9;]*m//g' "$err"; rm -f "$err"
  printf '\n[exit=%s]  [escapes ANSI en stdout: %s]\n' "$rc" "$escapes"
  RESULTS+=("${CURRENT_PHASE}|${desc}|${rc}|ansi=${escapes}")
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

printf '\033[1mcandil manual check\033[0m\n'
printf 'binario: %s\n' "$CANDIL_BIN"
candil_run "$CANDIL_BIN" version 2>&1 | head -1 | sed 's/^/version: /'
printf 'cwd    : %s\n' "$PWD"
printf 'atencion: esto corre doctor --fix en la fase 2, que crea data_dir y log_dir.\n'

# ── FASE 1 · el binario y el help ───────────────────────────────────────────
if want 1; then
  phase 1 "el binario y el help"
  run_json "el help sale por stdout y sin escapes" "$CANDIL_BIN" --help
  run "help (debe salir IGUAL que --help)" "$CANDIL_BIN" help
  run "-h" "$CANDIL_BIN" -h
  run "version" "$CANDIL_BIN" version
  run "--version (debe coincidir con version)" "$CANDIL_BIN" --version
  run "-v" "$CANDIL_BIN" -v
  run "sin argumentos (debe listar los 7 comandos)" "$CANDIL_BIN"

  printf '\n--- los cuatro flags que el help no mencionaba antes\n'
  candil_run "$CANDIL_BIN" run --help 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  printf '\n[mirar: --detach -d · --port -p · --force -f · --cpu · --yes -y]\n'
  RESULTS+=("1|flags de run visibles en su help|0|mirar a ojo")

  run "doctor --help" "$CANDIL_BIN" doctor --help
  run "models --help" "$CANDIL_BIN" models --help
  run_json "models list --help (CONOCIDO: imprime el help y ademas ejecuta)" \
    "$CANDIL_BIN" models list --help
fi

# ── FASE 2 · doctor ─────────────────────────────────────────────────────────
if want 2; then
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
    ALIAS=$("$CANDIL_BIN" models list 2>/dev/null | awk -F'|' '{gsub(/^ +| +$/, "", $2); if ($2 != "" && $2 != "alias" && $2 != "-") {print $2; exit}}')
  fi

  if [[ -n "${ALIAS:-}" ]]; then
    printf '\n(modelo detectado: %s)\n' "$ALIAS"
    run "models info $ALIAS" "$CANDIL_BIN" models info "$ALIAS"
    run "status antes de arrancar" "$CANDIL_BIN" status
    run "run $ALIAS (foreground; ctrl-c si se queda)" "$CANDIL_BIN" run "$ALIAS"
    run "status" "$CANDIL_BIN" status
    run "stop" "$CANDIL_BIN" stop
    run "run --detach" "$CANDIL_BIN" run "$ALIAS" --detach
    run "status con el engine detached" "$CANDIL_BIN" status
    run_json "stop" "$CANDIL_BIN" stop
  else
    printf '\nNo he detectado ningun modelo, me salto la parte de run.\n'
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
