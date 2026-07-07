###############################################################################
# Account: Development 
# Email  : james.jose109099+aws-dev@gmail.com
# Purpose: Dev workload hosting
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
    key          = "development/terraform.tfstate"
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
data "aws_ssm_parameter" "development_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

# ✅ Provider for Development account - NO assume_role needed!
provider "aws" {
  region = var.aws_region
  profile = "development"  # 👈 Uses your SSO profile directly
  
  # ✅ This ensures we only deploy to the development account
  allowed_account_ids = [data.aws_ssm_parameter.development_account_id.value]
  

}

# Modules use the default provider (no alias needed)
module "vpc" {
  source = "../../modules/vpc"
  name   = "dev-vpc"
  cidr   = "10.0.0.0/16"
}

module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name = "development"
}

