#!/usr/bin/env bash
# Paso 5 · Descargar el dataset (ver pipelines/training/README.md).
#
#   bash pipelines/training/setup/paso5.sh
#
# Hace lo mismo que `make get-data`, sin depender del Makefile: descarga data/data.parquet del GitHub Release y lo
# verifica (SHA-256 + las mismas reglas que el pipeline, con scripts/check_data.py).
# No necesita cuenta de GitHub ni de AWS. Antes de cambiar algo muestra qué hará y pregunta (y/n).
# La descarga solo reemplaza al archivo actual si llegó completa; si algo falla, lo que había queda igual.
# Otro origen: DATA_REPO=usuario/repo DATA_RELEASE=etiqueta bash …/paso5.sh
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
# Los releases no se copian a los forks: por defecto se usa el repo original.
DATA_REPO="${DATA_REPO:-kevin-ja/vantix}"
DATA_RELEASE="${DATA_RELEASE:-data-v1}"
URL="https://github.com/$DATA_REPO/releases/download/$DATA_RELEASE"
PY="$ROOT/.venv/bin/python"
CHECK="$ROOT/scripts/check_data.py"
DATA="$ROOT/data/data.parquet"
SHA="$DATA.sha256"

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
  rm -f "$DATA.part.$$" "$SHA.part.$$"
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

# --- checksum -----------------------------------------------------------------
valid_sha() { printf '%s\n' "$1" | grep -E '^[0-9a-f]{64}$' >/dev/null; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'
}

EXPECTED=""   # SHA-256 publicado en el release
read_published_sha() {
  if ! spin "Leyendo el SHA-256 publicado" \
      curl -fsSL --connect-timeout 20 --retry 3 -o "$SHA.part.$$" "$URL/data.parquet.sha256"; then
    return 1
  fi
  EXPECTED="$(awk 'NR == 1 {print $1}' "$SHA.part.$$")"
  valid_sha "$EXPECTED" || die "El SHA-256 publicado en $URL no es válido. No se cambió nada."
}

# --- flujo --------------------------------------------------------------------
main() {
  local actual="" replace=0 pending=0 offline=0

  if [ $# -gt 0 ]; then die "Este script no recibe opciones."; fi
  if [ "$(id -u)" -eq 0 ]; then die "Córrelo sin sudo: los archivos deben quedar en tu usuario."; fi
  if [ ! -t 0 ]; then die "Córrelo en una terminal interactiva: necesita preguntarte antes de cambiar algo."; fi
  printf '%s\n' "$DATA_REPO/$DATA_RELEASE" | grep -E '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' >/dev/null \
    || die "DATA_REPO o DATA_RELEASE no son válidos: $DATA_REPO, $DATA_RELEASE"
  command -v curl >/dev/null 2>&1 || die "Falta curl."
  [ -f "$CHECK" ] || die "No se encontró $CHECK: el script debe estar en pipelines/training/setup/ del repo."
  [ -x "$PY" ] || die "Falta el entorno de Python (.venv): corre primero paso3.sh."
  if [ -d "$DATA" ] || [ -d "$SHA" ]; then die "$DATA o su .sha256 es una carpeta. No se cambió nada."; fi

  LOG="$(mktemp)" || die "No se pudo crear un archivo temporal."
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  stage 1 "Revisar qué tienes"
  ok "Entorno de Python: existe"
  mkdir -p "$ROOT/data" || die "No se pudo crear $ROOT/data."
  if read_published_sha; then
    ok "Release $DATA_RELEASE de $DATA_REPO: disponible"
  else
    show_log
    offline=1
  fi

  if [ -f "$DATA" ]; then
    spin "Calculando el SHA-256 de tu archivo" sha256_of "$DATA" || { show_log; die "No se pudo leer $DATA."; }
    actual="$(tail -n 1 "$LOG")"
  fi
  if [ "$offline" -eq 1 ]; then
    # Sin release no se puede descargar, pero un archivo ya descargado y completo sirve igual.
    if [ -n "$actual" ] && [ -f "$SHA" ] && [ "$(awk 'NR == 1 {print $1}' "$SHA")" = "$actual" ]; then
      warn "No se pudo consultar $URL, pero tu archivo está completo: se usa ese"
    else
      die "No se pudo consultar $URL. Revisa tu conexión (y DATA_REPO / DATA_RELEASE) y vuelve a correr este script."
    fi
  elif [ -z "$actual" ]; then
    err "data/data.parquet: no existe"
    pending=1
  elif [ "$actual" = "$EXPECTED" ]; then
    ok "data/data.parquet: existe y está completo"
    # El .sha256 puede faltar o ser de otra versión aunque los datos estén bien: se repone sin descargar los datos.
    if [ ! -f "$SHA" ] || [ "$(awk 'NR == 1 {print $1}' "$SHA")" != "$EXPECTED" ]; then
      mv "$SHA.part.$$" "$SHA" || die "No se pudo escribir $SHA."
      ok "data/data.parquet.sha256: repuesto"
    fi
  else
    err "data/data.parquet: existe, pero está incompleto o es de otra versión"
    pending=1; replace=1
  fi

  stage 2 "Confirmar los cambios"
  if [ "$pending" -eq 0 ]; then
    ok "No hay nada que descargar"
  else
    echo "  Falta (1):"
    echo "  - Descargar data/data.parquet (~20 MB) de $URL"
    if [ "$replace" -eq 1 ]; then echo "      tu archivo actual se guarda como data/data.parquet.anterior.<fecha>"; fi
    echo
    confirm "¿Proceder?" || { echo "No se cambió nada."; exit 1; }
  fi

  stage 3 "Descargar"
  if [ "$pending" -eq 0 ]; then
    ok "Nada que hacer"
  else
    info "Descargando data.parquet"
    curl -fL --connect-timeout 20 --retry 3 --progress-bar -o "$DATA.part.$$" "$URL/data.parquet" \
      || die "La descarga falló (ver el error arriba). Lo que tenías queda igual; vuelve a correr este script."
    spin "Verificando el SHA-256" sha256_of "$DATA.part.$$" || { show_log; die "No se pudo leer la descarga."; }
    actual="$(tail -n 1 "$LOG")"
    if [ "$actual" != "$EXPECTED" ]; then
      echo "    esperado: $EXPECTED" >&2
      echo "    recibido: $actual" >&2
      die "La descarga llegó incompleta o dañada. Lo que tenías queda igual; vuelve a correr este script."
    fi
    ok "Descarga completa (SHA-256 correcto)"
    if [ "$replace" -eq 1 ]; then
      mv "$DATA" "$DATA.anterior.$(date +%Y%m%d%H%M%S)" || die "No se pudo guardar tu archivo actual. No se cambió nada."
    fi
    mv "$DATA.part.$$" "$DATA" && mv "$SHA.part.$$" "$SHA" || die "No se pudo guardar el dataset en data/."
    ok "Guardado en data/data.parquet"
  fi

  stage 4 "Comprobar"
  info "Mismas reglas que el pipeline de entrenamiento (scripts/check_data.py):"
  echo
  "$PY" "$CHECK" "$DATA" || { echo; die "El dataset no pasó la comprobación (ver el error arriba)."; }
  title "Todo listo. Puedes seguir con el Paso 6 del README."
  info "El dataset se sube a S3 más adelante, cuando la infraestructura ya exista."
}

main "$@"
