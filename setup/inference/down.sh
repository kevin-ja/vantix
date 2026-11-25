# Paso: Apagar la corrida semanal
#
# Apaga el scheduler. No borra nada: los scores, el pipeline y los roles se quedan. Es lo único que corre solo.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

review() {
  check_aws
  read_schedule
  case "$SCHEDULE" in
    falta)    ok "No hay corrida semanal: nada que apagar" ;;
    DISABLED) ok "Corrida semanal: ya estaba apagada" ;;
    ENABLED)  todo "Corrida semanal: encendida" ;;
  esac
}

apply() {
  check_state_bucket
  check_terraform
  tf_init infra/inference inference/terraform.tfstate
  if tf_plan infra/inference "-var=schedule_enabled=false"; then
    die "Terraform no ve cambios, pero el scheduler está $SCHEDULE: revisa infra/inference."
  fi
  show_plan infra/inference
  approve_plan infra/inference
  # Apagar no debe arrastrar otros cambios sin avisar.
  if grep -E '^  # .* (will be|must be|is tainted)' "$WORK/plan.txt" | grep -vE '^  # aws_scheduler_schedule\.weekly ' >/dev/null; then
    warn "El plan también cambia otras cosas (arriba)."
    confirm "¿Aplicarlo?" || die "No se cambió nada."
  fi
  tf_apply infra/inference
}

verify() {
  read_schedule
  [ "$SCHEDULE" = "DISABLED" ] || die "El scheduler quedó $SCHEDULE y debía quedar apagado."
  ok "Corrida semanal: apagada"
}

run_step
