terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Configuración parcial: el Makefile pasa bucket, key, region y profile (make up-inference).
  backend "s3" {}
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "vantix"
      Layer     = "inference"
      ManagedBy = "terraform"
    }
  }
}
