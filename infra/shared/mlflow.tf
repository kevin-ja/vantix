# Servidor de MLflow propio (mlflow_server/, capa independiente con su propio estado). VANTIX solo lo consume:
# lee su URL y el parámetro SSM de la contraseña, y da a sus roles permiso para usarlo y encenderlo/apagarlo.

data "terraform_remote_state" "mlflow_server" {
  backend = "s3"
  config = {
    bucket  = var.state_bucket
    key     = "mlflow-server/terraform.tfstate"
    region  = var.region
    profile = var.aws_profile
  }
}

locals {
  mlflow_tracking_uri       = data.terraform_remote_state.mlflow_server.outputs.tracking_uri
  mlflow_password_param     = data.terraform_remote_state.mlflow_server.outputs.admin_password_parameter
  mlflow_password_param_arn = "arn:aws:ssm:${var.region}:${local.account_id}:parameter${local.mlflow_password_param}"
  # Tag Name de la EC2 (cambia de id al reemplazarse; el tag no).
  mlflow_instance_name = "${var.mlflow_name}-server"
}

# Encender/apagar la EC2 del servidor (workflows train/promote y make mlflow-start/stop).
data "aws_iam_policy_document" "mlflow_power" {
  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"] # no admite permisos por recurso
  }
  statement {
    sid       = "StartStopMlflowServer"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Name"
      values   = [local.mlflow_instance_name]
    }
  }
}
