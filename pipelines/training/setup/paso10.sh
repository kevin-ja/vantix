#!/usr/bin/env bash
# Paso 10 · Subir el dataset a S3 (ver pipelines/training/README.md).
#
#   bash pipelines/training/setup/paso10.sh                              # lote 2025-04-30
#   bash pipelines/training/setup/paso10.sh --ingest-date=2025-05-31     # otra etiqueta de lote
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Misma lógica que `make upload-data`, sin depender del Makefile: verifica data/data.parquet (scripts/check_data.py) y lo
# sube (scripts/upload_raw.py) a s3://vantix-<cuenta>-data/raw/ingest_date=<fecha>/. Un lote ya subido no se sobrescribe.
# No necesita credenciales: usa la sesión de tu perfil de AWS (paso2.sh). Antes de subir pregunta (y/n).
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
INGEST_DATE="2025-04-30"
PY="$ROOT/.venv/bin/python"
DATA="$ROOT/data/data.parquet"

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

check_state_bucket() {
  spin "Buscando el bucket del estado" aws s3api head-bucket --bucket "$STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    || { show_log; die "No existe (o no es tuyo) el bucket $STATE_BUCKET: corre primero paso7.sh."; }
  ok "Bucket del estado: $STATE_BUCKET"
}

# --- Terraform ----------------------------------------------------------------
TERRAFORM_VERSION="1.15.8"   # exacta: la exige mlflow_server/infra/versions.tf

check_terraform() {
  local version
  if [ -x "$HOME/.local/bin/terraform" ]; then export PATH="$HOME/.local/bin:$PATH"; fi   # donde lo instala paso1.sh
  command -v terraform >/dev/null 2>&1 || die "Falta Terraform: corre primero paso1.sh."
  # Variables de la terminal que cambiarían lo que hace Terraform.
  unset TF_WORKSPACE TF_DATA_DIR TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply TF_CLI_ARGS_output
  export TF_IN_AUTOMATION=1
  version="$(terraform version | awk 'NR == 1 {sub(/^v/, "", $2); print $2}')"
  [ "$version" = "$TERRAFORM_VERSION" ] || die "Terraform es $version y se necesita $TERRAFORM_VERSION: corre primero paso1.sh."
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

# --- datos --------------------------------------------------------------------
valid_date() {
  printf '%s\n' "$1" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' >/dev/null \
    && "$PY" -c 'import datetime, sys; datetime.date.fromisoformat(sys.argv[1])' "$1" 2>/dev/null
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'
}

# Deja en LOT: falta | igual | distinto.
LOT=""; BUCKET=""; KEY=""
read_lot() {
  local remote
  LOT="falta"
  # Se lista (en vez de head-object) para distinguir "no está" de un error de permisos.
  spin "Buscando el lote $INGEST_DATE en S3" aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$KEY" \
    --query 'Contents[].Key' --output text || { show_log; die "No se pudo leer el bucket $BUCKET."; }
  grep -F -- "$KEY" "$LOG" >/dev/null || return 0
  spin "Comparando con tu archivo" aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query Metadata.sha256 --output text \
    || { show_log; die "No se pudo leer el lote en S3."; }
  remote="$(tail -n 1 "$LOG")"
  if [ "$remote" = "$(sha256_of "$DATA")" ]; then LOT="igual"; else LOT="distinto"; fi
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --ingest-date=*) INGEST_DATE="${arg#*=}" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  [ -x "$PY" ]   || die "Falta el entorno de Python (.venv): corre primero paso3.sh."
  [ -f "$DATA" ] || die "Falta el dataset (data/data.parquet): corre primero paso5.sh."
  valid_date "$INGEST_DATE" || die "--ingest-date debe ser una fecha real con la forma 2025-04-30: $INGEST_DATE"
  KEY="raw/ingest_date=$INGEST_DATE/data.parquet"

  stage 1 "Revisar qué tienes"
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  spin "Buscando el bucket de datos" tf infra/shared output -raw data_bucket \
    || { show_log; die "La infraestructura no está levantada: corre primero paso9.sh."; }
  BUCKET="$(tail -n 1 "$LOG")"
  # Sin infraestructura, `output` puede devolver un aviso en vez del nombre.
  printf '%s\n' "$BUCKET" | grep -E '^[a-z0-9.-]{3,63}$' >/dev/null || die "La infraestructura no está levantada: corre primero paso9.sh."
  ok "Bucket de datos: $BUCKET"
  info "Verificando el dataset (scripts/check_data.py):"
  "$PY" "$ROOT/scripts/check_data.py" "$DATA" | sed -e '/^Next step/d' -e '/^$/d' -e 's/^/    /' \
    || die "El dataset no pasó la comprobación (ver el error arriba): corre paso5.sh. No se subió nada."
  read_lot

  stage 2 "Confirmar los cambios"
  case "$LOT" in
    igual) ok "El lote $INGEST_DATE ya está en S3 y es idéntico a tu archivo: no hay nada que subir" ;;
    distinto) die "El lote $INGEST_DATE ya existe en S3 con otro archivo y no se sobrescribe. Usa otra fecha: --ingest-date=AAAA-MM-DD" ;;
    falta)
      echo "  En la cuenta $ACCOUNT_ID:"
      echo "  - Subir data/data.parquet a s3://$BUCKET/$KEY"
      warn "Un lote no se puede sobrescribir después de subirlo."
      echo
      confirm "¿Proceder?" || { echo "No se subió nada."; exit 1; } ;;
  esac

  stage 3 "Subir"
  if [ "$LOT" = "igual" ]; then
    ok "Nada que hacer"
  else
    spin "Subiendo el dataset" "$PY" "$ROOT/scripts/upload_raw.py" --input "$DATA" --bucket "$BUCKET" --ingest-date "$INGEST_DATE" \
      || { show_log; die "No se pudo subir (ver el error arriba). Vuelve a correr este script."; }
    ok "$(tail -n 1 "$LOG")"
  fi

  stage 4 "Comprobar"
  spin "Comprobando el lote en S3" aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text \
    || { show_log; die "El lote no está en S3."; }
  ok "s3://$BUCKET/$KEY ($(tail -n 1 "$LOG") bytes)"
  title "Todo listo. Para entrenar usa ingest_date = $INGEST_DATE."
}

main "$@"
