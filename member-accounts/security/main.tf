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
    bucket       = "james-terraform-state-2026"
    key          = "security/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

# ✅ Provider for reading SSM from management account
provider "aws" {
  alias   = "management"
  region  = var.aws_region
  profile = "management"
}

# ✅ Read the development account ID from SSM
data "aws_ssm_parameter" "security_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/security"
}

# ✅ Provider for Development account - NO assume_role needed!
provider "aws" {
  region  = var.aws_region
  profile = "security" # 👈 Uses your SSO profile directly

  # ✅ This ensures we only deploy to the development account
  allowed_account_ids = [data.aws_ssm_parameter.security_account_id.value]

  
}

# ✅ Modules
module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name = "security"
}

# Optional: Add VPC if needed
# module "vpc" {
#   source = "../../modules/vpc"
#   name   = "security-vpc"
#   cidr   = "10.1.0.0/16"
# }