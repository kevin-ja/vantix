#!/usr/bin/env bash
# Paso 6 · Encender o apagar la inferencia semanal (ver pipelines/inference/README.md). Opcional.
#
#   bash pipelines/inference/setup/paso6.sh --estado=on      # cada lunes 06:00 UTC
#   bash pipelines/inference/setup/paso6.sh --estado=off
#   bash pipelines/inference/setup/paso6.sh                  # muestra el estado y pregunta si cambiarlo
#   --profile=NOMBRE     si tu perfil de AWS no se llama vantix
#
# Misma lógica que `make schedule-on` / `schedule-off`, sin depender del Makefile y solo sobre infra/inference.
# La corrida semanal usa fechas "auto": toma el ÚLTIMO lote de raw/ y no espera aprobación. Por eso, para encender exige
# un champion, el pipeline desplegado y que su última corrida haya terminado bien, y muestra qué lote usaría.
# Compatible con bash 3.2, el que trae macOS (por eso sin `set -u`).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
REGION="us-east-1"           # fija en los workflows
PROFILE="vantix"
PIPELINE="vantix-inference"
TARGET=""                    # ENABLED | DISABLED

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

# Estado real del scheduler. Deja en SCHEDULE: ENABLED | DISABLED | falta.
SCHEDULE_NAME="vantix-inference-weekly"
SCHEDULE=""
read_schedule() {
  if spin "Leyendo el scheduler" aws scheduler get-schedule --region "$REGION" --name "$SCHEDULE_NAME" --query State --output text; then
    SCHEDULE="$(tail -n 1 "$LOG")"
    case "$SCHEDULE" in ENABLED|DISABLED) return 0 ;; esac
    die "AWS respondió un estado inesperado del scheduler: $SCHEDULE"
  fi
  grep 'ResourceNotFoundException' "$LOG" >/dev/null || { show_log; die "No se pudo leer el scheduler (ver el error arriba)."; }
  SCHEDULE="falta"
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

check_pipeline() {
  local last
  spin "Buscando el pipeline $PIPELINE" aws sagemaker list-pipeline-executions --region "$REGION" --pipeline-name "$PIPELINE" \
    --sort-by CreationTime --sort-order Descending --max-items 1 \
    --query 'PipelineExecutionSummaries[].PipelineExecutionStatus' --output text \
    || { show_log; die "El pipeline $PIPELINE no está desplegado: corre primero el workflow deploy_inference."; }
  last="$(awk 'NR == 1 {print $1}' "$LOG")"
  case "$last" in
    Succeeded) ok "Última corrida de $PIPELINE: terminó bien" ;;
    ""|None)   die "$PIPELINE no se ha ejecutado nunca: corre antes el workflow batch_inference_manual y revisa los scores." ;;
    *)         die "La última corrida de $PIPELINE está en estado $last: revísala antes de encender la corrida semanal." ;;
  esac
}

print_schedule() {
  if [ "$SCHEDULE" = "ENABLED" ]; then ok "Inferencia semanal: encendida"; else ok "Inferencia semanal: apagada"; fi
}

# --- flujo --------------------------------------------------------------------
main() {
  local arg enabled
  for arg in "$@"; do
    case "$arg" in
      --profile=*) PROFILE="${arg#*=}"; valid_profile "$PROFILE" || die "--profile no es válido: $PROFILE" ;;
      --estado=on)  TARGET="ENABLED" ;;
      --estado=off) TARGET="DISABLED" ;;
      --estado=*)   die "--estado debe ser on u off" ;;
      --help|-h)   awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
      *) die "Opción desconocida: $arg (ver --help)" ;;
    esac
  done
  start_checks
  [ -d "$ROOT/infra/inference" ] || die "No se encontró infra/inference: el script debe estar en pipelines/inference/setup/ del repo."

  stage 1 "Revisar qué tienes"
  check_aws
  check_state_bucket
  check_terraform
  read_schedule
  if [ "$SCHEDULE" = "falta" ]; then die "El scheduler no existe: corre primero pipelines/inference/setup/paso2.sh."; fi
  print_schedule
  if [ -z "$TARGET" ]; then
    if [ "$SCHEDULE" = "ENABLED" ]; then
      confirm "¿Apagarla?" || { echo "No se cambió nada."; exit 0; }
      TARGET="DISABLED"
    else
      confirm "¿Encenderla?" || { echo "No se cambió nada."; exit 0; }
      TARGET="ENABLED"
    fi
  fi
  if [ "$SCHEDULE" = "$TARGET" ]; then title "No hay nada que cambiar."; exit 0; fi
  # Apagar nunca se bloquea; encender exige que todo funcione.
  if [ "$TARGET" = "ENABLED" ]; then
    check_pipeline
    tf_init infra/shared shared/terraform.tfstate
    read_bucket
    check_champion
    read_lots
  fi

  stage 2 "Confirmar los cambios"
  export TF_VAR_aws_profile="$PROFILE" TF_VAR_region="$REGION" TF_VAR_state_bucket="$STATE_BUCKET"
  if [ "$TARGET" = "ENABLED" ]; then enabled="true"; else enabled="false"; fi
  tf_init infra/inference inference/terraform.tfstate
  tf_plan infra/inference "-var=schedule_enabled=$enabled"
  if [ $? -eq 0 ]; then die "Terraform no ve cambios, pero el scheduler está $SCHEDULE: revisa infra/inference."; fi
  show_plan infra/inference
  echo
  if [ "$TARGET" = "ENABLED" ]; then
    warn "Correrá sola cada lunes 06:00 UTC, sin aprobación, y cobra cada vez (~3 min de ml.t3.xlarge)."
    warn "Usará el último lote: $(printf '%s\n' "$LOTS" | tail -n 1). Si sus datos no llegan hasta el día anterior a la corrida, la corrida fallará."
  fi
  confirm "¿Proceder?" || { echo "No se cambió nada."; exit 1; }

  stage 3 "Configurar"
  tf_apply infra/inference

  stage 4 "Comprobar"
  read_schedule
  [ "$SCHEDULE" = "$TARGET" ] || die "El scheduler quedó $SCHEDULE y debía quedar $TARGET. Vuelve a correr este script."
  print_schedule
  title "Listo."
}

main "$@"
