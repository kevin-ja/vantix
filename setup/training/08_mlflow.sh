# Paso: MLflow
#
# Repositorio de imágenes (ECR) → imagen → infraestructura (EC2, CloudFront, S3…) → encendido y respondiendo. 💰
# Si la EC2 está apagada la enciende sin preguntar, e informa.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

NAME="vantix-mlflow"         # prefijo de los recursos: infra/shared y los workflows lo esperan así
DIR="mlflow_server/infra"
KEY="mlflow-server/terraform.tfstate"
HEALTH_WAIT=300              # segundos

IMAGE_TAG=""; VARS=(); URI=""; INSTANCE=""
read_outputs() {
  URI="$(tf "$DIR" output -raw tracking_uri)" && INSTANCE="$(tf "$DIR" output -raw instance_id)" \
    || die "No se pudieron leer los datos de MLflow."
}

DO_IMAGE=0; DO_INFRA=0
review() {
  DO_IMAGE=0; DO_INFRA=0
  check_aws
  check_state_bucket
  check_terraform
  check_committed mlflow_server .
  IMAGE_TAG="$(image_tag mlflow_server docker)"
  [ -n "$IMAGE_TAG" ] || die "No se encontró el commit de mlflow_server/docker."
  VARS=("-var=name=$NAME" "-var=region=$REGION" "-var=image_tag=$IMAGE_TAG" "-var=aws_profile=$PROFILE")
  if image_exists "$NAME" "$IMAGE_TAG"; then ok "Imagen $IMAGE_TAG: ya está en ECR"; else todo "Imagen $IMAGE_TAG: no está en ECR"; DO_IMAGE=1; fi
  if ! tf_review "$DIR" "$KEY" "${VARS[@]}"; then DO_INFRA=1; return 0; fi
  read_outputs
  ec2_state "$INSTANCE"
  if [ "$STATE" != "running" ]; then todo "EC2 $INSTANCE: $STATE"; return 0; fi
  ok "EC2 $INSTANCE: encendida"
  if responds "$URI/health"; then ok "MLflow: responde en $URI (usuario admin)"; else todo "MLflow: no responde en $URI"; fi
}

apply() {
  if [ "$DO_IMAGE" -eq 1 ]; then
    docker info >/dev/null 2>&1 || die "Docker está apagado: ábrelo y vuelve a correr $SETUP_COMMAND"
    info "Repositorio de imágenes (ECR)"
    live tf_lines tf "$DIR" apply -input=false -no-color -auto-approve "${VARS[@]}" -target=aws_ecr_repository.mlflow \
      || { show_log; die "No se pudo crear el repositorio (ver el error arriba)."; }
    info "Construyendo y subiendo la imagen $IMAGE_TAG (la primera vez tarda varios minutos)"
    build_image "$DIR" "$IMAGE_TAG" "$ROOT/mlflow_server/docker" || { show_log; die "No se pudo construir o subir la imagen (ver el error arriba)."; }
    ok "Imagen $IMAGE_TAG: subida"
  fi
  # Crear el repositorio cambia el estado: el plan se calcula siempre después.
  if [ "$((DO_IMAGE + DO_INFRA))" -gt 0 ]; then tf_up "$DIR" "$KEY" "${VARS[@]}"; fi
  read_outputs
  ensure_running "$INSTANCE"
}

verify() {
  if [ -z "$INSTANCE" ]; then read_outputs; fi
  spin "Esperando a que MLflow responda (hasta $HEALTH_WAIT s)" wait_health "$URI/health" "$HEALTH_WAIT" \
    || die "La EC2 está encendida, pero MLflow no respondió en $HEALTH_WAIT s. Espera unos minutos y vuelve a correr $SETUP_COMMAND"
  ok "MLflow: encendido y respondiendo en $URI (usuario admin)"
  warn "La EC2 queda encendida y cobrando. Para apagarla: make train-down"
}

run_step
