# Inferencia batch semanal: bucket de scores, rol de ejecución del pipeline y EventBridge Scheduler.
# El pipeline en sí NO se crea aquí: lo crea/actualiza pipelines/inference/pipeline_sagemaker.py (upsert).

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket  = var.state_bucket
    key     = "shared/terraform.tfstate"
    region  = var.region
    profile = var.aws_profile
  }
}

locals {
  shared       = data.terraform_remote_state.shared.outputs
  account_id   = local.shared.account_id
  data_arn     = local.shared.data_bucket_arn
  pipeline_arn = "arn:aws:sagemaker:${var.region}:${local.account_id}:pipeline/${var.pipeline_name}"
}

# ---------------------------------------------------------------------------
# S3: bucket de scores (lo escribe solo el pipeline; lo lee la API de campañas)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "scores" {
  bucket = "${var.project}-${local.account_id}-scores"

  # Los scores se pueden regenerar: make down-inference los borra.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "scores" {
  bucket = aws_s3_bucket.scores.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "scores" {
  bucket                  = aws_s3_bucket.scores.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scores" {
  bucket = aws_s3_bucket.scores.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Solo lectura para la API de campañas (si se pasa su rol).
data "aws_iam_policy_document" "campaign_read" {
  count = var.campaign_api_role_arn == "" ? 0 : 1

  statement {
    sid       = "CampaignApiList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.scores.arn]
    principals {
      type        = "AWS"
      identifiers = [var.campaign_api_role_arn]
    }
  }
  statement {
    sid       = "CampaignApiRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.scores.arn}/scores/*"]
    principals {
      type        = "AWS"
      identifiers = [var.campaign_api_role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "scores" {
  count      = var.campaign_api_role_arn == "" ? 0 : 1
  bucket     = aws_s3_bucket.scores.id
  policy     = data.aws_iam_policy_document.campaign_read[0].json
  depends_on = [aws_s3_bucket_public_access_block.scores]
}

# ---------------------------------------------------------------------------
# IAM: rol de ejecución del pipeline y de su Processing job
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "sagemaker_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "inference" {
  name               = "${var.project}-inference-exec"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_trust.json
}

data "aws_iam_policy_document" "inference" {
  # Bucket de datos: lee raw/ y models/champion/; lee y escribe el código de los jobs (pipelines/).
  statement {
    sid       = "DataList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.data_arn]
  }
  statement {
    sid       = "DataRead"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.data_arn}/raw/*", "${local.data_arn}/models/champion/*"]
  }
  statement {
    sid       = "JobCode"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.data_arn}/pipelines/*"]
  }

  # Bucket de scores: única salida.
  statement {
    sid       = "ScoresList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.scores.arn]
  }
  statement {
    sid       = "ScoresWrite"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.scores.arn}/*"]
  }

  # El pipeline lanza y monitorea su Processing job.
  statement {
    sid = "SageMakerJobs"
    actions = [
      "sagemaker:CreateProcessingJob",
      "sagemaker:DescribeProcessingJob",
      "sagemaker:StopProcessingJob",
      "sagemaker:AddTags",
      "sagemaker:ListTags",
    ]
    resources = ["arn:aws:sagemaker:${var.region}:${local.account_id}:*"]
  }

  # Imagen oficial de scikit-learn (ECR de AWS).
  statement {
    sid = "ECRPull"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["*"]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/sagemaker/*"]
  }
  statement {
    sid       = "Metrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "inference" {
  name   = "inference-exec"
  role   = aws_iam_role.inference.id
  policy = data.aws_iam_policy_document.inference.json
}

# El pipeline pasa este mismo rol a su job.
data "aws_iam_policy_document" "pass_role" {
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.inference.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "pass_role" {
  name   = "pass-role"
  role   = aws_iam_role.inference.id
  policy = data.aws_iam_policy_document.pass_role.json
}

# ---------------------------------------------------------------------------
# EventBridge Scheduler: lanza el pipeline cada semana con parámetros "auto"
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.project}-inference-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["sagemaker:StartPipelineExecution"]
    resources = [local.pipeline_arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-pipeline"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "weekly" {
  name                         = "${var.project}-inference-weekly"
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "UTC"
  state                        = var.schedule_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  # Fechas "auto" (= defaults del pipeline). AWS exige al menos un parámetro en el target.
  target {
    arn      = local.pipeline_arn
    role_arn = aws_iam_role.scheduler.arn

    sagemaker_pipeline_parameters {
      pipeline_parameter {
        name  = "IngestDate"
        value = "auto"
      }
      pipeline_parameter {
        name  = "SnapshotDate"
        value = "auto"
      }
      pipeline_parameter {
        name  = "ScoringDate"
        value = "auto"
      }
    }

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
