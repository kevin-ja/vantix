# Paso: Infraestructura de inferencia
#
# infra/shared → infra/inference (bucket de scores, rol de ejecución y scheduler semanal).
# Respeta el scheduler: si es nuevo, lo crea apagado; si ya existe, lo deja como está.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

ENABLED="false"; BEFORE=""
check_outputs() {
  local bucket role
  bucket="$(tf infra/inference output -raw scores_bucket)" && role="$(tf infra/inference output -raw inference_role_arn)" \
    || die "No se pudieron leer los datos de la infraestructura."
  task "Comprobando el bucket de scores" "Bucket de scores: $bucket" aws s3api head-bucket --bucket "$bucket" \
    || die "El bucket de scores no responde."
  task "Comprobando el rol de ejecución" "Rol de ejecución: ${role##*/}" aws iam get-role --role-name "${role##*/}" --query Role.Arn --output text \
    || die "El rol de ejecución no existe."
}

review() {
  check_aws
  check_state_bucket
  check_terraform
  check_mlflow_state
  check_github_repo
  read_schedule
  BEFORE="$SCHEDULE"
  case "$SCHEDULE" in
    falta)    info "Scheduler semanal: no existe (se crea apagado)" ;;
    DISABLED) ok "Scheduler semanal: apagado (se queda así)" ;;
    ENABLED)  ok "Scheduler semanal: encendido (se queda así)"; ENABLED="true" ;;
  esac
  # infra/inference lee los datos de infra/shared: solo se revisa si ese ya está al día.
  tf_review infra/shared shared/terraform.tfstate || return 0
  tf_review infra/inference inference/terraform.tfstate "-var=schedule_enabled=$ENABLED" || return 0
  check_outputs
}

apply() {
  tf_up infra/shared shared/terraform.tfstate
  tf_up infra/inference inference/terraform.tfstate "-var=schedule_enabled=$ENABLED"
}

verify() {
  check_outputs
  read_schedule
  if [ "$BEFORE" = "falta" ]; then BEFORE="DISABLED"; fi
  [ "$SCHEDULE" = "$BEFORE" ] || die "El scheduler quedó $SCHEDULE y debía quedar $BEFORE. Para apagarlo: make inference-down"
  if [ "$SCHEDULE" = "ENABLED" ]; then ok "Scheduler semanal: encendido"; else ok "Scheduler semanal: apagado"; fi
}

run_step
