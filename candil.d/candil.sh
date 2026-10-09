#!/usr/bin/env bash
# :: candil.d/candil.sh — instalador y verificador de candil (librería)
# ::
# :: Contrato de zaguan: --install / --check / --help.
# ::
# ::   bash candil.d/candil.sh --install   deps.get + compile
# ::   bash candil.d/candil.sh --check     verifica que compila
# ::   bash candil.d/candil.sh --help      esta ayuda
# ::
# :: candil es una LIBRERÍA: no tiene ejecutable ni se enlaza en ~/.local/bin.
# :: Lo que se instala aquí es el código compilado dentro del repo, para que los
# :: proyectos que dependen de él lo encuentren.
# ::
# :: Códigos de salida: 0 ok · 1 fallo · 2 opción desconocida · 3 falta herramienta
# ::
# :: Este script NO instala Erlang ni Elixir: comprueba que estén y, si faltan,
# :: dice qué ejecutar. Instalar un toolchain desde el script de otra tool es la
# :: forma de que nadie entienda por qué su máquina ha cambiado.

set -uo pipefail

# -----------------------------------------------------------------------------
# Resolver el path REAL de este script, atravesando symlinks.
#
# No es un detalle: si este .sh se acaba enlazando desde ~/.local/bin, `dirname`
# daría ~/.local/bin y REPO saldría como ~/.local. Que es exactamente el fallo
# que no se diagnostica: el error dice "no hay mix.exs en /Users/tu/.local".
#
# `readlink -f` no es portable (BSD no lo tiene). Un bucle de `readlink` sí.
# -----------------------------------------------------------------------------
_resolve_self() {
    local src="${BASH_SOURCE[0]}" dir
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

HERE="$(_resolve_self)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
NAME="candil"
# REPO es el padre del .d: <repo>/<name>.d/<name>.sh → <repo>
REPO="${CANDIL_REPO:-$(cd "$HERE/.." && pwd)}"

# ── salida ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; B=''; D=''; N=''
fi

ok()   { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; }
info() { printf '%s·%s %s\n' "$D" "$N" "$*"; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }

# -----------------------------------------------------------------------------
# Preflight: mix tiene que existir.
#
# Los shims de asdf van al PATH si faltan: sin ellos, `mix` no resuelve aunque
# Erlang y Elixir estén instalados, y el fallo dice "command not found", que
# apunta al sitio equivocado.
# -----------------------------------------------------------------------------
preflight() {
    case ":$PATH:" in
        *":$HOME/.asdf/shims:"*) ;;
        *)
            if [[ -d "$HOME/.asdf/shims" ]]; then
                info "shims de asdf no estaban en el PATH; se añaden para esta ejecución"
                PATH="$HOME/.asdf/shims:$PATH"
            fi
            ;;
    esac

    if ! command -v mix >/dev/null 2>&1; then
        err "mix no está instalado: $NAME no se puede compilar"
        printf '  %s\n' "solución (asdf):"
        printf '    %s\n' "git clone https://github.com/asdf-vm/asdf.git ~/.asdf"
        printf '    %s\n' "source ~/.asdf/asdf.sh   &&   asdf plugin add elixir"
        printf '    %s\n' "cd $REPO && asdf install"
        printf '  %s\n' "solución (Homebrew, macOS):"
        printf '    %s\n' "brew install erlang elixir"
        return 1
    fi

    return 0
}

# El repo tiene que ser un proyecto mix. No es "falta herramienta": es que este
# .sh no está donde debería, y eso es un fallo, no un préstamo.
check_project() {
    if [[ -f "$REPO/mix.exs" ]]; then
        return 0
    fi
    err "no hay mix.exs en $REPO"
    info "  ¿está $NAME.d en su sitio dentro del repo?"
    return 1
}

# Corre mix en silencio y, si falla, saca las últimas 20 líneas.
#
# Veinte, no todas: la traza de compilación de Elixir entera son cientos de
# líneas y el error útil ("undefined function", "could not find dependency")
# está siempre al final.
run_mix() {
    local out rc
    out=$(cd "$REPO" && "$@" 2>&1)
    rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$out" | tail -20 >&2
    fi
    return $rc
}

# ── --install ────────────────────────────────────────────────────────────────
do_install() {
    step "Preflight"
    if ! preflight; then
        err ""
        err "No se continúa: $NAME necesita mix (Elixir) para compilarse."
        return 3
    fi
    check_project || return 1
    info "elixir $(elixir --version 2>/dev/null | tail -1 | sed 's/^Elixir //')"
    info "repos  $REPO"

    step "Dependencias"
    if ! run_mix mix deps.get; then
        err "mix deps.get falló"
        err "  lo normal: una dependencia privada sin acceso de lectura"
        err "  ssh -T git@github.com   # debe responder: Hi <usuario>!"
        return 1
    fi
    ok "dependencias descargadas"

    step "Compilación"
    if ! run_mix mix compile; then
        err "mix compile falló"
        return 1
    fi
    ok "compilado"

    # Sin ejecutable ni symlink: es una librería. Se dice, para que nadie
    # espere un binario que esta variante no crea por diseño.
    step "Verificación"
    do_check
}

# ── --check ──────────────────────────────────────────────────────────────────
do_check() {
    local fails=0

    step "Toolchain"
    if ! preflight; then
        err "$NAME no puede compilarse sin mix"
        return 3
    fi
    ok "mix $(mix --version 2>/dev/null | head -1)"

    step "Proyecto"
    if check_project; then
        ok "mix.exs encontrado ($REPO)"
    else
        fails=$((fails + 1))
    fi

    step "Compilación"
    if run_mix mix compile; then
        ok "compila"
    else
        err "mix compile falló"
        fails=$((fails + 1))
    fi

    step "Resumen"
    if (( fails == 0 )); then
        ok "$NAME compila correctamente (librería: no hay binario que enlazar)"
        return 0
    fi
    err "$fails comprobación(es) fallida(s)"
    return 1
}

usage() {
    cat <<EOF
$NAME — librería Elixir

  Es una librería, NO un ejecutable: este script compila el código dentro del
  repo y no crea ni enlaza nada en ~/.local/bin. Lo consume, como dependencia,
  quien la declara en su mix.exs.

USO:
  bash $SELF --install   mix deps.get + mix compile (idempotente)
  bash $SELF --check     verifica que compila, sin tocar nada
  bash $SELF --help      esta ayuda

VARIABLES DE ENTORNO:
  CANDIL_REPO        raíz del repo (default: padre de este .d)

CÓDIGOS DE SALIDA:
  0  ok
  1  fallo (deps, compilación o mix.exs ausente)
  2  opción desconocida
  3  falta herramienta (mix / Elixir no están)
EOF
}

case "${1:-}" in
    --install) do_install ;;
    --check)   do_check ;;
    --help|-h) usage ;;
    *)
        err "opción desconocida: ${1:-<ninguna>}"
        usage
        exit 2
        ;;
esac
