#!/usr/bin/env bash
# Paso 9 · Levantar la infraestructura de entrenamiento (ver pipelines/training/README.md).
#
#   bash pipelines/training/setup/paso9.sh
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Misma lógica que `make up-training`, sin depender del Makefile: infra/shared (bucket de datos, OIDC y roles de GitHub)
# → infra/training (rol de ejecución). Para cada módulo muestra los cambios de Terraform y pregunta (y/n).
# No necesita credenciales: usa la sesión de tu perfil de AWS (paso2.sh).
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
MLFLOW_KEY="mlflow-server/terraform.tfstate"   # infra/shared lee de aquí la URL y la contraseña de MLflow

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

# tf_plan <módulo> [opciones] -> 0 sin cambios, 2 con cambios (quedan en $WORK/plan). Si falla, se detiene.
tf_plan() {
  local dir="$1" rc
  shift
  spin "Calculando los cambios de $dir" tf "$dir" plan -input=false -detailed-exitcode -out="$WORK/plan" "$@"
  rc=$?
  case "$rc" in
    0|2) return "$rc" ;;
    *) show_log; die "No se pudieron calcular los cambios de $dir (ver el error arriba)." ;;
  esac
}

# Muestra el plan: solo la lista si todo es nuevo, o completo si toca algo que ya existe.
show_plan() {
  tf "$1" show -no-color "$WORK/plan" > "$WORK/plan.txt" || die "No se pudo leer el plan de $1."
  if grep -E '^  # .* (will be updated|must be replaced|will be destroyed|is tainted)' "$WORK/plan.txt" >/dev/null; then
    cat "$WORK/plan.txt"
    if grep -E '^  # .* (must be replaced|will be destroyed|is tainted)' "$WORK/plan.txt" >/dev/null; then
      echo
      warn "ATENCIÓN: este plan DESTRUYE o REEMPLAZA recursos que ya existen:"
      grep -E '^  # .* (must be replaced|will be destroyed|is tainted)' "$WORK/plan.txt"
    fi
  else
    grep -E '^  # ' "$WORK/plan.txt"
    grep -E '^Plan:' "$WORK/plan.txt" | sed 's/^/  /'
  fi
}

# Aplica exactamente el plan mostrado.
tf_apply() {
  tf "$1" apply -input=false "$WORK/plan" \
    || die "Terraform falló en $1 (ver el error arriba). Vuelve a correr este script: continúa desde lo que falte."
}

# --- comprobaciones propias ---------------------------------------------------
check_mlflow_state() {
  spin "Buscando MLflow" aws s3api head-object --bucket "$STATE_BUCKET" --key "$MLFLOW_KEY" \
    || { show_log; die "MLflow no está levantado: corre primero paso8.sh."; }
  ok "MLflow: levantado"
}

check_github_repo() {
  local value
  value="$(awk '/^[ \t]*github_repo[ \t]*=/ { split($0, part, "\""); print part[2] }' "$ROOT/infra/shared/terraform.tfvars" 2>/dev/null)"
  [ -n "$value" ] || die "Falta autorizar tu repo (github_repo en infra/shared/terraform.tfvars): corre primero paso4.sh."
  ok "Repo autorizado: $value"
}

# AWS admite un solo proveedor OIDC de GitHub por cuenta. Si ya hay uno ajeno a este proyecto, Terraform fallaría a medias.
check_oidc_conflict() {
  local arn="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
  grep 'aws_iam_openid_connect_provider.github will be created' "$WORK/plan.txt" >/dev/null || return 0
  if spin "Buscando otro proveedor OIDC de GitHub" aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn"; then
    err "La cuenta ya tiene un proveedor OIDC de GitHub que no creó este proyecto: $arn"
    die "Usa una cuenta dedicada a Vantix. No se aplicó este módulo."
  fi
  grep 'NoSuchEntity' "$LOG" >/dev/null || { show_log; die "No se pudo comprobar el proveedor OIDC."; }
}

# up <módulo>
up() {
  local dir="infra/$1"
  title "$dir"
  tf_init "$dir" "$1/terraform.tfstate"
  tf_plan "$dir"
  if [ $? -eq 0 ]; then ok "$dir: al día, no hay nada que cambiar"; return 0; fi
  show_plan "$dir"
  check_oidc_conflict
  echo
  confirm "¿Aplicar estos cambios en la cuenta $ACCOUNT_ID?" || { echo "No se aplicó $dir."; exit 1; }
  tf_apply "$dir"
  ok "$dir: aplicado"
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg bucket role
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  [ -d "$ROOT/infra/shared" ] || die "No se encontró infra/shared: el script debe estar en pipelines/training/setup/ del repo."

  stage 1 "Revisar qué tienes"
  check_aws
  check_state_bucket
  check_terraform
  check_mlflow_state
  check_github_repo
  export TF_VAR_aws_profile="$PROFILE" TF_VAR_region="$REGION" TF_VAR_state_bucket="$STATE_BUCKET"

  stage 2 "Base compartida: bucket de datos, OIDC y roles de GitHub"
  up shared

  stage 3 "Entrenamiento: rol de ejecución"
  up training

  stage 4 "Comprobar"
  bucket="$(tf infra/shared output -raw data_bucket)" && role="$(tf infra/training output -raw training_role_arn)" \
    || die "No se pudieron leer los datos de la infraestructura."
  task "Comprobando el bucket de datos" "Bucket de datos: $bucket" aws s3api head-bucket --bucket "$bucket" \
    || die "El bucket de datos no responde."
  task "Comprobando el rol de ejecución" "Rol de ejecución: ${role##*/}" aws iam get-role --role-name "${role##*/}" --query Role.Arn --output text \
    || die "El rol de ejecución no existe."
  title "Todo listo. Puedes seguir con paso10.sh (subir los datos a S3)."
}

main "$@"
