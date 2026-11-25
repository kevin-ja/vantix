# Paso: Encender la corrida semanal
#
# Opcional. Corre sola cada lunes 06:00 UTC, sin aprobación y con el ÚLTIMO lote de raw/. Por eso exige un champion, el
# pipeline desplegado y que su última corrida haya terminado bien, muestra qué lote usaría y pregunta.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

PIPELINE="vantix-inference"
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

review() {
  check_aws
  check_state_bucket
  check_terraform
  read_schedule
  case "$SCHEDULE" in
    falta)   die "El scheduler no existe: corre primero make inference-up." ;;
    ENABLED) ok "Corrida semanal: ya estaba encendida" ;;
    *)       todo "Corrida semanal: apagada" ;;
  esac
}

apply() {
  check_pipeline
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  check_champion
  read_lots
  tf_init infra/inference inference/terraform.tfstate
  if tf_plan infra/inference "-var=schedule_enabled=true"; then
    die "Terraform no ve cambios, pero el scheduler está $SCHEDULE: revisa infra/inference."
  fi
  show_plan infra/inference
  approve_plan infra/inference
  warn "Correrá sola cada lunes 06:00 UTC, sin aprobación, y cobra cada vez (~3 min de ml.t3.xlarge)."
  warn "Usará el último lote: $(printf '%s\n' "$LOTS" | tail -n 1). Si sus datos no llegan hasta el día anterior a la corrida, la corrida fallará."
  confirm "¿Encenderla?" || die "No se cambió nada."
  tf_apply infra/inference
}

run_step
