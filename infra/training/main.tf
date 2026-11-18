# Rol de ejecución del pipeline de entrenamiento (SageMaker Pipelines + Processing/Training jobs).
# El pipeline en sí NO se crea aquí: lo crea/actualiza pipelines/training/pipeline_sagemaker.py (upsert).

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
  shared     = data.terraform_remote_state.shared.outputs
  account_id = local.shared.account_id
  bucket_arn = local.shared.data_bucket_arn
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "training" {
  name               = "${var.project}-training-exec"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "training" {
  # Datos, features, código de los jobs y artefactos.
  statement {
    sid       = "S3Bucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "S3Objects"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/*"]
  }

  # El pipeline lanza y monitorea sus jobs.
  statement {
    sid = "SageMakerJobs"
    actions = [
      "sagemaker:CreateProcessingJob",
      "sagemaker:DescribeProcessingJob",
      "sagemaker:StopProcessingJob",
      "sagemaker:CreateTrainingJob",
      "sagemaker:DescribeTrainingJob",
      "sagemaker:StopTrainingJob",
      "sagemaker:AddTags",
      "sagemaker:ListTags",
    ]
    resources = ["arn:aws:sagemaker:${var.region}:${local.account_id}:*"]
  }

  # Los jobs registran en MLflow.
  statement {
    sid       = "MLflow"
    actions   = ["sagemaker-mlflow:*", "sagemaker:DescribeMlflowTrackingServer"]
    resources = [local.shared.mlflow_tracking_arn]
  }

  # Imágenes oficiales de scikit-learn (ECR de AWS).
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

  # Logs y métricas de los jobs.
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

resource "aws_iam_role_policy" "training" {
  name   = "training-exec"
  role   = aws_iam_role.training.id
  policy = data.aws_iam_policy_document.training.json
}

# El pipeline pasa este mismo rol a sus jobs.
data "aws_iam_policy_document" "pass_role" {
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.training.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "pass_role" {
  name   = "pass-role"
  role   = aws_iam_role.training.id
  policy = data.aws_iam_policy_document.pass_role.json
}
