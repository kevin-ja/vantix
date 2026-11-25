#!/usr/bin/env bash
# Paso 6 · Crear y subir un lote de prueba (ver monitorization/README.md). Solo si no tienes datos nuevos.
#
#   bash monitorization/setup/paso6.sh --tipo=estable      # se parece al benchmark: 0 alertas
#   bash monitorization/setup/paso6.sh --tipo=degradado    # problemas a propósito: muchas alertas
#   --ingest-date=AAAA-MM-DD   etiqueta del lote (por defecto 2025-06-30 el estable y 2025-07-31 el degradado)
#   --profile=NOMBRE           si tu perfil de AWS no se llama vantix
#
# Genera el lote con scripts/make_synthetic_batches.py a partir de data/data.parquet y lo sube con scripts/upload_raw.py.
# CUIDADO: un lote no se puede sobrescribir y, si su fecha es la más reciente, pasa a ser "el último": lo usarían la
# inferencia y el monitoreo cuando se lanzan con fechas "auto". Antes de subir lo muestra y pregunta (y/n).
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
NAME="vantix-monitoring"     # prefijo de los recursos: los workflows lo esperan así
DIR="monitorization/infra"
KEY="monitorization/terraform.tfstate"
TFVARS="$ROOT/$DIR/terraform.tfvars"
KIND=""
INGEST_DATE=""
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

# Deja en LOTS las fechas de los lotes de raw/, de la más antigua a la más reciente.
LOTS=""
read_lots() {
  spin "Buscando lotes de datos" aws s3api list-objects-v2 --bucket "$BUCKET" --prefix raw/ --query 'Contents[].Key' --output text \
    || { show_log; die "No se pudo leer raw/."; }
  LOTS="$(tr '\t' '\n' < "$LOG" | sed -nE 's#^raw/ingest_date=([0-9]{4}-[0-9]{2}-[0-9]{2})/.+#\1#p' | sort -u)"
  [ -n "$LOTS" ] || die "No hay datos en raw/: corre primero pipelines/training/setup/paso10.sh."
  ok "Lotes de datos: $(printf '%s' "$LOTS" | paste -s -d ' ' -)"
}

valid_date() {
  printf '%s\n' "$1" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' >/dev/null \
    && "$PY" -c 'import datetime, sys; datetime.date.fromisoformat(sys.argv[1])' "$1" 2>/dev/null
}

# El generador escribe siempre los dos lotes: el que no se pidió va a una carpeta que se descarta.
generate() {
  local stable="$INGEST_DATE" degraded="$INGEST_DATE" skip="2000-01-31"
  if [ "$KIND" = "estable" ]; then degraded="$skip"; else stable="$skip"; fi
  "$PY" "$ROOT/monitorization/scripts/make_synthetic_batches.py" --raw "$DATA" --out "$WORK/raw" \
    --stable-ingest "$stable" --degraded-ingest "$degraded"
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg file newest
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --tipo=estable|--tipo=degradado) KIND="${arg#*=}" ;;
      --tipo=*) die "--tipo debe ser estable o degradado" ;;
      --ingest-date=*) INGEST_DATE="${arg#*=}" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  [ -d "$ROOT/$DIR" ] || die "No se encontró $DIR: el script debe estar en monitorization/setup/ del repo."
  [ -n "$KIND" ] || die "Indica el lote: --tipo=estable o --tipo=degradado"
  if [ -z "$INGEST_DATE" ]; then
    if [ "$KIND" = "estable" ]; then INGEST_DATE="2025-06-30"; else INGEST_DATE="2025-07-31"; fi
  fi
  [ -x "$PY" ]   || die "Falta el entorno de Python (.venv): corre primero pipelines/training/setup/paso3.sh."
  [ -f "$DATA" ] || die "Falta el dataset (data/data.parquet): corre primero pipelines/training/setup/paso5.sh."
  valid_date "$INGEST_DATE" || die "--ingest-date debe ser una fecha real con la forma 2025-06-30: $INGEST_DATE"

  stage 1 "Revisar qué tienes"
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  read_lots
  if printf '%s\n' "$LOTS" | grep -xF "$INGEST_DATE" >/dev/null; then
    title "El lote $INGEST_DATE ya existe y no se sobrescribe: no hay nada que subir."
    info "Para correr el monitoreo usa ingest_date = $INGEST_DATE. Si querías otro, usa --ingest-date."
    exit 0
  fi

  stage 2 "Confirmar los cambios"
  echo "  En la cuenta $ACCOUNT_ID:"
  echo "  - Generar un lote sintético ($KIND) y subirlo a s3://$BUCKET/raw/ingest_date=$INGEST_DATE/"
  warn "Son datos de PRUEBA y quedan junto a los reales. Un lote no se puede sobrescribir."
  newest="$(printf '%s\n' "$LOTS" | tail -n 1)"
  # Las fechas AAAA-MM-DD se ordenan como texto.
  if [ "$(printf '%s\n%s\n' "$newest" "$INGEST_DATE" | sort | tail -n 1)" = "$INGEST_DATE" ]; then
    warn "Pasará a ser el ÚLTIMO lote (hoy es $newest): la inferencia y el monitoreo lo usarán si se lanzan con fechas auto."
  fi
  echo
  confirm "¿Proceder?" || { echo "No se subió nada."; exit 1; }

  stage 3 "Generar y subir"
  spin "Generando el lote" generate || { show_log; die "No se pudo generar el lote (ver el error arriba)."; }
  file="$WORK/raw/ingest_date=$INGEST_DATE/data.parquet"
  [ -f "$file" ] || die "El generador no creó el lote esperado."
  ok "Lote generado"
  spin "Subiendo el lote" "$PY" "$ROOT/scripts/upload_raw.py" --input "$file" --bucket "$BUCKET" --ingest-date "$INGEST_DATE" \
    || { show_log; die "No se pudo subir (ver el error arriba). Vuelve a correr este script."; }
  ok "$(tail -n 1 "$LOG")"

  stage 4 "Comprobar"
  read_lots
  printf '%s\n' "$LOTS" | grep -xF "$INGEST_DATE" >/dev/null || die "El lote no aparece en S3."
  title "Todo listo. Para correr el monitoreo usa ingest_date = $INGEST_DATE."
}

main "$@"
