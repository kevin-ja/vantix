# Paso: Conectar GitHub con la infraestructura
#
# Carga en `production` las 4 variables que usan los workflows de inferencia. Salen de la infraestructura y no son secretos.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

ROLE_PATTERN="^arn:aws:iam::ACCOUNT:role/[A-Za-z0-9+=,.@_/-]+$"
SPECS=(
  "SCORES_BUCKET|infra/inference|scores_bucket|^[a-z0-9.-]{3,63}$"
  "INFERENCE_EXEC_ROLE_ARN|infra/inference|inference_role_arn|$ROLE_PATTERN"
  "GH_DEPLOY_INFERENCE_ROLE_ARN|infra/shared|github_deploy_inference_role_arn|$ROLE_PATTERN"
  "GH_BATCH_INFERENCE_ROLE_ARN|infra/shared|github_batch_inference_role_arn|$ROLE_PATTERN"
)
SCOPE="env"; SOURCE="make inference-up"; TRUST_ROLE="GH_DEPLOY_INFERENCE_ROLE_ARN"; TRUST_SUB="environment:production"

review() {
  check_account
  check_repo
  check_environment
  check_aws
  check_state_bucket
  check_terraform
  tf_init infra/shared shared/terraform.tfstate
  tf_init infra/inference inference/terraform.tfstate
  read_values
  check_trust
  read_current
  compare
}

apply() { save_pending; }

verify() { read_current; compare; }

run_step
