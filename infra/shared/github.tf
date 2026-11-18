# GitHub Actions → AWS sin llaves fijas (OIDC). Por ahora, solo el workflow de promoción
# (.github/workflows/promote.yml, docs/arch_mlops.md §5). Lo pueden asumir únicamente los jobs del repo
# que corren en el environment "production", que exige aprobación manual en GitHub.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_promote_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "github_promote" {
  name                 = "${var.project}-github-promote"
  assume_role_policy   = data.aws_iam_policy_document.github_promote_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_promote" {
  # Encender/apagar MLflow y registrar la versión (alias, tags).
  statement {
    sid = "MLflow"
    actions = [
      "sagemaker-mlflow:*",
      "sagemaker:DescribeMlflowTrackingServer",
      "sagemaker:StartMlflowTrackingServer",
      "sagemaker:StopMlflowTrackingServer",
    ]
    resources = [aws_sagemaker_mlflow_tracking_server.this.arn]
  }
  statement {
    sid       = "ListData"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.data.arn]
  }
  # Leer artefactos del run (MLflow) y escribir segment_map en el run + el champion exportado.
  statement {
    sid       = "ReadArtifacts"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.data.arn}/mlflow/*", "${aws_s3_bucket.data.arn}/models/*"]
  }
  statement {
    sid       = "WriteArtifacts"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.data.arn}/mlflow/*", "${aws_s3_bucket.data.arn}/models/champion/*"]
  }
}

resource "aws_iam_role_policy" "github_promote" {
  name   = "promote"
  role   = aws_iam_role.github_promote.id
  policy = data.aws_iam_policy_document.github_promote.json
}
