# Recursos compartidos por training e inference: bucket de datos/artefactos (+ consumo del MLflow propio, mlflow.tf).

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.project}-${local.account_id}-data"
}

# ---------------------------------------------------------------------------
# S3: raw/, silver/, models/, pipelines/ (código de los jobs), mlflow/ (artefactos del MLflow viejo, solo lectura histórica)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "data" {
  bucket = local.bucket_name

  # Sin esto el destroy falla con un bucket versionado no vacío; ojo: un terraform destroy borra todos los datos.
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

# MLflow: servidor propio en mlflow_server/ (ver mlflow.tf). El MLflow administrado de SageMaker se dio de baja
# el 2026-11-18 tras migrar su registry; sus artefactos viejos siguen en s3://…/mlflow/ (mapa de IDs en
# s3://…/mlflow-migration/).
