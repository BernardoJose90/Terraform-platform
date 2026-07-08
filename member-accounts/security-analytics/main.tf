###############################################################################
# Account: Security Analytics
# Email  : james.jose109099+aws-security-analytics@gmail.com
# Purpose: AI-generated analysis of medium/low severity security findings
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
    bucket       = "james-terraform-state-2026"           # same bucket as management
    key          = "security-analytics/terraform.tfstate" # different key
    region       = "eu-west-2"
    use_lockfile = true # native S3 locking
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
data "aws_ssm_parameter" "security_analytics_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/security_analytics"
}

# ✅ Provider for Development account - NO assume_role needed!
provider "aws" {
  region  = var.aws_region
  profile = "security-analytics" # 👈 Uses your SSO profile directly

  # ✅ This ensures we only deploy to the development account
  allowed_account_ids = [data.aws_ssm_parameter.security_analytics_account_id.value]
  
}

module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name = "security-analytics"
}
