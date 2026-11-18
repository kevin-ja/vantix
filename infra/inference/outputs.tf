output "inference_role_arn" {
  value = aws_iam_role.inference.arn
}

output "data_bucket" {
  value = local.shared.data_bucket
}

output "scores_bucket" {
  value = aws_s3_bucket.scores.bucket
}

output "schedule_name" {
  value = aws_scheduler_schedule.weekly.name
}

output "schedule_state" {
  value = aws_scheduler_schedule.weekly.state
}

output "region" {
  value = var.region
}
