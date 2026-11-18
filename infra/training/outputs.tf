output "training_role_arn" {
  value = aws_iam_role.training.arn
}

output "data_bucket" {
  value = local.shared.data_bucket
}

output "mlflow_tracking_arn" {
  value = local.shared.mlflow_tracking_arn
}

output "region" {
  value = var.region
}
