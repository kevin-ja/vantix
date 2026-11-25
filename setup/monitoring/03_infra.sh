# Paso: Infraestructura del monitoreo
#
# La primera vez: repositorio de imágenes (ECR) → imagen del backend → infraestructura. Después solo infraestructura: la
# imagen la publica el CI (ci_monitoring). Al final la EC2 queda encendida y Grafana respondiendo. 💰
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

NAME="vantix-monitoring"     # prefijo de los recursos: los workflows lo esperan así
DIR="monitorization/infra"
KEY="monitorization/terraform.tfstate"
TFVARS="$ROOT/$DIR/terraform.tfvars"
IMAGE_PARAM="/$NAME/backend-image"   # etiqueta vigente del backend
HEALTH_WAIT=420              # segundos
# Lo que entra en la imagen: su etiqueta es el último commit que tocó algo de esto.
IMAGE_SOURCES=(docker src ../pipelines/__init__.py ../pipelines/common/__init__.py ../pipelines/common/config.py
  ../pipelines/common/features.py ../pipelines/common/io.py ../pipelines/common/storage.py)

check_config() {
  local key
  for key in data_bucket alert_email github_repo; do
    [ -n "$(tfvars_values "$TFVARS" "$key")" ] || die "Falta $key en $DIR/terraform.tfvars."
  done
  ok "Configuración: completa"
}

IMAGE_TAG=""; VARS=(); URI=""; INSTANCE=""
read_outputs() {
  URI="$(tf "$DIR" output -raw grafana_url)" && INSTANCE="$(tf "$DIR" output -raw instance_id)" \
    || die "No se pudieron leer los datos del monitoreo."
}

print_email() {
  local status
  spin "Comprobando el correo de alertas" aws ses get-identity-verification-attributes --region "$REGION" --identities "$ALERT_EMAIL" \
    --query 'VerificationAttributes.*.VerificationStatus' --output text || { show_log; warn "No se pudo leer el estado del correo."; return 0; }
  status="$(tail -n 1 "$LOG")"
  if [ "$status" = "Success" ]; then ok "Correo de alertas: confirmado"; return 0; fi
  warn "Correo de alertas: sin confirmar (${status:-sin estado}). El monitoreo funciona igual, pero no llegarán correos."
  if [ "$status" = "Pending" ]; then
    info "Abre el correo de Amazon Web Services (revisa spam) y pulsa el enlace: vence a las 24 horas."
  else
    info "Para pedir otro correo de confirmación:"
    info "aws ses verify-email-identity --email-address $ALERT_EMAIL --profile $PROFILE --region $REGION"
  fi
}

DO_IMAGE=0; DO_INFRA=0
review() {
  DO_IMAGE=0; DO_INFRA=0
  check_aws
  check_state_bucket
  check_terraform
  check_config
  check_committed monitorization . "${IMAGE_SOURCES[@]}"
  IMAGE_TAG="$(image_tag monitorization "${IMAGE_SOURCES[@]}")"
  [ -n "$IMAGE_TAG" ] || die "No se encontró el commit de la imagen."
  VARS=("-var=name=$NAME" "-var=region=$REGION" "-var=initial_image_tag=$IMAGE_TAG" "-var=aws_profile=$PROFILE")
  if spin "Buscando la imagen vigente" aws ssm get-parameter --region "$REGION" --name "$IMAGE_PARAM" --query Parameter.Value --output text; then
    ok "Imagen vigente del backend: $(tail -n 1 "$LOG") (la publica el CI)"
  else
    grep 'ParameterNotFound' "$LOG" >/dev/null || { show_log; die "No se pudo leer la imagen vigente (ver el error arriba)."; }
    if image_exists "$NAME-backend" "$IMAGE_TAG"; then
      ok "Imagen $IMAGE_TAG: ya está en ECR"
    else
      todo "Imagen $IMAGE_TAG: no está en ECR"; DO_IMAGE=1
    fi
  fi
  if ! tf_review "$DIR" "$KEY" "${VARS[@]}"; then DO_INFRA=1; return 0; fi
  read_outputs
  print_email
  ec2_state "$INSTANCE"
  if [ "$STATE" != "running" ]; then todo "EC2 $INSTANCE: $STATE"; return 0; fi
  ok "EC2 $INSTANCE: encendida"
  if responds "$URI/api/health"; then ok "Grafana: responde en $URI (usuario admin)"; else todo "Grafana: no responde en $URI"; fi
}

apply() {
  if [ "$DO_IMAGE" -eq 1 ]; then
    docker info >/dev/null 2>&1 || die "Docker está apagado: ábrelo y vuelve a correr $SETUP_COMMAND"
    info "Repositorio de imágenes (ECR)"
    live tf_lines tf "$DIR" apply -input=false -no-color -auto-approve "${VARS[@]}" -target=aws_ecr_repository.backend \
      || { show_log; die "No se pudo crear el repositorio (ver el error arriba)."; }
    info "Construyendo y subiendo la imagen $IMAGE_TAG (la primera vez tarda varios minutos)"
    build_image "$DIR" "$IMAGE_TAG" --build-arg "GIT_COMMIT=$IMAGE_TAG" -f "$ROOT/monitorization/docker/Dockerfile" "$ROOT" \
      || { show_log; die "No se pudo construir o subir la imagen (ver el error arriba)."; }
    ok "Imagen $IMAGE_TAG: subida"
  fi
  # Crear el repositorio cambia el estado: el plan se calcula siempre después.
  if [ "$((DO_IMAGE + DO_INFRA))" -gt 0 ]; then tf_up "$DIR" "$KEY" "${VARS[@]}"; fi
  read_outputs
  ensure_running "$INSTANCE"
}

verify() {
  spin "Esperando a que Grafana responda (hasta $HEALTH_WAIT s)" wait_health "$URI/api/health" "$HEALTH_WAIT" \
    || die "La EC2 está encendida, pero Grafana no respondió en $HEALTH_WAIT s. Espera unos minutos y vuelve a correr $SETUP_COMMAND"
  ok "Grafana: encendido y respondiendo en $URI (usuario admin)"
  info "Contraseña: aws ssm get-parameter --name /$NAME/grafana-admin-password --with-decryption --query Parameter.Value --output text --profile $PROFILE --region $REGION"
  if [ "$DO_INFRA" -eq 1 ]; then print_email; fi
  warn "La EC2 queda encendida y cobrando. Para apagarla: make monitoring-down"
}

run_step
