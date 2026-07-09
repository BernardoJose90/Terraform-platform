###############################################################################
# Account: Production
# Email  : james.jose109099+aws-prod@gmail.com
# Purpose: Live workload hosting
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
    key          = "production/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

# ✅ Provider for reading SSM from management account (assumes cross-account role)
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

# ✅ Read the production account ID from SSM
data "aws_ssm_parameter" "production_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/production"
}

# ✅ Main provider for the production account itself — no profile needed
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.production_account_id.value]


}

module "vpc" {
  source = "../../modules/vpc"
  name   = "prod-vpc"
  cidr   = "10.40.0.0/16"
}

module "terraform_deploy_role" {
  source       = "../../modules/terraform-deploy-role"
  account_name = "production"

  # GitHub repository information (case-sensitive!)
  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  # AWS account configuration
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  role_name             = "TerraformDeploy"
}
