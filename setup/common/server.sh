# Servidores propios (MLflow y monitoreo): imagen en ECR, EC2 y espera de respuesta. Compatible con bash 3.2.

# La imagen se etiqueta con un commit: el código tiene que estar commiteado.
# check_committed <carpeta> <rutas…> (relativas a la carpeta)
check_committed() {
  local dir="$1" dirty
  shift
  dirty="$(git -C "$ROOT/$dir" status --porcelain -- "$@")" || die "No se pudo leer el estado de git."
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
    die "Hay cambios sin commitear en $dir/ (arriba): haz commit y vuelve a intentarlo."
  fi
  if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = "true" ]; then
    die "El repo se clonó sin historial (--depth) y la etiqueta de la imagen saldría mal. Corre: git fetch --unshallow"
  fi
}

# image_tag <carpeta> <rutas…> -> último commit que tocó la imagen
image_tag() { local dir="$1"; shift; git -C "$ROOT/$dir" log -1 --format=%h -- "$@"; }

# image_exists <repositorio> <etiqueta> -> 0 existe, 1 no existe. Si ECR no responde, se detiene.
image_exists() {
  spin "Buscando la imagen $2" aws ecr describe-images --region "$REGION" --repository-name "$1" \
    --image-ids "imageTag=$2" --output text && return 0
  grep -E 'RepositoryNotFoundException|ImageNotFoundException' "$LOG" >/dev/null && return 1
  show_log
  die "No se pudo consultar ECR (ver el error arriba)."
}

# Deja pasar solo los pasos del Dockerfile y la subida.
docker_lines() { awk '/^#[0-9]+ \[/ { sub(/^#[0-9]+ /, ""); print "  → " $0; fflush() } /pushing (layers|manifest)/ && !seen[$0]++ { print "  → subiendo la imagen"; fflush() }'; }

# build_image <módulo de Terraform> <etiqueta> <opciones de docker build…>
push_image() {
  local repo="$1" tag="$2"
  shift 2
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${repo%%/*}" || return 1
  docker buildx build --progress=plain --platform linux/amd64 --provenance=false -t "$repo:$tag" --push "$@"
}
build_image() {
  local module="$1" tag="$2" repo
  shift 2
  repo="$(tf "$module" output -raw ecr_repository_url)" || return 1
  live docker_lines push_image "$repo" "$tag" "$@"
}

# find_instance <etiqueta Name> -> deja el id en INSTANCE, o vacío si no existe
find_instance() {
  spin "Buscando la EC2" aws ec2 describe-instances --region "$REGION" --output text \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' || { show_log; die "No se pudo buscar la EC2."; }
  INSTANCE="$(awk '{print $1; exit}' "$LOG")"
  if [ "$INSTANCE" = "None" ]; then INSTANCE=""; fi
}

# ec2_state <id> -> deja el estado en STATE
ec2_state() {
  spin "Comprobando la EC2" aws ec2 describe-instances --region "$REGION" --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].State.Name' --output text || { show_log; die "No se pudo leer la EC2 $1."; }
  STATE="$(tail -n 1 "$LOG")"
}

# start_instance <id> <estado>: una EC2 que se está apagando no se puede encender hasta que termine.
start_instance() {
  if [ "$2" = "stopping" ]; then
    aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$1" || return 1
  fi
  aws ec2 start-instances --region "$REGION" --instance-ids "$1" --output text || return 1
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$1"
}

# Enciende la EC2 si está apagada, e informa. ensure_running <id>
ensure_running() {
  ec2_state "$1"
  case "$STATE" in
    running|pending) ok "EC2 $1: ya estaba encendida" ;;
    stopped|stopping)
      info "EC2 $1: apagada ($STATE). Se enciende ahora."
      spin "Encendiendo la EC2" start_instance "$1" "$STATE" || { show_log; die "No se pudo encender la EC2 (ver el error arriba)."; }
      ok "EC2 $1: este setup la encendió" ;;
    *) die "La EC2 $1 está en un estado inesperado: $STATE. Vuelve a intentarlo en unos minutos." ;;
  esac
}

# Apaga la EC2 si está encendida. No borra nada. ensure_stopped <id>
ensure_stopped() {
  ec2_state "$1"
  case "$STATE" in
    stopped|stopping) ok "EC2 $1: ya estaba apagada" ;;
    running|pending)
      task "Apagando la EC2" "EC2 $1: apagada" aws ec2 stop-instances --region "$REGION" --instance-ids "$1" --output text \
        || die "No se pudo apagar la EC2 (ver el error arriba)." ;;
    *) die "La EC2 $1 está en un estado inesperado: $STATE." ;;
  esac
}

responds() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1")" = "200" ]; }

# wait_health <url> <segundos>
wait_health() {
  local start=$SECONDS
  until responds "$1"; do
    if [ $((SECONDS - start)) -ge "$2" ]; then return 1; fi
    sleep "${HEALTH_INTERVAL:-10}"
  done
}
