#!/bin/bash
# Deploy + ejecución en el servidor de monitoreo (doc/ci_cd.md). Lo instala el arranque de la EC2 en
# /opt/monitoring/monitoring.sh y lo invocan systemd (al arrancar) y run_monitoring_manual.yml (por SSM).
#
#   monitoring.sh prepare          resuelve la imagen del backend (puntero SSM → .env), login en ECR y pull
#   monitoring.sh run <job> [...]  prepare + levanta db/frontend + ejecuta el job (run_monitoring, build_benchmark)
#
# La imagen vigente la decide el CI (ci_monitoring.yml) escribiendo su tag en el parámetro SSM IMAGE_PARAM.
# Variables (en /opt/monitoring/.env, escritas por user_data): AWS_REGION, ECR_REPO, IMAGE_PARAM.
set -euo pipefail
cd /opt/monitoring

env_get() { grep "^$1=" .env | cut -d= -f2-; }
region=$(env_get AWS_REGION)
repo=$(env_get ECR_REPO)
param=$(env_get IMAGE_PARAM)

prepare() {
  local tag image
  tag=$(aws ssm get-parameter --region "$region" --name "$param" --query Parameter.Value --output text)
  image="$repo:$tag"
  if grep -q '^BACKEND_IMAGE=' .env; then
    sed -i "s|^BACKEND_IMAGE=.*|BACKEND_IMAGE=$image|" .env
  else
    echo "BACKEND_IMAGE=$image" >> .env
  fi
  aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "${repo%%/*}" >/dev/null
  docker compose --profile job pull --quiet restore backend
  echo "imagen del backend: $image"
}

case "${1:-}" in
  prepare)
    prepare
    ;;
  run)
    shift
    [ $# -ge 1 ] || { echo "uso: monitoring.sh run <job> [args]" >&2; exit 2; }
    prepare
    docker compose up -d --wait db frontend   # el restore (si la base está vacía) corre antes de frontend
    docker compose run --rm backend "$@"
    ;;
  *)
    echo "uso: monitoring.sh {prepare|run <job> [args]}" >&2
    exit 2
    ;;
esac
