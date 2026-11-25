# Paso: Infraestructura de entrenamiento
#
# infra/shared (bucket de datos, OIDC y roles de GitHub) → infra/training (rol de ejecución).
. "$(dirname "${BASH_SOURCE[0]}")/../common/step.sh"

check_outputs() {
  local bucket role
  bucket="$(tf infra/shared output -raw data_bucket)" && role="$(tf infra/training output -raw training_role_arn)" \
    || die "No se pudieron leer los datos de la infraestructura."
  task "Comprobando el bucket de datos" "Bucket de datos: $bucket" aws s3api head-bucket --bucket "$bucket" \
    || die "El bucket de datos no responde."
  task "Comprobando el rol de ejecución" "Rol de ejecución: ${role##*/}" aws iam get-role --role-name "${role##*/}" --query Role.Arn --output text \
    || die "El rol de ejecución no existe."
}

review() {
  check_aws
  check_state_bucket
  check_terraform
  check_mlflow_state
  check_github_repo
  # infra/training lee los datos de infra/shared: solo se revisa si ese ya está al día.
  tf_review infra/shared shared/terraform.tfstate || return 0
  tf_review infra/training training/terraform.tfstate || return 0
  check_outputs
}

apply() {
  tf_up infra/shared shared/terraform.tfstate
  tf_up infra/training training/terraform.tfstate
}

run_step
