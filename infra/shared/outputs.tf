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

output "mlflow_tracking_server_name" {
  value = aws_sagemaker_mlflow_tracking_server.this.tracking_server_name
}

# Tracking URI para mlflow.set_tracking_uri() (requiere el paquete sagemaker-mlflow).
output "mlflow_tracking_arn" {
  value = aws_sagemaker_mlflow_tracking_server.this.arn
}

output "mlflow_tracking_url" {
  value = aws_sagemaker_mlflow_tracking_server.this.tracking_server_url
}
