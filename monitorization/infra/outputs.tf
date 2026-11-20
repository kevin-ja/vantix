output "grafana_url" {
  description = "Grafana (HTTPS vía CloudFront). Usuario: admin."
  value       = "https://${aws_cloudfront_distribution.grafana.domain_name}"
}

output "instance_id" {
  value = aws_instance.server.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "monitoring_bucket" {
  value = aws_s3_bucket.monitoring.bucket
}

output "grafana_password_parameter" {
  description = "Parámetro SSM con la contraseña de admin de Grafana."
  value       = aws_ssm_parameter.grafana_password.name
}

output "image_parameter" {
  description = "Parámetro SSM con el tag vigente del backend (lo escribe ci_monitoring.yml)."
  value       = aws_ssm_parameter.backend_image.name
}

output "github_ci_role_arn" {
  value = aws_iam_role.github_ci.arn
}

output "github_run_role_arn" {
  value = aws_iam_role.github_run.arn
}
