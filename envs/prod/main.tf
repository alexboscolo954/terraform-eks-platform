# prod environment. State: S3 with native locking (use_lockfile, Terraform >= 1.11).
#   terraform init -backend-config="bucket=<state-bucket>"
#   terraform plan -var-file=prod.tfvars
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
  backend "s3" {
    key          = "eks-platform/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

variable "aws_account_id" {
  description = "The only account this environment may touch (guards against a wrong profile)."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "admin_role_arns" {
  type = list(string)
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]
  default_tags {
    tags = { repo = "terraform-eks-platform" }
  }
}

module "platform" {
  source          = "../../modules/platform"
  name            = "platform-prod"
  environment     = "prod"
  admin_role_arns = var.admin_role_arns
}

output "cluster_name" {
  value = module.platform.cluster_name
}

output "posture" {
  value = module.platform.posture
}
