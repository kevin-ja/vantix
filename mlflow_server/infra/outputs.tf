output "tracking_uri" {
  description = "MLFLOW_TRACKING_URI de los clientes (HTTPS vía CloudFront)."
  value       = "https://${aws_cloudfront_distribution.mlflow.domain_name}"
}

output "instance_id" {
  value = aws_instance.mlflow.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.mlflow.repository_url
}

output "bucket" {
  value = aws_s3_bucket.mlflow.bucket
}

output "admin_password_parameter" {
  description = "Parámetro SSM con la contraseña de admin (usuario: admin)."
  value       = aws_ssm_parameter.admin_password.name
}

output "image_uri" {
  value = local.image_uri
}
