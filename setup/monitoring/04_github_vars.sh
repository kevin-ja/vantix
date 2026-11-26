# Paso: Conectar GitHub con el monitoreo
#
# Carga en tu repo las 3 variables que usan los workflows del monitoreo. Van a nivel de repo, no en `production`: esos
# workflows no piden aprobación porque no tocan el modelo ni los scores. No son secretos.
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

ROLE_PATTERN="^arn:aws:iam::ACCOUNT:role/[A-Za-z0-9+=,.@_/-]+$"
SPECS=(
  "GH_MONITORING_CI_ROLE_ARN|monitorization/infra|github_ci_role_arn|$ROLE_PATTERN"
  "GH_MONITORING_RUN_ROLE_ARN|monitorization/infra|github_run_role_arn|$ROLE_PATTERN"
  "MONITORING_GRAFANA_URL|monitorization/infra|grafana_url|^https://[A-Za-z0-9.-]+$"
)
SCOPE="repo"; SOURCE="make monitoring-up"; TRUST_ROLE="GH_MONITORING_RUN_ROLE_ARN"; TRUST_SUB="ref:refs/heads/main"

review() {
  check_account
  check_repo
  check_aws
  check_state_bucket
  check_terraform
  tf_init monitorization/infra monitorization/terraform.tfstate
  read_values
  check_trust
  read_current
  compare
}

apply() { save_pending; }

verify() { read_current; compare; }

run_step
