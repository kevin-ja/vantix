# GitHub Actions → AWS sin llaves fijas (OIDC). Un rol por workflow, con solo los permisos que usa
# (docs/arch_mlops.md). Los asumen únicamente los jobs del repo que corren en el environment "production".
#   vantix-github-promote          promote.yml           (§5)
#   vantix-github-train            train.yml             (§7, manual)
#   vantix-github-deploy-inference deploy-inference.yml  (§6, ref → upsert; no ejecuta: eso lo hace el scheduler)

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_production_trust" {
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
  assume_role_policy   = data.aws_iam_policy_document.github_production_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_promote" {
  # Encender/apagar el MLflow propio y leer su contraseña (registrar la versión, alias, tags).
  source_policy_documents = [data.aws_iam_policy_document.mlflow_power.json]
  statement {
    sid       = "MLflowPassword"
    actions   = ["ssm:GetParameter"]
    resources = [local.mlflow_password_param_arn]
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

# ---------------------------------------------------------------------------
# train.yml y deploy-inference.yml: subir el código y hacer upsert del pipeline (el de training además lo lanza).
# Los roles de ejecución y los pipelines viven en infra/training e infra/inference: se referencian por nombre.
# ---------------------------------------------------------------------------
locals {
  github_pipeline_roles = {
    train = {
      pipeline  = "${var.project}-training"
      exec_role = "${var.project}-training-exec"
      actions = [
        "sagemaker:StartPipelineExecution",
        "sagemaker:DescribePipelineExecution",
        "sagemaker:ListPipelineExecutionSteps",
      ]
    }
    deploy-inference = {
      pipeline  = "${var.project}-inference"
      exec_role = "${var.project}-inference-exec"
      actions   = []
    }
  }
}

resource "aws_iam_role" "github_pipeline" {
  for_each             = local.github_pipeline_roles
  name                 = "${var.project}-github-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.github_production_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_pipeline" {
  for_each = local.github_pipeline_roles

  statement {
    sid = "Pipeline"
    actions = concat([
      "sagemaker:CreatePipeline",
      "sagemaker:UpdatePipeline",
      "sagemaker:DescribePipeline",
      "sagemaker:AddTags",
      "sagemaker:ListTags",
    ], each.value.actions)
    resources = [
      "arn:aws:sagemaker:${var.region}:${local.account_id}:pipeline/${each.value.pipeline}",
      "arn:aws:sagemaker:${var.region}:${local.account_id}:pipeline/${each.value.pipeline}/*",
    ]
  }
  statement {
    sid       = "PassExecRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${each.value.exec_role}"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["sagemaker.amazonaws.com"]
    }
  }
  statement {
    sid       = "Bucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.data.arn]
  }
  statement {
    sid       = "Code"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.data.arn}/pipelines/*"]
  }
}

resource "aws_iam_role_policy" "github_pipeline" {
  for_each = local.github_pipeline_roles
  name     = each.key
  role     = aws_iam_role.github_pipeline[each.key].id
  policy   = data.aws_iam_policy_document.github_pipeline[each.key].json
}

# train.yml enciende el MLflow propio si está apagado (el paso Train registra en él) y lo apaga al terminar.
resource "aws_iam_role_policy" "github_train_mlflow" {
  name   = "mlflow-power"
  role   = aws_iam_role.github_pipeline["train"].id
  policy = data.aws_iam_policy_document.mlflow_power.json
}
