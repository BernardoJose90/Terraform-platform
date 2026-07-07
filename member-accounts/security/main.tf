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

# ✅ Read the security account ID from SSM
data "aws_ssm_parameter" "account_id" {
  provider = aws.management
  name     = "/organizations/accounts/security"
}

# ✅ Resolve the value to break the dependency cycle
resource "terraform_data" "account_id" {
  input = data.aws_ssm_parameter.account_id.value
}

# ✅ Main provider with assume_role to security account
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [terraform_data.account_id.input]
  assume_role {
    role_arn     = "arn:aws:iam::${terraform_data.account_id.input}:role/OrganizationAccountAccessRole"
    session_name = "TerraformSecurity"
  }
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