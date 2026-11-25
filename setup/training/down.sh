# Paso: Apagar MLflow
#
# Apaga la EC2 de MLflow. No borra nada: su estado vive en S3 y `make train-up` la vuelve a encender.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

TAG="vantix-mlflow-server"   # etiqueta Name de la EC2: el id cambia al reemplazarse
INSTANCE=""
review() {
  check_aws
  spin "Buscando la EC2 de MLflow" aws ec2 describe-instances --region "$REGION" --output text \
    --filters "Name=tag:Name,Values=$TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' || { show_log; die "No se pudo buscar la EC2."; }
  INSTANCE="$(awk '{print $1; exit}' "$LOG")"
  if [ -z "$INSTANCE" ] || [ "$INSTANCE" = "None" ]; then ok "No hay EC2 de MLflow: nada que apagar"; return 0; fi
  ec2_state "$INSTANCE"
  case "$STATE" in
    stopped|stopping) ok "EC2 $INSTANCE: ya estaba apagada" ;;
    *) todo "EC2 $INSTANCE: $STATE" ;;
  esac
}

apply() {
  # Un entrenamiento registra en MLflow: apagarlo a mitad lo haría fallar.
  if spin "Buscando entrenamientos en curso" aws sagemaker list-pipeline-executions --region "$REGION" --pipeline-name vantix-training \
      --query "PipelineExecutionSummaries[?PipelineExecutionStatus=='Executing'].PipelineExecutionArn" --output text; then
    if grep '^arn:' "$LOG" >/dev/null; then
      warn "Hay un entrenamiento en curso: si apagas MLflow, fallará."
      confirm "¿Apagar de todos modos?" || die "No se apagó MLflow."
    fi
  elif ! grep -E 'ResourceNotFound|does not exist' "$LOG" >/dev/null; then
    show_log
    die "No se pudo comprobar si hay un entrenamiento en curso. No se apagó MLflow."
  fi
  ensure_stopped "$INSTANCE"
}

verify() {
  warn "La IP y el disco se siguen cobrando (~USD 5/mes). Para encenderla: make train-up"
}

run_step
