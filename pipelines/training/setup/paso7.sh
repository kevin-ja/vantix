#!/usr/bin/env bash
# Paso 7 · Crear el bucket del estado de Terraform (ver pipelines/training/README.md).
#
#   bash pipelines/training/setup/paso7.sh
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Misma lógica que `make bootstrap`, sin depender del Makefile: crea el bucket vantix-<cuenta>-tfstate (versionado y
# sin acceso público). Si ya existe, solo corrige lo que falte; nunca borra nada.
# No necesita credenciales: usa la sesión de tu perfil de AWS (paso2.sh). Antes de cambiar algo pregunta (y/n).
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"

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

LOG=""; SPIN_PID=""; WORK=""
cleanup() {
  if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
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

# task "qué está haciendo" "qué quedó hecho" comando… -> subpaso con ✔ o ✘ y el error exacto.
task() {
  local doing="$1" done_msg="$2"
  shift 2
  if spin "$doing" "$@"; then ok "$done_msg"; return 0; fi
  err "$doing: falló"
  show_log
  return 1
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

valid_profile() { printf '%s\n' "$1" | grep -E '^[A-Za-z0-9._-]+$' >/dev/null; }

# --- AWS ----------------------------------------------------------------------
ACCOUNT_ID=""; STATE_BUCKET=""

# El perfil manda: las llaves u otro perfil activos en la terminal podrían apuntar a otra cuenta.
use_profile() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
  export AWS_PROFILE="$PROFILE" AWS_PAGER=""
}

whoami_aws() { aws sts get-caller-identity --profile "$PROFILE" --query Account --output text; }

check_aws() {
  env -u AWS_PROFILE aws configure list-profiles 2>/dev/null | grep -xF -- "$PROFILE" >/dev/null \
    || die "No existe el perfil de AWS '$PROFILE': corre primero paso2.sh."
  if ! spin "Comprobando la sesión de AWS" whoami_aws; then
    err "Sesión de AWS: vencida o sin iniciar"
    confirm "¿Iniciar sesión en AWS? (se abre el navegador)" || die "Sin sesión de AWS no se puede continuar."
    aws sso login --profile "$PROFILE" || die "No se pudo iniciar sesión (ver el error arriba). Vuelve a correr paso2.sh."
    spin "Comprobando la sesión de AWS" whoami_aws || { show_log; die "AWS no respondió."; }
  fi
  ACCOUNT_ID="$(tail -n 1 "$LOG")"
  printf '%s\n' "$ACCOUNT_ID" | grep -E '^[0-9]{12}$' >/dev/null || die "AWS respondió una cuenta inesperada: $ACCOUNT_ID"
  STATE_BUCKET="vantix-$ACCOUNT_ID-tfstate"
  ok "Cuenta de AWS: $ACCOUNT_ID (perfil $PROFILE)"
}

start_checks() {
  if [ "$(id -u)" -eq 0 ]; then die "Córrelo sin sudo: tu sesión de AWS está en tu usuario."; fi
  if [ ! -t 0 ]; then die "Córrelo en una terminal interactiva: necesita preguntarte antes de cambiar algo."; fi
  command -v aws >/dev/null 2>&1 || die "Falta AWS CLI: corre primero paso1.sh."
  WORK="$(mktemp -d)" || die "No se pudo crear una carpeta temporal."
  LOG="$WORK/log"
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  use_profile
}

# --- bucket -------------------------------------------------------------------
s3() { aws s3api "$@" --bucket "$STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID"; }

BUCKET=""; VERSIONING=""; PRIVATE=""
read_bucket() {
  BUCKET="falta"; VERSIONING="falta"; PRIVATE="falta"
  if ! spin "Buscando el bucket $STATE_BUCKET" s3 head-bucket; then
    if grep -E '\(404\)|Not Found' "$LOG" >/dev/null; then return 0; fi
    show_log
    die "No se puede usar el bucket $STATE_BUCKET: existe en otra cuenta, o AWS no respondió."
  fi
  BUCKET="ok"
  spin "Comprobando el versionado" s3 get-bucket-versioning --query Status --output text || { show_log; die "No se pudo leer el versionado."; }
  if [ "$(tail -n 1 "$LOG")" = "Enabled" ]; then VERSIONING="ok"; fi
  if spin "Comprobando el acceso público" s3 get-public-access-block --output text \
      --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]'; then
    if [ "$(tail -n 1 "$LOG" | tr '\t' ' ')" = "True True True True" ]; then PRIVATE="ok"; fi
  elif ! grep 'NoSuchPublicAccessBlockConfiguration' "$LOG" >/dev/null; then
    show_log
    die "No se pudo leer el acceso público."
  fi
}

print_bucket() {
  if [ "$BUCKET" != "ok" ]; then err "Bucket $STATE_BUCKET: no existe"; return; fi
  ok "Bucket $STATE_BUCKET: existe"
  if [ "$VERSIONING" = "ok" ]; then ok "Versionado: activado"; else err "Versionado: desactivado"; fi
  if [ "$PRIVATE" = "ok" ]; then ok "Acceso público: bloqueado"; else err "Acceso público: sin bloquear"; fi
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks

  stage 1 "Revisar qué tienes"
  check_aws
  read_bucket
  print_bucket

  stage 2 "Confirmar los cambios"
  if [ "$BUCKET$VERSIONING$PRIVATE" = "okokok" ]; then
    ok "No hay nada que cambiar"
  else
    echo "  En la cuenta $ACCOUNT_ID, región $REGION:"
    if [ "$BUCKET" != "ok" ];     then echo "  - Crear el bucket $STATE_BUCKET"; fi
    if [ "$VERSIONING" != "ok" ]; then echo "  - Activar el versionado"; fi
    if [ "$PRIVATE" != "ok" ];    then echo "  - Bloquear el acceso público"; fi
    echo
    confirm "¿Proceder?" || { echo "No se cambió nada."; exit 1; }
  fi

  stage 3 "Configurar"
  if [ "$BUCKET$VERSIONING$PRIVATE" = "okokok" ]; then ok "Nada que hacer"; fi
  if [ "$BUCKET" != "ok" ]; then
    task "Creando el bucket" "Bucket creado" aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
      || die "No se pudo crear el bucket (ver el error arriba)."
  fi
  if [ "$VERSIONING" != "ok" ]; then
    task "Activando el versionado" "Versionado activado" s3 put-bucket-versioning --versioning-configuration Status=Enabled \
      || die "No se pudo activar el versionado. Vuelve a correr este script: continúa desde aquí."
  fi
  if [ "$PRIVATE" != "ok" ]; then
    task "Bloqueando el acceso público" "Acceso público bloqueado" s3 put-public-access-block --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
      || die "No se pudo bloquear el acceso público. Vuelve a correr este script: continúa desde aquí."
  fi

  stage 4 "Comprobar"
  read_bucket
  print_bucket
  [ "$BUCKET$VERSIONING$PRIVATE" = "okokok" ] || die "El bucket no quedó como se esperaba. Vuelve a correr este script."
  title "Todo listo. Puedes seguir con paso8.sh (levantar MLflow)."
}

main "$@"
