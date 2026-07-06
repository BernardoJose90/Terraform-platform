###############################################################################
# Account: Security
# Email  : james.jose109099+aws-security@gmail.com
# Purpose: GuardDuty delegated admin, Security Hub, IAM Access Analyzer
###############################################################################

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"   # same bucket as management
    key          = "security/terraform.tfstate"  # different key
    region       = "eu-west-2"
    use_lockfile = true                            # native S3 locking
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ONE module call — merged, not duplicated. Path matches your existing
# working reference ("../modules/..."); if your actual directory depth
# needs "../../modules/..." instead, use whichever one your OTHER already-
# working stacks use — just make sure this file only has ONE such block.
module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name          = "security"           # change per account
}
