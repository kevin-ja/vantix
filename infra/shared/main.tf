# Recursos compartidos por training e inference: bucket de datos/artefactos y MLflow.

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.project}-${local.account_id}-data"
}

# ---------------------------------------------------------------------------
# S3: raw/, silver/, mlflow/ (artefactos), pipelines/ (código de los jobs)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "data" {
  bucket = local.bucket_name

  # make down-shared exige CONFIRM=yes; sin esto el destroy falla con un bucket versionado no vacío.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Benchmark fijo (docs/arch_mlops.md §5.1): models/benchmark/ se escribe una sola vez (make benchmark-freeze)
# y luego nadie lo modifica ni lo borra, ni siquiera un administrador. Para cambiarlo hay que quitar esta
# política a propósito (PR + terraform apply).
data "aws_iam_policy_document" "data_bucket" {
  statement {
    sid       = "FreezeBenchmark"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectTagging"]
    resources = ["${aws_s3_bucket.data.arn}/models/benchmark/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = data.aws_iam_policy_document.data_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.data]
}

# ---------------------------------------------------------------------------
# MLflow administrado por SageMaker
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

resource "aws_iam_role" "mlflow" {
  name               = "${var.project}-mlflow"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_trust.json
}

data "aws_iam_policy_document" "mlflow_s3" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.data.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.data.arn}/mlflow/*"]
  }
}

resource "aws_iam_role_policy" "mlflow_s3" {
  name   = "s3-artifacts"
  role   = aws_iam_role.mlflow.id
  policy = data.aws_iam_policy_document.mlflow_s3.json
}

resource "aws_sagemaker_mlflow_tracking_server" "this" {
  tracking_server_name = "${var.project}-mlflow"
  tracking_server_size = var.mlflow_server_size
  role_arn             = aws_iam_role.mlflow.arn
  artifact_store_uri   = "s3://${aws_s3_bucket.data.bucket}/mlflow"

  # Registro solo en el Model Registry de MLflow (promoción manual con alias @champion).
  automatic_model_registration = false

  depends_on = [aws_iam_role_policy.mlflow_s3]
}
