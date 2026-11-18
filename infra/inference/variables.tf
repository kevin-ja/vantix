variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  type    = string
  default = "vantix"
}

variable "project" {
  type    = string
  default = "vantix"
}

variable "state_bucket" {
  description = "Bucket del estado de Terraform (lo pasa el Makefile) para leer los outputs de shared."
  type        = string
}

variable "pipeline_name" {
  description = "Nombre del pipeline de SageMaker (debe coincidir con pipelines/inference/pipeline_sagemaker.py)."
  type        = string
  default     = "vantix-inference"
}

variable "schedule_expression" {
  description = "Cuándo corre la inferencia (UTC). Por defecto: lunes 06:00."
  type        = string
  default     = "cron(0 6 ? * MON *)"
}

variable "schedule_enabled" {
  description = "El scheduler se crea apagado; activar con TF_VAR_schedule_enabled=true tras validar una corrida manual."
  type        = bool
  default     = false
}

variable "campaign_api_role_arn" {
  description = "Rol IAM de la API de campañas (solo lectura del bucket de scores). Vacío = no se da acceso."
  type        = string
  default     = ""
}
