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

variable "github_repo" {
  description = <<-EOT
    Repositorio cuyos workflows pueden asumir roles vía OIDC, tal como lo envía GitHub en el claim `sub`:
    owner@<id>/repo@<id> (IDs inmutables; un repo recreado con el mismo nombre tiene otro id y no entra).
    IDs: gh api repos/kevin-ja/vantix --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'
  EOT
  type        = string
  default     = "kevin-ja@176353864/vantix@1463070333"
}
