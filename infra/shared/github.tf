# GitHub Actions → AWS sin llaves fijas (OIDC). Un rol por workflow, con solo los permisos que usa
# (docs/arch_mlops.md). Los asumen únicamente los jobs del repo que corren en el environment "production".
#   vantix-github-promote          promote_best_model_manual.yml, rollback_model_manual.yml  (§5)
#   vantix-github-train            train_pipeline_manual.yml                                  (§7)
#   vantix-github-deploy-inference deploy_inference.yml          (§6, ref → upsert; no ejecuta)
#   vantix-github-batch-inference  batch_inference_manual.yml    (§7, solo ejecuta; no actualiza el pipeline)

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
  # Artefactos de MLflow: por el proxy del servidor propio (sin S3). Aquí solo el champion exportado.
  statement {
    sid       = "ReadModels"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.data.arn}/models/*"]
  }
  statement {
    sid       = "WriteChampion"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.data.arn}/models/champion/*"]
  }
}

resource "aws_iam_role_policy" "github_promote" {
  name   = "promote"
  role   = aws_iam_role.github_promote.id
  policy = data.aws_iam_policy_document.github_promote.json
}

# ---------------------------------------------------------------------------
# train_pipeline_manual.yml y deploy_inference.yml: subir el código y hacer upsert del pipeline (el de training además lo lanza).
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

# train_pipeline_manual.yml enciende el MLflow propio si está apagado (data_processing y model_training registran en él) y lo apaga al terminar.
resource "aws_iam_role_policy" "github_train_mlflow" {
  name   = "mlflow-power"
  role   = aws_iam_role.github_pipeline["train"].id
  policy = data.aws_iam_policy_document.mlflow_power.json
}

# ---------------------------------------------------------------------------
# batch_inference_manual.yml: solo EJECUTA vantix-inference (no lo actualiza, para no deshacer un rollback de
# código) y lee latest.json del bucket de scores. Sin PassRole: el pipeline ya tiene su rol de ejecución.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "github_batch_inference" {
  name                 = "${var.project}-github-batch-inference"
  assume_role_policy   = data.aws_iam_policy_document.github_production_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_batch_inference" {
  statement {
    sid = "RunInferencePipeline"
    actions = [
      "sagemaker:StartPipelineExecution",
      "sagemaker:DescribePipelineExecution",
      "sagemaker:ListPipelineExecutionSteps",
    ]
    resources = [
      "arn:aws:sagemaker:${var.region}:${local.account_id}:pipeline/${var.project}-inference",
      "arn:aws:sagemaker:${var.region}:${local.account_id}:pipeline/${var.project}-inference/*",
    ]
  }
  statement {
    sid       = "ReadLatestScores"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.project}-${local.account_id}-scores/scores/latest.json"]
  }
}

resource "aws_iam_role_policy" "github_batch_inference" {
  name   = "batch-inference"
  role   = aws_iam_role.github_batch_inference.id
  policy = data.aws_iam_policy_document.github_batch_inference.json
}

