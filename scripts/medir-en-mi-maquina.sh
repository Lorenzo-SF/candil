#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
#  Medir en la maquina del dueno lo que NO se puede medir en un runner.
#
#  Esto NO es un test. Un test comprueba que algo hace lo que dice; esto
#  comprueba si lo que dice SIRVE, y para eso hacen falta tu GPU, tus modelos
#  y tus tiempos.
#
#  Todo lo que imprima sale en UN fichero, para poder leerlo sin preguntarte.
#
#      bash scripts/medir-en-mi-maquina.sh
#
#  Antes de esto, dos cosas, y estan las dos al principio del script:
#    · GIT_DIR_CANDIL, si tienes el repo en otro sitio
#    · TUS_MODELOS, si quieres medir con los tuyos y no con los de ejemplo
# ══════════════════════════════════════════════════════════════════════════
set -uo pipefail

# ── 0 · Donde esta tu repo ────────────────────────────────────────────────
GIT_DIR_CANDIL="${GIT_DIR_CANDIL:-$HOME/candil}"
REPORT="${REPORT:-$HOME/candil-medicion-$(date +%Y%m%d-%H%M).log}"

if [ ! -d "$GIT_DIR_CANDIL/.git" ]; then
  echo "No encuentro el repo en $GIT_DIR_CANDIL."
  echo "O ponlo asi:   GIT_DIR_CANDIL=/ruta/real/candil bash $0"
  exit 1
fi

cd "$GIT_DIR_CANDIL" || exit 1

# ── 1 · El entorno, y por que CANDIL_DATA_DIR va SIEMPRE ──────────────────
#
# `Candil.Instances` escribe un `instances.json` en disco. Sin esta variable,
# este script te lo escribe en el `~/.candil` REAL, y el siguiente `candil
# status` te ensucia. El modulo lo avisa en su propio `@doc`:
# "a test that writes instances.json into the developer's real ~/.candil is a
# test nobody runs twice".
export CANDIL_DATA_DIR="$(mktemp -d)"
export MIX_ENV=test

# Toolchain, si lo tienes montado como en las otras maquinas.
[ -f /workspace/tools/env.sh ] && . /workspace/tools/env.sh
[ -f "$HOME/tools/env.sh" ]       && . "$HOME/tools/env.sh"

section() { printf '\n\n════════ %s ════════\n%s\n' "$1" "$2" >>"$REPORT"; }
note()    { printf '%s\n' "$*" | tee -a "$REPORT"; }

note "Candil · medicion en la maquina del dueno"
note "repo   : $GIT_DIR_CANDIL  @ $(git rev-parse --short HEAD 2>/dev/null)"
note "fecha  : $(date)"
note "CANDIL_DATA_DIR = $CANDIL_DATA_DIR   (temporal, no toca tu ~/.candil)"

# ══════════════════════════════════════════════════════════════════════════
#  A · Lo que se puede medir aqui, y es el suelo
# ══════════════════════════════════════════════════════════════════════════
section "A · la suite, que es el suelo" "si esto esta rojo, lo demas no cuenta"

{
  echo "--- hardware que ve Candil ---"
  mix run -e 'IO.inspect(Candil.Detector.Devices.detect(), label: "dispositivos")' 2>&1

  echo "--- gates ---"
  mix format --check-formatted;                       echo "format exit=$?"
  mix compile --force --warnings-as-errors;           echo "compile exit=$?"
  mix credo;                                          echo "credo exit=$?"
  mix test --seed 0 2>&1 | tail -5;                   echo "test exit=${PIPESTATUS[0]}"
} 2>&1 | tee -a "$REPORT"

section "A2 · la cola en el camino caliente" "exclusive = false NO debe arrancar cola"

# ══════════════════════════════════════════════════════════════════════════
#  B · La medicion que necesita un modelo de verdad
# ══════════════════════════════════════════════════════════════════════════
section "B · las capas del enrutado, con TUS modelos" \
       "si no rellenas la seccion 2 del script, esto mide vectores de mentira"

if [ -f scripts/router-layers-check.exs ]; then
  note ""
  note "El script tiene dos secciones:"
  note "  1 · el mecanismo, con un clasificador y un embedder FALSOS  -> corre ya"
  note "  2 · LA MEDICION, con los tuyos                           -> hay que rellenarla"
  note ""
  note "Para la seccion 2, edita scripts/router-layers-check.exs y pon:"
  note "  · MiEmbedder     -> el nombre de TU modulo de embeddings"
  note "  · MiClasificador -> el nombre de TU clasificador"
  note "  · @prompts       -> las preguntas TUyas, con el modelo que"
  note "                       deberia ganar en cada una"
  note ""
  note "Si no lo editas, corre la seccion 1 y ya:"
  mix run scripts/router-layers-check.exs
  echo "router-layers-check exit=$?" | tee -a "$REPORT"
else
  note "FALTA scripts/router-layers-check.exs — no esta en esta rama."
fi

# ══════════════════════════════════════════════════════════════════════════
#  C · La medicion que necesita una GPU de verdad
# ══════════════════════════════════════════════════════════════════════════
section "C · la cola contra un destino REALMENTE exclusivo" \
       "esto es lo que un runner con modelos falsos NO puede medir"

cat <<'CMD' | tee -a "$REPORT"

  Lo que hay que mirar, y lo que significaria cada cosa:

    · un turno de 0 ms con un modelo de verdad  ->  el reloj no esta midiendo
      la inferencia, y la politica no sirve de nada. ES EL FALLO MAS PROBABLE.
    · la segunda peticion no espera             ->  la cola no existe para
      destinos reales, aunque los tests digan que si.
    · la peticion a un proveedor remoto espera  ->  hay un acoplamiento que no
      deberia existir, y dos destinos distintos se estan estorbando.

  Para medirlo hace falta un modelo local CARGADO y declarado exclusivo:

    · arranca tu modelo        candil run <tu-modelo>
    · declaralo exclusivo      exclusive = true   en su [model.<alias>]
    · en otra terminal, dos peticiones a la vez al MISMO alias
    · y una tercera a un alias remoto, que NO deberia esperar

  Este script solo comprueba la MECANICA con destinos falsos, que ya esta
  cubierta por la suite. La parte que necesita la GPU la tienes que mirar tu,
  porque necesita tu modelo cargado y tus tiempos.
CMD

note ""
note "Informe completo en:  $REPORT"
note ""
note "Cuando lo tengas, pegame el fichero o dime la ruta y lo leo."
