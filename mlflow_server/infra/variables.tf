variable "name" {
  description = "Prefijo de todos los recursos."
  type        = string
  default     = "mlflow-server"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  description = "Perfil de AWS CLI (null en CI, donde las credenciales vienen del entorno)."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "t3.small (2 vCPU, 2 GB) alcanza para un equipo chico (ver docs/architecture.md, Alcance)."
  type        = string
  default     = "t3.small"
}

variable "availability_zone" {
  description = "AZ de la subred por defecto donde corre la EC2 (no todas las AZ tienen todos los tipos)."
  type        = string
  default     = "us-east-1a"
}

variable "image_tag" {
  description = "Tag inmutable de la imagen en ECR (commit de git de mlflow_server/; lo pasa el Makefile)."
  type        = string
}

# Reproducibilidad: AMI fija. Amazon Linux 2023 bloquea sus repositorios a la versión de la AMI, así que
# `dnf install docker` instala siempre la misma versión. Para actualizar (a propósito, por PR):
#   aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
variable "ami_id" {
  description = "AMI de Amazon Linux 2023 (x86_64) fijada."
  type        = string
  default     = "ami-00f43ee0e98d52529"
}

variable "compose_version" {
  description = "Versión del plugin Docker Compose (binario de GitHub, verificado por sha256)."
  type        = string
  default     = "v2.32.4"
}

variable "compose_sha256" {
  description = "sha256 de docker-compose-linux-x86_64 para compose_version."
  type        = string
  default     = "ed1917fb54db184192ea9d0717bcd59e3662ea79db48bff36d3475516c480a6b"
}
