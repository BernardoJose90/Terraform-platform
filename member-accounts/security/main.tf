###############################################################################
# Account: Security
# Purpose: GuardDuty delegated admin, Security Hub, IAM Access Analyzer
###############################################################################

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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

# Provider for reading SSM from the management account (cross-account role).
provider "aws" {
  alias  = "management"
  region = var.aws_region
  assume_role {
    role_arn = "arn:aws:iam::145678291484:role/SSMReadOnly"
  }
}

data "aws_ssm_parameter" "security_account_id" {
  provider = aws.management
  name     = "/organizations/accounts/security"
}

# Main provider for the security account itself, no profile needed.
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [data.aws_ssm_parameter.security_account_id.value]
}

module "terraform_deploy_boundary" {
  source = "../../modules/terraform-deploy-boundary"

  account_name          = "security"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "security" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"

  # This account's SSO/Identity Store admin work (sso.tf,
  # iam-supplemental.tf) — the one thing it does that no other account
  # does. GuardDuty/Security Hub/IAM Access Analyzer (see file header)
  # don't get a toggle: nothing in this repo manages them yet, so there's
  # nothing to grant permissions for — same fail-safe reasoning as
  # monitoring/main.tf's boundary comment.
  enable_sso_management = true
}

module "github-oidc-roles" {
  source       = "../../modules/github-oidc-roles"
  account_name = "security"

  github_org  = "BernardoJose90"
  github_repo = "Terraform-platform"

  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "security" # must match the backend "s3" key above
  role_name             = "TerraformDeploy"

  permissions_boundary_arn = module.terraform_deploy_boundary.arn
}