variable "name" {
  description = "Prefijo de todos los recursos."
  type        = string
  default     = "vantix-monitoring"
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

variable "data_bucket" {
  description = "Bucket de datos de Vantix (solo lectura: raw/ y models/champion/)."
  type        = string
}

variable "alert_email" {
  description = "Correo que recibe las alertas (y remitente). SES lo verifica: llega un correo de confirmación."
  type        = string
}

variable "image_tag" {
  description = "Tag inmutable de la imagen del backend en ECR (commit; lo pasa el Makefile)."
  type        = string
}

variable "instance_type" {
  description = "t3.small (2 vCPU, 2 GB): Postgres + Grafana + un job de pandas sobre ~850k filas (con swap)."
  type        = string
  default     = "t3.small"
}

variable "availability_zone" {
  description = "AZ de la EC2 y del volumen EBS de datos (tienen que coincidir)."
  type        = string
  default     = "us-east-1a"
}

variable "data_volume_size" {
  description = "GB del volumen EBS persistente (datos de Postgres y Grafana)."
  type        = number
  default     = 10
}

# Reproducibilidad: AMI fija (Amazon Linux 2023 bloquea sus repositorios a la versión de la AMI).
variable "ami_id" {
  description = "AMI de Amazon Linux 2023 (x86_64) fijada; la misma que usa mlflow_server."
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
