terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 기존 terraform state와 분리된 독립 backend
  backend "s3" {
    bucket         = "y2ks-terraform-state-951913065915"
    key            = "monitoring/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "y2ks-terraform-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "y2ks-terraform-state-951913065915"
    key    = "terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  oidc_issuer = data.terraform_remote_state.infra.outputs.oidc_issuer
}
