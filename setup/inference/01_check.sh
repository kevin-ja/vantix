# Paso: Requisitos
#
# Solo lee. Comprueba lo que deja listo el entrenamiento y que haya un champion completo y datos.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

check_data_variable() {
  if ! spin "Leyendo las variables de GitHub" gh variable list -R "github.com/$REPO" --env "$ENVIRONMENT" \
      --json name,value --jq '.[] | select(.name == "DATA_BUCKET") | .value'; then
    stop_if_offline
    show_log
    die "No se pudieron leer las variables (ver el error arriba)."
  fi
  [ "$(tail -n 1 "$LOG")" = "$BUCKET" ] || die "La variable DATA_BUCKET falta o tiene otro valor: corre primero make train-up."
  ok "Variables de entrenamiento: DATA_BUCKET correcta"
}

review() {
  check_account
  check_repo
  check_environment
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  read_bucket
  check_champion
  read_lots
  check_data_variable
}

run_step
