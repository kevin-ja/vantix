# Paso: Apagar el monitoreo
#
# Apaga la EC2 del monitoreo. No borra nada: los datos viven en un disco aparte y `make monitoring-up` la enciende otra vez.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

TAG="vantix-monitoring-server"   # etiqueta Name de la EC2: el id cambia al reemplazarse
INSTANCE=""
review() {
  check_aws
  find_instance "$TAG"
  if [ -z "$INSTANCE" ]; then ok "No hay EC2 de monitoreo: nada que apagar"; return 0; fi
  ec2_state "$INSTANCE"
  case "$STATE" in
    stopped|stopping) ok "EC2 $INSTANCE: ya estaba apagada" ;;
    *) todo "EC2 $INSTANCE: $STATE" ;;
  esac
}

apply() {
  # El job corre en la EC2 por SSM: apagarla a mitad lo cortaría.
  spin "Buscando corridas en curso" aws ssm list-command-invocations --region "$REGION" --instance-id "$INSTANCE" \
    --filters key=Status,value=InProgress --query 'CommandInvocations[].CommandId' --output text \
    || { show_log; die "No se pudo comprobar si hay una corrida en curso. No se apagó nada."; }
  if [ -s "$LOG" ] && ! grep -x 'None' "$LOG" >/dev/null; then
    warn "Hay una corrida de monitoreo en curso: si apagas la EC2, se corta."
    confirm "¿Apagar de todos modos?" || die "No se apagó la EC2."
  fi
  ensure_stopped "$INSTANCE"
}

verify() {
  warn "La IP y los discos se siguen cobrando (~USD 6/mes). Para encenderla: make monitoring-up"
}

run_step
