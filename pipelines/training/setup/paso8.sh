#!/usr/bin/env bash
# Paso 8 · Levantar MLflow (ver pipelines/training/README.md y mlflow_server/README.md).
#
#   bash pipelines/training/setup/paso8.sh
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Misma lógica que `make mlflow-server-up`, sin depender de ningún Makefile: repositorio de imágenes (ECR) → imagen →
# infraestructura (EC2, CloudFront, S3…). Muestra los cambios que hará Terraform y pregunta (y/n) antes de aplicarlos.
# Al final, si la EC2 está apagada la enciende sin preguntar, e informa: este paso termina con MLflow respondiendo.
# Crea recursos que COBRAN. No necesita credenciales: usa la sesión de tu perfil de AWS (paso2.sh).
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
NAME="vantix-mlflow"         # prefijo de los recursos: infra/shared y los workflows lo esperan así
DIR="mlflow_server/infra"
KEY="mlflow-server/terraform.tfstate"
HEALTH_WAIT=300              # segundos

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

# --- MLflow -------------------------------------------------------------------
IMAGE_TAG=""; VARS=()

# La imagen se etiqueta con el último commit que tocó docker/: el código tiene que estar commiteado.
check_source() {
  if [ -n "$(git -C "$ROOT/mlflow_server" status --porcelain -- .)" ]; then
    die "mlflow_server/ tiene cambios sin commitear: haz commit (o descártalos) y vuelve a correr este script."
  fi
  if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = "true" ]; then
    die "El repo se clonó sin historial (--depth) y la etiqueta de la imagen saldría mal. Corre: git fetch --unshallow"
  fi
  IMAGE_TAG="$(git -C "$ROOT/mlflow_server" log -1 --format=%h -- docker)"
  [ -n "$IMAGE_TAG" ] || die "No se encontró el commit de mlflow_server/docker."
  VARS=("-var=name=$NAME" "-var=region=$REGION" "-var=image_tag=$IMAGE_TAG" "-var=aws_profile=$PROFILE")
  ok "Código de MLflow: commiteado (imagen $IMAGE_TAG)"
}

image_exists() {
  spin "Buscando la imagen $IMAGE_TAG" aws ecr describe-images --region "$REGION" --repository-name "$NAME" \
    --image-ids "imageTag=$IMAGE_TAG" --output text
}

build_image() {
  local repo
  repo="$(tf "$DIR" output -raw ecr_repository_url)" || return 1
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${repo%%/*}" || return 1
  docker buildx build --platform linux/amd64 --provenance=false -t "$repo:$IMAGE_TAG" --push "$ROOT/mlflow_server/docker"
}

# start_instance <id> <estado>: una EC2 que se está apagando no se puede encender hasta que termine.
start_instance() {
  if [ "$2" = "stopping" ]; then
    aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$1" || return 1
  fi
  aws ec2 start-instances --region "$REGION" --instance-ids "$1" --output text || return 1
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$1"
}

wait_health() {
  local waited=0
  while [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1/health")" != "200" ]; do
    if [ "$waited" -ge "$HEALTH_WAIT" ]; then return 1; fi
    sleep 10
    waited=$((waited + 10))
  done
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg uri instance state image=0 changes=0
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  for arg in docker git curl; do
    command -v "$arg" >/dev/null 2>&1 || die "Falta $arg: corre primero paso1.sh."
  done
  [ -d "$ROOT/$DIR" ] || die "No se encontró $DIR: el script debe estar en pipelines/training/setup/ del repo."

  stage 1 "Revisar qué tienes"
  check_aws
  check_state_bucket
  check_terraform
  check_source
  if spin "Comprobando Docker" docker info; then ok "Docker: encendido"; else die "Docker está apagado: corre paso2.sh o abre Docker Desktop."; fi
  tf_init "$DIR" "$KEY"
  if image_exists; then
    ok "Imagen $IMAGE_TAG: ya está en ECR"; image=1
  elif grep -E 'RepositoryNotFoundException|ImageNotFoundException' "$LOG" >/dev/null; then
    err "Imagen $IMAGE_TAG: no está en ECR"
  else
    show_log
    die "No se pudo consultar ECR (ver el error arriba)."
  fi
  tf_plan "$DIR" "${VARS[@]}"
  if [ $? -eq 2 ]; then err "Infraestructura de MLflow: hay cambios por aplicar"; changes=1; else ok "Infraestructura de MLflow: al día"; fi

  stage 2 "Confirmar los cambios"
  if [ "$image" -eq 1 ] && [ "$changes" -eq 0 ]; then
    ok "No hay nada que cambiar"
  else
    echo "  En la cuenta $ACCOUNT_ID, región $REGION:"
    if [ "$image" -eq 0 ]; then echo "  - Crear el repositorio de imágenes (ECR) si no existe, y construir y subir la imagen $IMAGE_TAG"; fi
    if [ "$changes" -eq 1 ]; then
      echo "  - Infraestructura:"
      show_plan "$DIR"
      echo
      warn "La EC2 cobra mientras está encendida (~USD 0,02/h); la IP y el disco, siempre (~USD 5/mes)."
    fi
    echo
    confirm "¿Proceder?" || { echo "No se cambió nada."; exit 1; }
  fi

  stage 3 "Configurar"
  if [ "$image" -eq 1 ] && [ "$changes" -eq 0 ]; then ok "Nada que hacer"; fi
  if [ "$image" -eq 0 ]; then
    title "[imagen] Repositorio en ECR"
    tf "$DIR" apply -input=false -auto-approve "${VARS[@]}" -target=aws_ecr_repository.mlflow \
      || die "No se pudo crear el repositorio (ver el error arriba). Vuelve a correr este script: continúa desde aquí."
    title "[imagen] Construir y subir $IMAGE_TAG"
    info "La primera vez tarda varios minutos."
    build_image || die "No se pudo construir o subir la imagen (ver el error arriba). Vuelve a correr este script: continúa desde aquí."
    ok "Imagen $IMAGE_TAG subida"
  fi
  if [ "$changes" -eq 1 ]; then
    title "[infraestructura] Cambios"
    # Crear el repositorio cambió el estado: el plan se recalcula y se vuelve a mostrar.
    if [ "$image" -eq 0 ]; then
      tf_plan "$DIR" "${VARS[@]}"
      if [ $? -eq 2 ]; then
        show_plan "$DIR"
        echo
        confirm "¿Aplicar estos cambios?" || { echo "La imagen quedó subida, pero la infraestructura no se cambió."; exit 1; }
      else
        changes=0
      fi
    fi
    if [ "$changes" -eq 1 ]; then
      tf_apply "$DIR"
      ok "Infraestructura de MLflow aplicada"
    fi
  fi

  stage 4 "Comprobar"
  uri="$(tf "$DIR" output -raw tracking_uri)" && instance="$(tf "$DIR" output -raw instance_id)" \
    || die "No se pudieron leer los datos de MLflow."
  ok "URL: $uri (usuario admin)"
  spin "Comprobando la EC2" aws ec2 describe-instances --region "$REGION" --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].State.Name' --output text || { show_log; die "No se pudo leer la EC2."; }
  state="$(tail -n 1 "$LOG")"
  case "$state" in
    running|pending) ok "EC2 $instance: ya estaba encendida" ;;
    stopped|stopping)
      info "EC2 $instance: apagada ($state). Se enciende ahora."
      spin "Encendiendo la EC2" start_instance "$instance" "$state" \
        || { show_log; die "No se pudo encender la EC2 (ver el error arriba)."; }
      ok "EC2 $instance: este script la encendió" ;;
    *) die "La EC2 $instance está en un estado inesperado: $state. Vuelve a correr este script en unos minutos." ;;
  esac
  if spin "Esperando a que MLflow responda (hasta $HEALTH_WAIT s)" wait_health "$uri"; then
    ok "MLflow: encendido y respondiendo"
  else
    die "La EC2 está encendida, pero MLflow no respondió en $HEALTH_WAIT s. Espera unos minutos y vuelve a correr este script."
  fi
  warn "La EC2 queda encendida y cobrando. Para apagarla: aws ec2 stop-instances --instance-ids $instance --profile $PROFILE --region $REGION"
  title "Todo listo. Puedes seguir con paso9.sh (infraestructura de entrenamiento)."
}

main "$@"
