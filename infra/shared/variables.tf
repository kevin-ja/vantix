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

variable "mlflow_server_size" {
  description = "Small | Medium | Large. Small cuesta USD 0,60/h mientras está encendido."
  type        = string
  default     = "Small"
}
