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
