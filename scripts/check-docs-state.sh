#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  ¿Las afirmaciones de estado siguen ciertas?
#
#  EL PROBLEMA REAL
#  ────────────────
#  No es que los documentos mienten. Es que **nadie los revisa**. Un documento
#  con fecha se detecta viejo. Uno sin fecha, con seis meses de atraso, se lee
#  como actual y se lo cree cualquiera —incluido el que escribe el codigo que
#  lo contradice.
#
#  QUE HACE ESTO
#  ──────────────
#  Busca afirmaciones de estado en los moduledocs —«no implementado», «queda
#  por», «aun no», «phase N»— y exige que cada una lleve la fecha de cuando se
#  comprobo:
#
#      ...the `:embedding` layer is not implemented yet (checked: 2026-10-14).
#
#  Y avisa si esa fecha tiene mas de seis meses.
#
#  LO QUE **NO** HACE, y es lo importante
#  ─────────────────────────────────────
#  **No comprueba si la afirmacion es cierta.** No sabe nada de Candil. Solo
#  pide que quien la escribe puts la fecha de cuando la miro. Si sigue siendo
#  falsa, este gate no la salva; lo que hace es que **no vuelva a pasar seis
#  meses sin que nadie mire**.
#
#  El problema de este repo no es que los documentos mientan: es que se
#  escribieron una vez y no se volvieron a abrir.
#
#  ──────────────────────────────────────────────────────────────────────────
#  Por que un script y no un test de ExUnit: porque mira **documentos**, y un
#  modulo de pruebas que lee markdown es el sitio raro de este repo. Un script
#  en `scripts/` hace lo que el resto de scripts de ahi hacen.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

cd "$(dirname "$0")/.."

MESES_MAXIMOS="${DOCS_STALE_MONTHS:-6}"
HOY="$(date +%F)"
LIMITE="$(date -d "${MESES_MAXIMOS} months ago" +%F 2>/dev/null || date +%F)"

# Las frases que **afirman un estado**. Un «no hay ningun proceso» es una
# afirmacion; «el vendor nunca ha hecho» tambien. Lo que NO entra: un nombre de
# funcion que se llame `no_existe_algo`, que es codigo, no estado.
PATRON='no (esta|están|estaba) implementad|queda por (hacer|ver)|todavia no|aun no|no existe todavia|lands? in phase|fase [0-9]+'

SIN_FECHA=0
VIEJAS=0
TOTAL=0

while IFS= read -r linea; do
  TOTAL=$((TOTAL + 1))
  fichero="${linea%%:*}"

  fecha="$(grep -oE 'checked: [0-9]{4}-[0-9]{2}-[0-9]{2}' <<<"$linea" | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"

  if [ -z "$fecha" ]; then
    echo "  SIN FECHA  $fichero:$(cut -d: -f2 <<<"$linea")"
    echo "            ${linea:0:96}"
    SIN_FECHA=$((SIN_FECHA + 1))
    continue
  fi

  if [[ "$fecha" < "$LIMITE" ]]; then
    echo "  VIEJA      $fichero:$(cut -d: -f2 <<<"$linea")  (checked: $fecha, hace mas de ${MESES_MAXIMOS} meses)"
    VIEJAS=$((VIEJAS + 1))
  fi
done < <(grep -rnE "$PATRON" lib/ docs/ --include="*.ex" --include="*.md" 2>/dev/null | grep -v "^\s*#" | grep -v "check-docs-state" | head -60)

echo ""
echo "══════════════════════════════════════════════════════"
echo "  $TOTAL afirmaciones de estado"
echo "  $SIN_FECHA sin fecha   ·   $VIEJAS con fecha vieja (mas de ${MESES_MAXIMOS} meses)"
echo "══════════════════════════════════════════════════════"

if [ "$SIN_FECHA" -gt 0 ] || [ "$VIEJAS" -gt 0 ]; then
  echo ""
  echo "Cada una necesita un \`(checked: $HOY)\` al final de la frase."
  echo "No tienes que reescribir el documento: pon la fecha de cuando la miraste."
  echo ""
  echo "  · Si la afirmacion SIGUE siendo cierta → ponle la fecha de hoy."
  echo "  · Si ya NO es cierta → borrala o corrijela. Ahi es donde este repo"
  echo "    tiene deuda de verdad, y se ve porque la frase tiene fecha."
  # **Modo aviso por defecto, y a proposito.** Una puerta que falla el primer dia
  # con 60 hallazgos genera ruido, y del ruido sale silenciar la puerta —el mismo
  # camino que tomo `credo --strict`. Se pone en modo estricto cuando el numero
  # baje, no antes.
  if [ "${DOCS_STATE_STRICT:-0}" = "1" ]; then
    echo ""
    echo "MODO ESTRICTO: la puerta falla."
    exit 1
  fi

  echo ""
  echo "Modo aviso. Pon DOCS_STATE_STRICT=1 para que la puerta corte cuando esto este a cero."
  exit 0
fi

echo ""
echo "Todas las afirmaciones de estado tienen fecha reciente."
exit 0