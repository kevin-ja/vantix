# GitHub Actions → AWS sin llaves (OIDC), un rol por workflow con solo lo que usa (ver ../doc/ci_cd.md).
# Reutiliza el proveedor OIDC de infra/shared. Sin environment ni aprobación: los asumen solo ejecuciones
# desde main (push a main o workflow_dispatch sobre main).
#   vantix-monitoring-github-ci   ci_monitoring.yml          build + push a ECR + actualiza el puntero SSM
#   vantix-monitoring-github-run  run_monitoring_manual.yml  enciende la EC2 y ejecuta el job por SSM

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_main_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

# --- CI: build + push + puntero -----------------------------------------------------------------
resource "aws_iam_role" "github_ci" {
  name                 = "${var.name}-github-ci"
  assume_role_policy   = data.aws_iam_policy_document.github_main_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_ci" {
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "ECRPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.backend.arn]
  }
  statement {
    sid       = "ImagePointer"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.backend_image.arn]
  }
}

resource "aws_iam_role_policy" "github_ci" {
  name   = "ci"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci.json
}

# --- Run: encender la EC2 y ejecutar el job por SSM ------------------------------------------------
resource "aws_iam_role" "github_run" {
  name                 = "${var.name}-github-run"
  assume_role_policy   = data.aws_iam_policy_document.github_main_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_run" {
  statement {
    sid       = "Describe"
    actions   = ["ec2:DescribeInstances", "ssm:DescribeInstanceInformation", "ssm:GetCommandInvocation"]
    resources = ["*"]
  }
  # Solo la EC2 del monitoreo (por tag: la instancia se reemplaza y cambia de ID).
  statement {
    sid       = "StartStop"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = ["${var.name}-server"]
    }
  }
  statement {
    sid       = "RunCommandOnServer"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["${var.name}-server"]
    }
  }
  statement {
    sid       = "RunCommandDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "ImagePointer"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.backend_image.arn]
  }
}

resource "aws_iam_role_policy" "github_run" {
  name   = "run"
  role   = aws_iam_role.github_run.id
  policy = data.aws_iam_policy_document.github_run.json
}
