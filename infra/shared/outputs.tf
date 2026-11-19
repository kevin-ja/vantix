output "account_id" {
  value = local.account_id
}

output "region" {
  value = var.region
}

output "data_bucket" {
  value = aws_s3_bucket.data.bucket
}

output "data_bucket_arn" {
  value = aws_s3_bucket.data.arn
}

# Variable AWS_ROLE_ARN del workflow de promoción en GitHub.
output "github_promote_role_arn" {
  value = aws_iam_role.github_promote.arn
}

# Variables GH_*_ROLE_ARN de train_pipeline_manual.yml, deploy_inference.yml y batch_inference_manual.yml.
output "github_train_role_arn" {
  value = aws_iam_role.github_pipeline["train"].arn
}

output "github_deploy_inference_role_arn" {
  value = aws_iam_role.github_pipeline["deploy-inference"].arn
}

# Servidor de MLflow propio (mlflow_server/).
output "mlflow_tracking_uri" {
  value = local.mlflow_tracking_uri
}

output "mlflow_password_param" {
  value = local.mlflow_password_param
}

output "mlflow_password_param_arn" {
  value = local.mlflow_password_param_arn
}

output "mlflow_instance_name" {
  value = local.mlflow_instance_name
}

output "github_batch_inference_role_arn" {
  value = aws_iam_role.github_batch_inference.arn
}

