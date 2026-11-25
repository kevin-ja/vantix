#!/usr/bin/env bash
# Paso 3 · Crear el entorno de Python (ver pipelines/training/README.md).
#
#   bash pipelines/training/setup/paso3.sh
#
# Hace lo mismo que `make venv`, sin depender del Makefile: crea .venv/ en la raíz del repo con Python 3.11 e
# instala requirements-dev.txt. Si ya existe, solo completa lo que falte.
# Antes de cambiar algo muestra qué hará y pregunta (y/n).
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

PYTHON_VERSION="3.11"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
VENV="$ROOT/.venv"
PY="$VENV/bin/python"
REQS="$ROOT/requirements-dev.txt"

# --- salida -------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi
stage() { printf '\n%s━━ Etapa %s/4 · %s ━━%s\n' "$BOLD" "$1" "$2" "$OFF"; }
title() { printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; }
info()  { printf '  → %s\n' "$*"; }
ok()    { printf '  %s✔%s %s\n' "$GREEN" "$OFF" "$*"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$OFF" "$*"; }
err()   { printf '  %s✘%s %s\n' "$RED" "$OFF" "$*" >&2; }
die()   { err "$*"; exit 1; }

LOG=""; SPIN_PID=""
cleanup() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; fi
  if [ -n "$LOG" ]; then rm -f "$LOG"; fi
}
show_log() { sed 's/^/    /' "$LOG" >&2; }

# spin "qué está haciendo" comando… -> muestra la espera con los segundos y borra la línea al terminar.
# Devuelve el resultado del comando; su salida queda en $LOG.
spin() {
  local msg="$1" rc n=0 start=$SECONDS frames='|/-\'
  shift
  if [ ! -t 1 ]; then "$@" >"$LOG" 2>&1 </dev/null; return; fi
  "$@" >"$LOG" 2>&1 </dev/null &
  SPIN_PID=$!
  while kill -0 "$SPIN_PID" 2>/dev/null; do
    printf '\r  %s %s… %ss\033[K' "${frames:$((n % 4)):1}" "$msg" "$((SECONDS - start))"
    n=$((n + 1))
    sleep 0.2
  done
  wait "$SPIN_PID"
  rc=$?
  SPIN_PID=""
  printf '\r\033[K'
  return "$rc"
}

# confirm "pregunta" -> 0 si responde y, 1 si responde n
confirm() {
  local answer
  while true; do
    printf '%s%s [y/n]: %s' "$BOLD" "$1" "$OFF"
    read -r answer || return 1
    case "$answer" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *)   echo "Responde y o n." ;;
    esac
  done
}

# --- comprobaciones -----------------------------------------------------------
python_version() { "$PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null; }

# Las librerías están al día si uv no cambiaría nada. Deja el detalle en $LOG.
libs_ready() {
  spin "Comprobando las librerías" uv pip install --dry-run --python "$PY" -r "$REQS" \
    && grep "Would make no changes" "$LOG" >/dev/null
}

# Lo que usan los comandos de la guía (descargar, verificar y subir el dataset).
try_imports() { "$PY" -c 'import boto3, mlflow, pandas, pyarrow, sagemaker, sklearn'; }

# --- flujo --------------------------------------------------------------------
main() {
  local do_create=0 do_recreate=0 do_libs=0 total i=0 version

  if [ $# -gt 0 ]; then die "Este script no recibe opciones."; fi
  if [ "$(id -u)" -eq 0 ]; then die "Córrelo sin sudo: el entorno debe quedar en tu usuario."; fi
  if [ ! -t 0 ]; then die "Córrelo en una terminal interactiva: necesita preguntarte antes de cambiar algo."; fi
  command -v uv >/dev/null 2>&1 || die "Falta uv: corre primero paso1.sh."
  [ -f "$REQS" ] || die "No se encontró $REQS: el script debe estar en pipelines/training/setup/ del repo."

  LOG="$(mktemp)" || die "No se pudo crear un archivo temporal."
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  stage 1 "Revisar qué tienes"
  ok "uv: $(uv --version | awk '{print $2}')"
  if [ ! -e "$VENV" ] && [ ! -L "$VENV" ]; then
    err "Entorno .venv: no existe"
    do_create=1; do_libs=1
  elif [ ! -f "$VENV/pyvenv.cfg" ]; then
    die "$VENV existe, pero no es un entorno de Python. No se cambió nada: muévelo o bórralo y vuelve a correr este script."
  else
    version="$(python_version)"
    case "$version" in
      "$PYTHON_VERSION".*)
        ok "Entorno .venv: existe, con Python $version"
        if libs_ready; then
          ok "Librerías: al día con requirements-dev.txt"
        else
          err "Librerías: faltan o tienen otra versión"
          do_libs=1
        fi ;;
      *)
        err "Entorno .venv: tiene Python ${version:-que no funciona} (se necesita $PYTHON_VERSION)"
        do_recreate=1; do_libs=1 ;;
    esac
  fi

  total=$((do_create + do_recreate + do_libs))
  stage 2 "Confirmar los cambios"
  if [ "$total" -eq 0 ]; then
    ok "No hay nada que cambiar"
  else
    echo "  Falta ($total):"
    if [ "$do_create" -eq 1 ]; then
      echo "  - Crear $VENV con Python $PYTHON_VERSION (si no lo tienes, uv lo descarga)"
    fi
    if [ "$do_recreate" -eq 1 ]; then
      echo "  - BORRAR $VENV y crearlo de nuevo con Python $PYTHON_VERSION (si no lo tienes, uv lo descarga)"
    fi
    if [ "$do_libs" -eq 1 ]; then
      echo "  - Instalar las librerías de requirements-dev.txt:"
      sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e 's/^/      /' "$REQS"
    fi
    echo
    if ! confirm "¿Proceder?"; then echo "No se cambió nada."; exit 1; fi
  fi

  stage 3 "Configurar"
  if [ "$total" -eq 0 ]; then ok "Nada que hacer"; fi
  if [ "$((do_create + do_recreate))" -gt 0 ]; then
    i=$((i + 1)); title "[$i/$total] Crear el entorno"
    if [ "$do_recreate" -eq 1 ]; then
      rm -rf "$VENV" || die "No se pudo borrar $VENV."
      ok "Entorno anterior borrado"
    fi
    uv venv --python "$PYTHON_VERSION" "$VENV" || die "No se pudo crear el entorno (ver el error arriba)."
    ok "Entorno .venv creado con Python $(python_version)"
  fi
  if [ "$do_libs" -eq 1 ]; then
    i=$((i + 1)); title "[$i/$total] Instalar las librerías"
    info "La primera vez puede tardar unos minutos: descarga las librerías y sus dependencias."
    uv pip install --python "$PY" -r "$REQS" \
      || die "No se pudieron instalar (ver el error arriba). Vuelve a correr este script: continúa desde aquí."
    ok "Librerías instaladas"
  fi

  stage 4 "Comprobar"
  version="$(python_version)"
  case "$version" in
    "$PYTHON_VERSION".*) ok "Python: $version" ;;
    *) die "El entorno tiene Python ${version:-que no funciona} y se necesita $PYTHON_VERSION." ;;
  esac
  if libs_ready; then
    ok "Librerías: al día con requirements-dev.txt"
  else
    show_log
    die "Las librerías no coinciden con requirements-dev.txt."
  fi
  if spin "Cargando las librerías" try_imports; then
    ok "Librerías: cargan sin errores"
  else
    show_log
    die "Alguna librería no carga (ver el error arriba)."
  fi
  title "Todo listo. Puedes seguir con el Paso 4 del README."
}

main "$@"
