#!/usr/bin/env bash
# Paso 1 · Comprobar los requisitos del monitoreo (ver monitorization/README.md).
#
#   bash monitorization/setup/paso1.sh
#   --repo=ana/vantix    si tu repo no es el del remoto origin
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Solo lee: no cambia nada en GitHub ni en AWS. Comprueba lo que deja listo el setup de entrenamiento, que haya un
# champion y datos, y lo que el monitoreo da por hecho en la cuenta: proveedor OIDC, VPC por defecto, subred y AMI.
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
NAME="vantix-monitoring"     # prefijo de los recursos: los workflows lo esperan así
DIR="monitorization/infra"
KEY="monitorization/terraform.tfstate"
TFVARS="$ROOT/$DIR/terraform.tfvars"
REPO=""
export GH_PAGER="cat"

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

valid_repo() { printf '%s\n' "$1" | grep -E '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' >/dev/null; }
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

# --- GitHub -------------------------------------------------------------------
USER_LOGIN=""; USER_ID=""
# Si el error no es de autenticación, iniciar sesión no lo arregla: se detiene y lo muestra.
stop_if_offline() {
  if grep -iE 'error connecting|could not resolve|no such host|timeout|timed out|HTTP 5[0-9][0-9]|rate limit' "$LOG" >/dev/null; then
    show_log
    die "GitHub no respondió. Revisa tu conexión y vuelve a correr este script."
  fi
}


github() { gh api --hostname github.com "$@"; }

check_account() {
  if ! spin "Comprobando tu sesión de GitHub" github user --jq '[.login, (.id | tostring)] | @tsv'; then
    stop_if_offline
    die "No hay sesión de GitHub: corre primero pipelines/training/setup/paso4.sh."
  fi
  USER_LOGIN="$(tail -n 1 "$LOG" | cut -f 1)"
  USER_ID="$(tail -n 1 "$LOG" | cut -f 2)"
  printf '%s\n' "$USER_ID" | grep -E '^[0-9]+$' >/dev/null || die "GitHub respondió una cuenta inesperada."
  ok "Cuenta de GitHub: $USER_LOGIN"
}

# owner/repo del remoto "origin". Vacío si no hay o no es de github.com.
repo_from_origin() {
  git -C "$ROOT" remote get-url origin 2>/dev/null | sed -nE \
    -e 's#/+$##' -e 's#\.git$##' \
    -e 's#^(https?|ssh)://([^/@]+@)?github\.com(:[0-9]+)?/([^/]+/[^/]+)$#\4#p' \
    -e 's#^[^/@]+@github\.com:([^/]+/[^/]+)$#\1#p'
}

check_repo() {
  local admin
  if [ -z "$REPO" ]; then REPO="$(repo_from_origin)"; fi
  if [ -z "$REPO" ]; then die "No se pudo detectar tu repo por el remoto origin: indícalo con --repo=usuario/repo."; fi
  if ! spin "Buscando $REPO en GitHub" github "repos/$REPO" --jq '[.full_name, (.permissions.admin | tostring)] | @tsv'; then
    stop_if_offline
    die "$REPO no existe, o la cuenta $USER_LOGIN no puede verlo. Indica tu repo con --repo=usuario/repo."
  fi
  REPO="$(tail -n 1 "$LOG" | cut -f 1)"
  admin="$(tail -n 1 "$LOG" | cut -f 2)"
  if [ "$admin" != "true" ]; then
    die "La cuenta $USER_LOGIN no administra $REPO. Usa tu fork (--repo=usuario/repo) o cambia de cuenta con pipelines/training/setup/paso4.sh."
  fi
  ok "Repo: $REPO"
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

# El champion está completo si están los 4 archivos que lee la inferencia.
check_champion() {
  local file version k
  spin "Buscando el champion" aws s3api list-objects-v2 --bucket "$BUCKET" --prefix models/champion/ --query 'Contents[].Key' --output text \
    || { show_log; die "No se pudo leer models/champion/."; }
  for file in preprocessor.pkl model.pkl segment_map.json manifest.json; do
    tr '\t' '\n' < "$LOG" | grep -xF "models/champion/$file" >/dev/null \
      || die "No hay un champion completo (falta models/champion/$file): promueve un modelo (Paso 13 de pipelines/training/README.md)."
  done
  spin "Leyendo el champion" aws s3 cp --no-progress "s3://$BUCKET/models/champion/manifest.json" "$WORK/manifest.json" \
    || { show_log; die "No se pudo leer el champion."; }
  version="$(sed -nE 's/.*"model_version": *"?([0-9]+)"?.*/\1/p' "$WORK/manifest.json" | head -n 1)"
  k="$(sed -nE 's/.*"k": *([0-9]+).*/\1/p' "$WORK/manifest.json" | head -n 1)"
  ok "Champion: versión ${version:-?}, k=${k:-?}"
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

# tfvars_values <variable>: sus valores en terraform.tfvars, uno por línea (puede haber ninguno o estar repetida).
tfvars_values() {
  [ -f "$TFVARS" ] || return 0
  awk -v key="$1" '{ line = $0; sub(/^[ \t]+/, "", line) } index(line, key) == 1 && substr(line, length(key) + 1) ~ /^[ \t]*=/ { split(line, part, "\""); print part[2] }' "$TFVARS"
}

# Valor por defecto de una variable de Terraform (zona y AMI están fijadas ahí).
tf_default() {
  awk -v key="$1" '$0 ~ "^variable \"" key "\"" { on = 1 } on && /default/ { split($0, part, "\""); print part[2]; exit }' "$ROOT/$DIR/variables.tf"
}

check_authorized() {
  [ -n "$(tfvars_values github_repo)" ] || die "Falta autorizar tu repo (github_repo en $DIR/terraform.tfvars): corre primero pipelines/training/setup/paso4.sh."
  ok "Repo autorizado: $(tfvars_values github_repo | head -n 1)"
}

check_oidc() {
  spin "Buscando el proveedor OIDC de GitHub" aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" \
    || { show_log; die "No existe el proveedor OIDC de GitHub: corre primero pipelines/training/setup/paso9.sh."; }
  ok "Proveedor OIDC de GitHub: existe"
}

check_network() {
  local zone ami vpc subnet
  zone="$(tf_default availability_zone)"
  ami="$(tf_default ami_id)"
  spin "Buscando la VPC por defecto" aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text \
    || { show_log; die "No se pudieron leer las VPC."; }
  vpc="$(tail -n 1 "$LOG")"
  case "$vpc" in vpc-*) ok "VPC por defecto: $vpc" ;; *) die "La cuenta no tiene VPC por defecto en $REGION. Créala con: aws ec2 create-default-vpc --profile $PROFILE --region $REGION" ;; esac
  spin "Buscando la subred de $zone" aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" "Name=availability-zone,Values=$zone" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text \
    || { show_log; die "No se pudieron leer las subredes."; }
  subnet="$(tail -n 1 "$LOG")"
  case "$subnet" in subnet-*) ok "Subred por defecto en $zone: $subnet" ;; *) die "La VPC por defecto no tiene subred en $zone. Créala con: aws ec2 create-default-subnet --availability-zone $zone --profile $PROFILE --region $REGION" ;; esac
  if ! spin "Buscando la AMI" aws ec2 describe-images --region "$REGION" --image-ids "$ami" --query 'Images[0].State' --output text; then
    show_log
    die "La AMI fijada ($ami) no está disponible: hay que actualizar ami_id en $DIR/variables.tf."
  fi
  [ "$(tail -n 1 "$LOG")" = "available" ] || die "La AMI fijada ($ami) ya no está disponible: hay que actualizar ami_id en $DIR/variables.tf."
  ok "AMI: $ami disponible"
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --repo=*)    REPO="${arg#*=}";    valid_repo "$REPO"       || die "--repo debe tener la forma usuario/repo: $REPO" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  command -v gh  >/dev/null 2>&1 || die "Falta GitHub CLI: corre primero pipelines/training/setup/paso1.sh."
  command -v git >/dev/null 2>&1 || die "Falta Git: corre primero pipelines/training/setup/paso1.sh."
  [ -d "$ROOT/$DIR" ] || die "No se encontró $DIR: el script debe estar en monitorization/setup/ del repo."

  stage 1 "GitHub"
  check_account
  check_repo
  check_authorized

  stage 2 "AWS"
  check_aws
  check_state_bucket
  check_terraform
  check_oidc

  stage 3 "Datos y modelo"
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  check_champion
  read_lots

  stage 4 "Red y servidor"
  check_network
  title "Todo listo. Puedes seguir con monitorization/setup/paso2.sh (correo de alertas)."
}

main "$@"
