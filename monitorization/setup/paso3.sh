#!/usr/bin/env bash
# Paso 3 · Levantar el monitoreo (ver monitorization/README.md).
#
#   bash monitorization/setup/paso3.sh
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Misma lógica que `make bootstrap` (la primera vez) y `make up` (después) de monitorization/, sin depender de ningún
# Makefile. La primera vez: repositorio de imágenes (ECR) → imagen del backend → infraestructura. Después, solo
# infraestructura: la imagen la publica el CI (ci_monitoring). Muestra los cambios y pregunta (y/n) antes de aplicarlos.
# Un cambio puede REEMPLAZAR la EC2; los datos viven en un disco aparte. Si el plan tocara ese disco o el bucket de
# respaldos, se detiene. Crea recursos que COBRAN.
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
NAME="vantix-monitoring"     # prefijo de los recursos: los workflows lo esperan así
DIR="monitorization/infra"
KEY="monitorization/terraform.tfstate"
TFVARS="$ROOT/$DIR/terraform.tfvars"
IMAGE_PARAM="/$NAME/backend-image"   # tag vigente del backend
HEALTH_WAIT=420              # segundos

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

# tfvars_values <variable>: sus valores en terraform.tfvars, uno por línea (puede haber ninguno o estar repetida).
tfvars_values() {
  [ -f "$TFVARS" ] || return 0
  awk -v key="$1" '{ line = $0; sub(/^[ \t]+/, "", line) } index(line, key) == 1 && substr(line, length(key) + 1) ~ /^[ \t]*=/ { split(line, part, "\""); print part[2] }' "$TFVARS"
}

# --- monitoreo ----------------------------------------------------------------
# Lo que entra en la imagen: su etiqueta es el último commit que tocó algo de esto.
IMAGE_SOURCES=(docker src ../pipelines/__init__.py ../pipelines/common/__init__.py ../pipelines/common/config.py
  ../pipelines/common/features.py ../pipelines/common/io.py ../pipelines/common/storage.py)
IMAGE_TAG=""; VARS=()

check_source() {
  local dirty
  dirty="$(git -C "$ROOT/monitorization" status --porcelain -- . "${IMAGE_SOURCES[@]}")" || die "No se pudo leer el estado de git."
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
    die "Hay cambios sin commitear en el monitoreo (arriba): haz commit y vuelve a correr este script."
  fi
  if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = "true" ]; then
    die "El repo se clonó sin historial (--depth) y la etiqueta de la imagen saldría mal. Corre: git fetch --unshallow"
  fi
  IMAGE_TAG="$(git -C "$ROOT/monitorization" log -1 --format=%h -- "${IMAGE_SOURCES[@]}")"
  [ -n "$IMAGE_TAG" ] || die "No se encontró el commit de la imagen."
  VARS=("-var=name=$NAME" "-var=region=$REGION" "-var=initial_image_tag=$IMAGE_TAG" "-var=aws_profile=$PROFILE")
  ok "Código del monitoreo: commiteado"
}

check_config() {
  local key
  for key in data_bucket alert_email; do
    [ -n "$(tfvars_values "$key")" ] || die "Falta $key en $DIR/terraform.tfvars: corre primero monitorization/setup/paso2.sh."
  done
  [ -n "$(tfvars_values github_repo)" ] || die "Falta autorizar tu repo (github_repo): corre primero pipelines/training/setup/paso4.sh."
  ok "Configuración: completa"
}

image_exists() {
  spin "Buscando la imagen $IMAGE_TAG" aws ecr describe-images --region "$REGION" --repository-name "$NAME-backend" \
    --image-ids "imageTag=$IMAGE_TAG" --output text
}

build_image() {
  local repo
  repo="$(tf "$DIR" output -raw ecr_repository_url)" || return 1
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${repo%%/*}" || return 1
  docker buildx build --platform linux/amd64 --provenance=false --build-arg "GIT_COMMIT=$IMAGE_TAG" \
    -f "$ROOT/monitorization/docker/Dockerfile" -t "$repo:$IMAGE_TAG" --push "$ROOT"
}

# Los datos no se arriesgan: un plan que borre o reemplace el disco o el bucket de respaldos no se aplica desde aquí.
protect_data() {
  if grep -E '^  # aws_(ebs_volume\.data|s3_bucket\.monitoring) (must be replaced|will be destroyed)' "$WORK/plan.txt" >/dev/null; then
    die "El plan borraría los datos del monitoreo (arriba). No se aplicó nada: revisa el cambio antes de continuar."
  fi
  if grep -E '^  # aws_instance\.server must be replaced' "$WORK/plan.txt" >/dev/null; then
    warn "La EC2 se reemplaza; el disco de datos se vuelve a montar en la nueva. Grafana no responderá unos minutos."
  fi
}

wait_health() {
  local waited=0
  while [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1/api/health")" != "200" ]; do
    if [ "$waited" -ge "$HEALTH_WAIT" ]; then return 1; fi
    sleep 10
    waited=$((waited + 10))
  done
}

print_email() {
  local email status
  email="$(tfvars_values alert_email | head -n 1)"
  spin "Comprobando el correo de alertas" aws ses get-identity-verification-attributes --region "$REGION" --identities "$email" \
    --query 'VerificationAttributes.*.VerificationStatus' --output text || { show_log; warn "No se pudo leer el estado del correo."; return 0; }
  status="$(tail -n 1 "$LOG")"
  if [ "$status" = "Success" ]; then ok "Correo de alertas: confirmado"; return 0; fi
  warn "Correo de alertas: sin confirmar (${status:-sin estado}). El monitoreo funciona igual, pero no llegarán correos."
  if [ "$status" = "Pending" ]; then
    info "Abre el correo de Amazon Web Services (revisa spam) y pulsa el enlace: vence a las 24 horas."
  else
    info "Para pedir otro correo de confirmación:"
    info "aws ses verify-email-identity --email-address $email --profile $PROFILE --region $REGION"
  fi
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg uri instance state first=0 image=1 changes=0
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  for arg in git curl; do
    command -v "$arg" >/dev/null 2>&1 || die "Falta $arg: corre primero pipelines/training/setup/paso1.sh."
  done
  [ -d "$ROOT/$DIR" ] || die "No se encontró $DIR: el script debe estar en monitorization/setup/ del repo."

  stage 1 "Revisar qué tienes"
  check_aws
  check_state_bucket
  check_terraform
  check_config
  check_source
  tf_init "$DIR" "$KEY"
  if spin "Buscando la imagen vigente" aws ssm get-parameter --region "$REGION" --name "$IMAGE_PARAM" --query Parameter.Value --output text; then
    ok "Imagen vigente del backend: $(tail -n 1 "$LOG") (la publica el CI)"
  else
    grep 'ParameterNotFound' "$LOG" >/dev/null || { show_log; die "No se pudo leer la imagen vigente (ver el error arriba)."; }
    first=1
    if image_exists; then
      ok "Imagen $IMAGE_TAG: ya está en ECR"
    elif grep -E 'RepositoryNotFoundException|ImageNotFoundException' "$LOG" >/dev/null; then
      err "Imagen $IMAGE_TAG: no está en ECR"; image=0
      command -v docker >/dev/null 2>&1 || die "Falta Docker: corre primero pipelines/training/setup/paso1.sh."
      if spin "Comprobando Docker" docker info; then ok "Docker: encendido"; else die "Docker está apagado: abre Docker Desktop y vuelve a correr este script."; fi
    else
      show_log
      die "No se pudo consultar ECR (ver el error arriba)."
    fi
  fi
  tf_plan "$DIR" "${VARS[@]}"
  if [ $? -eq 2 ]; then err "Infraestructura del monitoreo: hay cambios por aplicar"; changes=1; else ok "Infraestructura del monitoreo: al día"; fi

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
      protect_data
      warn "La EC2 cobra mientras está encendida (~USD 0,02/h); la IP y los discos, siempre (~USD 6/mes)."
    fi
    if [ "$first" -eq 1 ]; then warn "AWS enviará un correo de confirmación a $(tfvars_values alert_email | head -n 1)."; fi
    echo
    confirm "¿Proceder?" || { echo "No se cambió nada."; exit 1; }
  fi

  stage 3 "Configurar"
  if [ "$image" -eq 1 ] && [ "$changes" -eq 0 ]; then ok "Nada que hacer"; fi
  if [ "$image" -eq 0 ]; then
    title "[imagen] Repositorio en ECR"
    tf "$DIR" apply -input=false -auto-approve "${VARS[@]}" -target=aws_ecr_repository.backend \
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
        protect_data
        confirm "¿Aplicar estos cambios?" || { echo "La imagen quedó subida, pero la infraestructura no se cambió."; exit 1; }
      else
        changes=0
      fi
    fi
    if [ "$changes" -eq 1 ]; then
      tf_apply "$DIR"
      ok "Infraestructura del monitoreo aplicada"
    fi
  fi

  stage 4 "Comprobar"
  uri="$(tf "$DIR" output -raw grafana_url)" && instance="$(tf "$DIR" output -raw instance_id)" \
    || die "No se pudieron leer los datos del monitoreo."
  ok "Grafana: $uri (usuario admin)"
  info "Contraseña: aws ssm get-parameter --name /$NAME/grafana-admin-password --with-decryption --query Parameter.Value --output text --profile $PROFILE --region $REGION"
  print_email
  spin "Comprobando la EC2" aws ec2 describe-instances --region "$REGION" --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].State.Name' --output text || { show_log; die "No se pudo leer la EC2."; }
  state="$(tail -n 1 "$LOG")"
  case "$state" in
    running|pending)
      if spin "Esperando a que Grafana responda (hasta $HEALTH_WAIT s)" wait_health "$uri"; then
        ok "Grafana: responde"
      else
        die "Grafana no respondió en $HEALTH_WAIT s. Espera unos minutos y vuelve a correr este script."
      fi
      warn "La EC2 queda encendida y cobrando. Para apagarla: aws ec2 stop-instances --instance-ids $instance --profile $PROFILE --region $REGION" ;;
    *) warn "EC2: $state. No hace falta encenderla: el workflow run_monitoring_manual la enciende solo." ;;
  esac
  title "Todo listo. Puedes seguir con monitorization/setup/paso4.sh (conectar GitHub)."
}

main "$@"
