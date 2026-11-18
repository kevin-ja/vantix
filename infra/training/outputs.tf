output "training_role_arn" {
  value = aws_iam_role.training.arn
}

output "data_bucket" {
  value = local.shared.data_bucket
}

output "mlflow_tracking_uri" {
  value = local.shared.mlflow_tracking_uri
}

output "mlflow_password_param" {
  value = local.shared.mlflow_password_param
}

output "region" {
  value = var.region
}
