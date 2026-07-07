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

# First provider with alias for reading SSM
provider "aws" {
  alias  = "management"
  region = var.aws_region
}

data "aws_ssm_parameter" "development_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/development"
}

# Use terraform_data to resolve the value without alias issues
resource "terraform_data" "dev_account_id" {
  input = data.aws_ssm_parameter.development_account_id.value
}

# Default provider with assume_role
provider "aws" {
  region = var.aws_region
  
  allowed_account_ids = [terraform_data.dev_account_id.input]
  
  assume_role {
    role_arn     = "arn:aws:iam::${terraform_data.dev_account_id.input}:role/OrganizationAccountAccessRole"
    session_name = "TerraformDev"
  }
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

