#!/bin/bash
# snapshot.sh — extrae el contenido de los proyectos del ecosistema lasaca
#
# Genera, en el mismo directorio donde vive este script:
#   - Un archivo por proyecto:  snap-<nombre>.txt
#   - El combinado:             snapshot-completo-<ts>.txt
#   - Un resumen:               snapshot-resumen-<ts>.txt
#
# Uso:
#   ./snapshot.sh                       # todos los proyectos
#   ./snapshot.sh candil elpaso         # solo los indicados
#
# Proyectos cubiertos:
#   ~/workspace/github/         apero, alaja, pote, arrea, trebejo, botica, candil, elpaso
#   ~/workspace/github/lasaca/  ropero, gunter, arriero, posadero


# ═══════════════════════════════════════════════════════════════
# Localización del script
# ═══════════════════════════════════════════════════════════════

_SELF="${BASH_SOURCE[0]:-$0}"
_REAL="$(readlink -f "$_SELF" 2>/dev/null \
    || perl -MCwd -e 'print Cwd::abs_path shift' "$_SELF" 2>/dev/null \
    || echo "$_SELF")"
SCRIPT_DIR="$(cd "$(dirname "$_REAL")" && pwd)"

TIMESTAMP="$(date +%Y%m%d-%H%M)"
FULL_OUT="$SCRIPT_DIR/snapshot-completo-$TIMESTAMP.txt"
SUMMARY_OUT="$SCRIPT_DIR/snapshot-resumen-$TIMESTAMP.txt"

# Limpieza de ejecuciones anteriores (solo los nuestros)
rm -f "$SCRIPT_DIR"/snap-*.txt
rm -f "$SCRIPT_DIR"/snapshot-completo-*.txt
rm -f "$SCRIPT_DIR"/snapshot-resumen-*.txt

# ═══════════════════════════════════════════════════════════════
# Configuración de proyectos
# ═══════════════════════════════════════════════════════════════
# Formato: "nombre:tipo:base_dir"
#   tipo: elixir | go | bash

LASACA="$HOME/workspace/github"
LASACA="$HOME/workspace/github/lasaca"

ALL_PROJECTS=(
  # ── ~/workspace/github/ ──
  "apero:elixir:$LASACA"
  "alaja:elixir:$LASACA"
  "pote:elixir:$LASACA"
  "arrea:elixir:$LASACA"
  "trebejo:elixir:$LASACA"
  "botica:elixir:$LASACA"
  "candil:elixir:$LASACA"
  "elpaso:elixir:$LASACA"

  # ── ~/workspace/github/lasaca/ ──
  "ropero:bash:$LASACA"
  "gunter:bash:$LASACA"
  "arriero:go:$LASACA"
  "posadero:elixir:$LASACA"
)

# Filtro por argumentos de CLI
if [ $# -gt 0 ]; then
  PROYECTOS=()
  for wanted in "$@"; do
    for entry in "${ALL_PROJECTS[@]}"; do
      IFS=':' read -r name _tipo _base <<< "$entry"
      [ "$name" = "$wanted" ] && PROYECTOS+=("$entry")
    done
  done
  if [ ${#PROYECTOS[@]} -eq 0 ]; then
    echo "Ningún proyecto coincide con: $*"
    echo "Disponibles:"
    for entry in "${ALL_PROJECTS[@]}"; do
      IFS=':' read -r name tipo _base <<< "$entry"
      printf "  %-12s (%s)\n" "$name" "$tipo"
    done
    exit 1
  fi
else
  PROYECTOS=("${ALL_PROJECTS[@]}")
fi

# ═══════════════════════════════════════════════════════════════
# Utilidades
# ═══════════════════════════════════════════════════════════════

header() {
  echo ""
  echo "################################################################"
  echo "## $*"
  echo "################################################################"
  echo ""
}

file_block() {
  local f="$1"
  echo ""
  echo "----- $f -----"
  if [ -f "$f" ]; then
    cat "$f"
  else
    echo "(no existe: $f)"
  fi
  echo "----- fin $f -----"
}

# ═══════════════════════════════════════════════════════════════
# Extractores por tipo
# ═══════════════════════════════════════════════════════════════

extract_elixir() {
  local name="$1" proj="$2"

  header "PROYECTO: $name (Elixir)"
  echo "Path: $proj"
  echo "Fecha: $(date -Iseconds)"

  cd "$proj" || return 1

  # ── Metadatos ──────────────────────────────────────────────
  header "$name / metadatos"
  file_block mix.exs
  file_block config/config.exs
  file_block config/runtime.exs
  file_block config/test.exs
  file_block README.md
  file_block .formatter.exs
  file_block .tool-versions

  # ── Estructura ─────────────────────────────────────────────
  header "$name / estructura"
  echo "=== Ficheros .ex en lib/ ==="
  find lib -type f -name "*.ex" 2>/dev/null | sort
  echo ""
  echo "=== Ficheros en test/ ==="
  find test -type f 2>/dev/null | sort
  echo ""
  echo "=== Ficheros en priv/ ==="
  find priv -type f 2>/dev/null | head -20 | sort
  echo ""
  echo "=== LOC por fichero (top 50) ==="
  find lib -name "*.ex" -exec wc -l {} + 2>/dev/null | sort -n | tail -50
  echo ""
  echo "=== Versión Elixir/OTP ==="
  elixir --version 2>/dev/null

  # ── Contenido: lib/ ────────────────────────────────────────
  header "$name / lib/ completo"
  find lib -type f -name "*.ex" 2>/dev/null | sort | while read -r f; do
    file_block "$f"
  done

  # ── Contenido: test/ ───────────────────────────────────────
  header "$name / test/ completo"
  find test -type f \( -name "*.ex" -o -name "*.exs" \) 2>/dev/null | sort | while read -r f; do
    file_block "$f"
  done

  # ── Mix tasks ──────────────────────────────────────────────
  if [ -d lib/mix ]; then
    header "$name / mix tasks"
    find lib/mix -type f -name "*.ex" 2>/dev/null | sort | while read -r f; do
      file_block "$f"
    done
  fi

  # ── Baseline ───────────────────────────────────────────────
  if [ -f mix.exs ]; then
    header "$name / baseline"
    echo "=== mix deps.get ==="
    timeout 120 mix deps.get 2>&1 | tail -15
    echo ""
    echo "=== mix compile --warnings-as-errors ==="
    timeout 120 mix compile --warnings-as-errors 2>&1 | tail -20
    echo ""
    echo "=== mix test ==="
    timeout 180 mix test 2>&1 | tail -40
    echo ""
    echo "=== mix credo --strict ==="
    timeout 60 mix credo --strict 2>&1 | tail -30
  fi
}

extract_go() {
  local name="$1" proj="$2"

  header "PROYECTO: $name (Go)"
  echo "Path: $proj"
  echo "Fecha: $(date -Iseconds)"

  cd "$proj" || return 1

  # ── Metadatos ──────────────────────────────────────────────
  header "$name / metadatos"
  file_block go.mod
  file_block go.sum
  file_block README.md
  file_block Makefile
  file_block .tool-versions

  # ── Estructura ─────────────────────────────────────────────
  header "$name / estructura"
  echo "=== Ficheros .go ==="
  find . -type f -name "*.go" 2>/dev/null | grep -v "/vendor/" | sort
  echo ""
  echo "=== Directorios (raíz + nivel 2) ==="
  find . -maxdepth 2 -type d 2>/dev/null | grep -v "/vendor/" | sort
  echo ""
  echo "=== LOC por fichero ==="
  find . -name "*.go" -not -path "*/vendor/*" -exec wc -l {} + 2>/dev/null | sort -n | tail -40

  # ── Contenido ──────────────────────────────────────────────
  header "$name / código completo"
  find . -type f -name "*.go" 2>/dev/null | grep -v "/vendor/" | sort | while read -r f; do
    file_block "$f"
  done

  # ── Configs ────────────────────────────────────────────────
  header "$name / configs"
  for f in $(find . -maxdepth 2 -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.toml" -o -name "*.json" \) 2>/dev/null | grep -v vendor | grep -v node_modules | head -20); do
    file_block "$f"
  done

  # ── Baseline ───────────────────────────────────────────────
  header "$name / baseline"
  if command -v go >/dev/null 2>&1; then
    echo "=== go version ==="
    go version 2>&1
    echo ""
    echo "=== go build ./... ==="
    timeout 120 go build ./... 2>&1 | tail -20
    echo ""
    echo "=== go test ./... ==="
    timeout 120 go test ./... 2>&1 | tail -30
  else
    echo "(go no está instalado)"
  fi
}

extract_bash() {
  local name="$1" proj="$2"

  header "PROYECTO: $name (Bash)"
  echo "Path: $proj"
  echo "Fecha: $(date -Iseconds)"

  cd "$proj" || return 1

  # ── Metadatos ──────────────────────────────────────────────
  header "$name / metadatos"
  file_block README.md
  file_block .tool-versions
  file_block Makefile

  # ── Estructura ─────────────────────────────────────────────
  header "$name / estructura"
  echo "=== Listado raíz ==="
  ls -la
  echo ""
  echo "=== Todos los .sh (hasta nivel 3) ==="
  find . -maxdepth 3 -type f -name "*.sh" 2>/dev/null | sort
  echo ""
  echo "=== Ficheros ejecutables ==="
  find . -maxdepth 3 -type f -executable 2>/dev/null | sort
  echo ""
  echo "=== Todos los ficheros relevantes ==="
  find . -maxdepth 3 -type f \( \
    -name "*.sh" -o -name "*.bash" -o -name "*.zsh" \
    -o -name "*.md" -o -name "*.yaml" -o -name "*.yml" \
    -o -name "*.toml" -o -name "*.json" -o -name "*.conf" \
  \) 2>/dev/null | sort | head -100
  echo ""
  echo "=== LOC por fichero de código ==="
  find . -maxdepth 3 -type f \( -name "*.sh" -o -name "*.bash" -o -name "*.zsh" \) \
    -exec wc -l {} + 2>/dev/null | sort -n | tail -50

  # ── Entry point ────────────────────────────────────────────
  header "$name / entry point"
  for f in "$name" "bin/$name" "$name.sh"; do
    [ -f "$f" ] && file_block "$f"
  done

  # ── Carpetas de módulos ────────────────────────────────────
  for d in "$name.d" "bin" "lib" "scripts" "modules"; do
    if [ -d "$d" ]; then
      header "$name / $d/"
      find "$d" -maxdepth 2 -type f \( -name "*.sh" -o -name "*.bash" -o -name "$name" \) 2>/dev/null | sort | while read -r f; do
        file_block "$f"
      done
    fi
  done

  # ── Configs ────────────────────────────────────────────────
  header "$name / configs"
  for f in $(find . -maxdepth 2 -type f \( \
      -name "*.yaml" -o -name "*.yml" -o -name "*.toml" \
      -o -name "*.json" -o -name "*.jsonc" -o -name "*.conf" \
    \) 2>/dev/null | grep -v node_modules | head -20); do
    file_block "$f"
  done

  # ── Baseline ───────────────────────────────────────────────
  header "$name / baseline"
  if command -v shellcheck >/dev/null 2>&1 && [ -f "$name" ]; then
    echo "=== shellcheck $name ==="
    shellcheck "$name" 2>&1 | head -30
  else
    echo "(shellcheck no disponible, o no hay entry point)"
  fi
}

# ═══════════════════════════════════════════════════════════════
# Loop principal
# ═══════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════"
echo "  SNAPSHOT lasaca"
echo "  Inicio:    $(date -Iseconds)"
echo "  Output:    $SCRIPT_DIR"
echo "  Proyectos: ${#PROYECTOS[@]}"
echo "═══════════════════════════════════════════════════════════"
echo ""

for entry in "${PROYECTOS[@]}"; do
  IFS=':' read -r name tipo base <<< "$entry"
  proj="$base/$name"
  snap_file="$SCRIPT_DIR/snap-${name}.txt"

  printf "→ %-12s (%s) — %s\n" "$name" "$tipo" "$proj"

  {
    echo "SNAPSHOT generado: $(date -Iseconds)"
    echo "Proyecto: $name"
    echo "Tipo: $tipo"
    echo "Path: $proj"
    echo ""

    if [ ! -d "$proj" ]; then
      header "!! DIRECTORIO NO EXISTE: $proj"
    else
      case "$tipo" in
        elixir) extract_elixir "$name" "$proj" ;;
        go)     extract_go     "$name" "$proj" ;;
        bash)   extract_bash   "$name" "$proj" ;;
        *)      header "TIPO DESCONOCIDO: $tipo" ;;
      esac
    fi

    echo ""
    echo "########## FIN DEL SNAPSHOT: $name ##########"
  } > "$snap_file"

  lines=$(wc -l < "$snap_file")
  printf "   ✓ %-12s → %-32s (%s líneas)\n" "$name" "$(basename "$snap_file")" "$lines"
done

# ═══════════════════════════════════════════════════════════════
# Snapshot completo (concatenación de los individuales)
# ═══════════════════════════════════════════════════════════════

echo ""
echo "→ Concatenando snapshot completo..."

{
  echo "################################################################"
  echo "## SNAPSHOT COMPLETO — ecosistema lasaca"
  echo "## Generado:  $(date -Iseconds)"
  echo "## Proyectos: ${#PROYECTOS[@]}"
  echo "## Script:    $SCRIPT_DIR"
  echo "################################################################"

  for entry in "${PROYECTOS[@]}"; do
    IFS=':' read -r name tipo base <<< "$entry"
    snap_file="$SCRIPT_DIR/snap-${name}.txt"

    [ -f "$snap_file" ] || continue

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "════  $name ($tipo)"
    echo "════════════════════════════════════════════════════════════════"
    cat "$snap_file"
  done

  echo ""
  echo "########## FIN DEL SNAPSHOT COMPLETO ##########"
} > "$FULL_OUT"

full_lines=$(wc -l < "$FULL_OUT")

# ═══════════════════════════════════════════════════════════════
# Resumen
# ═══════════════════════════════════════════════════════════════

{
  echo "RESUMEN DE SNAPSHOT"
  echo "Generado:   $(date -Iseconds)"
  echo "Script dir: $SCRIPT_DIR"
  echo ""
  printf "%-12s %-8s %10s  %s\n" "PROYECTO" "TIPO" "LÍNEAS" "FICHERO"
  printf "%-12s %-8s %10s  %s\n" "────────" "────" "──────" "───────"

  for entry in "${PROYECTOS[@]}"; do
    IFS=':' read -r name tipo base <<< "$entry"
    snap_file="$SCRIPT_DIR/snap-${name}.txt"

    if [ -f "$snap_file" ]; then
      lines=$(wc -l < "$snap_file")
      printf "%-12s %-8s %10s  %s\n" "$name" "$tipo" "$lines" "$(basename "$snap_file")"
    else
      printf "%-12s %-8s %10s  %s\n" "$name" "$tipo" "0" "(no generado)"
    fi
  done

  echo ""
  echo "Total proyectos: ${#PROYECTOS[@]}"
  echo ""
  echo "Snapshot completo:  $FULL_OUT"
  echo "  Total líneas:     $full_lines"
} > "$SUMMARY_OUT"

# ═══════════════════════════════════════════════════════════════
# Fin
# ═══════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  FIN"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Snapshot completo:"
echo "  $FULL_OUT  ($full_lines líneas)"
echo ""
echo "Resumen:"
echo "  $SUMMARY_OUT"
echo ""
echo "Snapshots individuales:"
for f in "$SCRIPT_DIR"/snap-*.txt; do
  [ -f "$f" ] || continue
  printf "  %-32s %8s líneas\n" "$(basename "$f")" "$(wc -l < "$f")"
done
echo ""

cat "$SUMMARY_OUT"