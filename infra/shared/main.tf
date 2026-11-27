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

# MLflow: servidor propio en mlflow_server/ (ver mlflow.tf), con sus artefactos en su propio bucket.
