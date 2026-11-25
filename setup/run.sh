#!/usr/bin/env bash
# Levanta, revisa o apaga un sistema de Vantix. Lo llama el Makefile:
#
#   bash setup/run.sh up    training|inference|monitoring     levanta lo que falte, en orden
#   bash setup/run.sh check training|inference|monitoring     solo lee: qué está listo y qué falta
#   bash setup/run.sh down  training|inference|monitoring     apaga lo que cobra; no borra nada
#
# Los datos salen de .env (ver .env.example). Ninguno es una credencial. El plan está en planning-setup.md.
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail
umask 077

export ROOT SETUP_MODE SETUP_LOG
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
SETUP_MODE="$1"; SETUP_LOG=""
SYSTEM="$2"
. "$ROOT/setup/common/ui.sh"
. "$ROOT/setup/common/env.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

step_title() { sed -n 's/^# Paso: //p' "$1" | head -n 1; }

# --- inicio ---------------------------------------------------------------------
case "$SETUP_MODE" in up|check|down) ;; *) usage; exit 2 ;; esac
case "$SYSTEM" in training|inference|monitoring) ;; *) usage; exit 2 ;; esac
[ $# -eq 2 ] || { usage; exit 2; }

# Define NAME, MAKE_NAME, REQUIRED, STEPS, COST y NEXT.
. "$ROOT/setup/$SYSTEM/system.sh" || exit 1
COMMAND="make $MAKE_NAME-$SETUP_MODE"

if [ "$(id -u)" -eq 0 ]; then die "Córrelo sin sudo: tus sesiones de AWS y GitHub están en tu usuario."; fi
if [ "$SETUP_MODE" != "check" ] && [ ! -t 0 ]; then die "Córrelo en una terminal interactiva: puede necesitar preguntarte algo."; fi

# --- .env: lo primero, antes de tocar nada ---------------------------------------
if [ ! -f "$ROOT/.env" ]; then
  err "No existe .env"
  echo "  Créalo, complétalo y vuelve a correr $COMMAND:" >&2
  echo "    cp .env.example .env" >&2
  exit 1
fi
if ! env_load "$ROOT/.env" "${REQUIRED[@]}"; then
  err ".env incompleto o con errores (${#ENV_PROBLEMS[@]}):"
  for problem in "${ENV_PROBLEMS[@]}"; do echo "      $problem" >&2; done
  echo "  Corrígelo y vuelve a correr: $COMMAND" >&2
  exit 1
fi

STEPS_FOUND=()
if [ "$SETUP_MODE" = "down" ]; then STEPS="down"; fi
for step in $STEPS; do
  [ -f "$ROOT/setup/$SYSTEM/$step.sh" ] || die "Falta setup/$SYSTEM/$step.sh."
  STEPS_FOUND+=("$ROOT/setup/$SYSTEM/$step.sh")
done
[ ${#STEPS_FOUND[@]} -gt 0 ] || die "$NAME todavía no tiene pasos en setup/$SYSTEM/."

mkdir -p "$ROOT/setup/logs" || die "No se pudo crear setup/logs."
SETUP_LOG="$ROOT/setup/logs/$MAKE_NAME-$SETUP_MODE-$(date +%Y%m%d-%H%M%S).log"
: > "$SETUP_LOG" || die "No se pudo crear el registro."

# --- informe --------------------------------------------------------------------
title "$NAME · cuenta $ACCOUNT_ID · repo ${GITHUB_REPO:--}"
if [ "$SETUP_MODE" = "up" ]; then
  echo "  Se harán estos pasos, en orden. Lo que ya esté listo no se repite:"
  i=0
  for file in "${STEPS_FOUND[@]}"; do i=$((i + 1)); printf '    %2d. %s\n' "$i" "$(step_title "$file")"; done
  echo
  printf '%s\n' "$COST" | sed 's/^/  /'
  echo
  confirm "¿Empezar?" || { echo "No se cambió nada."; exit 1; }
fi

# --- pasos ----------------------------------------------------------------------
trap 'exit 130' INT TERM
total=${#STEPS_FOUND[@]}; i=0; pending=0
for file in "${STEPS_FOUND[@]}"; do
  i=$((i + 1))
  title "$(printf '[%2d/%d] %s' "$i" "$total" "$(step_title "$file")")"
  # Cada paso corre aparte: lo que cambie en su entorno no afecta a los demás.
  SETUP_COMMAND="$COMMAND" bash "$file"
  rc=$?
  if [ "$rc" -eq 130 ]; then echo; echo "Cancelado. Para continuar: $COMMAND"; exit 130; fi
  if [ "$rc" -eq 0 ]; then continue; fi
  if [ "$SETUP_MODE" = "check" ]; then pending=$((pending + 1)); continue; fi
  echo >&2
  err "Se detuvo en el paso $i de $total. Lo anterior quedó hecho."
  echo "    Detalle:       ${SETUP_LOG#"$ROOT"/}" >&2
  echo "    Para continuar: $COMMAND" >&2
  exit 1
done

if [ "$SETUP_MODE" = "check" ]; then
  if [ "$pending" -eq 0 ]; then title "$NAME: todo listo."; exit 0; fi
  title "$NAME: $pending de $total pasos con algo pendiente. Para completarlo: make $MAKE_NAME-up"
  exit 1
fi
title "$NAME: listo."
if [ "$SETUP_MODE" = "up" ]; then printf '%s\n' "$NEXT" | sed 's/^/  /'; fi
exit 0
