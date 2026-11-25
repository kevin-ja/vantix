#!/usr/bin/env bash
# Paso 2 · Configurar el monitoreo (ver monitorization/README.md).
#
#   bash monitorization/setup/paso2.sh --alert-email=ana@ejemplo.com
#   bash monitorization/setup/paso2.sh                  # conserva el correo actual, o lo pregunta si no hay
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Guarda en monitorization/infra/terraform.tfvars (no se sube a git) el correo que recibe las alertas y el bucket de
# datos, que se lee de la infraestructura. Conserva las demás variables y guarda una copia. No cambia nada en AWS.
# El correo no es una credencial, pero es un dato personal: por eso no va en el repo. Antes de cambiar algo pregunta (y/n).
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
NAME="vantix-monitoring"     # prefijo de los recursos: los workflows lo esperan así
DIR="monitorization/infra"
KEY="monitorization/terraform.tfstate"
TFVARS="$ROOT/$DIR/terraform.tfvars"
EMAIL=""

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
    || die "No existe el perfil de AWS '$PROFILE': corre primero pipelines/training/setup/paso2.sh."
  if ! spin "Comprobando la sesión de AWS" whoami_aws; then
    err "Sesión de AWS: vencida o sin iniciar"
    confirm "¿Iniciar sesión en AWS? (se abre el navegador)" || die "Sin sesión de AWS no se puede continuar."
    aws sso login --profile "$PROFILE" || die "No se pudo iniciar sesión (ver el error arriba). Vuelve a correr pipelines/training/setup/paso2.sh."
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
  command -v aws >/dev/null 2>&1 || die "Falta AWS CLI: corre primero pipelines/training/setup/paso1.sh."
  WORK="$(mktemp -d)" || die "No se pudo crear una carpeta temporal."
  LOG="$WORK/log"
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  use_profile
}

check_state_bucket() {
  spin "Buscando el bucket del estado" aws s3api head-bucket --bucket "$STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    || { show_log; die "No existe (o no es tuyo) el bucket $STATE_BUCKET: corre primero pipelines/training/setup/paso7.sh."; }
  ok "Bucket del estado: $STATE_BUCKET"
}

# --- Terraform ----------------------------------------------------------------
TERRAFORM_VERSION="1.15.8"   # exacta: la exige mlflow_server/infra/versions.tf

check_terraform() {
  local version
  if [ -x "$HOME/.local/bin/terraform" ]; then export PATH="$HOME/.local/bin:$PATH"; fi   # donde lo instala pipelines/training/setup/paso1.sh
  command -v terraform >/dev/null 2>&1 || die "Falta Terraform: corre primero pipelines/training/setup/paso1.sh."
  # Variables de la terminal que cambiarían lo que hace Terraform.
  unset TF_WORKSPACE TF_DATA_DIR TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply TF_CLI_ARGS_output
  export TF_IN_AUTOMATION=1
  version="$(terraform version | awk 'NR == 1 {sub(/^v/, "", $2); print $2}')"
  [ "$version" = "$TERRAFORM_VERSION" ] || die "Terraform es $version y se necesita $TERRAFORM_VERSION: corre primero pipelines/training/setup/paso1.sh."
  ok "Terraform: $version"
}

tf() { local dir="$1"; shift; terraform -chdir="$ROOT/$dir" "$@"; }

# tf_init <módulo> <clave del estado>
tf_init() {
  spin "Preparando Terraform en $1" tf "$1" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="key=$2" -backend-config="region=$REGION" \
    -backend-config="profile=$PROFILE" -backend-config="use_lockfile=true" \
    || { show_log; die "No se pudo preparar Terraform en $1 (ver el error arriba)."; }
  ok "$1: Terraform preparado"
}

# Deja en BUCKET el bucket de datos (output de infra/shared, ya preparado con tf_init).
BUCKET=""
read_bucket() {
  spin "Buscando el bucket de datos" tf infra/shared output -raw data_bucket \
    || { show_log; die "La infraestructura de entrenamiento no está levantada: corre primero pipelines/training/setup/paso9.sh."; }
  BUCKET="$(tail -n 1 "$LOG")"
  # Sin infraestructura, `output` puede devolver un aviso en vez del nombre.
  printf '%s\n' "$BUCKET" | grep -E '^[a-z0-9.-]{3,63}$' >/dev/null \
    || die "La infraestructura de entrenamiento no está levantada: corre primero pipelines/training/setup/paso9.sh."
  ok "Bucket de datos: $BUCKET"
}

# tfvars_values <variable>: sus valores en terraform.tfvars, uno por línea (puede haber ninguno o estar repetida).
tfvars_values() {
  [ -f "$TFVARS" ] || return 0
  awk -v key="$1" '{ line = $0; sub(/^[ \t]+/, "", line) } index(line, key) == 1 && substr(line, length(key) + 1) ~ /^[ \t]*=/ { split(line, part, "\""); print part[2] }' "$TFVARS"
}

valid_email() { printf '%s\n' "$1" | grep -E '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' >/dev/null; }

# set_value <variable> <valor>: deja una sola línea con ese valor y conserva el resto del archivo.
set_value() {
  local part
  part="$(dirname "$TFVARS")/nuevo.$$.tfvars"
  if [ -f "$TFVARS" ]; then cp -p "$TFVARS" "$part" || return 1; else ( umask 077 && : > "$part" ) || return 1; fi
  awk -v key="$1" -v new="$1 = \"$2\"" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    index(line, key) == 1 && substr(line, length(key) + 1) ~ /^[ \t]*=/ { if (!done) print new; done = 1; next }
    { print }
    END { if (!done) print new }' "$([ -f "$TFVARS" ] && printf '%s' "$TFVARS" || printf /dev/null)" > "$part" || { rm -f "$part"; return 1; }
  mv "$part" "$TFVARS"
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg current_email current_bucket set_email=0 set_bucket=0
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --alert-email=*) EMAIL="${arg#*=}"; valid_email "$EMAIL" || die "--alert-email no es válido: $EMAIL" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  [ -d "$ROOT/$DIR" ] || die "No se encontró $DIR: el script debe estar en monitorization/setup/ del repo."

  stage 1 "Revisar qué tienes"
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  current_email="$(tfvars_values alert_email)"
  current_bucket="$(tfvars_values data_bucket)"
  if [ -z "$EMAIL" ] && valid_email "$current_email"; then EMAIL="$current_email"; fi
  while [ -z "$EMAIL" ]; do
    printf '  Correo que recibirá las alertas: '
    read -r EMAIL || die "Cancelado: no se cambió nada."
    if ! valid_email "$EMAIL"; then echo "  No es un correo válido."; EMAIL=""; fi
  done
  if [ "$current_email" = "$EMAIL" ];   then ok "alert_email: $EMAIL";   else err "alert_email: falta o tiene otro valor"; set_email=1; fi
  if [ "$current_bucket" = "$BUCKET" ]; then ok "data_bucket: $BUCKET"; else err "data_bucket: falta o tiene otro valor"; set_bucket=1; fi

  stage 2 "Confirmar los cambios"
  if [ "$((set_email + set_bucket))" -eq 0 ]; then
    ok "No hay nada que cambiar"
  else
    echo "  En $DIR/terraform.tfvars (lo demás no cambia; guarda una copia):"
    if [ "$set_email" -eq 1 ]; then
      if [ -n "$current_email" ]; then echo "  - alert_email, antes: $(printf '%s' "$current_email" | paste -s -d ' ' -)"; fi
      echo "  - alert_email = \"$EMAIL\""
    fi
    if [ "$set_bucket" -eq 1 ]; then
      if [ -n "$current_bucket" ]; then echo "  - data_bucket, antes: $(printf '%s' "$current_bucket" | paste -s -d ' ' -)"; fi
      echo "  - data_bucket = \"$BUCKET\""
    fi
    echo
    confirm "¿Proceder?" || { echo "No se cambió nada."; exit 1; }
  fi

  stage 3 "Configurar"
  if [ "$((set_email + set_bucket))" -eq 0 ]; then
    ok "Nada que hacer"
  else
    if [ -f "$TFVARS" ]; then
      # Termina en .tfvars para que .gitignore lo excluya; Terraform solo carga terraform.tfvars.
      cp -p "$TFVARS" "$(dirname "$TFVARS")/anterior.$(date +%Y%m%d%H%M%S).tfvars" || die "No se pudo guardar la copia. No se cambió nada."
    fi
    if [ "$set_email" -eq 1 ]; then set_value alert_email "$EMAIL" || die "No se pudo escribir el archivo."; ok "alert_email: guardado"; fi
    if [ "$set_bucket" -eq 1 ]; then set_value data_bucket "$BUCKET" || die "No se pudo escribir el archivo."; ok "data_bucket: guardado"; fi
  fi

  stage 4 "Comprobar"
  [ "$(tfvars_values alert_email)" = "$EMAIL" ] && [ "$(tfvars_values data_bucket)" = "$BUCKET" ] || die "El archivo no quedó como se esperaba."
  if ! terraform fmt - < "$TFVARS" >"$LOG" 2>&1; then show_log; die "$DIR/terraform.tfvars no es un archivo válido de Terraform (ver el error arriba)."; fi
  ok "alert_email = \"$EMAIL\""
  ok "data_bucket = \"$BUCKET\""
  if [ "$set_email" -eq 1 ]; then warn "AWS pedirá confirmar ese correo cuando apliques el cambio con monitorization/setup/paso3.sh."; fi
  title "Todo listo. Puedes seguir con monitorization/setup/paso3.sh (infraestructura)."
}

main "$@"
