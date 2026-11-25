# Paso: Conectar GitHub con AWS
#
# Carga en `production` las 6 variables que usan los workflows. Salen de la infraestructura y no son secretos.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

ROLE_PATTERN="^arn:aws:iam::ACCOUNT:role/[A-Za-z0-9+=,.@_/-]+$"
SPECS=(
  "DATA_BUCKET|infra/shared|data_bucket|^[a-z0-9.-]{3,63}$"
  "MLFLOW_TRACKING_URI|infra/shared|mlflow_tracking_uri|^https://[A-Za-z0-9.-]+$"
  "MLFLOW_PASSWORD_PARAM|infra/shared|mlflow_password_param|^/[A-Za-z0-9/_.-]+$"
  "GH_TRAIN_ROLE_ARN|infra/shared|github_train_role_arn|$ROLE_PATTERN"
  "GH_PROMOTE_ROLE_ARN|infra/shared|github_promote_role_arn|$ROLE_PATTERN"
  "TRAINING_EXEC_ROLE_ARN|infra/training|training_role_arn|$ROLE_PATTERN"
)
SCOPE="env"; SOURCE="make train-up"; TRUST_ROLE="GH_TRAIN_ROLE_ARN"; TRUST_SUB="environment:production"

review() {
  check_account
  check_repo
  check_environment
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  tf_init infra/training training/terraform.tfstate
  read_values
  check_trust
  read_current
  compare
}

apply() { save_pending; }

verify() { read_current; compare; }

run_step
