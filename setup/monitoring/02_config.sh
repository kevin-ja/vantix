# Paso: Correo de alertas y bucket de datos
#
# Guarda en monitorization/infra/terraform.tfvars (no se sube a git) el correo de .env y el bucket de datos, que se lee de
# la infraestructura. Conserva lo demás y guarda una copia. No cambia nada en AWS.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

DIR="monitorization/infra"
TFVARS="$ROOT/$DIR/terraform.tfvars"

# expect <variable> <valor>
expect() {
  if [ "$(tfvars_values "$TFVARS" "$1")" = "$2" ]; then ok "$1 = \"$2\""; else todo "$1: falta o tiene otro valor"; fi
}

review() {
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  expect alert_email "$ALERT_EMAIL"
  expect data_bucket "$BUCKET"
}

# save <variable> <valor>
save() {
  local before
  before="$(tfvars_values "$TFVARS" "$1" | paste -s -d ' ' -)"
  if [ "$before" = "$2" ]; then return 0; fi
  tfvars_set "$TFVARS" "$1" "$2" || die "No se pudo escribir $DIR/terraform.tfvars."
  if [ -n "$before" ]; then info "$1: antes decía $before (se guardó una copia)"; fi
  if [ "$1" = "alert_email" ]; then warn "AWS pedirá confirmar ese correo cuando se aplique el cambio (paso siguiente)."; fi
}

apply() {
  save alert_email "$ALERT_EMAIL"
  save data_bucket "$BUCKET"
  if ! terraform fmt - < "$TFVARS" >"$LOG" 2>&1; then show_log; die "$DIR/terraform.tfvars no es un archivo válido de Terraform (ver el error arriba)."; fi
}

verify() {
  expect alert_email "$ALERT_EMAIL"
  expect data_bucket "$BUCKET"
}

run_step
