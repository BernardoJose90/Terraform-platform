##############################################################################
# Account: Security Analytics
# Purpose: AI-generated analysis of medium/low severity security findings
##############################################################################

terraform {
  required_version = "~> 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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

# Provider for reading SSM from the management account (cross-account role).
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

data "aws_ssm_parameter" "security_analytics_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/security_analytics"
}

# Main provider for the security_analytics account itself, no profile needed.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.security_analytics_account_id.value]

}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "security-analytics"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "security-analytics" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"
}
